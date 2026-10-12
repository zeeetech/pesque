defmodule PesqueWeb.SignupHTML do
  @moduledoc """
  The bodies of the signup pages: the form and the confirmation that follows a
  created account.

  Pure functions of their assigns, like `PesqueWeb.PageHTML`, so a page is a
  value a test can read without a request. The copy is written for someone who
  has never heard of atproto: it stays away from protocol vocabulary, and every
  failure says what to do next instead of only what went wrong.
  """

  use Gettext, backend: PesqueWeb.Gettext

  import PesqueWeb.HTML, only: [escape: 1]

  @doc """
  The form.

  `:registration` decides whether the invite code is asked for. `:invite_code`,
  `:handle` and `:email` carry what was typed, so a rejected form does not make
  the person type it again; the password is never carried. `:error`, when
  given, is a reason the domain answered and comes back as a sentence above the
  form.
  """
  def form(assigns) do
    """
    <section class="hero">
      <p class="eyebrow">// conta</p>
      <h1>#{gettext("create account")}</h1>
      <p class="pitch">#{pitch(assigns.registration)}</p>
    </section>
    #{notice(assigns[:error])}
    <form class="consent" method="post" action="/signup">
      #{invite_field(assigns)}
      <div class="field">
        <label for="handle">#{gettext("your name")}</label>
        <div class="row">
          <input id="handle" name="handle" type="text" autocomplete="username" autocapitalize="none" spellcheck="false" value="#{escape(assigns[:handle] || "")}" required>
          <span class="suffix">.#{escape(assigns.handle_domain)}</span>
        </div>
        <p class="hint">#{gettext("Letters, numbers and hyphen. This is the name people use to find you.")}</p>
      </div>
      <div class="field">
        <label for="email">#{gettext("email")}</label>
        <input id="email" name="email" type="email" autocomplete="email" value="#{escape(assigns[:email] || "")}" required>
        <p class="hint">#{gettext("We do not send confirmation emails. Keep this address: it is how whoever runs the server helps you recover the account.")}</p>
      </div>
      <div class="field">
        <label for="password">#{gettext("your password")}</label>
        <input id="password" name="password" type="password" autocomplete="new-password" minlength="8" required>
        <p class="hint">#{gettext("At least 8 characters.")}</p>
      </div>
      <div class="actions">
        <button class="btn primary" type="submit">#{gettext("create my account")}</button>
      </div>
    </form>
    """
  end

  @doc "The confirmation a created account lands on."
  def done(assigns) do
    """
    <section class="hero">
      <p class="eyebrow">// conta</p>
      <h1>#{gettext("account created")}</h1>
      <p class="pitch">#{gettext("Your account is ready. To sign in, open the official Bluesky app and use this name and the password you just chose.")}</p>
    </section>
    <section class="facts">
      <h2 class="head"><span class="sl">/</span>#{gettext("your account")}</h2>
      <dl class="grid">
        <div><dt>#{gettext("your name")}</dt><dd>#{escape(assigns.handle)}</dd></div>
      </dl>
    </section>
    <div class="cta">
      <a class="btn primary" href="https://bsky.app">#{gettext("open the app")} →</a>
      <a class="btn" href="/">#{gettext("about this server")}</a>
    </div>
    """
  end

  defp pitch(:closed),
    do:
      gettext(
        "This server is invite only. To create an account, you need a code from whoever invited you."
      )

  defp pitch(:open), do: gettext("Fill in the form to create your account.")

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

  # Every reason the domain answers with, said as what to do next. A reason
  # this build does not name is the server's own failure, and it says so
  # without pretending to know more than it does.
  defp message(:invite_code_required),
    do: gettext("This server is invite only. You need a code to create an account.")

  defp message(:invalid_invite_code),
    do:
      gettext(
        "That code is not valid. It may have expired or already been used. Ask whoever invited you for a new one."
      )

  defp message(:invalid_handle),
    do: gettext("Choose a name with letters, numbers or hyphen. No dots and no spaces.")

  defp message(:handle_not_available),
    do: gettext("That name is already taken here. Choose another.")

  defp message(:password_too_short), do: gettext("The password needs at least 8 characters.")

  defp message(:email_required), do: gettext("An email is required.")

  defp message(:email_taken),
    do:
      gettext(
        "Another account here already uses that email. If it is yours, ask whoever runs the server for help recovering it."
      )

  defp message(:account_exists), do: gettext("This server already has its account.")

  defp message(_reason),
    do:
      gettext(
        "Something went wrong on our side. Try again in a moment. If it keeps happening, tell whoever runs the server."
      )
end
