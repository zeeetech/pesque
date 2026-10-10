defmodule Pesque.Migrate.HttpTest do
  @moduledoc """
  The real old-PDS client against a throwaway local server.

  The orchestration is tested with `FakeOldPds`, which cannot see the wire, and
  three moves have already broken there: listBlobs pages, bsky redirects sync
  reads to the account's own host, and the sign call moved out of the `server`
  namespace. So these drive `Pesque.Migrate.Http` itself, at the socket, and
  assert the request line it actually sends.
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

    assert requested() == [
             "GET /xrpc/com.atproto.sync.listBlobs?did=did%3Aplc%3Aexample HTTP/1.1",
             "GET /xrpc/com.atproto.sync.listBlobs?did=did%3Aplc%3Aexample&cursor=page-2 HTTP/1.1"
           ]
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
    assert Enum.at(requested(), 1) == "GET /served HTTP/1.1"
  end

  test "sign_plc_operation posts to the identity endpoint, not the old server one" do
    base = serve(fn _base -> [{200, [], ~s({"operation":{"type":"plc_operation"}})}] end)

    assert {:ok, %{"type" => "plc_operation"}} =
             Http.sign_plc_operation(base, "jwt", %{"alsoKnownAs" => []}, "the-code")

    assert requested() == ["POST /xrpc/com.atproto.identity.signPlcOperation HTTP/1.1"]
  end

  # A one-connection-at-a-time HTTP server: it answers each request with the
  # next canned response, then closes, so a read that follows a redirect or a
  # cursor reaches the next response on a fresh connection.
  defp serve(build) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    base = "http://127.0.0.1:#{port}"
    test = self()
    pid = spawn_link(fn -> accept(listen, build.(base), test) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    base
  end

  defp accept(_listen, [], _test), do: Process.sleep(:infinity)

  defp accept(listen, [response | rest], test) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, socket} ->
        head = read_request(socket)
        send(test, {:request, head |> String.split("\r\n") |> hd()})
        :ok = :gen_tcp.send(socket, encode(response))
        :gen_tcp.close(socket)
        accept(listen, rest, test)

      {:error, _reason} ->
        :ok
    end
  end

  defp read_request(socket, buffer \\ "") do
    case :binary.match(buffer, "\r\n\r\n") do
      :nomatch ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, chunk} -> read_request(socket, buffer <> chunk)
          {:error, _reason} -> buffer
        end

      {pos, 4} ->
        head = binary_part(buffer, 0, pos)
        rest = binary_part(buffer, pos + 4, byte_size(buffer) - pos - 4)
        drain_body(socket, head, rest)
        head
    end
  end

  # A POST body must be read before the connection closes, or the client errors
  # writing it instead of reading the response.
  defp drain_body(socket, head, rest) do
    case content_length(head) do
      size when is_integer(size) and byte_size(rest) < size ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, chunk} -> drain_body(socket, head, rest <> chunk)
          {:error, _reason} -> :ok
        end

      _ ->
        :ok
    end
  end

  defp content_length(head) do
    head
    |> String.split("\r\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(String.trim(name)) == "content-length",
            do: String.to_integer(String.trim(value))

        _ ->
          nil
      end
    end)
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

  defp requested(acc \\ []) do
    receive do
      {:request, line} -> requested([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
