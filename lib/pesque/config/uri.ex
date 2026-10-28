defmodule Pesque.Config.URI do
  @moduledoc false

  use Ecto.Type

  @impl true
  def type, do: :string

  @impl true
  def load(uri) when is_binary(uri) do
    {:ok, URI.parse(uri)}
  end

  def load(_), do: :error

  @impl true
  def dump(%URI{} = uri), do: {:ok, URI.to_string(uri)}
  def dump(uri) when is_binary(uri), do: {:ok, uri}
  def dump(_), do: :error

  @impl true
  def cast(uri) when is_binary(uri) do
    with {:error, _} <- URI.new(uri), do: :error
  end

  def cast(%URI{} = uri), do: {:ok, uri}
  def cast(_), do: :error
end
