defmodule Pesque.ReleaseTest do
  use ExUnit.Case, async: false

  alias Pesque.Release

  describe "describe_error/1" do
    test "turns the account errors a person can hit into sentences" do
      assert Release.describe_error(:handle_not_available) =~ "taken"

      # "not under this domain" and "taken" used to be one sentence, so the
      # operator could not tell which they had. The domain one names the
      # domain, which is what the operator acts on.
      assert Release.describe_error(:handle_not_under_domain) =~ Pesque.handle_domain()

      assert Release.describe_error(:invalid_handle) =~ "valid handle"
      assert Release.describe_error(:account_exists) =~ "already has an account"
      assert Release.describe_error(:password_too_short) =~ "8 characters"
      assert Release.describe_error(:email_required) =~ "email"
    end

    test "falls back to inspect for a reason it does not know" do
      assert Release.describe_error({:unexpected, 42}) == "{:unexpected, 42}"
    end

    test "names the old PDS's own message, so a bare status is not all a caller sees" do
      assert Release.describe_error({:old_pds_status, 400, "A request body was provided"}) =~
               "the old PDS answered 400: A request body was provided"

      assert Release.describe_error({:old_pds_status, 401}) == "the old PDS answered 401"
    end
  end
end
