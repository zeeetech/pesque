defmodule Pesque.EventFrames do
  @moduledoc """
  The firehose frames that are not commits: the `#identity`, `#account` and
  `#sync` events the spec puts next to `#commit` on the same stream.

  Pure, like `Pesque.Commit.frame/3`: they turn the seq the log hands them
  plus what the event is about into bytes. `Pesque.Events` is what decides
  the seq, writes the row and pushes it to connected sockets.
  """

  alias Pesque.CBOR
  alias Pesque.CID
  alias Pesque.Car
  alias Pesque.Commit

  @sync_max_car_bytes 10_000

  @statuses [
    :activated,
    :takendown,
    :suspended,
    :deleted,
    :deactivated,
    :desynchronized,
    :throttled
  ]

  @doc """
  An `#identity` frame: this account's handle, for a downstream service whose
  identity cache is now stale.
  """
  def identity(seq, did, handle) do
    frame("#identity", %{
      "seq" => seq,
      "did" => did,
      "handle" => handle,
      "time" => now()
    })
  end

  @doc """
  An `#account` frame: whether the account has a repo here at all.

  `active` follows from the status rather than being passed alongside it, so a
  caller cannot publish a deactivated account that claims to be active.
  `:activated` is the spec's absence of a reason: an account with nothing wrong
  with it carries no `status` at all, because the field is the reason it is not
  active and there is none.
  """
  def account(seq, did, status) when status in @statuses do
    frame("#account", body(seq, did, status))
  end

  @doc """
  Builds a `#sync` frame carrying only the signed head commit block.

  The CAR root is the commit CID, and the CAR contains no MST or record blocks.
  """
  def sync(seq, did, rev, %CID{} = commit_cid, commit_bytes) when is_binary(commit_bytes) do
    car = Car.encode([commit_cid], %{commit_cid => commit_bytes})

    encoded =
      frame("#sync", %{
        "seq" => seq,
        "did" => did,
        "blocks" => %CBOR.Bytes{data: car},
        "rev" => rev,
        "time" => now()
      })

    cond do
      byte_size(car) > @sync_max_car_bytes -> {:error, :sync_too_large}
      byte_size(encoded) > Commit.max_frame_bytes() -> {:error, :frame_too_large}
      true -> {:ok, encoded}
    end
  end

  defp body(seq, did, :activated) do
    %{
      "seq" => seq,
      "did" => did,
      "active" => true,
      "time" => now()
    }
  end

  defp body(seq, did, status) do
    %{
      "seq" => seq,
      "did" => did,
      "active" => false,
      "status" => Atom.to_string(status),
      "time" => now()
    }
  end

  defp frame(type, body) do
    CBOR.encode(%{"op" => 1, "t" => type}) <> CBOR.encode(body)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
