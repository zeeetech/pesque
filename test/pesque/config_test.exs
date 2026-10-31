defmodule Pesque.ConfigTest do
  @moduledoc """
  The config file is a small grammar, and the ways it can be wrong are a typo,
  a missing setting and a value the server cannot use. All of them fail boot
  rather than being ignored, so they are tested as errors naming the line.
  """

  use ExUnit.Case, async: false

  alias Pesque.Config

  describe "parse/1" do
    test "reads keys, values, comments and blank lines" do
      text = """
      # a comment
      url_scheme = https
      hostname = pds.example.com

      port = 4000
      """

      assert {:ok, values} = Config.parse(text)

      assert values == %{
               "url_scheme" => {"https", 2},
               "hostname" => {"pds.example.com", 3},
               "port" => {"4000", 5}
             }
    end

    test "keeps a value that contains an equals sign" do
      assert {:ok, %{"plc_directory" => {"https://x/?a=b", 1}}} =
               Config.parse("plc_directory = https://x/?a=b")
    end

    test "names the line of an unknown key" do
      assert {:error, {:unknown_key, "hostnmae", 2}} =
               Config.parse("port = 1\nhostnmae = x")
    end

    test "names the line of a repeated key" do
      assert {:error, {:duplicate_key, "port", 2}} = Config.parse("port = 1\nport = 2")
    end

    test "refuses a line with no equals sign" do
      assert {:error, {:invalid_line, 1}} =
               Config.parse("url_scheme https")
    end

    test "refuses a key with no value" do
      assert {:error, {:missing_value, 1}} = Config.parse("url_scheme =")
    end
  end

  describe "effective/1" do
    test "resolves the required settings and the defaults" do
      assert {:ok, settings} = Config.effective(file())

      assert settings.url_scheme == :https
      assert settings.hostname == "pds.example.com"
      assert settings.port == 4000
      assert settings.data_dir == "/data"
      assert settings.mode == :single
      assert settings.registration == :closed
      assert settings.handle_domain == "pds.example.com"
      assert settings.crawler == []
      assert settings.admin_dids == []
    end

    test "stores hostname and handle domain as strings while accepting URL forms" do
      path =
        file(
          "url_scheme = https\nhostname = https://pds.example.com/path\nhandle_domain = https://handles.example.com/path\nport = 4000\ndata_dir = /data\n"
        )

      assert {:ok, settings} = Config.effective(path)
      assert settings.hostname == "pds.example.com"
      assert settings.handle_domain == "handles.example.com"
    end

    test "rejects a hostname the previous URI type could not cast" do
      path = file("url_scheme = https\nhostname = not a uri\nport = 4000\ndata_dir = /data\n")

      assert {:error, errors} = Config.effective(path)
      assert errors.hostname =~ "line 2"
    end

    test "refuses a missing file" do
      path = Path.join(System.tmp_dir!(), "pesque-missing-#{unique()}.conf")

      assert {:error, {:missing_file, ^path}} = Config.effective(path)
    end

    test "names the setting and line of a value it cannot use" do
      path =
        file("""
        url_scheme = ftp
        hostname = pds.example.com
        port = 0
        data_dir = /data
        """)

      assert {:error, errors} = Config.effective(path)
      assert errors.url_scheme =~ "line 1"
      assert errors.port =~ "line 3"
    end

    test "raises a config error with the file and the setting" do
      path =
        file("""
        url_scheme = https
        hostname = pds.example.com
        port = 0
        data_dir = /data
        """)

      error = assert_raise Pesque.Config.Error, fn -> Config.effective!(path) end

      assert Exception.message(error) =~ path
      assert Exception.message(error) =~ "port"
    end
  end

  describe "advertised origin" do
    test "uses the scheme's default port on a public hostname" do
      settings = Config.source_config!(file())

      assert settings[:public_url] == "https://pds.example.com"

      assert settings[PesqueWeb.Endpoint][:url] == [
               host: "pds.example.com",
               scheme: "https",
               port: 443
             ]
    end

    test "keeps the listening port for loopback development" do
      path = file("url_scheme = http\nhostname = localhost\nport = 4000\ndata_dir = data\n")

      settings = Config.source_config!(path)

      assert settings[:public_url] == "http://localhost:4000"

      assert settings[PesqueWeb.Endpoint][:url] == [
               host: "localhost",
               scheme: "http",
               port: 4000
             ]
    end

    test "keeps the listening port on a private host" do
      path = file("url_scheme = http\nhostname = 192.168.1.10\nport = 4000\ndata_dir = data\n")

      assert Config.source_config!(path)[:public_url] == "http://192.168.1.10:4000"
    end
  end

  describe "init/1" do
    test "carries the PDS_CONFIG lookup into the boot" do
      assert Config.init({:system, "PDS_CONFIG"}) == {:system, "PDS_CONFIG"}
    end
  end

  describe "template/0" do
    test "the committed example is the template" do
      assert File.read!("pesque.conf.example") == Config.template()
    end

    test "the template parses as the required settings" do
      assert {:ok, values} = Config.parse(Config.template())

      assert values == %{
               "url_scheme" => {"https", 4},
               "hostname" => {"pds.example.com", 5},
               "port" => {"4000", 8},
               "data_dir" => {"/data", 11}
             }
    end
  end

  defp file(
         text \\ "url_scheme = https\nhostname = pds.example.com\nport = 4000\ndata_dir = /data\n"
       ) do
    path = Path.join(System.tmp_dir!(), "pesque-#{unique()}.conf")
    File.write!(path, text)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp unique, do: System.unique_integer([:positive])
end
