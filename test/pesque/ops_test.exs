defmodule Pesque.OpsTest do
  @moduledoc """
  The contract of record is documentation-as-code, so the doc is tested: the
  primitives are exactly the driver table, and the release wrapper dispatches
  the same verb list the CLI answers, so a verb added on one side and not the
  other fails here.
  """

  use ExUnit.Case, async: true

  @callbacks [
    data_dir: 0,
    run_once: 1,
    up: 0,
    down: 0,
    restart: 0,
    pull: 1,
    logs: 1,
    health: 0,
    interactive?: 0,
    owns_lifecycle?: 0
  ]

  test "the driver contract is exactly these primitives" do
    assert Pesque.Ops.behaviour_info(:callbacks) |> Enum.sort() == Enum.sort(@callbacks)
  end

  test "run_once carries the verb, argv, env, mounts and the interactive flag" do
    run = %Pesque.Ops.RunOnce{verb: "doctor", env: %{"PDS_SERVE" => "false"}}

    assert run.verb == "doctor"
    assert run.argv == []
    assert run.env == %{"PDS_SERVE" => "false"}
    assert run.mounts == %{}
    refute run.interactive?
  end

  test "the verbs are the fixed list the spec's wrapper names" do
    assert Pesque.Cli.verbs() ==
             ~w(account invite migrate doctor status backup restore config crawl)
  end

  test "the release wrapper dispatches the CLI's verbs through one eval" do
    wrapper = Pesque.Mix.ReleaseSteps.wrapper()

    for verb <- Pesque.Cli.verbs() do
      assert wrapper =~ verb, "the wrapper does not name the #{verb} verb"
    end

    assert wrapper =~ "#!/bin/sh"
    assert wrapper =~ "pesque.core"
    assert wrapper =~ ~s[exec "$CORE" eval 'Pesque.Cli.main()' "$@"]
  end
end
