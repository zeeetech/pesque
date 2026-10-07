defmodule Pesque.ConfigTest do
  @moduledoc """
  The config file is a small grammar, and the two ways it can be wrong are a
  typo and a line the parser cannot read. Both have to fail boot rather than be
  ignored, so they are tested as errors with a line number.
  """

  use ExUnit.Case, async: false

  alias Pesque.Config

  describe "parse/1" do
    test "reads keys, values, comments and blank lines" do
      text = """
      # a comment
      hostname = pds.example.com

      mode = path_multi # trailing comment
      port=4000
      """

      assert {:ok, values} = Config.parse(text)

      assert values == %{
               "hostname" => "pds.example.com",
               "mode" => "path_multi",
               "port" => "4000"
             }
    end

    test "keeps a value that contains an equals sign" do
      assert {:ok, %{"plc_directory" => "https://x/?a=b"}} =
               Config.parse("plc_directory = https://x/?a=b")
    end

    test "names the line of an unknown key" do
      assert {:error, {:unknown_key, "hostnmae", 2}} = Config.parse("port = 1\nhostnmae = x")
    end

    test "names the line of a repeated key" do
      assert {:error, {:duplicate_key, "port", 2}} = Config.parse("port = 1\nport = 2")
    end

    test "refuses a line with no equals sign" do
      assert {:error, {:invalid_line, 1}} = Config.parse("hostname pds.example.com")
    end

    test "refuses a key with no value" do
      assert {:error, {:missing_value, 1}} = Config.parse("hostname =")
    end
  end

  describe "get/3" do
    test "the environment wins over the file, which wins over the default" do
      System.put_env("PDS_PORT", "9000")
      on_exit(fn -> System.delete_env("PDS_PORT") end)

      assert Config.get(%{"port" => "8000"}, "port", "4000") == "9000"
    end

    test "the file wins over the default" do
      assert Config.get(%{"port" => "8000"}, "port", "4000") == "8000"
    end

    test "the default is the last word" do
      assert Config.get(%{}, "port", "4000") == "4000"
    end
  end

  describe "load/0" do
    test "a missing file is an empty map, not an error" do
      System.put_env("PDS_CONFIG", Path.join(System.tmp_dir!(), "pesque-no-such-file.conf"))
      on_exit(fn -> System.delete_env("PDS_CONFIG") end)

      assert Config.load() == {:ok, %{}}
      assert Config.load!() == %{}
    end

    test "a bad file raises with its path" do
      path = Path.join(System.tmp_dir!(), "pesque-bad-#{System.unique_integer([:positive])}.conf")
      File.write!(path, "nonsense\n")
      on_exit(fn -> File.rm(path) end)

      System.put_env("PDS_CONFIG", path)
      on_exit(fn -> System.delete_env("PDS_CONFIG") end)

      assert_raise RuntimeError, ~r/#{Regex.escape(path)}.*line 1/, fn -> Config.load!() end
    end
  end
end
