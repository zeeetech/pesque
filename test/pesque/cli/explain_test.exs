defmodule Pesque.Cli.ExplainTest do
  @moduledoc """
  The operator copy: every reason renders, the known ones render the sentence
  the operator acts on, and the catalog actually translates. The locale is
  pinned and the assertions read the English msgids, so the tests do not move
  under the translations.
  """

  use ExUnit.Case, async: false

  alias Pesque.Cli.Explain

  setup do
    Gettext.put_locale(PesqueWeb.Gettext, "en")
    :ok
  end

  describe "for_reason/1" do
    test "splits the copy that ends in an instruction into problem and next" do
      explanation = Explain.for_reason(:plc_code_missing)

      assert explanation.problem == "no PLC code was read"
      assert explanation.next =~ "MIGRATE_PLC_TOKEN"
      assert explanation.detail == nil

      explanation = Explain.for_reason(:no_input)

      assert explanation.problem == "nothing was read from the prompt"
      assert explanation.next =~ "stdin"
      assert explanation.detail == nil
    end

    test "answers nil next where the problem needs no instruction" do
      assert %{next: nil} = Explain.for_reason(:email_required)
      assert %{next: nil} = Explain.for_reason(:password_too_short)
      assert %{next: nil} = Explain.for_reason(:account_exists)
      assert %{next: nil} = Explain.for_reason({:unwritable, "/tmp/x", :eacces})
    end

    test "names the old PDS's own message, so a bare status is not all a caller sees" do
      explanation = Explain.for_reason({:old_pds_status, 400, "A request body was provided"})

      assert explanation.problem == "the old PDS answered 400: A request body was provided"

      assert %{problem: "the old PDS answered 401"} = Explain.for_reason({:old_pds_status, 401})
    end

    test "carries the values the reason brought with it" do
      explanation = Explain.for_reason(:handle_not_under_domain)

      assert explanation.problem =~ Pesque.handle_domain()
      assert explanation.next =~ Pesque.handle_domain()

      assert %{problem: "the password must be at least 8 characters"} =
               Explain.for_reason(:password_too_short)
    end

    test "the fallback apologizes, asks for a report, and keeps the raw reason" do
      explanation = Explain.for_reason({:unexpected, 42})

      assert explanation.problem =~ "could not complete the operation"
      assert explanation.next =~ "PESQUE_DEBUG=1"
      assert explanation.detail == "{:unexpected, 42}"
    end

    test "is total: a sample of reasons and an unmapped one all answer a well-formed map" do
      reasons = [
        :handle_not_available,
        :too_large,
        :not_found,
        :no_crawler_configured,
        :locked,
        {:unknown_key, "hostnmae", 1},
        {:retired_key, "hostname", 1, "set public_url instead"},
        {:missing_setting, "public_url", "set public_url in pesque.conf"},
        {:invalid_setting, "port", "0", "must be an integer between 1 and 65535", 2},
        {:unreadable, "/tmp/pesque.conf", :enoent},
        {:bad_archive, :no_manifest},
        {:swap_failed, "config", :eexist},
        {:unsupported_backup_version, 7},
        {:unexpected, 42}
      ]

      for reason <- reasons do
        assert %{problem: problem, next: next, detail: detail} = Explain.for_reason(reason)
        assert is_binary(problem) and problem != ""
        assert is_binary(next) or next == nil
        # detail carries the raw reason on the fallback alone.
        assert detail == nil or reason == {:unexpected, 42}
      end
    end
  end

  describe "render/1" do
    test "renders the problem alone when there is no next step" do
      assert Explain.render(:email_required) == "an email address is required"
    end

    test "indents the next step by two spaces on its own line" do
      rendered = Explain.render(:plc_code_missing)

      assert rendered ==
               "no PLC code was read\n  run this where the prompt can be answered, or set MIGRATE_PLC_TOKEN"
    end

    test "the fallback renders the detail line too" do
      assert Explain.render({:unexpected, 42}) =~ "\n  {:unexpected, 42}"
    end
  end

  describe "the catalog" do
    test "renders Portuguese under pt_BR" do
      Gettext.put_locale(PesqueWeb.Gettext, "pt_BR")

      explanation = Explain.for_reason(:handle_not_available)

      assert explanation.problem =~ "em uso"
      assert explanation.next =~ "outro nome"
    end
  end
end
