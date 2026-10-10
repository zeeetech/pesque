defmodule Pesque.Migrate.HttpTest do
  @moduledoc """
  The real old-PDS client against a throwaway local server.

  The orchestration is tested with `FakeOldPds`, which cannot see the wire, and
  two moves have already broken there: listBlobs pages and bsky redirects sync
  reads to the account's own host. So these drive `Pesque.Migrate.Http` itself,
  at the socket, with no test-only seam.
  """

  use ExUnit.Case, async: false

  alias Pesque.Migrate.Http

  test "list_blobs reads every page, not just the first" do
    base =
      serve(fn _base ->
        [
          {200, [], ~s({"cids":["bafkqaaa","bafkqaab"],"cursor":"page-2"})},
          {200, [], ~s({"cids":["bafkqake"]})}
        ]
      end)

    assert {:ok, ["bafkqaaa", "bafkqaab", "bafkqake"]} =
             Http.list_blobs(base, "jwt", "did:plc:example")
  end

  test "a read follows a redirect to the host that serves the bytes" do
    base =
      serve(fn base ->
        [
          {302, [{"location", base <> "/served"}], ""},
          {200, [], "the repo bytes"}
        ]
      end)

    assert {:ok, "the repo bytes"} = Http.get_repo(base, "jwt", "did:plc:example")
  end

  # A one-connection-at-a-time HTTP server: it answers each request with the
  # next canned response, then closes, so a read that follows a redirect or a
  # cursor reaches the next response on a fresh connection.
  defp serve(build) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    base = "http://127.0.0.1:#{port}"
    pid = spawn_link(fn -> accept(listen, build.(base)) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    base
  end

  defp accept(_listen, []), do: Process.sleep(:infinity)

  defp accept(listen, [response | rest]) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, socket} ->
        read_head(socket, "")
        :ok = :gen_tcp.send(socket, encode(response))
        :gen_tcp.close(socket)
        accept(listen, rest)

      {:error, _reason} ->
        :ok
    end
  end

  defp read_head(socket, buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      :nomatch ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, chunk} -> read_head(socket, buffer <> chunk)
          {:error, _reason} -> buffer
        end

      _found ->
        buffer
    end
  end

  defp encode({status, headers, body}) do
    reason = if status == 200, do: "OK", else: "Redirect"

    lines = Enum.map_join(headers, fn {name, value} -> "#{name}: #{value}\r\n" end)

    "HTTP/1.1 #{status} #{reason}\r\n" <>
      lines <>
      "content-type: application/json\r\n" <>
      "content-length: #{byte_size(body)}\r\n" <>
      "connection: close\r\n\r\n" <> body
  end
end
