defmodule Pesque.Cli.Report do
  @moduledoc """
  The plain "next steps" block a multi-step verb ends with: an ordered list of
  steps rendered as one block on stdout.

  No status marks, no spinners, no live redraw: the one-off usually runs
  without a TTY, and a plain block is what survives a pipe. Rendering is pure;
  the caller prints the block, so the stream it lands on stays the caller's.
  """

  @doc """
  Renders the steps in order with a blank line between two of them. A step may
  span lines of its own; its interior layout is the caller's.
  """
  @spec next_steps([String.t()]) :: String.t()
  def next_steps(steps) do
    Enum.join(steps, "\n\n")
  end
end
