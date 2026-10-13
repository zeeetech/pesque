defmodule PesqueWeb.MigrateHTML do
  @moduledoc """
  The bodies of the migration pages: the form that starts a move and the page
  that watches one.

  Pure functions of their assigns, like `PesqueWeb.SignupHTML`, so a page is a
  value a test can read without a request. The copy is written for someone who
  has never heard of atproto: it stays away from protocol vocabulary, and every
  failure says what to do next instead of only what went wrong.
  """

  use Gettext, backend: PesqueWeb.Gettext

  import PesqueWeb.HTML, only: [escape: 1]

  alias Pesque.Migrate.Job

  @doc """
  The form.

  `:registration` decides whether the invite code is asked for. `:old_pds`,
  `:handle` and `:email` carry what was typed, so a rejected form does not make
  the person type it again; the password is never carried. `:error`, when
  given, is a reason the controller answered and comes back as a sentence above
  the form. The name is asked for in full, unlike signup's, because a move can
  bring a name no domain of this server is under.
  """
  def form(assigns) do
    """
    <section class="hero">
      <p class="eyebrow">// conta</p>
      <h1>#{gettext("move your account")}</h1>
      <p class="pitch">#{gettext("You already have an account on atproto, and you want this server to hold it. The name does not change, and nothing is published here until the switch works.")}</p>
    </section>
    #{notice(assigns[:error])}
    <form class="consent" method="post" action="/migrate">
      #{invite_field(assigns)}
      <div class="field">
        <label for="old_pds">#{gettext("your current server")}</label>
        <input id="old_pds" name="old_pds" type="text" autocomplete="off" autocapitalize="none" spellcheck="false" value="#{escape(assigns[:old_pds] || "")}" required>
        <p class="hint">#{gettext("The address of the server that holds the account now, like https://bsky.social.")}</p>
      </div>
      <div class="field">
        <label for="handle">#{gettext("your name")}</label>
        <input id="handle" name="handle" type="text" autocomplete="username" autocapitalize="none" spellcheck="false" value="#{escape(assigns[:handle] || "")}" required>
        <p class="hint">#{gettext("The full name you use today, like alice.bsky.social.")}</p>
      </div>
      <div class="field">
        <label for="email">#{gettext("email")}</label>
        <input id="email" name="email" type="email" autocomplete="email" value="#{escape(assigns[:email] || "")}" required>
        <p class="hint">#{gettext("The account's email. The code for the last step arrives there.")}</p>
      </div>
      <div class="field">
        <label for="password">#{gettext("your password")}</label>
        <input id="password" name="password" type="password" autocomplete="current-password" required>
        <p class="hint">#{gettext("The account's password, not an app password. It is used now and is not stored.")}</p>
      </div>
      <div class="actions">
        <button class="btn primary" type="submit">#{gettext("move my account")}</button>
      </div>
    </form>
    <section class="facts">
      <p class="pitch">#{gettext("Everything or nothing: if any step fails before the switch, your old account keeps working and nothing is published here.")}</p>
      <p class="pitch">#{gettext("This server makes the move, not the app: that is why it asks for your password and the code that arrives by email. That is what authorizes the switch.")}</p>
      <details>
        <summary>#{gettext("your name and its DNS")}</summary>
        <p>#{gettext("If your name is under this server's domain, there is nothing to do: this server takes care of it.")}</p>
        <p>#{gettext("If the name is on a domain you own, that domain needs a TXT record pointing at your account's DID.")}</p>
        <p>#{gettext("The DID does not change in the move, so a name that already resolves to your account is already set.")}</p>
        <p>#{gettext("The record is a TXT at _atproto of your domain, with the value did= followed by your account's DID. It takes a few minutes to propagate.")}</p>
      </details>
    </section>
    """
  end

  @doc """
  The page that watches a move, one body per phase.

  A move that is still going says so and shows the facts the row already
  knows; the controller adds the tag that makes the page poll itself. One
  waiting on the code asks for it. The other two close the story: the move
  worked, or it did not and the person starts again.
  """
  def status(%{job: %Job{phase: :running}} = assigns) do
    """
    <section class="hero">
      <p class="eyebrow">// conta</p>
      <h1>#{gettext("moving your account")}</h1>
      <p class="pitch">#{gettext("We are copying your data from the old server. This can take a few minutes.")}</p>
    </section>
    <section class="facts">
      <h2 class="head"><span class="sl">/</span>#{gettext("the move")}</h2>
      <dl class="grid">
        <div><dt>#{gettext("your name")}</dt><dd>#{escape(assigns.job.handle)}</dd></div>
        <div><dt>#{gettext("your current server")}</dt><dd>#{escape(assigns.job.old_pds)}</dd></div>
      </dl>
    </section>
    """
  end

  def status(%{job: %Job{phase: :awaiting_code}} = assigns) do
    """
    <section class="hero">
      <p class="eyebrow">// conta</p>
      <h1>#{gettext("one code left")}</h1>
      <p class="pitch">#{gettext("The old server sent a code to the account's email. Paste it here to finish.")}</p>
    </section>
    <form class="consent" method="post" action="/migrate/#{escape(assigns.job.token)}/code">
      <div class="field">
        <label for="code">#{gettext("the code from your email")}</label>
        <input id="code" name="code" type="text" autocomplete="one-time-code" required>
        <p class="hint">#{gettext("The code is good for 15 minutes. If it expires, start again.")}</p>
      </div>
      <div class="actions">
        <button class="btn primary" type="submit">#{gettext("finish the move")}</button>
      </div>
    </form>
    """
  end

  def status(%{job: %Job{phase: :done}} = _assigns) do
    """
    <section class="hero">
      <p class="eyebrow">// conta</p>
      <h1>#{gettext("done")}</h1>
      <p class="pitch">#{gettext("Your account is held here now. Sign in to the app with the same name and the same password as before.")}</p>
    </section>
    <div class="cta">
      <a class="btn primary" href="https://bsky.app">#{gettext("open the app")} →</a>
    </div>
    """
  end

  def status(%{job: %Job{phase: :failed, error: error}}) do
    """
    <section class="hero">
      <p class="eyebrow">// conta</p>
      <h1>#{gettext("it did not work")}</h1>
    </section>
    <p class="notice error" role="alert">#{escape(message(error))}</p>
    <p class="pitch">#{gettext("Your old account keeps working. Nothing was published here.")}</p>
    <div class="cta">
      <a class="btn" href="/migrate">#{gettext("start again")}</a>
    </div>
    """
  end

  defp invite_field(%{registration: :closed} = assigns) do
    """
    <div class="field">
      <label for="invite_code">#{gettext("invite code")}</label>
      <input id="invite_code" name="invite_code" type="text" autocomplete="off" autocapitalize="none" spellcheck="false" value="#{escape(assigns[:invite_code] || "")}" required>
      <p class="hint">#{gettext("The code whoever invited you sent.")}</p>
    </div>
    """
  end

  defp invite_field(_assigns), do: ""

  defp notice(nil), do: ""

  defp notice(reason) do
    ~s(<p class="notice error" role="alert">#{escape(message(reason))}</p>)
  end

  @doc """
  The sentence for a failure code.

  A code this build does not name is the server's own failure, and it gets the
  one sentence that says so without pretending to know more. The controller's
  reasons arrive as atoms and the row's codes as strings of the same names, so
  both spellings reach the same sentence.
  """
  def message(reason) do
    case describe(reason) do
      {:named, text} ->
        text

      :unnamed ->
        gettext(
          "Something went wrong on our side. Try again in a moment. If it keeps happening, tell whoever runs the server."
        )
    end
  end

  @doc """
  Whether the page has a sentence of its own for `reason`.

  The caller logs the ones it does not: a sentence a person cannot act on is
  worth a line an operator can.
  """
  def named?(reason), do: match?({:named, _text}, describe(reason))

  # The row's codes are the vocabulary: one clause per code the move can
  # answer with, said as what to do next. The controller's reasons are atoms
  # spelled the same way, so they read through one bridge clause.
  defp describe(reason) when is_atom(reason), do: describe(Atom.to_string(reason))

  # The two invite codes share one sentence: either way the code did not open
  # the door, and either way the way out is a new code.
  defp describe(code) when code in ["invalid_invite_code", "invite_code_required"],
    do:
      {:named,
       gettext(
         "That invite code is not valid, or it was already used. Ask whoever invited you for a new one."
       )}

  defp describe("invalid_handle"),
    do: {:named, gettext("Check the name: it has to be the full name, like alice.bsky.social.")}

  defp describe("invalid_old_pds"),
    do: {:named, gettext("The old server's address has to start with https://.")}

  defp describe("email_required"), do: {:named, gettext("An email is required.")}

  defp describe("password_required"), do: {:named, gettext("A password is required.")}

  defp describe("handle_not_available"),
    do:
      {:named,
       gettext(
         "That name is already in use here. If you already moved this account, it is already here."
       )}

  defp describe("handle_not_under_domain"),
    do:
      {:named,
       gettext(
         "That name is not under the domain this server hands out names on. Use the full name, like alice.example.com, or a name that already points at your account."
       )}

  defp describe("disallowed_handle"),
    do:
      {:named,
       gettext(
         "That name is not accepted here. Use a name that resolves to your account, or a name on this server."
       )}

  defp describe("email_taken"),
    do:
      {:named,
       gettext(
         "That email already belongs to an account here. If you already moved this account, it is already here."
       )}

  defp describe("password_too_short"),
    do:
      {:named,
       gettext(
         "The old account's password has fewer than 8 characters, and here a password has to be longer. Change it there and try again."
       )}

  defp describe("account_exists"), do: {:named, gettext("This server already has its account.")}

  defp describe("old_pds_unauthorized"),
    do:
      {:named,
       gettext(
         "We could not sign in to your old account. Check the password: it is the account password, not an app password."
       )}

  defp describe("old_pds_rejected"),
    do: {:named, gettext("The old server refused the request. Check the address and the name.")}

  defp describe("old_pds_unreachable"),
    do:
      {:named,
       gettext("We could not reach the old server. Check the address, or try again in a moment.")}

  defp describe("code_timeout"),
    do:
      {:named, gettext("The code took too long to arrive. Start again and keep the email open.")}

  defp describe("interrupted"),
    do:
      {:named,
       gettext(
         "The server restarted in the middle of the move. Start again: what already came over is reused."
       )}

  defp describe("too_large"),
    do:
      {:named,
       gettext(
         "One of your files is larger than this server accepts. Tell whoever runs the server."
       )}

  defp describe(_code), do: :unnamed
end
