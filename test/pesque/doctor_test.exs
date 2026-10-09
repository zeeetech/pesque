defmodule Pesque.DoctorTest do
  use ExUnit.Case, async: false

  alias Pesque.Doctor
  alias Pesque.Identity

  setup do
    previous = Application.get_env(:pesque, :hostname)
    previous_crawlers = Application.get_env(:pesque, :crawlers)
    Application.put_env(:pesque, :hostname, "pds.example.com")
    Application.put_env(:pesque, :crawlers, ["https://bsky.network"])

    on_exit(fn ->
      Application.put_env(:pesque, :hostname, previous)
      Application.put_env(:pesque, :crawlers, previous_crawlers)
    end)

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

        String.contains?(url, "getHostStatus") ->
          {:ok, 200, JSON.encode!(host_status(1))}

        true ->
          {:ok, 404, ""}
      end
    end
  end

  defp host_status(account_count) do
    %{
      "hostname" => "pds.example.com",
      "status" => "active",
      "accountCount" => account_count,
      "seq" => if(account_count > 0, do: 42, else: -1)
    }
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
    assert Enum.map(all_ok(), &elem(&1, 0)) == [:ok, :ok, :ok, :ok, :ok, :ok, :ok]
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

  test "a relay that holds the host but no accounts warns" do
    http = fn url ->
      if String.contains?(url, "getHostStatus"),
        do: {:ok, 200, JSON.encode!(host_status(0))},
        else: http_ok().(url)
    end

    assert status(all_ok(http: http), "relay") == :warn
  end

  test "a relay that cannot be reached warns" do
    http = fn url ->
      if String.contains?(url, "getHostStatus"),
        do: {:error, :timeout},
        else: http_ok().(url)
    end

    assert status(all_ok(http: http), "relay") == :warn
  end

  test "no crawler configured warns rather than passing silently" do
    Application.put_env(:pesque, :crawlers, [])

    assert status(all_ok(), "relay") == :warn
  end

  test "the config file check names the file it read" do
    path =
      Path.join(System.tmp_dir!(), "pesque-doctor-#{System.unique_integer([:positive])}.conf")

    File.write!(path, "hostname = pds.example.com\n")
    previous = System.get_env("PDS_CONFIG")
    System.put_env("PDS_CONFIG", path)

    on_exit(fn ->
      File.rm(path)

      if previous,
        do: System.put_env("PDS_CONFIG", previous),
        else: System.delete_env("PDS_CONFIG")
    end)

    {state, _title, detail} = Enum.find(all_ok(), &(elem(&1, 1) == "config file"))
    assert state == :ok
    assert detail =~ "is read"
  end

  test "the config file check says so when there is no file" do
    previous = System.get_env("PDS_CONFIG")
    System.put_env("PDS_CONFIG", "/nonexistent/pesque.conf")

    on_exit(fn ->
      if previous,
        do: System.put_env("PDS_CONFIG", previous),
        else: System.delete_env("PDS_CONFIG")
    end)

    {state, _title, detail} = Enum.find(all_ok(), &(elem(&1, 1) == "config file"))
    assert state == :ok
    assert detail =~ "no file at"
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
