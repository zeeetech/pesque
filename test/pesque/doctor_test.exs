defmodule Pesque.DoctorTest do
  use ExUnit.Case, async: false

  alias Pesque.Doctor
  alias Pesque.Identity

  setup do
    previous = Application.get_env(:pesque, :hostname)
    Application.put_env(:pesque, :hostname, "pds.example.com")
    on_exit(fn -> Application.put_env(:pesque, :hostname, previous) end)
    :ok
  end

  defp did_document do
    %{
      "id" => Identity.did(),
      "verificationMethod" => [
        %{
          "id" => Identity.did() <> "#atproto",
          "publicKeyMultibase" => Identity.public_key_multibase()
        }
      ]
    }
  end

  defp http_ok do
    fn url ->
      cond do
        String.ends_with?(url, "describeServer") ->
          {:ok, 200, JSON.encode!(%{"did" => Identity.did()})}

        String.ends_with?(url, "/.well-known/did.json") ->
          {:ok, 200, JSON.encode!(did_document())}

        true ->
          {:ok, 404, ""}
      end
    end
  end

  defp all_ok(overrides \\ []) do
    Doctor.checks(
      http: Keyword.get(overrides, :http, http_ok()),
      resolver: Keyword.get(overrides, :resolver, fn _host -> {:ok, ["203.0.113.7"]} end),
      resolves: Keyword.get(overrides, :resolves, fn _handle, _did -> true end)
    )
  end

  defp status(results, title),
    do: Enum.find_value(results, &if(elem(&1, 1) == title, do: elem(&1, 0)))

  test "every check passes when the server answers as it should" do
    assert Enum.map(all_ok(), &elem(&1, 0)) == [:ok, :ok, :ok, :ok, :ok]
  end

  test "a describeServer did that is not this server's fails" do
    http = fn url ->
      if String.ends_with?(url, "describeServer") do
        {:ok, 200, JSON.encode!(%{"did" => "did:web:someone.else"})}
      else
        http_ok().(url)
      end
    end

    assert status(all_ok(http: http), "describeServer") == :fail
  end

  test "a did document that publishes a different key fails" do
    http = fn url ->
      if String.ends_with?(url, "/.well-known/did.json") do
        document = %{
          "verificationMethod" => [%{"id" => "x#atproto", "publicKeyMultibase" => "zWrong"}]
        }

        {:ok, 200, JSON.encode!(document)}
      else
        http_ok().(url)
      end
    end

    assert status(all_ok(http: http), "did document") == :fail
  end

  test "a handle that does not resolve fails" do
    assert status(all_ok(resolves: fn _handle, _did -> false end), "handle") == :fail
  end

  test "a hostname that does not resolve fails the dns check" do
    assert status(all_ok(resolver: fn _host -> :error end), "dns") == :fail
  end

  test "an IP hostname warns on configuration and fails dns" do
    Application.put_env(:pesque, :hostname, "192.241.176.198")
    results = all_ok()

    assert status(results, "configuration") == :warn
    assert status(results, "dns") == :fail
  end

  describe "Pesque.hostname_is_ip?/0" do
    test "is true for an address and false for a name" do
      Application.put_env(:pesque, :hostname, "192.241.176.198")
      assert Pesque.hostname_is_ip?()

      Application.put_env(:pesque, :hostname, "pds.example.com")
      refute Pesque.hostname_is_ip?()
    end
  end
end
