defmodule Pesque.Migrate.TestTransport do
  @moduledoc """
  The plain transport the migration client's socket tests speak through.

  `Pesque.OAuth.Fetch` is what production uses, and it refuses anything but a
  public https address, which a throwaway server on loopback is not. The tests
  that drive `Pesque.Migrate.Http` at the socket inject this instead: the same
  request, the same response shape, no policy. What they assert is still the
  request line the client sends and the redirect it follows, and the policy
  stays where it belongs.
  """

  @connect_timeout 5_000
  @timeout 30_000

  @doc "Makes one request and answers the shape `Pesque.OAuth.Fetch.request/5` does."
  def request(%URI{} = uri, method, headers, body, _opts) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    {content_type, headers} = split_content_type(headers)

    request =
      case method do
        :get -> {URI.to_string(uri), charlist(headers)}
        :post -> {URI.to_string(uri), charlist(headers), to_charlist(content_type), body}
      end

    options = [
      connect_timeout: @connect_timeout,
      timeout: @timeout,
      # The client owns the redirect loop, so the transport hands the 3xx back
      # rather than chasing it.
      autoredirect: false
    ]

    case :httpc.request(method, request, options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
        {:ok, status, normalize(response_headers), IO.iodata_to_binary(response_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp split_content_type(headers) do
    case List.keyfind(headers, "content-type", 0) do
      {_name, value} -> {value, List.keydelete(headers, "content-type", 0)}
      nil -> {"application/json", headers}
    end
  end

  defp charlist(headers) do
    Enum.map(headers, fn {name, value} -> {to_charlist(name), to_charlist(value)} end)
  end

  defp normalize(headers) do
    Enum.map(headers, fn {name, value} -> {to_string(name), to_string(value)} end)
  end
end
