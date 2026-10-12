defmodule PesqueWeb.MigrateTest do
  @moduledoc """
  The move form and the page that watches a move.

  The move itself runs off-request: a form answer opens a row and starts a
  task, so a test that reads the row while the move runs holds the old
  server's transport still, and a test that wants a phase writes the row
  directly through `Pesque.Migrate.Jobs`. The page is reached by path rather
  than by host, so a request names no host of its own.
  """

  use PesqueWeb.ConnCase, async: false

  import Ecto.Query

  alias Pesque.Migrate.Job
  alias Pesque.Migrate.Jobs
  alias Pesque.Repo

  @password "hunter2hunter2"

  # The move's client speaks through a transport this test can hold, so a row
  # read right after the redirect is not racing the task. It answers like an
  # unreachable old server would: nothing comes back, the move fails, and the
  # row lands on a failure the page has a sentence for.
  defmodule HeldTransport do
    def request(_uri, _method, _headers, _body, _opts) do
      Process.sleep(300)
      {:error, :held}
    end
  end

  setup do
    %{code: invite_code()}
  end

  defp invite_code do
    {:ok, [%{codes: [code]}]} = Accounts.create_invite_codes(1, 1, [])
    code
  end

  defp get_page(path) do
    build_conn() |> dispatch(Endpoint, :get, path, nil)
  end

  # The migrate bucket counts a request against the address it came from, and
  # every test would otherwise share the loopback's allowance for the hour the
  # suite runs in. An address of its own keeps a test to its own budget, which
  # is also the shape a request arrives in behind the proxy. The range is the
  # one reserved for documentation.
  defp post_form(params) do
    conn = build_conn() |> Map.put(:remote_ip, {203, 0, 113, unique_address()})
    dispatch(conn, Endpoint, :post, "/migrate", params)
  end

  defp post_code(token, params) do
    conn = build_conn() |> Map.put(:remote_ip, {203, 0, 113, unique_address()})
    dispatch(conn, Endpoint, :post, "/migrate/" <> token <> "/code", params)
  end

  defp unique_address, do: :erlang.unique_integer([:positive]) |> rem(253) |> Kernel.+(1)

  defp content_type(conn), do: conn |> get_resp_header("content-type") |> hd()

  test "the form asks where the account is now" do
    conn = get_page("/migrate")

    assert conn.status == 200
    assert content_type(conn) =~ "text/html"
    assert conn.resp_body =~ "trazer sua conta"
    assert conn.resp_body =~ "seu servidor atual"
    assert conn.resp_body =~ "código do convite"
    assert conn.resp_body =~ "seu nome e o DNS dele"
    refute conn.resp_body =~ "<script"
  end

  test "the path is not served where the server is its single account" do
    put_mode(:conformant_single)

    assert get_page("/migrate").status == 404
    assert post_form(%{"old_pds" => "https://old.example.com"}).status == 404
  end

  test "a filled form opens the move and answers the page that watches it", %{code: code} do
    put_transport(HeldTransport)

    conn = post_form(attrs(code, "https://old.example.com", "alice.localhost", "alice@localhost"))

    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    assert location =~ "/migrate/"
    token = String.replace_prefix(location, "/migrate/", "")

    assert %Job{phase: :running, handle: "alice.localhost"} = Jobs.get(token)

    # The move ends when the held transport does, and the row is read to its
    # face: nothing is left running behind the test to write into the next
    # one's database.
    assert %Job{phase: :failed} = await_phase(token, :failed)
  end

  test "a form with no code on a closed server renders the form again and opens nothing" do
    conn = post_form(attrs(nil, "https://old.example.com", "bob.localhost", "bob@localhost"))

    assert conn.status == 200
    assert conn.resp_body =~ "Esse código de convite não vale"
    assert job_count() == 0
  end

  test "an old server without https renders the form with what was typed still in it" do
    conn =
      post_form(%{
        "old_pds" => "http://old.example.com",
        "handle" => "carol.localhost",
        "email" => "carol@localhost",
        "password" => @password
      })

    assert conn.status == 200
    assert conn.resp_body =~ "O endereço do servidor antigo precisa começar com https://."
    assert conn.resp_body =~ ~s(value="http://old.example.com")
    assert conn.resp_body =~ ~s(value="carol.localhost")
    assert conn.resp_body =~ ~s(value="carol@localhost")
    assert job_count() == 0
  end

  test "a running move polls itself and names the facts" do
    {:ok, job} = Jobs.open("dan.localhost", "https://old.example.com")

    conn = get_page("/migrate/" <> job.token)

    assert conn.status == 200
    assert conn.resp_body =~ ~s(<meta http-equiv="refresh" content="3">)
    assert conn.resp_body =~ "trazendo sua conta"
    assert conn.resp_body =~ "dan.localhost"
    assert conn.resp_body =~ "https://old.example.com"
  end

  test "a move waiting on the code asks for it, and does not reload" do
    {:ok, job} = Jobs.open("erin.localhost", "https://old.example.com")
    {:ok, _} = Jobs.advance(job, :awaiting_code)

    conn = get_page("/migrate/" <> job.token)

    assert conn.status == 200
    assert conn.resp_body =~ "falta um código"
    assert conn.resp_body =~ ~s(autocomplete="one-time-code")
    assert conn.resp_body =~ "terminar a mudança"
    refute conn.resp_body =~ "http-equiv"
  end

  test "a finished move points at the app" do
    {:ok, job} = Jobs.open("frank.localhost", "https://old.example.com")
    {:ok, _} = Jobs.advance(job, :done)

    conn = get_page("/migrate/" <> job.token)

    assert conn.status == 200
    assert conn.resp_body =~ "pronto"
    assert conn.resp_body =~ "Sua conta agora é guardada aqui"
    assert conn.resp_body =~ "https://bsky.app"
  end

  test "a failed move says what to do next" do
    {:ok, job} = Jobs.open("gina.localhost", "https://old.example.com")
    {:ok, _} = Jobs.advance(job, :failed, "old_pds_unreachable")

    conn = get_page("/migrate/" <> job.token)

    assert conn.status == 200
    assert conn.resp_body =~ "não deu"
    assert conn.resp_body =~ "Não conseguimos falar com o servidor antigo"
    assert conn.resp_body =~ "Sua conta antiga continua funcionando"
    assert conn.resp_body =~ "começar de novo"
  end

  test "a failure the page cannot name falls back to the generic sentence" do
    {:ok, job} = Jobs.open("hugo.localhost", "https://old.example.com")
    {:ok, _} = Jobs.advance(job, :failed, "unknown")

    conn = get_page("/migrate/" <> job.token)

    assert conn.status == 200
    assert conn.resp_body =~ "Algo deu errado do nosso lado"
  end

  test "a code for a move that is no longer running says it took too long" do
    {:ok, job} = Jobs.open("ivan.localhost", "https://old.example.com")
    {:ok, _} = Jobs.advance(job, :awaiting_code)

    conn = post_code(job.token, %{"code" => "123456"})

    assert conn.status == 200
    assert conn.resp_body =~ "O código demorou demais pra chegar"
  end

  test "a code for a token nothing names is not found" do
    assert post_code("no-such-token", %{"code" => "123456"}).status == 404
  end

  defp attrs(code, old_pds, handle, email) do
    %{
      "invite_code" => code,
      "old_pds" => old_pds,
      "handle" => handle,
      "email" => email,
      "password" => @password
    }
  end

  defp job_count, do: Repo.one(from j in Job, select: count(j.id))

  defp put_transport(module) do
    Application.put_env(:pesque, :migrate_fetch, module)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:pesque, :migrate_fetch)
    end)
  end

  # The row is the only state a page sees, so the test waits on the row rather
  # than on a message: the move runs in a task this process does not own.
  defp await_phase(token, phase, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    case Jobs.get(token) do
      %Job{phase: ^phase} = row ->
        row

      _other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("the move never reached #{inspect(phase)}")
        end

        Process.sleep(10)
        await_phase(token, phase, deadline)
    end
  end
end
