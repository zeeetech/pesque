defmodule PesqueWeb.Xrpc.Params do
  @moduledoc """
  The one paging shape every paged endpoint reads.

  A paged endpoint parses a limit and a cursor, clamps them, and answers the
  cursor for the next page when there is more to read. All three steps are the
  same across endpoints, so they live here rather than being re-derived per
  controller.
  """

  @doc """
  A paging parameter as an integer, or `:error` when it is not one.

  Query-string parameters arrive as text, so only a string that is entirely
  digits is a number. Everything else is the caller's to decide: a page treats
  it as the smallest value, and a caller with another policy reads `:error`
  itself.
  """
  def int(value) when is_integer(value), do: value

  def int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _other -> :error
    end
  end

  def int(_value), do: :error

  @doc """
  The limit and offset a request asks for, clamped to the endpoint's bounds.

  A limit or cursor that is not a whole number reads as 0, and the clamps turn
  that into the smallest page and the first page respectively. That is a
  deliberate choice over a 400: a paging parameter a client got wrong should
  not fail a read that would otherwise succeed.
  """
  def page(params, default_limit, max_limit) do
    limit =
      params
      |> Map.get("limit", default_limit)
      |> value_or_zero()
      |> max(1)
      |> min(max_limit)

    offset =
      params
      |> Map.get("cursor", 0)
      |> value_or_zero()
      |> max(0)

    {limit, offset}
  end

  @doc """
  The next-page cursor for a reply, or the reply unchanged on the last page.

  `items` is everything the endpoint read from the store, one more than the
  page when there is another page, so a count over it decides whether the page
  was full. The cursor is the offset the next page starts at.
  """
  def put_cursor(reply, items, limit, offset) do
    if length(items) > limit,
      do: Map.put(reply, "cursor", Integer.to_string(offset + limit)),
      else: reply
  end

  defp value_or_zero(value) do
    case int(value) do
      :error -> 0
      n -> n
    end
  end
end
