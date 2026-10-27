defmodule Pesque.HandleAvailabilityTest do
  @moduledoc """
  The reads behind the two new endpoints: handle_available?/1 and
  handle_suggestions/2 for checkHandleAvailability, invite_codes_for/2 for
  getAccountInviteCodes.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Pesque.Accounts
  alias Pesque.Accounts.InviteCode
  alias Pesque.Repo

  @password "hunter2hunter2"

  setup do
    Pesque.DataCase.setup()
    put_mode(:multi)
    :ok
  end

  describe "handle_available?/1" do
    test "a free handle under this server's domain is available" do
      assert Accounts.handle_available?(label() <> ".localhost")
    end

    test "a handle an account holds is not available" do
      refute Accounts.handle_available?(account().handle)
    end

    test "a handle another account holds as an email is not available" do
      email = label() <> ".localhost"
      {:ok, _} = Accounts.create_account(label() <> ".localhost", email, @password)

      refute Accounts.handle_available?(email)
    end

    test "a handle on a foreign domain is not available" do
      refute Accounts.handle_available?(label() <> ".example.com")
    end

    test "a malformed label is not available" do
      refute Accounts.handle_available?("!!!" <> ".localhost")
    end
  end

  describe "handle_suggestions/2" do
    test "suggestions are available and never the input" do
      taken = account().handle

      suggestions = Accounts.handle_suggestions(taken)

      assert suggestions != []

      for %{"handle" => handle, "method" => method} <- suggestions do
        refute handle == taken
        assert is_binary(method)
        assert Accounts.handle_available?(handle)
      end
    end

    test "the email's local part is offered" do
      taken = account().handle

      assert %{"handle" => "coolname.localhost", "method" => "email"} in Accounts.handle_suggestions(
               taken,
               "coolname@example.com"
             )
    end

    test "a foreign handle has no local suggestions" do
      assert Accounts.handle_suggestions("someone.example.com") == []
    end
  end

  describe "invite_codes_for/2" do
    test "answers the codes earmarked for the account" do
      user = account()
      {:ok, [%{codes: [code]}]} = Accounts.create_invite_codes(1, 1, [user.did])

      assert [%{code: ^code}] = Accounts.invite_codes_for(user.did)
    end

    test "a code created for nobody belongs to no account" do
      user = account()
      {:ok, _} = Accounts.create_invite_codes(1, 1, [])

      assert Accounts.invite_codes_for(user.did) == []
    end

    test "include_used false drops a code with no uses left" do
      user = account()
      {:ok, [%{codes: [code]}]} = Accounts.create_invite_codes(1, 1, [user.did])

      Repo.update_all(from(i in InviteCode, where: i.code == ^code), set: [uses: 1])

      assert Accounts.invite_codes_for(user.did, include_used: false) == []
      assert [%{code: ^code}] = Accounts.invite_codes_for(user.did)
    end
  end

  defp account do
    {:ok, user} =
      Accounts.create_account(label() <> ".localhost", label() <> "@localhost", @password)

    user
  end

  defp label, do: "h" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp put_mode(mode) do
    previous = Application.get_env(:pesque, :mode)
    on_exit(fn -> Application.put_env(:pesque, :mode, previous) end)
    Application.put_env(:pesque, :mode, mode)
  end
end
