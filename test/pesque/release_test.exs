defmodule Pesque.ReleaseTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pesque.Release

  describe "describe_error/1" do
    test "turns the account errors a person can hit into sentences" do
      assert Release.describe_error(:handle_not_available) =~ "handle"
      assert Release.describe_error(:account_exists) =~ "already has an account"
      assert Release.describe_error(:password_too_short) =~ "8 characters"
      assert Release.describe_error(:email_required) =~ "email"
    end

    test "falls back to inspect for a reason it does not know" do
      assert Release.describe_error({:unexpected, 42}) == "{:unexpected, 42}"
    end

    test "names the old PDS's own message, so a bare status is not all a caller sees" do
      assert Release.describe_error({:old_pds_status, 400, "A request body was provided"}) =~
               "the old PDS answered 400: A request body was provided"

      assert Release.describe_error({:old_pds_status, 401}) == "the old PDS answered 401"
    end
  end

  describe "create_account_from_env/0" do
    setup do
      Pesque.DataCase.setup()

      previous = Application.get_all_env(:pesque)

      on_exit(fn ->
        Enum.each(previous, fn {key, value} -> Application.put_env(:pesque, key, value) end)
      end)

      Application.put_env(:pesque, :mode, :path_multi)
      Application.put_env(:pesque, :identity, :plc)
      Application.put_env(:pesque, :plc_client, Pesque.Plc.TestClient)
      Application.put_env(:pesque, :hostname, "pds.example.com")
      Application.put_env(:pesque, :handle_domain, "pds.example.com")

      put_account_env("alice.pds.example.com", "alice@example.com")
      on_exit(&clear_env/0)
    end

    test "prints the account and the DNS records to add, not the raw tuple" do
      output = capture_io(fn -> assert Release.create_account_from_env() == :ok end)

      assert output =~ "Account created."
      assert output =~ "alice.pds.example.com"
      assert output =~ "did:plc:"
      assert output =~ "_atproto.alice.pds.example.com   TXT"
      assert output =~ "203.0.113.7"
      refute output =~ "{:ok"
    end

    test "reports a taken handle as a sentence, and answers :error" do
      capture_io(fn -> assert Release.create_account_from_env() == :ok end)

      stderr =
        capture_io(:stderr, fn ->
          assert Release.create_account_from_env() == :error
        end)

      assert stderr =~ "Could not create the account"
      assert stderr =~ "handle"
    end
  end

  defp put_account_env(handle, email) do
    System.put_env("ACCOUNT_HANDLE", handle)
    System.put_env("ACCOUNT_EMAIL", email)
    System.put_env("ACCOUNT_PASSWORD", "hunter2hunter2")
    System.put_env("PDS_PUBLIC_IP", "203.0.113.7")
  end

  defp clear_env do
    for key <- ["ACCOUNT_HANDLE", "ACCOUNT_EMAIL", "ACCOUNT_PASSWORD", "PDS_PUBLIC_IP"] do
      System.delete_env(key)
    end
  end
end
