defmodule Pesque.BlockOwnershipTest do
  use ExUnit.Case, async: false

  alias Pesque.{CID, Car, Repo, RepoServer, RepoStore, Varint}
  alias Pesque.Accounts.User

  setup do
    alice = account("alice")
    bob = account("bob")

    start_repo(alice.did)
    start_repo(bob.did)

    %{alice: alice, bob: bob}
  end

  test "an identical block is stored once per did, not once per cid", %{alice: alice, bob: bob} do
    root = RepoStore.get_meta("root:" <> alice.did)

    assert root == RepoStore.get_meta("root:" <> bob.did)
    assert RepoStore.existing_cids(alice.did, [root]) == MapSet.new([root])
    assert RepoStore.existing_cids(bob.did, [root]) == MapSet.new([root])
  end

  test "the second account's repo CAR carries its genesis root block", %{bob: bob} do
    blocks = bob.did |> repo_car() |> car_blocks()
    root = CID.parse(RepoStore.get_meta("root:" <> bob.did))
    commit = CID.parse(RepoStore.get_meta("commit:" <> bob.did))

    assert is_binary(blocks[root])
    assert is_binary(blocks[commit])
  end

  defp account(name) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    %{
      did: "did:web:localhost:user:" <> name <> suffix,
      handle: name <> suffix <> ".localhost",
      email: name <> suffix <> "@localhost",
      password_hash: "not-a-real-hash"
    }
    |> User.changeset()
    |> Repo.insert!()
  end

  # A call round trip, not the pid, guarantees the genesis commit in
  # handle_continue/2 has already run.
  defp start_repo(did) do
    {:ok, pid} = Pesque.RepoSupervisor.ensure_started(did)
    RepoServer.entries(pid)
    pid
  end

  defp repo_car(did) do
    blocks = Map.new(RepoStore.blocks_for(did), fn b -> {CID.parse(b.cid), b.data} end)
    commit = RepoStore.get_meta("commit:" <> did)

    Car.encode([CID.parse(commit)], blocks)
  end

  defp car_blocks(car) do
    {header_len, rest} = Varint.decode(car)
    <<_header::binary-size(^header_len), sections::binary>> = rest

    Enum.reduce(split_sections(sections), %{}, fn {_len, payload}, acc ->
      {_version, r1} = Varint.decode(payload)
      {_codec, r2} = Varint.decode(r1)
      {_algo, r3} = Varint.decode(r2)
      {digest_len, r4} = Varint.decode(r3)
      cid_len = byte_size(payload) - byte_size(r4) + digest_len
      <<cid_bytes::binary-size(^cid_len), bytes::binary>> = payload
      Map.put(acc, CID.from_bytes(cid_bytes), bytes)
    end)
  end

  defp split_sections(<<>>), do: []

  defp split_sections(bin) do
    {len, rest} = Varint.decode(bin)
    <<payload::binary-size(^len), tail::binary>> = rest
    [{len, payload} | split_sections(tail)]
  end
end
