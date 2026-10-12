defmodule PesqueWeb.PageHTML do
  @moduledoc """
  The bodies of the two pages the server renders for a person: the landing at
  the server's own name, and one page per handle it hosts.

  Pure functions of their assigns, so a page is a value the controller builds
  and a test can read without a request. Only public facts are rendered: a
  handle page never shows an account's email, or anything else its own
  `describeRepo` would not already publish.
  """

  use Gettext, backend: PesqueWeb.Gettext

  import PesqueWeb.HTML, only: [escape: 1]

  @doc """
  The landing at the server's hostname.

  The facts are the configuration an operator would want a visitor to see and
  that `describeServer` already publishes, so nothing here is a secret.
  """
  def landing(assigns) do
    facts =
      [
        {gettext("hostname"), assigns.hostname},
        {gettext("accounts"), accounts(assigns.mode)},
        {gettext("identity"), identity(assigns.identity)},
        {gettext("handles"), assigns.handle_domain},
        {gettext("registration"), registration(assigns.registration)},
        {gettext("version"), "pesque v" <> assigns.version}
      ] ++ account_facts(assigns[:account])

    """
    <section class="hero">
      <p class="eyebrow">// atproto</p>
      <h1>#{escape(assigns.hostname)}</h1>
      <p class="tag">#{gettext("personal data server")}</p>
      <p class="pitch">#{gettext("A personal data server for the atproto network. It stores an account's records, signs every change and answers the network on its own. Self-hosted, so the data stays where its owner put it.")}</p>
      <div class="cta">
        #{cta(assigns.mode)}
      </div>
      <p class="learn"><a class="inline" href="https://atproto.com">#{gettext("what is atproto?")} →</a></p>
    </section>
    <section class="facts">
      <h2 class="head"><span class="sl">/</span>#{gettext("this server")}</h2>
      <dl class="grid">
        #{fact_rows(facts)}
      </dl>
    </section>
    """
  end

  @doc """
  One page per handle this server hosts.

  `:active` decides the wording only: a deactivated account still has a handle,
  so the page stays and says so rather than 404ing on a name that resolves.
  """
  def handle(assigns) do
    facts = [
      {gettext("handle"), assigns.handle},
      {gettext("did"), assigns.did},
      {gettext("status"), status(assigns.active)}
    ]

    """
    <section class="hero">
      <p class="eyebrow">// atproto</p>
      <h1>#{escape(assigns.handle)}</h1>
      <p class="tag">#{gettext("atproto account on this server")}</p>
      <p class="pitch">#{pitch(assigns.active)}</p>
      <div class="cta">
        <a class="btn primary" href="https://bsky.app/profile/#{escape(assigns.handle)}">#{gettext("view on bluesky")} →</a>
        <a class="btn" href="#{escape(assigns.home)}">#{gettext("about this server")}</a>
      </div>
    </section>
    <section class="facts">
      <h2 class="head"><span class="sl">/</span>#{gettext("identity")}</h2>
      <dl class="grid">
        #{fact_rows(facts)}
      </dl>
      <p class="meta">at://#{escape(assigns.handle)}</p>
    </section>
    """
  end

  defp fact_rows(facts) do
    Enum.map_join(facts, "\n", fn {label, value} ->
      "<div><dt>#{escape(label)}</dt><dd>#{escape(value)}</dd></div>"
    end)
  end

  # The actions, primary first: the row reads as an answer with options rather
  # than as a button buried between two others. "What is atproto?" is not here,
  # because it is not an action: a reader may want the network explained before
  # choosing one, so it sits under the row as a link. The move leads because it
  # is the action a person with an account elsewhere is looking for; creating
  # an account here is the other way in, not the first one.
  defp cta(mode) do
    [
      migrate_link(mode),
      signup_link(mode),
      ~s(<a class="btn" href="https://bsky.app">#{gettext("open a client")} →</a>)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n        ")
  end

  # A server with many accounts takes accounts that live elsewhere, so the
  # landing offers the way over. A server that is its single account has no
  # move page, and the link would be a dead end.
  defp migrate_link(:path_multi),
    do: ~s(<a class="btn primary" href="/migrate">#{gettext("move my account")}</a>)

  defp migrate_link(_mode), do: ""

  # A server with many accounts takes them by invite, so the landing offers the
  # way in. A server that is its single account has no signup page, and the
  # link would be a dead end.
  defp signup_link(:path_multi),
    do: ~s(<a class="btn" href="/signup">#{gettext("create account")}</a>)

  defp signup_link(_mode), do: ""

  defp account_facts(nil), do: []

  defp account_facts(%{handle: handle, did: did}) do
    [{gettext("handle"), handle}, {gettext("did"), did}]
  end

  defp accounts(:conformant_single), do: gettext("single account")
  defp accounts(:path_multi), do: gettext("community server")

  defp identity(:web), do: "did:web"
  defp identity(:plc), do: "did:plc"

  defp registration(:open), do: gettext("open")
  defp registration(:closed), do: gettext("invite only")

  defp status(true), do: gettext("active")
  defp status(false), do: gettext("dormant")

  defp pitch(true), do: gettext("This handle is hosted here. Everything below is public.")

  defp pitch(false),
    do:
      gettext(
        "This handle is hosted here, but the account is dormant. Everything below is public."
      )
end
