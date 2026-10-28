defmodule Pesque.ConfigTest do
  @moduledoc """
  The config file is a small grammar, and the ways it can be wrong are a typo,
  a retired key and a value the server cannot use. All of them fail boot
  rather than being ignored, so they are tested as errors with a line number.
  """

  use ExUnit.Case, async: false

  alias Pesque.Config
  alias Pesque.Did

  describe "parse/1" do
    test "reads keys, values, comments and blank lines" do
      text = """
      # a comment
      public_url = https://pds.example.com

      mode = multi # trailing comment
      port=4000
      """

      assert {:ok, values} = Config.parse(text)

      assert values == %{
               "public_url" => {"https://pds.example.com", 2},
               "mode" => {"multi", 4},
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

    test "names the replacement of a retired key" do
      assert {:error, {:retired_key, "hostname", 2, advice}} =
               Config.parse("port = 1\nhostname = pds.example.com")

      assert advice =~ "public_url"
    end

    test "names the line of a repeated key" do
      assert {:error, {:duplicate_key, "port", 2}} = Config.parse("port = 1\nport = 2")
    end

    test "refuses a line with no equals sign" do
      assert {:error, {:invalid_line, 1}} = Config.parse("public_url https://pds.example.com")
    end

    test "refuses a key with no value" do
      assert {:error, {:missing_value, 1}} = Config.parse("public_url =")
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

  describe "resolve/2" do
    test "derives the address, the defaults and the handle domain from public_url" do
      assert {:ok, settings} = Config.resolve(%{"public_url" => "https://pds.example.com"})

      assert settings.public_url == "https://pds.example.com"
      assert settings.hostname == "pds.example.com"
      assert settings.url_scheme == "https"
      assert settings.url_port == 443
      assert settings.port == 4000
      assert settings.mode == :single
      assert settings.registration == :closed
      assert settings.handle_domain == "pds.example.com"
      assert settings.crawler == []
      assert settings.lexicon_aggregator == nil
      assert settings.admin_dids == []
      assert settings.privacy_policy_url == ""
      assert settings.terms_of_service_url == ""
    end

    test "keeps the listening port separate from an advertised http port" do
      assert {:ok, settings} =
               Config.resolve(%{"public_url" => "http://localhost:4000", "port" => "4000"})

      assert settings.public_url == "http://localhost:4000"
      assert settings.hostname == "localhost"
      assert settings.url_scheme == "http"
      assert settings.url_port == 4000
      assert settings.port == 4000
    end

    test "accepts a nonstandard advertised port without moving the listener" do
      assert {:ok, settings} =
               Config.resolve(%{
                 "public_url" => "https://pds.example.com:8443",
                 "port" => "4000"
               })

      assert settings.url_port == 8443
      assert settings.port == 4000
    end

    test "derives an explicit handle domain and the remaining knobs" do
      assert {:ok, settings} =
               Config.resolve(%{
                 "public_url" => "https://pds.example.com",
                 "mode" => "multi",
                 "handle_domain" => "Example.COM",
                 "registration" => "open",
                 "crawler" => "https://bsky.network, https://relay.example.com",
                 "admin_dids" => "did:plc:one, did:plc:two",
                 "blob_upload_limit" => "1048576",
                 "repo_import_limit" => "2097152",
                 "proxy_timeout" => "1000",
                 "proxy_response_limit" => "2048",
                 "privacy_policy_url" => "https://example.com/privacy",
                 "terms_of_service_url" => "https://example.com/terms"
               })

      assert settings.mode == :multi
      assert settings.handle_domain == "example.com"
      assert settings.registration == :open
      assert settings.crawler == ["https://bsky.network", "https://relay.example.com"]
      assert settings.admin_dids == ["did:plc:one", "did:plc:two"]
      assert settings.blob_upload_limit == 1_048_576
      assert settings.repo_import_limit == 2_097_152
      assert settings.proxy_timeout == 1000
      assert settings.proxy_response_limit == 2048
      assert settings.privacy_policy_url == "https://example.com/privacy"
      assert settings.terms_of_service_url == "https://example.com/terms"
    end

    test "uses the development public URL when the file has none" do
      assert Config.development?()
      assert {:ok, settings} = Config.resolve(%{})
      assert settings.public_url == "http://localhost:4000"
    end

    test "requires public_url in a deployment" do
      defaults = Map.put(Config.defaults(), "public_url", nil)

      assert {:error, {:missing_setting, "public_url", advice}} =
               Config.resolve(%{}, defaults)

      assert advice =~ "public_url"
    end

    test "refuses an origin with a path, query, fragment or credentials" do
      for public_url <- [
            "https://pds.example.com/path",
            "https://pds.example.com?x=1",
            "https://pds.example.com#fragment",
            "https://user:pass@pds.example.com",
            "ftp://pds.example.com",
            "https:///path"
          ] do
        assert {:error, {:invalid_setting, "public_url", ^public_url, _expectation, nil}} =
                 Config.resolve(%{"public_url" => public_url})
      end
    end

    test "refuses invalid port, mode, registration and limits" do
      assert {:error, {:invalid_setting, "port", "0", _expectation, nil}} =
               Config.resolve(%{"public_url" => "https://x.test", "port" => "0"})

      assert {:error, {:invalid_setting, "mode", "path_multi", _expectation, nil}} =
               Config.resolve(%{"public_url" => "https://x.test", "mode" => "path_multi"})

      assert {:error, {:invalid_setting, "registration", "first", _expectation, nil}} =
               Config.resolve(%{
                 "public_url" => "https://x.test",
                 "registration" => "first"
               })

      assert {:error, {:invalid_setting, "blob_upload_limit", "-1", _expectation, nil}} =
               Config.resolve(%{"public_url" => "https://x.test", "blob_upload_limit" => "-1"})
    end

    test "refuses a non-https lexicon aggregator" do
      assert {:error,
              {:invalid_setting, "lexicon_aggregator", "http://x.test", _expectation, nil}} =
               Config.resolve(%{
                 "public_url" => "https://pds.example.com",
                 "lexicon_aggregator" => "http://x.test"
               })
    end

    # public_url replaces hostname, url_scheme and url_port, but the identity
    # rules did not move: did:web still derives from the listening port, so a
    # proxy's nonstandard advertised port does not rewrite the host DID.
    test "does not change how did:web derives from the host and listening port" do
      assert {:ok, settings} =
               Config.resolve(%{
                 "public_url" => "https://pds.example.com:8443",
                 "port" => "4000"
               })

      assert Did.did_for_username(:single, Did.did_host(settings.hostname, settings.port), nil) ==
               "did:web:pds.example.com"

      assert {:ok, local} =
               Config.resolve(%{"public_url" => "http://localhost:8080", "port" => "4000"})

      assert Did.did_for_username(:single, Did.did_host(local.hostname, local.port), nil) ==
               "did:web:localhost%3A4000"
    end
  end

  describe "validate_env/0" do
    test "PDS_CONFIG and the development PLC switch pass" do
      System.put_env("PDS_CONFIG", "somewhere.conf")
      System.put_env("PDS_PLC_LOCAL", "true")

      on_exit(fn ->
        System.delete_env("PDS_CONFIG")
        System.delete_env("PDS_PLC_LOCAL")
      end)

      assert Config.validate_env() == :ok
    end

    test "a per-setting environment variable is refused, naming it" do
      System.put_env("PDS_HOSTNAME", "pds.example.com")
      on_exit(fn -> System.delete_env("PDS_HOSTNAME") end)

      assert {:error, {:unknown_env, ["PDS_HOSTNAME"]}} = Config.validate_env()
    end

    test "the retired internal variables are refused too" do
      System.put_env("PDS_TAG", "1.14.2")
      System.put_env("PDS_PUBLIC_IP", "203.0.113.7")

      on_exit(fn ->
        System.delete_env("PDS_TAG")
        System.delete_env("PDS_PUBLIC_IP")
      end)

      assert {:error, {:unknown_env, ["PDS_PUBLIC_IP", "PDS_TAG"]}} = Config.validate_env()
    end

    test "a typo the file layer would refuse is refused here too" do
      System.put_env("PDS_NOT_A_REAL_KEY", "1")
      on_exit(fn -> System.delete_env("PDS_NOT_A_REAL_KEY") end)

      assert {:error, {:unknown_env, ["PDS_NOT_A_REAL_KEY"]}} = Config.validate_env()
    end

    test "variables of other namespaces are none of this layer's business" do
      System.put_env("PESQUE_BACKEND", "docker")
      on_exit(fn -> System.delete_env("PESQUE_BACKEND") end)

      assert Config.validate_env() == :ok
    end
  end

  describe "resolution/0" do
    test "reports effective values with their source, derived values included" do
      path =
        Path.join(System.tmp_dir!(), "pesque-where-#{System.unique_integer([:positive])}.conf")

      File.write!(path, "public_url = https://file.example.com\nport = 9000\n")
      on_exit(fn -> File.rm(path) end)

      previous = System.get_env("PDS_CONFIG")
      System.put_env("PDS_CONFIG", path)
      on_exit(fn -> restore_config(previous) end)

      assert {:ok, entries} = Config.resolution()

      assert {"public_url", "https://file.example.com", {:file, 1}} in entries
      assert {"port", 9000, {:file, 2}} in entries
      assert {"hostname", "file.example.com", {:derived, "public_url"}} in entries
      assert {"url_scheme", "https", {:derived, "public_url"}} in entries
      assert {"url_port", 443, {:derived, "public_url"}} in entries
      assert {"mode", :single, :default} in entries
      assert {"handle_domain", "file.example.com", {:derived, "public_url"}} in entries
    end

    test "reports a value the runtime would refuse instead of only provenance" do
      path =
        Path.join(
          System.tmp_dir!(),
          "pesque-where-bad-#{System.unique_integer([:positive])}.conf"
        )

      File.write!(path, "public_url = https://file.example.com\nport = 99999\n")
      on_exit(fn -> File.rm(path) end)

      previous = System.get_env("PDS_CONFIG")
      System.put_env("PDS_CONFIG", path)
      on_exit(fn -> restore_config(previous) end)

      assert {:error, {:invalid_setting, "port", "99999", _expectation, 2}} =
               Config.resolution()
    end
  end

  describe "template/0" do
    test "the committed example is the template, so the two cannot drift" do
      assert File.read!("pesque.conf.example") == Config.template()
    end

    test "the template has one live setting and parses as that setting" do
      assert {:ok, values} = Config.parse(Config.template())
      assert values == %{"public_url" => {"https://pds.example.com", 4}}
    end
  end

  defp restore_config(previous) do
    if previous, do: System.put_env("PDS_CONFIG", previous), else: System.delete_env("PDS_CONFIG")
  end
end
