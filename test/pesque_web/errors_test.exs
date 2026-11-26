defmodule PesqueWeb.ErrorsTest do
  @moduledoc """
  The reason the write path gained after RepoSupervisor learned to wait out
  the Registry gap: a repo that is starting answers 503, the same retry a
  busy repo asks for, rather than a MatchError no client can act on.
  """

  use ExUnit.Case, async: true

  alias PesqueWeb.Xrpc.Errors

  test "a repo that is starting answers the retry :busy asks for" do
    assert Errors.to_xrpc(:unavailable) ==
             {503, "InternalServerError", "the repo is starting, retry the request"}
  end

  test "a nonce demand answers the OAuth code a client retries on, not the generic auth name" do
    assert Errors.to_xrpc(:use_dpop_nonce) ==
             {401, "use_dpop_nonce", "the DPoP proof needs the server nonce"}
  end

  test "an event sequence collision is retryable" do
    assert Errors.to_xrpc(:event_seq_taken) == Errors.to_xrpc(:busy)
  end

  test "sync size limits answer InvalidRequest with the enforced bound" do
    for {reason, limit} <- [
          too_many_ops: 200,
          record_too_large: 1_000_000,
          commit_too_large: 2_000_000,
          frame_too_large: 5_000_000,
          sync_too_large: 10_000
        ] do
      assert {400, "InvalidRequest", message} = Errors.to_xrpc(reason)
      assert message =~ Integer.to_string(limit)
    end
  end
end
