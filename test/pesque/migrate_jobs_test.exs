defmodule Pesque.Migrate.JobsTest do
  @moduledoc """
  A move that runs off-request, driven end to end with the old PDS faked.

  The row is what a page watches, so the assertions read the row: it opens
  with a token, waits in `:awaiting_code` for the code the account holder
  received, and ends in `:done` or in `:failed` with the reason the move
  gave. The runner advances it, so the row is driven through
  `Pesque.Migrate.Runner` with a real move under a faked old PDS, in the task
  the runner starts.
  """

  use Pesque.DataCase, async: false

  alias Pesque.Accounts
  alias Pesque.Car
  alias Pesque.CID
  alias Pesque.Migrate.Job
  alias Pesque.Migrate.Jobs
  alias Pesque.Migrate.Runner
  alias Pesque.RepoServer
  alias Pesque.RepoStore
  alias Pesque.RepoSupervisor

  @password "hunter2hunter2"

  setup do
    restore_env()
    Application.put_env(:pesque, :mode, :multi)
    Application.put_env(:pesque, :identity, :plc)
    Application.put_env(:pesque, :plc_client, Pesque.Plc.TestClient)
    Pesque.FakeStore.put(:plc_submit_result, :ok)
    :ok
  end

  test "open mints a token and get reads the row back" do
    assert {:ok, job} = Jobs.open("alice.localhost", "https://old.example.com")
    assert job.phase == :running
    assert job.handle == "alice.localhost"
    assert job.old_pds == "https://old.example.com"
    assert is_binary(job.token) and job.token != ""

    assert %Job{id: id} = Jobs.get(job.token)
    assert id == job.id

    assert Jobs.get("no-such-token") == nil
    assert Jobs.get(nil) == nil
    assert Jobs.get(1234) == nil
  end

  test "the runner drives a whole move and the row ends done" do
    did = old_did()
    handle = unique("alice") <> ".localhost"
    configure_happy_path(did, handle)

    {:ok, job} = Jobs.open(handle, "https://old.example.com")
    assert :ok = Runner.start(job, move_opts(handle))

    await_phase(job.token, :awaiting_code)
    assert :ok = Runner.submit_code(job.token, "email-code")

    {:ok, row} = await_phase(job.token, :done)
    assert row.error == nil
    assert Accounts.get_user(did).active
  end

  test "the move waits in awaiting_code and a token with nothing registered is not running" do
    did = old_did()
    handle = unique("bob") <> ".localhost"
    configure_happy_path(did, handle)

    {:ok, job} = Jobs.open(handle, "https://old.example.com")
    assert :ok = Runner.start(job, move_opts(handle))

    {:ok, row} = await_phase(job.token, :awaiting_code)
    assert row.phase == :awaiting_code

    assert {:error, :not_running} = Runner.submit_code("nobody-holds-this", "email-code")

    assert :ok = Runner.submit_code(job.token, "email-code")
    await_phase(job.token, :done)
  end

  test "a move the domain refuses ends failed with the code the reason maps to" do
    did = old_did()
    handle = unique("carol") <> ".localhost"
    configure_happy_path(did, handle)

    {:ok, job} = Jobs.open(handle, "https://old.example.com")

    assert :ok = Runner.start(job, move_opts(handle) ++ [invite_code: "not-a-real-code"])

    {:ok, row} = await_phase(job.token, :failed)
    assert row.error == "invalid_invite_code"
  end

  test "reap marks the moves a restart left behind and counts them" do
    {:ok, running} = Jobs.open("dan.localhost", "https://old.example.com")

    {:ok, waiting} = Jobs.open("erin.localhost", "https://old.example.com")
    {:ok, _} = Jobs.advance(waiting, :awaiting_code)

    {:ok, finished} = Jobs.open("frank.localhost", "https://old.example.com")
    {:ok, _} = Jobs.advance(finished, :done)

    assert 2 = Jobs.reap_interrupted()

    assert %Job{phase: :failed, error: "interrupted"} = Jobs.get(running.token)
    assert %Job{phase: :failed, error: "interrupted"} = Jobs.get(waiting.token)
    assert %Job{phase: :done, error: nil} = Jobs.get(finished.token)
  end

  # The row is the only state a page sees, so the tests wait on the row rather
  # than on a message: the move runs in a task this process does not own.
  defp await_phase(token, phase, deadline \\ System.monotonic_time(:millisecond) + 10_000)

  defp await_phase(token, phase, deadline) do
    case Jobs.get(token) do
      %Job{phase: ^phase} = row ->
        {:ok, row}

      _other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk(
            "the move never reached #{inspect(phase)}; the row reads #{inspect(Jobs.get(token))}"
          )
        end

        Process.sleep(10)
        await_phase(token, phase, deadline)
    end
  end

  defp move_opts(handle) do
    [
      old_pds: "https://old.example.com",
      handle: handle,
      email: handle <> "@localhost",
      password: @password,
      client: Pesque.Migrate.FakeOldPds,
      log: fn _line -> :ok end
    ]
  end

  defp configure_happy_path(did, handle) do
    Pesque.FakeStore.put(
      :fake_create_session,
      {:ok, %{access_jwt: "access", did: did, handle: handle}}
    )

    Pesque.FakeStore.put(:fake_repo_car, source_car())
    Pesque.FakeStore.put(:fake_blobs, {:ok, [blob_cid()]})
    Pesque.FakeStore.put(:fake_blob, {:ok, "blob bytes", "text/plain"})
    Pesque.FakeStore.put(:plc_resolve_result, {:ok, pds_document(did)})
  end

  # The CID the fake's bytes hash to, so a re-run finds the stored blob under
  # the same CID listBlobs named, as real content addressing guarantees.
  defp blob_cid, do: CID.to_string(CID.from_data("blob bytes", CID.raw()))

  # A real CAR, built from a throwaway account's genesis repo, so
  # Car.decode_repo and RepoImport.persist_import run against bytes a repo
  # actually exports.
  defp source_car do
    {:ok, user} = Accounts.create_account("source.localhost", "source@localhost", @password)
    {:ok, pid} = RepoSupervisor.ensure_started(user.did)
    RepoServer.entries(pid)

    commit = RepoStore.get_meta("commit:" <> user.did)

    blocks =
      user.did
      |> RepoStore.blocks_for()
      |> Map.new(fn block -> {CID.parse(block.cid), block.data} end)

    Car.encode([CID.parse(commit)], blocks)
  end

  defp pds_document(did) do
    %{
      "service" => [
        %{
          "id" => did <> "#atproto_pds",
          "type" => "AtprotoPersonalDataServer",
          "serviceEndpoint" => Pesque.service_endpoint()
        }
      ]
    }
  end

  defp old_did, do: "did:plc:" <> Pesque.Base32.encode(:crypto.strong_rand_bytes(15))

  defp unique(prefix), do: prefix <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp restore_env do
    previous = Application.get_all_env(:pesque)

    on_exit(fn ->
      Enum.each([:mode, :identity, :plc_client], &Application.delete_env(:pesque, &1))
      Enum.each(previous, fn {key, value} -> Application.put_env(:pesque, key, value) end)
    end)
  end
end
