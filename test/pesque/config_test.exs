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

      mode = multi # trailing comment
      port=4000
      """

      assert {:ok, values} = Config.parse(text)

      assert values == %{
               "hostname" => "pds.example.com",
               "mode" => "multi",
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

    # resolution/0 reports an empty environment value as unset, and get/3
    # decides what boot does, so both have to read "" the same way or
    # `config validate` would lie about the server.
    test "an empty environment value reads as unset" do
      System.put_env("PDS_PORT", "")
      on_exit(fn -> System.delete_env("PDS_PORT") end)

      assert Config.get(%{}, "port", "4000") == "4000"
      assert Config.get(%{"port" => "8000"}, "port", "4000") == "8000"
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

  describe "validate_env/0" do
    test "a known config key and the internal variables pass" do
      System.put_env("PDS_PORT", "9000")
      System.put_env("PDS_CONFIG", "somewhere.conf")
      System.put_env("PDS_PUBLIC_IP", "203.0.113.7")

      on_exit(fn ->
        System.delete_env("PDS_PORT")
        System.delete_env("PDS_CONFIG")
        System.delete_env("PDS_PUBLIC_IP")
      end)

      assert Config.validate_env() == :ok
    end

    test "an unknown PDS_ variable fails, naming it" do
      System.put_env("PDS_HOSTNMAE", "typo.example.com")
      on_exit(fn -> System.delete_env("PDS_HOSTNMAE") end)

      assert {:error, {:unknown_env, ["PDS_HOSTNMAE"]}} = Config.validate_env()
    end

    test "a typo the file layer would refuse is refused here too" do
      System.put_env("PDS_NOT_A_REAL_KEY", "1")
      on_exit(fn -> System.delete_env("PDS_NOT_A_REAL_KEY") end)

      assert {:error, {:unknown_env, ["PDS_NOT_A_REAL_KEY"]}} = Config.validate_env()
    end

    test "the retired identity setting is refused rather than read" do
      System.put_env("PDS_IDENTITY", "plc")
      on_exit(fn -> System.delete_env("PDS_IDENTITY") end)

      assert {:error, {:unknown_env, ["PDS_IDENTITY"]}} = Config.validate_env()
    end

    test "variables of other namespaces are none of this layer's business" do
      System.put_env("PESQUE_BACKEND", "docker")
      on_exit(fn -> System.delete_env("PESQUE_BACKEND") end)

      assert Config.validate_env() == :ok
    end
  end

  describe "resolution/0" do
    test "every key answers with the layer that decided it" do
      System.put_env("PDS_PORT", "9000")
      on_exit(fn -> System.delete_env("PDS_PORT") end)

      path =
        Path.join(System.tmp_dir!(), "pesque-where-#{System.unique_integer([:positive])}.conf")

      File.write!(path, "hostname = file.example.com\n")
      on_exit(fn -> File.rm(path) end)

      previous = System.get_env("PDS_CONFIG")
      System.put_env("PDS_CONFIG", path)
      on_exit(fn -> restore_config(previous) end)

      assert {:ok, entries} = Config.resolution()
      assert {"port", {:env, "PDS_PORT", "9000"}} in entries
      assert {"hostname", {:file, 1, "file.example.com"}} in entries
      assert {"mode", :default} in entries
    end
  end

  describe "template/0" do
    test "the committed example is the template, so the two cannot drift" do
      assert File.read!("pesque.conf.example") == Config.template()
    end

    test "the template's live lines parse as the config they document" do
      assert {:ok, values} = Config.parse(Config.template())

      assert values == %{
               "hostname" => "pds.example.com",
               "mode" => "multi",
               "handle_domain" => "example.com",
               "registration" => "closed"
             }
    end
  end

  defp restore_config(previous) do
    if previous, do: System.put_env("PDS_CONFIG", previous), else: System.delete_env("PDS_CONFIG")
  end
end
