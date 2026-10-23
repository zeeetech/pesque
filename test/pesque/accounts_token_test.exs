defmodule Pesque.Accounts.TokenTest do
  @moduledoc """
  The shape of an issued code, and the normalisation a presented one goes
  through.

  The lexicon calls a token an opaque string, but the official client validates
  it before the request is ever sent (`^[A-Z2-7]{5}-[A-Z2-7]{5}$`), so a server
  that mints any other shape is unreachable from that client for confirmEmail,
  updateEmail, resetPassword, deleteAccount and signPlcOperation. These pin the
  shape at the issuer and the canonicalisation at the reader.
  """

  use ExUnit.Case, async: false

  alias Pesque.Accounts.Token

  @did "did:plc:token-test"
  @code ~r/^[A-Z2-7]{5}-[A-Z2-7]{5}$/

  setup do
    Pesque.DataCase.setup()
    :ok
  end

  describe "issue/4" do
    test "mints the base32 shape the official client requires, for every purpose" do
      for purpose <- Token.purposes() do
        assert {:ok, %{token: token}} = Token.issue(purpose, @did, 60)
        assert token =~ @code, "#{purpose} minted #{inspect(token)}"
      end
    end

    test "uses only the base32 alphabet, never 0, 1, 8 or 9" do
      tokens = for _ <- 1..100, do: issue!()

      refute Enum.any?(tokens, &String.contains?(&1, ["0", "1", "8", "9"]))
    end

    test "does not repeat a code" do
      tokens = for _ <- 1..100, do: issue!()

      assert length(Enum.uniq(tokens)) == length(tokens)
    end

    test "a code is bound to the purpose it was minted for" do
      {:ok, %{token: token}} = Token.issue(:email, @did, 60)

      assert {:error, :invalid_token} = Token.fetch(:reset_password, token, @did)
      assert {:ok, _row} = Token.fetch(:email, token, @did)
    end
  end

  describe "fetch/3" do
    test "matches the canonical code the client sends" do
      {:ok, %{token: token}} = Token.issue(:email, @did, 60)

      assert {:ok, _row} = Token.fetch(:email, token, @did)
    end

    test "accepts the code lowercased" do
      {:ok, %{token: token}} = Token.issue(:email, @did, 60)

      assert {:ok, _row} = Token.fetch(:email, String.downcase(token), @did)
    end

    test "accepts the code without the dash" do
      {:ok, %{token: token}} = Token.issue(:email, @did, 60)

      assert {:ok, _row} = Token.fetch(:email, String.replace(token, "-", ""), @did)
    end

    test "accepts the code with stray whitespace" do
      {:ok, %{token: token}} = Token.issue(:email, @did, 60)

      assert {:ok, _row} = Token.fetch(:email, "  #{token}\n", @did)
    end

    test "refuses a code that names no row" do
      assert {:error, :invalid_token} = Token.fetch(:email, "ZZZZZ-ZZZZZ", @did)
    end
  end

  describe "normalize/1" do
    test "canonicalises the shapes a caller may paste" do
      assert Token.normalize("abcde-fghij") == "ABCDE-FGHIJ"
      assert Token.normalize("abcdefghij") == "ABCDE-FGHIJ"
      assert Token.normalize(" ABCDE-FGHIJ ") == "ABCDE-FGHIJ"
      assert Token.normalize("ABCDE FGHIJ") == "ABCDE-FGHIJ"
    end

    test "leaves anything that is not ten alphabet characters compacted" do
      refute Token.normalize("nope") =~ @code
      refute Token.normalize("") =~ @code
      # 0, 1, 8 and 9 are outside the alphabet, so this collapses below ten.
      refute Token.normalize("0123456789") =~ @code
    end
  end

  defp issue! do
    {:ok, %{token: token}} = Token.issue(:email, @did, 60)
    token
  end
end
