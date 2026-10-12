defmodule Pesque.Lexicon.LocalResolver do
  @moduledoc """
  The lexicons this server already holds: `priv/lexicons` and `data/lexicons`,
  indexed at boot by `Pesque.Lexicon.Registry`.

  No cache and no clock: the boot-time index is the authority, and a reload
  swaps it atomically. A set an operator curates locally is answered from disk
  on every request, which is what makes the local answer outrank anything the
  cache or an aggregator could hold.
  """

  @behaviour Pesque.Lexicon.Resolver

  @impl true
  def resolve(nsid) when is_binary(nsid) do
    case Pesque.Lexicon.Registry.get(nsid) do
      nil -> {:error, :not_found}
      document -> {:ok, document}
    end
  end

  def resolve(_nsid), do: {:error, :not_found}
end
