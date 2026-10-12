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
end
