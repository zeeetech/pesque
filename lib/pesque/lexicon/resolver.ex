defmodule Pesque.Lexicon.Resolver do
  @moduledoc """
  The one question resolving a permission set asks of its source: what is the
  document this NSID names?

  Two implementations ship. `Pesque.Lexicon.LocalResolver` answers from the
  lexicons this server already holds and is always authoritative; anything it
  cannot answer goes to `Pesque.Lexicon.AggregatorResolver`, which fetches
  from the operator-configured aggregator. Tests can stand in a third one:
  `Pesque.OAuth.PermissionSets` reads the implementation to use from the
  `:pesque, :lexicon_resolver` application env.
  """

  @callback resolve(nsid :: String.t()) :: {:ok, document :: map()} | {:error, term()}
end
