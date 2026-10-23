defmodule Pesque.Cli.Locale do
  @moduledoc """
  Resolves the language for a CLI run and puts it for gettext.

  Order: the `PESQUE_LANG` environment variable, then `LANG`, then the backend
  default. Only a locale this build ships is accepted, so a stray value cannot
  pick one that does not exist. The web plug (`PesqueWeb.Plugs.SetLocale`) is
  the browser spelling of the same question; this one reads no conn, which is
  why it lives here.
  """

  alias PesqueWeb.Gettext, as: Backend

  @doc """
  The locale the CLI renders in: `PESQUE_LANG`, then `LANG`, normalized and
  accepted only if shipped, else the backend default. A source that names no
  language (`C`, `POSIX`, empty) counts as unset, and the next one is read.
  """
  def resolve do
    candidate(System.get_env("PESQUE_LANG")) || candidate(System.get_env("LANG")) ||
      Gettext.get_locale(Backend)
  end

  @doc "Puts the resolved locale for the calling process. Called once at entry."
  def put do
    Gettext.put_locale(Backend, resolve())
  end

  defp candidate(nil), do: nil
  defp candidate(""), do: nil

  # The full tag is tried first, then the bare language, so `pt_BR.UTF-8` and
  # `en_US` both land on a shipped locale.
  defp candidate(requested) do
    normalized = normalize(requested)

    [normalized, bare(normalized)]
    |> Enum.find(&(&1 in Gettext.known_locales(Backend)))
  end

  # `pt-BR` reads as the shipped `pt_BR`, and anything after the first dot is
  # encoding noise (`pt_BR.UTF-8` is the shell's spelling of `pt_BR`). `C` and
  # `POSIX` mean "no language", which here is unset.
  defp normalize(tag) do
    normalized =
      tag
      |> String.split(".")
      |> hd()
      |> String.trim()
      |> String.replace("-", "_")

    if normalized in ~w(C POSIX), do: nil, else: normalized
  end

  defp bare(nil), do: nil
  defp bare(tag), do: tag |> String.split("_") |> hd()
end
