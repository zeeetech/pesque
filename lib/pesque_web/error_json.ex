defmodule PesqueWeb.ErrorJSON do
  @moduledoc "Renders framework-level errors (bad JSON bodies, 404s) in XRPC shape."

  def render("400.json", _assigns) do
    %{"error" => "InvalidRequest", "message" => "the request could not be processed"}
  end

  def render("404.json", _assigns) do
    %{"error" => "NotFound", "message" => "nothing at this path"}
  end

  def render(_template, _assigns) do
    %{"error" => "InternalServerError", "message" => "internal server error"}
  end
end
