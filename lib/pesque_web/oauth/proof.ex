defmodule PesqueWeb.OAuth.Proof do
  @moduledoc """
  Reading and checking the DPoP proof on a request.

  The proof lives in a header and binds to the URL of the request, so the
  `htu` it claims is checked against the URL this server advertises rather
  than against the raw request line. That is what makes the check survive a
  reverse proxy rewriting host and scheme: the client's proof says what the
  client believes the endpoint is, and that is the same string the metadata
  told it.

  `use_dpop_nonce` is the one failure a client retries instead of giving up,
  and the spec has a client reject a response that omits `DPoP-Nonce` when the
  request carried a proof, so the header goes on the conn for every failure
  path. The caller renders whatever Errors says for the reason.

  The answer is {:ok, conn} with `:dpop_jkt` assigned, or {:error, reason} with
  the header already set. Keeping the conn in the success arm only is what lets
  the callers pass it straight to json/2 without a second clause.
  """

  import Plug.Conn

  alias Pesque.OAuth.DPoP
  alias Pesque.OAuth.Nonce

  @doc """
  Checks the proof on `conn`.

  `access_token` is the bearer presented with the request, or nil, which is
  what decides whether `ath` is required or forbidden. Answers `{:ok, conn}`
  with `:dpop_jkt` assigned, or `{:error, reason, conn}` with `DPoP-Nonce` set
  on the conn, which the caller renders.
  """
  def check(conn, access_token \\ nil) do
    with {:ok, proof} <- proof(conn),
         {:ok, %{jkt: jkt}} <- DPoP.check(proof, conn.method, url(conn), access_token) do
      {:ok, assign(conn, :dpop_jkt, jkt)}
    else
      {:error, reason} -> {:error, reason, put_resp_header(conn, "dpop-nonce", Nonce.current())}
    end
  end

  @doc "The URL a proof's `htu` is checked against: the advertised one, no query."
  def url(conn), do: Pesque.base_url() <> conn.request_path

  @doc "The live server nonce, for a success response."
  def nonce, do: Nonce.current()

  @doc "Sets `DPoP-Nonce` on a successful DPoP-answered response."
  def with_nonce(conn), do: put_resp_header(conn, "dpop-nonce", Nonce.current())

  defp proof(conn) do
    case get_req_header(conn, "dpop") do
      [proof] when is_binary(proof) and proof != "" -> {:ok, proof}
      [] -> {:error, :missing_dpop_proof}
      _other -> {:error, :invalid_dpop_proof}
    end
  end
end
