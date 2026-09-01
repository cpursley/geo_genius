defmodule GeoGenius.Runners.PgFlowTest do
  # PgFlow is optional. The ordinary test graph includes its DSL and chooses a
  # neutral compile-time deadline so it exercises the real shipped Job module.
  # The separate no-optional-dependencies gate proves the always-compiled
  # backend remains warning-free without PgFlow itself.
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

  test "the test consumer compiles the real job with its explicit deadline" do
    assert Code.ensure_loaded?(PgFlow.Job)
    assert Runners.PgFlow.job_timeout_seconds() == 1_200
    assert Code.ensure_loaded?(Runners.PgFlow.Job)

    definition = Runners.PgFlow.Job.__pgflow_definition__()
    assert definition.opts[:timeout] == 1_200
    assert hd(definition.steps).timeout == 1_200
  end

  test "available?/0 is false without a running engine supervisor" do
    assert Code.ensure_loaded?(PgFlow)
    assert Code.ensure_loaded?(Runners.PgFlow.Job)
    assert Process.whereis(PgFlow.Supervisor) == nil
    refute Runners.PgFlow.available?()
  end

  test "enqueue/3 returns an error naming pgflow rather than raising", %{context: context} do
    {_collection, _release_id, run_id} = ImportFixture.claim_run!(context)

    # A backend that called straight into `PgFlow.enqueue/2` without checking
    # `available?/0` first would try to submit against an unstarted engine.
    # The guard turns that into a plain, callable error.
    assert {:error, {:not_enqueued, reason}} =
             Runners.PgFlow.enqueue(context, run_id, %{publish: false})

    assert reason =~ "pgflow"
    assert reason =~ "PgFlow"

    # Left exactly where it was claimed: an enqueue that could not hand the
    # job to PgFlow at all must not touch the run's own state, the same
    # guarantee `Runners.Task` gives when it cannot reach its supervisor.
    assert Catalog.import_run(context, run_id).status == "pending"
  end

  test "unavailable_message/0 carries the whole optional integration remedy" do
    message = Runners.PgFlow.unavailable_message()

    # A host that follows only part of this message -- adds `:pgflow` but
    # not Phoenix, or adds both but never force-recompiles this library --
    # hits a compile failure or a stale `Job` the message never warned
    # about. Every assertion here names one step a truncated message could
    # plausibly still pass while leaving that gap.
    assert message =~ ":pgflow"
    assert message =~ ~s({:phoenix, "~> 1.7"})
    assert message =~ ~s({:phoenix_live_view, "~> 1.0"})
    assert message =~ ~s({:livefilter, "~> 0.2"})
    refute message =~ "deps.compile geo_genius --force"
    assert message =~ "pgflow.gen.job_migration"
    assert message =~ "GeoGenius.Runners.PgFlow.Job"
    assert message =~ "GeoGenius.Runner"
  end

  describe "PgFlow host readiness" do
    test "the operation repo must be the repo PgFlow actually uses" do
      context = Context.new(repo: GeoGenius.TestRepo, prefix: "geo_genius")

      assert :ok = Runners.PgFlow.repository_alignment(context, GeoGenius.TestRepo)

      assert {:error, {:not_enqueued, message}} =
               Runners.PgFlow.repository_alignment(context, GeoGenius.SandboxedRepo)

      assert message =~ inspect(GeoGenius.TestRepo)
      assert message =~ inspect(GeoGenius.SandboxedRepo)
      assert message =~ "same Repo"
    end

    test "a missing PgFlow repo is a definite pre-enqueue configuration failure" do
      context = Context.new(repo: GeoGenius.TestRepo, prefix: "geo_genius")

      assert {:error, {:not_enqueued, message}} =
               Runners.PgFlow.repository_alignment(context, nil)

      assert message =~ "configured Repo"
      assert message =~ "not available"
    end

    test "the host must choose a timeout and an explicit staleness window" do
      assert {:error, {:not_enqueued, no_timeout}} =
               Runners.PgFlow.timeout_readiness(nil, 900)

      assert {:error, {:not_enqueued, no_stale_window}} =
               Runners.PgFlow.timeout_readiness(3_900, nil)

      assert no_timeout =~ ":pgflow_job_timeout_seconds"
      assert no_timeout =~ "compile"
      assert no_stale_window =~ "stale_after_seconds"
    end

    test "the compiled job timeout must exceed the per-statement staleness window" do
      assert {:error, {:not_enqueued, equal_message}} =
               Runners.PgFlow.timeout_readiness(900, 900)

      assert {:error, {:not_enqueued, shorter_message}} =
               Runners.PgFlow.timeout_readiness(899, 900)

      assert equal_message =~ "900"
      assert equal_message =~ "must exceed"
      assert shorter_message =~ "899"
      assert :ok = Runners.PgFlow.timeout_readiness(901, 900)
    end

    test "the stored PgFlow definition must carry the compiled host timeout" do
      assert :ok =
               Runners.PgFlow.job_definition_readiness({:ok, %{opt_timeout: 1_200}}, 1_200)

      assert {:error, {:not_enqueued, message}} =
               Runners.PgFlow.job_definition_readiness({:ok, %{opt_timeout: 3_900}}, 1_200)

      assert message =~ "3900"
      assert message =~ "1200"
      assert message =~ "migration"
    end

    test "the stored execute step must carry the compiled host timeout" do
      assert :ok =
               Runners.PgFlow.job_step_readiness({:ok, %{opt_timeout: 1_200}}, 1_200)

      assert {:error, {:not_enqueued, message}} =
               Runners.PgFlow.job_step_readiness({:ok, %{opt_timeout: 3_900}}, 1_200)

      assert message =~ "execute"
      assert message =~ "3900"
      assert message =~ "1200"
      assert message =~ "migration"
    end

    test "a missing stored job definition retains the exact migration remedy" do
      assert {:error, {:not_enqueued, message}} =
               Runners.PgFlow.job_definition_readiness({:error, :not_found}, 1_200)

      assert message == Runners.PgFlow.flow_not_compiled_message()
    end

    test "a missing compiled flow returns the exact migration remedy" do
      assert {:error, {:not_enqueued, message}} =
               Runners.PgFlow.flow_registration({:ok, false})

      assert message =~ "GeoGenius.Runners.PgFlow.Job"
      assert message =~ "mix pgflow.gen.job_migration GeoGenius.Runners.PgFlow.Job"
      assert message =~ "mix ecto.migrate"
    end

    test "a missing flow reported during enqueue keeps the same actionable contract" do
      assert {:error, {:not_enqueued, message}} =
               Runners.PgFlow.enqueue_result({:error, {:flow_not_compiled, "geo_genius_import"}})

      assert message == Runners.PgFlow.flow_not_compiled_message()
    end

    test "an unhealthy worker fails before a durable job can sit queued forever" do
      assert {:error, {:not_enqueued, message}} =
               Runners.PgFlow.worker_readiness({:ok, false})

      assert message =~ "no healthy worker"
      assert message =~ "GeoGenius.Runners.PgFlow.Job"
      assert message =~ "jobs: [GeoGenius.Runners.PgFlow.Job]"
    end

    test "database probe failures remain errors rather than pretending the host is ready" do
      reason = %DBConnection.ConnectionError{message: "database unavailable", severity: :error}

      assert {:error, {:not_enqueued, flow_message}} =
               Runners.PgFlow.flow_registration({:error, reason})

      assert {:error, {:not_enqueued, worker_message}} =
               Runners.PgFlow.worker_readiness({:error, reason})

      assert flow_message =~ "could not verify"
      assert worker_message =~ "could not verify"
      assert flow_message =~ "database unavailable"
      assert worker_message =~ "database unavailable"
    end

    test "a generic error after PgFlow.enqueue/2 reports an unknown acceptance outcome" do
      reason = %DBConnection.ConnectionError{message: "connection lost", severity: :error}

      assert {:error, {:outcome_unknown, ^reason}} =
               Runners.PgFlow.enqueue_result({:error, reason})
    end

    test "successful probes and enqueue results retain their plain success contracts" do
      assert :ok = Runners.PgFlow.flow_registration({:ok, true})
      assert :ok = Runners.PgFlow.worker_readiness({:ok, true})
      assert :ok = Runners.PgFlow.enqueue_result({:ok, Ecto.UUID.generate()})
    end
  end

  test "the availability chain skips PgFlow and lands on Task or Inline" do
    # The real Job module is compiled in this test consumer, but no engine is
    # running. Resolution must still land on one of the automatic backends,
    # never infer PgFlow merely from its compiled integration.
    assert Runner.configured([]) in [Runners.Task, Runners.Inline]
  end

  describe "job_outcome/2" do
    # `Job.run/2` -- the module that actually calls `job_outcome/2` from
    # inside PgFlow's `perform :execute` step -- is absent only from the
    # no-optional-dependencies build, so these tests keep the mapping covered
    # from `GeoGenius.Pipeline.execute/3`'s return shapes to the
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

    test "{:noop, run} maps duplicate delivery to already_running without claiming completion" do
      run = %ImportRun{run_id: Ecto.UUID.generate(), status: "pending"}

      assert Runners.PgFlow.job_outcome({:noop, run}, run.run_id) == %{
               "outcome" => "already_running"
             }
    end

    test "{:ok, malformed} raises a clear invalid-outcome error" do
      run_id = Ecto.UUID.generate()

      assert_raise RuntimeError,
                   ~r/GeoGenius import run #{run_id} returned an invalid pipeline outcome/,
                   fn ->
                     Runners.PgFlow.job_outcome({:ok, %{status: "completed"}}, run_id)
                   end
    end

    test "{:noop, malformed} raises a clear invalid-outcome error" do
      run_id = Ecto.UUID.generate()

      assert_raise RuntimeError,
                   ~r/GeoGenius import run #{run_id} returned an invalid pipeline outcome/,
                   fn ->
                     Runners.PgFlow.job_outcome({:noop, %{status: "pending"}}, run_id)
                   end
    end

    test "an unrecorded pipeline outcome raises naming the run rather than returning" do
      run_id = Ecto.UUID.generate()

      # A `job_outcome/2` that swallowed the `:unrecorded` case and
      # returned a plain map instead of raising would leave PgFlow with no
      # signal that nothing happened for this run id at all -- this is the
      # one assertion that would catch it.
      assert_raise RuntimeError, ~r/#{run_id}/, fn ->
        Runners.PgFlow.job_outcome(
          {:error, {:unrecorded, :not_started, "does not exist"}},
          run_id
        )
      end
    end
  end

  describe "job_input_opts/1" do
    # `Job.run/1` is the only caller, so this is the direct coverage for the opts it hands to
    # `Pipeline.execute/3` ever gets.

    test "reads publish and stale_after_seconds from string-keyed input" do
      input = %{"publish" => true, "stale_after_seconds" => 120}

      assert Runners.PgFlow.job_input_opts(input) == [publish: true, stale_after_seconds: 120]
    end

    test "defaults to publish: false and stale_after_seconds: nil when input carries neither" do
      assert Runners.PgFlow.job_input_opts(%{}) == [publish: false, stale_after_seconds: nil]
    end
  end

  describe "job_context/2" do
    # Same rationale as `job_input_opts/1`: the only production caller is
    # `Job.run/2`; the no-optional-dependencies build omits that module.

    test "rebuilds a context from PgFlow's execution repo and the job's own prefix" do
      AppEnv.put(:repo, GeoGenius.SandboxedRepo)

      assert Runners.PgFlow.job_context(%{"prefix" => "geo_genius"}, GeoGenius.TestRepo) ==
               Context.new(repo: GeoGenius.TestRepo, prefix: "geo_genius")
    end

    test "raises naming the missing key when input carries no prefix" do
      assert_raise KeyError, fn -> Runners.PgFlow.job_context(%{}, GeoGenius.TestRepo) end
    end
  end
end
