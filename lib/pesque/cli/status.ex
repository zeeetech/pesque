defmodule Pesque.Cli.Status do
  @moduledoc """
  The operator report, run with the endpoint down: the server's identity, the
  account counts, the storage footprint and the configured crawlers.

  Read-only, and it judges exactly one thing: listing the accounts is itself
  the proof the database opened, which is the answer the retired `health`
  check was reaching for. No uptime field, because a one-off boots with the
  endpoint down, so process uptime would be a lie. `--json` prints the same
  gathered facts as one JSON object on stdout.
  """

  use Gettext, backend: PesqueWeb.Gettext

  alias Pesque.Cli.Input
  alias Pesque.Cli.Output
  alias Pesque.Identity
  alias Pesque.Release
  alias Pesque.RepoStore
  alias Pesque.Storage

  @usage "usage: pesque status"

  # Two spaces past the widest label ("handle domain"), so the values line up.
  @label_width 15

  def run(argv) do
    with {:ok, opts, []} <- Input.options(argv, [json: :boolean], @usage),
         :ok <- Release.boot!() do
      data = gather()

      if opts[:json] do
        Output.json(%{"status" => data})
      else
        data |> report() |> Enum.each(&IO.puts/1)
      end

      :ok
    end
  end

  @doc """
  The report's lines for `data` in the shape the verb gathers: a section
  header, then one `label  value` line per field, sections apart by a blank
  line. Pure, so it renders for tests without booting the app.
  """
  def report(data) do
    sections = [
      [gettext("server") | server_fields(data.server)],
      [gettext("accounts") | account_fields(data.accounts)],
      [gettext("storage") | storage_fields(data.storage)],
      crawler_lines(data.crawlers)
    ]

    # One level of flattening: List.flatten/1 would shred the iodata a line
    # is made of into separate lines.
    sections |> Enum.intersperse([""]) |> Enum.concat()
  end

  # Field labels are plain literals (a label is a name, not a sentence, and a
  # short msgid would inherit a browser page's translation under the shared
  # catalog); the section headers and "none configured" are prose and go
  # through gettext.
  defp server_fields(server) do
    [
      field("did", server.did),
      field("hostname", server.hostname),
      field("handle domain", server.handle_domain),
      field("mode", server.mode),
      field("identity", server.identity),
      field("registration", server.registration),
      field("version", server.version)
    ]
  end

  defp account_fields(accounts) do
    [
      field("total", accounts.total),
      field("active", accounts.active),
      field("deactivated", accounts.deactivated)
    ]
  end

  defp storage_fields(storage) do
    [
      field("data dir", storage.data_dir),
      field("database", bytes(storage.database_bytes)),
      field("blobs", bytes(storage.blob_bytes))
    ]
  end

  defp crawler_lines([]), do: [gettext("crawlers"), ["  ", gettext("none configured")]]
  defp crawler_lines(crawlers), do: [gettext("crawlers") | Enum.map(crawlers, &["  ", &1])]

  defp field(label, value) do
    ["  ", String.pad_trailing(label, @label_width), to_string(value)]
  end

  defp bytes(size), do: gettext("%{n} bytes", n: size)

  # The imperative half: read the world, hand the pure report a plain map.

  defp gather do
    %{
      server: %{
        did: Identity.did(),
        hostname: Pesque.hostname(),
        handle_domain: Pesque.handle_domain(),
        mode: Pesque.mode(),
        identity: Pesque.identity(),
        registration: Pesque.registration(),
        version: Pesque.version()
      },
      accounts: account_counts(),
      storage: %{
        data_dir: Pesque.data_dir(),
        database_bytes: file_size(Path.join(Pesque.data_dir(), "pesque.db")),
        blob_bytes: tree_size(Storage.blobs_dir())
      },
      crawlers: Pesque.crawlers()
    }
  end

  # Reading the counts is itself the proof the database opened: this is where
  # a data directory that cannot serve fails, and the failure is the non-zero
  # exit the retired `health` verb answered.
  defp account_counts do
    users = RepoStore.list_users()

    %{
      total: length(users),
      active: Enum.count(users, &is_nil(&1.deactivated_at)),
      deactivated: Enum.count(users, &(&1.deactivated_at != nil))
    }
  end

  # A simple recursive walk: a status read is a rare one-off, so the size is
  # summed from the filesystem rather than kept anywhere. Something that is
  # not there counts as zero, which is what a server that never stored a
  # blob should read.
  defp tree_size(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, 0, fn entry, acc ->
          acc + entry_size(Path.join(dir, entry))
        end)

      {:error, _reason} ->
        0
    end
  end

  defp entry_size(path), do: if(File.dir?(path), do: tree_size(path), else: file_size(path))

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _reason} -> 0
    end
  end
end
