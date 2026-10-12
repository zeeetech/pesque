defmodule Pesque.Accounts.Token do
  @moduledoc """
  A one-time, expiring, single-use code for an account flow: signing a PLC
  operation, deleting an account, confirming or moving an email, resetting a
  password. One table and one module, because the flows differ only in what
  spending a code then does.

  A code is stored hashed, never in the clear, so a row read out of this table
  is not a code that authorizes anything. `purpose` keeps a code minted for one
  flow from being spent by another - without it a deletion code and a password
  reset code would be indistinguishable, since both are bound to a DID and an
  expiry - and `used_at` makes a code single use: it is written by the same
  conditional update that spends it, so two callers racing with one code
  produce one effect and one refusal.

  `email` is set only for the email flow, where a code is bound to the address
  it was minted for.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Pesque.Repo

  @purposes [:plc_operation, :account_delete, :email, :reset_password]

  @type purpose :: :plc_operation | :account_delete | :email | :reset_password

  schema "account_tokens" do
    field :token_hash, :string
    field :purpose, Ecto.Enum, values: @purposes
    field :did, :string
    field :email, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "The flows a code can be minted for."
  def purposes, do: @purposes

  @doc """
  Issues a single-use code of `purpose` for `did`, good for `ttl_seconds`.

  `email`, set only by the email flow, binds the code to the address it was
  minted for. Only the hash is stored: the token is answered in the clear here
  and this is the last place it exists, so the caller is what carries it to the
  operator. Answers `{:ok, %{token:, expires_at:}}` or `{:error, :token_failed}`.
  """
  @spec issue(purpose(), String.t(), pos_integer(), String.t() | nil) ::
          {:ok, %{token: String.t(), expires_at: DateTime.t()}} | {:error, :token_failed}
  def issue(purpose, did, ttl_seconds, email \\ nil)
      when purpose in @purposes and is_integer(ttl_seconds) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(ttl_seconds, :second)
      |> DateTime.truncate(:second)

    attrs = %{
      token_hash: hash_token(token),
      purpose: purpose,
      did: did,
      email: email,
      expires_at: expires_at
    }

    case changeset(attrs) |> Repo.insert() do
      {:ok, _row} -> {:ok, %{token: token, expires_at: expires_at}}
      {:error, _changeset} -> {:error, :token_failed}
    end
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:token_hash, :purpose, :did, :email, :expires_at, :used_at])
    |> validate_required([:token_hash, :purpose, :did, :expires_at])
    |> unique_constraint(:token_hash)
  end

  @doc """
  The unspent, unexpired code `purpose` names, narrowed to `did` when given.

  The DID is nil for a code a caller presents without a session (a password
  reset names its own account), and set when the caller is already
  authenticated as the account, so a code for another account is refused.
  Answers `{:ok, row}`, `{:error, :invalid_token}` for a code that names no
  row, is for another purpose or account, or was already spent, and
  `{:error, :expired_token}` for one that ran out of time. Expiry is separate
  so a client told ExpiredToken asks for a new code instead of guessing whether
  the one it holds is merely wrong.
  """
  @spec fetch(purpose(), String.t(), String.t() | nil) ::
          {:ok, %__MODULE__{}} | {:error, :invalid_token | :expired_token}
  def fetch(purpose, token, did \\ nil)

  def fetch(purpose, token, did) when is_binary(token) do
    query =
      from(t in __MODULE__, where: t.token_hash == ^hash_token(token) and t.purpose == ^purpose)

    query = if did, do: where(query, [t], t.did == ^did), else: query

    case Repo.one(query) do
      nil -> {:error, :invalid_token}
      %__MODULE__{used_at: nil} = row -> not_expired(row)
      %__MODULE__{} -> {:error, :invalid_token}
    end
  end

  def fetch(_purpose, _token, _did), do: {:error, :invalid_token}

  @doc """
  Spends a code: one conditional update, so only the caller whose update matches
  an unspent row proceeds. Answers `:ok` or `:invalid_token`.
  """
  @spec spend(%__MODULE__{}) :: :ok | :invalid_token
  def spend(%__MODULE__{id: id}) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    {count, _} =
      from(t in __MODULE__, where: t.id == ^id and is_nil(t.used_at))
      |> Repo.update_all(set: [used_at: now])

    if count == 1, do: :ok, else: :invalid_token
  end

  def hash_token(token), do: Base.encode16(:crypto.hash(:sha256, token), case: :lower)

  defp not_expired(%__MODULE__{expires_at: expires_at} = row) do
    if DateTime.before?(expires_at, DateTime.utc_now()) do
      {:error, :expired_token}
    else
      {:ok, row}
    end
  end
end
