defmodule Pesque.Preferences do
  @moduledoc "An account's private preferences, one opaque JSON array per DID."

  alias Pesque.Preferences.Preference
  alias Pesque.Repo

  # The array is stored as one opaque document, so the only thing to bound is
  # its size: a caller can send a list of anything, and a megabyte is far past
  # what a client writes while still bounded.
  @max_bytes 1_048_576

  @doc """
  Reads an account's preferences.

  Answers `{:ok, list}` with the stored array verbatim, or `{:ok, []}` when
  nothing was ever stored. Each entry is parsed, not validated: the PDS owns
  the document but not the meaning of what an app put in it.
  """
  @spec get(String.t()) :: {:ok, [map()]} | {:error, term()}
  def get(did) when is_binary(did) do
    case Repo.get_by(Preference, did: did) do
      nil -> {:ok, []}
      %Preference{preferences: stored} -> decode(stored)
    end
  end

  def get(_did), do: {:error, :invalid_did}

  @doc """
  Replaces an account's preferences with `preferences`.

  Answers `{:ok, :stored}`, or `{:error, :preferences_too_large}` when the
  encoded array is past the cap.
  """
  @spec put(String.t(), [map()]) :: {:ok, :stored} | {:error, term()}
  def put(did, preferences) when is_binary(did) and is_list(preferences) do
    encoded = JSON.encode!(preferences)

    if byte_size(encoded) > @max_bytes do
      {:error, :preferences_too_large}
    else
      upsert(did, encoded)
    end
  end

  defp decode(stored) do
    case JSON.decode(stored) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _other -> {:ok, []}
    end
  end

  # One row per DID, so a write replaces the document rather than appending.
  # The unique index on did is the conflict target, and only the document and
  # its timestamp move.
  defp upsert(did, encoded) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    changeset = Preference.changeset(%{did: did, preferences: encoded, updated_at: now})

    case Repo.insert(changeset,
           on_conflict: {:replace, [:preferences, :updated_at]},
           conflict_target: :did
         ) do
      {:ok, _row} -> {:ok, :stored}
      {:error, _changeset} -> {:error, :preferences_not_stored}
    end
  end
end
