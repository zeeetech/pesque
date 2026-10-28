defmodule Pesque.Config.Error do
  defexception [:reason]

  @impl true
  def exception(reason), do: %__MODULE__{reason: reason}

  @impl true
  def message(%__MODULE__{reason: reason}), do: Pesque.Config.describe(reason)
end
