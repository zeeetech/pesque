defmodule PesqueWeb.HTML do
  @moduledoc """
  Escaping for the browser-facing pages.

  Built on Phoenix.HTML rather than a local replace list so the pages share the
  escaping rules the rest of the ecosystem uses, and a value that is already
  safe passes through instead of being escaped a second time.
  """

  import Phoenix.HTML, only: [html_escape: 1, safe_to_string: 1]

  @doc "Escapes a value for HTML text or an attribute, returning a binary."
  @spec escape(term()) :: binary()
  def escape(value), do: value |> html_escape() |> safe_to_string()
end
