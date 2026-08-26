defmodule GeoGenius.Runners.PgFlowTest do
  # `:pgflow` is not a dependency of this library -- see
  # `GeoGenius.Runners.PgFlow`'s moduledoc for why: as of 0.3.1, pgflow does
  # not compile at all without Phoenix and Phoenix LiveView present. Nothing
  # in this suite can load it, start a `PgFlow.Supervisor`, or exercise
  # `GeoGenius.Runners.PgFlow.Job` -- that module is defined only when
  # `PgFlow.Job` loads, and it never does in this repository. What this
  # suite verifies is exactly what a host without pgflow experiences:
  # `available?/0` is false, `enqueue/3` returns an error naming the
  # package rather than raising, the availability chain lands on
  # `Runners.Task` or `Runners.Inline` instead, and (in `job_outcome/2`,
  # the one piece of `Job`'s logic that lives on this always-compiled
  # module instead) every shape `GeoGenius.Pipeline.execute/3` can return.
  use ExUnit.Case, async: false

  alias GeoGenius.AppEnv
  alias GeoGenius.Catalog
  alias GeoGenius.Context
  alias GeoGenius.GraphFixture
  alias GeoGenius.ImportFixture
  alias GeoGenius.ImportRun
  alias GeoGenius.Runner
  alias GeoGenius.Runners

  setup do
    GraphFixture.teardown!()
    on_exit(&GraphFixture.teardown!/0)

    unique = System.unique_integer([:positive])
    cache_dir = Path.join(System.tmp_dir!(), "geo_genius_pgflow_cache_#{unique}")
    AppEnv.put(:cache_dir, cache_dir)
    on_exit(fn -> File.rm_rf(cache_dir) end)

    {:ok, context: Context.new(repo: GeoGenius.TestRepo, prefix: "geo_genius")}
  end

  test "name/0" do
    assert Runners.PgFlow.name() == "pgflow"
  end

  test "name/0 round-trips through Runner.module_for_backend/1" do
    # A `module_for_backend/1` that only ever searched `Runners.Task` and
    # `Runners.Inline` -- forgetting the new entry -- would still resolve
    # every name it already knew about and pass a weaker assertion; this one
    # fails unless "pgflow" specifically comes back as `Runners.PgFlow`.
    assert Runner.module_for_backend("pgflow") == {:ok, Runners.PgFlow}
  end

  test "PgFlow.Job is not loaded, so GeoGenius.Runners.PgFlow.Job does not exist" do
    # Pins the actual, current state of this repository: `:pgflow` is not
    # declared, so neither `PgFlow.Job` nor the `defmodule
    # GeoGenius.Runners.PgFlow.Job do ... end` guarded behind
    # `Code.ensure_loaded?(PgFlow.Job)` ever compiles. An implementation
    # that dropped the guard -- or guarded on the wrong module -- would
    # either fail to compile this repository at all, or leave this
    # assertion false.
    refute Code.ensure_loaded?(PgFlow.Job)
    refute Code.ensure_loaded?(Runners.PgFlow.Job)
  end

  test "available?/0 is false with :pgflow not installed" do
    # `Process.whereis(PgFlow.Supervisor)` returns `nil` regardless of
    # whether the earlier `Code.ensure_loaded?(PgFlow)` and
    # `Code.ensure_loaded?(Job)` checks ran at all, so this test cannot
    # discriminate an implementation that skipped either of them from one
    # that runs them correctly -- both still answer `false` here. What
    # this test actually pins is an implementation that answered `true`
    # unconditionally. The checks' short-circuit ordering and the
    # supervisor-running branch are not exercised by any test in this
    # repository, since nothing here can load `pgflow` or start one --
    # that is the host-only surface this whole module documents.
    refute Code.ensure_loaded?(PgFlow)
    refute Runners.PgFlow.available?()
  end

  test "enqueue/3 returns an error naming pgflow rather than raising", %{context: context} do
    {_collection, _release_id, run_id} = ImportFixture.claim_run!(context)

    # A backend that called straight into `PgFlow.enqueue/2` without
    # checking `available?/0` first would raise `UndefinedFunctionError`
    # here, since `PgFlow` does not exist anywhere in this build -- exactly
    # the crash `enqueue/3`'s `if available?() do ... end` guard exists to
    # turn into a plain, callable error instead. `assert {:error, _} = ...`
    # only passes if the call returns rather than raising.
    assert {:error, reason} = Runners.PgFlow.enqueue(context, run_id, %{publish: false})
    assert reason =~ "pgflow"
    assert reason =~ "PgFlow"

    # Left exactly where it was claimed: an enqueue that could not hand the
    # job to PgFlow at all must not touch the run's own state, the same
    # guarantee `Runners.Task` gives when it cannot reach its supervisor.
    assert Catalog.import_run(context, run_id).status == "pending"
  end

  test "unavailable_message/0 carries the whole remedy, including the Phoenix requirement" do
    message = Runners.PgFlow.unavailable_message()

    # A host that follows only part of this message -- adds `:pgflow` but
    # not Phoenix, or adds both but never force-recompiles this library --
    # hits a compile failure or a stale `Job` the message never warned
    # about. Every assertion here names one step a truncated message could
    # plausibly still pass while leaving that gap.
    assert message =~ ":pgflow"
    assert message =~ ~s({:phoenix, "~> 1.7"})
    assert message =~ ~s({:phoenix_live_view, "~> 1.0"})
    assert message =~ "mix deps.compile geo_genius --force"
    assert message =~ "pgflow.gen.job_migration"
    assert message =~ "GeoGenius.Runners.PgFlow.Job"
    assert message =~ "GeoGenius.Runner"
  end

  test "the availability chain skips PgFlow and lands on Task or Inline" do
    # Stronger than membership in the full three-backend list: `Runners.PgFlow`
    # can never be available in this repository, so `configured/1` must
    # resolve to one of the other two -- never `Runners.PgFlow` -- every
    # single time, not merely as one of three possibilities.
    assert Runner.configured([]) in [Runners.Task, Runners.Inline]
  end

  describe "job_outcome/2" do
    # `Job.run/1` -- the module that actually calls `job_outcome/2` from
    # inside PgFlow's `perform :execute` step -- never compiles in this
    # repository, so these are the only tests anywhere that cover the
    # mapping from `GeoGenius.Pipeline.execute/3`'s return shapes to the
    # plain outcome PgFlow gets back. Each clause of `Pipeline.execute/3`'s
    # own `@spec` has exactly one test below.

    test "{:ok, run} maps to a completed outcome" do
      run = %ImportRun{run_id: Ecto.UUID.generate(), status: "completed"}

      assert Runners.PgFlow.job_outcome({:ok, run}, run.run_id) == %{"outcome" => "completed"}
    end

    test "{:error, %ImportRun{}} -- a failure the pipeline already recorded -- maps to a failed outcome without raising" do
      run = %ImportRun{
        run_id: Ecto.UUID.generate(),
        status: "failed",
        error: %{"phase" => "downloading"}
      }

      # An implementation that raised on every non-`:ok` result -- rather
      # than only on the genuinely unrecorded case below -- would crash
      # this test instead of returning a plain outcome map, even though
      # the catalog already holds the failure durably.
      assert Runners.PgFlow.job_outcome({:error, run}, run.run_id) == %{"outcome" => "failed"}
    end

    test "{:error, {:unrecorded, reason}} raises naming the run rather than returning" do
      run_id = Ecto.UUID.generate()

      # A `job_outcome/2` that swallowed the `:unrecorded` case and
      # returned a plain map instead of raising would leave PgFlow with no
      # signal that nothing happened for this run id at all -- this is the
      # one assertion that would catch it.
      assert_raise RuntimeError, ~r/#{run_id}/, fn ->
        Runners.PgFlow.job_outcome({:error, {:unrecorded, "does not exist"}}, run_id)
      end
    end
  end

  describe "job_input_opts/1" do
    # `Job.run/1` -- which never compiles in this repository -- is the only
    # caller, so this is the only coverage the opts it hands to
    # `Pipeline.execute/3` ever gets.

    test "reads publish and stale_after_seconds from string-keyed input" do
      input = %{"publish" => true, "stale_after_seconds" => 120}

      assert Runners.PgFlow.job_input_opts(input) == [publish: true, stale_after_seconds: 120]
    end

    test "defaults to publish: false and stale_after_seconds: nil when input carries neither" do
      assert Runners.PgFlow.job_input_opts(%{}) == [publish: false, stale_after_seconds: nil]
    end
  end

  describe "job_context/1" do
    # Same rationale as `job_input_opts/1`: the only place this logic would
    # otherwise run is inside `Job.run/1`, which never compiles here.

    setup do
      AppEnv.put(:repo, GeoGenius.TestRepo)
    end

    test "rebuilds a context from application environment and the job's own prefix" do
      assert Runners.PgFlow.job_context(%{"prefix" => "geo_genius"}) ==
               Context.new(repo: GeoGenius.TestRepo, prefix: "geo_genius")
    end

    test "raises naming the missing key when input carries no prefix" do
      assert_raise KeyError, fn -> Runners.PgFlow.job_context(%{}) end
    end
  end
end
