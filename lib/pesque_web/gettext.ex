defmodule PesqueWeb.Gettext do
  @moduledoc """
  The gettext backend for the browser-facing pages.

  Only the pages a person reads in a browser are translated: the landing, the
  handle page and the OAuth consent page. The protocol surface stays English,
  the language the rest of the code is written in, so gettext never reaches the
  XRPC controllers.

  The message ids are English and the shipped translation is Portuguese, which
  is the default locale because this server is self-hosted in Brazil. A
  Portuguese-speaking operator gets Portuguese without asking; everyone else
  gets English from the same source strings.
  """

  use Gettext.Backend, otp_app: :pesque
end
