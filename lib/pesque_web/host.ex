defmodule PesqueWeb.Host do
  @moduledoc """
  Which of the names a request may arrive under.

  A request reaches this server either at a name that is the server itself or
  at a handle it hosts. The question is asked in more than one place, so the
  rule lives here once: the identity controller answers a DID for the name on
  the wire, and the page controller decides between the landing and a handle
  page. They pass different name lists on purpose, because a handle domain set
  apart from the hostname is a handle name, not the server's own.
  """

  @doc """
  Whether `host` is one of `server_names`.

  The host on the wire never carries a port, while a configured name can under
  a non-default port, so the port is dropped from both sides before the
  comparison. Both are lowercased because DNS names are case-insensitive.
  """
  @spec server_host?(binary(), [binary()]) :: boolean()
  def server_host?(host, server_names) when is_binary(host) do
    normalize(host) in Enum.map(server_names, &normalize/1)
  end

  defp normalize(name), do: name |> String.split(":", parts: 2) |> hd() |> String.downcase()
end
