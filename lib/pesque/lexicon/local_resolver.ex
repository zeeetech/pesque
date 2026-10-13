defmodule Pesque.Lexicon.LocalResolver do
  @moduledoc """
  The lexicons this server ships: `priv/lexicons`, indexed at boot by
  `Pesque.Lexicon.Registry`.

  No cache and no clock: the boot-time index is the authority, and a reload
  swaps it atomically. A set this server carries is answered from disk on every
  request, which is what makes the local answer outrank anything the cache or an
  aggregator could hold. A set it does not carry goes to the aggregator, the
  only other source.
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
