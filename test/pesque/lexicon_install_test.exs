defmodule Pesque.Lexicon.InstallTest do
  use ExUnit.Case, async: true

  alias Pesque.Lexicon.Install

  setup do
    root = Path.join(System.tmp_dir!(), "pesque-install-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp write(root, path, document) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, JSON.encode!(document))
  end

  defp lexicon(nsid) do
    %{
      "lexicon" => 1,
      "id" => nsid,
      "defs" => %{
        "main" => %{"type" => "record", "key" => "tid", "record" => %{"type" => "object"}}
      }
    }
  end

  # The identity is the `id` field, not the path: a repository's filenames do
  # not map to NSID segments.
  test "reads the NSID from id, not the path", %{root: root} do
    write(root, "lexicons/repo/archive.json", lexicon("sh.tangled.repo.archive"))
    write(root, "lexicons/addCollaborator.json", lexicon("sh.tangled.addCollaborator"))

    assert {:ok, documents} = Install.discover(root)

    assert Map.keys(documents) |> Enum.sort() ==
             ["sh.tangled.addCollaborator", "sh.tangled.repo.archive"]
  end

  # A monorepo is mostly not lexicons; scoping to lexicons/ keeps the walk out
  # of everything else.
  test "scopes to lexicons/ when it exists", %{root: root} do
    write(root, "package.json", %{"name" => "monorepo"})
    write(root, "lexicons/sh/tangled/feed.json", lexicon("sh.tangled.feed.star"))
    write(root, "app/elsewhere.json", lexicon("sh.tangled.elsewhere"))

    assert {:ok, documents} = Install.discover(root)
    assert Map.keys(documents) == ["sh.tangled.feed.star"]
  end

  test "falls back to the whole tree when there is no lexicons/ dir", %{root: root} do
    write(root, "sh/tangled/feed.json", lexicon("sh.tangled.feed.star"))
    write(root, "README.json", %{"not" => "a lexicon"})

    assert {:ok, documents} = Install.discover(root)
    assert Map.keys(documents) == ["sh.tangled.feed.star"]
  end

  test "skips the com.atproto namespace", %{root: root} do
    write(root, "lexicons/com/atproto/repo/strongRef.json", lexicon("com.atproto.repo.strongRef"))
    write(root, "lexicons/sh/tangled/repo.json", lexicon("sh.tangled.repo"))

    assert {:ok, documents} = Install.discover(root)
    assert Map.keys(documents) == ["sh.tangled.repo"]
  end

  # The NSID becomes a filename, so a string that is not an NSID must not reach
  # the path: `../../etc/passwd` would otherwise travel out of data/lexicons.
  test "skips a file whose id is not a valid NSID", %{root: root} do
    write(root, "lexicons/evil.json", %{"lexicon" => 1, "id" => "../../etc/passwd"})
    write(root, "lexicons/ok.json", lexicon("sh.tangled.repo"))

    assert {:ok, documents} = Install.discover(root)
    assert Map.keys(documents) == ["sh.tangled.repo"]
  end

  test "a document without lexicon => 1 is not a lexicon", %{root: root} do
    write(root, "lexicons/thing.json", %{"id" => "sh.tangled.repo", "defs" => %{}})
    assert {:ok, documents} = Install.discover(root)
    assert documents == %{}
  end

  test "a missing directory is an error, not an empty install", %{root: root} do
    assert {:error, {:not_a_directory, _}} = Install.discover(Path.join(root, "nope"))
  end

  test "install writes each document as <nsid>.json", %{root: root} do
    target = Path.join(root, "out")
    documents = %{"sh.tangled.repo" => lexicon("sh.tangled.repo")}

    assert {:ok, ["sh.tangled.repo"]} = Install.install(documents, target)

    written = Path.join(target, "sh.tangled.repo.json")
    assert File.exists?(written)
    assert JSON.decode!(File.read!(written))["id"] == "sh.tangled.repo"
  end
end
