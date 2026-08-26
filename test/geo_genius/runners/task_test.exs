defmodule GeoGenius.Runners.TaskTest do
  # `GeoGenius.await/3` does not exist yet -- it ships in a later task -- so
  # completion here is confirmed with a bounded poll against the catalog
  # directly, the same read `await/3` will eventually wrap.
  use ExUnit.Case, async: false

  alias GeoGenius.AppEnv
  alias GeoGenius.Catalog
  alias GeoGenius.Context
  alias GeoGenius.GraphFixture
  alias GeoGenius.ImportFixture
  alias GeoGenius.RecordingRepo
  alias GeoGenius.Runners

  @import_start [:geo_genius, :import, :start]
  @poll_interval 20
  @poll_timeout 5_000

  setup do
    GraphFixture.teardown!()
    on_exit(&GraphFixture.teardown!/0)

    unique = System.unique_integer([:positive])
    cache_dir = Path.join(System.tmp_dir!(), "geo_genius_task_cache_#{unique}")
    AppEnv.put(:cache_dir, cache_dir)
    AppEnv.restore_on_exit(:task_supervisor)

    on_exit(fn -> File.rm_rf(cache_dir) end)

    {:ok, context: Context.new(repo: GeoGenius.TestRepo, prefix: "geo_genius")}
  end

  test "name/0" do
    assert Runners.Task.name() == "task"
  end

  test "available?/0 is true with no configuration at all" do
    # GeoGenius.Application starts GeoGenius.TaskSupervisor whenever the host
    # has not configured :task_supervisor itself, so a host that configured
    # nothing gets a genuinely available backend -- not one that only looks
    # available because a config key happens to be unset.
    assert Runners.Task.available?()
  end

  test "enqueue/3 with no configuration starts the run under the library's own supervisor and it completes",
       %{context: context} do
    {_collection, _release_id, run_id} = ImportFixture.claim_run!(context)

    # No config :geo_genius, :task_supervisor is set anywhere in this test --
    # that is the point being proven. A regression back to requiring host
    # configuration would return {:error, reason} here instead of :ok.
    assert :ok = Runners.Task.enqueue(context, run_id, %{publish: false})

    assert poll_status!(context, run_id) == "completed"
  end

  test "enqueue/3 with a configured but dead supervisor names it instead of exiting", %{
    context: context
  } do
    Application.put_env(:geo_genius, :task_supervisor, GeoGenius.Runners.TaskTest.DeadSupervisor)
    {_collection, _release_id, run_id} = ImportFixture.claim_run!(context)

    # A prior implementation called `Task.Supervisor.start_child/2` against
    # whatever name the config held without checking it first, which exits
    # the calling process with `{:noproc, ...}` here rather than returning
    # `{:error, reason}` -- exactly the failure the no-`spawn/1` rule exists
    # to prevent, just arrived at through the supervised path instead.
    assert {:error, reason} = Runners.Task.enqueue(context, run_id, %{publish: false})
    assert reason =~ "GeoGenius.Runners.TaskTest.DeadSupervisor"

    assert Catalog.import_run(context, run_id).status == "pending"
  end

  test "enqueue/3 surfaces a live supervisor's refusal to start the child instead of swallowing it",
       %{context: context} do
    # A supervisor that is genuinely running can still refuse the child --
    # :max_children here stands in for any start_child failure. Nothing was
    # started, so :ok would be a lie a caller acts on by polling a run that
    # stays pending forever; the refusal must come back as the named error
    # enqueue/3's spec promises.
    name = Module.concat(__MODULE__, "FullSup#{System.unique_integer([:positive])}")
    start_supervised!({Elixir.Task.Supervisor, name: name, max_children: 0})
    Application.put_env(:geo_genius, :task_supervisor, name)

    {_collection, _release_id, run_id} = ImportFixture.claim_run!(context)

    assert {:error, reason} = Runners.Task.enqueue(context, run_id, %{publish: false})
    assert reason =~ "max_children"
    assert reason =~ inspect(name)

    assert Catalog.import_run(context, run_id).status == "pending"
  end

  test "enqueue/3 starts the run under the configured supervisor and it completes", %{
    context: context
  } do
    start_supervisor!()
    {_collection, _release_id, run_id} = ImportFixture.claim_run!(context)

    assert :ok = Runners.Task.enqueue(context, run_id, %{publish: false})

    assert poll_status!(context, run_id) == "completed"
  end

  test "publish: true reaches the pipeline running under the supervisor", %{context: context} do
    start_supervisor!()
    {collection, release_id, run_id} = ImportFixture.claim_run!(context)

    assert :ok = Runners.Task.enqueue(context, run_id, %{publish: true})
    assert poll_status!(context, run_id) == "completed"

    assert Catalog.published_release(context, collection) == release_id
  end

  test "enqueue/3 forwards :stale_after_seconds into the pipeline's derived timeout",
       %{context: context} do
    {_collection, _release_id, run_id} = ImportFixture.claim_run!(context)
    recording_context = %{context | repo: RecordingRepo}
    RecordingRepo.record_to(self())
    on_exit(&RecordingRepo.stop_recording_to/0)

    # Runners.Inline pins this same forwarding contract; this is the Task
    # side of it. An implementation that built opts without
    # :stale_after_seconds -- or dropped or replaced its value -- would
    # still return :ok and complete the run under Pipeline's 900_000ms
    # default; only the derived, non-default timeout on the actual SQL
    # distinguishes it, read here from the test's own mailbox because the
    # executing process's dies with it.
    assert :ok = Runners.Task.enqueue(recording_context, run_id, %{stale_after_seconds: 30})
    assert poll_status!(context, run_id) == "completed"

    recorded = RecordingRepo.recorded()

    assert RecordingRepo.options_for(recorded, "rebuild_relations")[:timeout] == 30_000
  end

  test "enqueue/3 with the library's own supervisor stopped names the application, not host config",
       %{context: context} do
    # The default supervisor's death is the one resolve/0 arm nothing else
    # can reach: GeoGenius.Application keeps GeoGenius.TaskSupervisor alive
    # for the entire suite. Terminate it inside this test's own window --
    # public_ingestion_test.exs, the only other file that resolves a runner
    # unpinned, is async: false and cannot overlap (see application_test.exs,
    # which uses the same reasoning for its start/2 window) -- and restore
    # it in `after` even when an assertion fails partway through. The error
    # must tell this host the truth: the :geo_genius application is not
    # running its supervisor, not that some never-written :task_supervisor
    # config names a dead process.
    :ok = Supervisor.terminate_child(GeoGenius.Supervisor, GeoGenius.TaskSupervisor)

    try do
      refute Runners.Task.available?()

      assert {:error, reason} =
               Runners.Task.enqueue(context, Ecto.UUID.generate(), %{publish: false})

      assert reason =~ "GeoGenius.TaskSupervisor is not running"
      assert reason =~ "GeoGenius.Application was not skipped or stopped"
      refute reason =~ "config :geo_genius, :task_supervisor names"
    after
      {:ok, _pid} = Supervisor.restart_child(GeoGenius.Supervisor, GeoGenius.TaskSupervisor)
    end
  end

  @tag capture_log: true
  test "a task killed mid-run is not restarted -- recovery belongs to the lease, not the supervisor",
       %{context: context} do
    {_collection, _release_id, run_id} = ImportFixture.claim_run!(context)
    kills_remaining = :counters.new(1, [])
    :counters.put(kills_remaining, 1, 1)
    report_execution_and_kill_once(run_id, kills_remaining)

    assert :ok = Runners.Task.enqueue(context, run_id, %{publish: false})

    # The handler reports each distinct execution of this run once, at its
    # first phase span, then brutal-kills the first one. start_child/2's
    # default restart: :temporary means an abnormal exit is final -- the
    # run is left claimed, for the lease to reclaim once stale_after
    # elapses, exactly as Runners.Task's moduledoc promises ("it is the
    # lease, not the supervisor, that eventually reclaims it"). Under
    # restart: :transient or :permanent the supervisor re-runs the fun in
    # a fresh process, whose own first span reports a second execution.
    assert_receive {:executed, first_pid}, 2_000
    refute first_pid == self()
    refute_receive {:executed, _restarted_pid}, 500

    refute Catalog.import_run(context, run_id).status in ["completed", "failed"]
  end

  # Attaches a handler that reports each distinct executing process of this
  # run to the test -- once per process, at its first
  # [:geo_genius, :import, :start] span, which telemetry runs in the
  # emitting process itself -- and brutal-kills the first, so long as the
  # cross-process kill budget allows. Process.exit(self(), :kill) is the
  # one exit a telemetry handler can deliver that the emitting process
  # cannot rescue, and the report is sent before it lands.
  defp report_execution_and_kill_once(run_id, kills_remaining) do
    test_pid = self()
    handler_id = {__MODULE__, run_id}

    :telemetry.attach(
      handler_id,
      @import_start,
      fn _event, _measurements, metadata, _config ->
        report_execution(metadata, run_id, test_pid, kills_remaining)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp report_execution(metadata, run_id, test_pid, kills_remaining) do
    if metadata.run_id == run_id and not Process.get(:task_test_execution_reported, false) do
      Process.put(:task_test_execution_reported, true)
      send(test_pid, {:executed, self()})
      kill_within_budget(kills_remaining)
    end

    :ok
  end

  defp kill_within_budget(kills_remaining) do
    if :counters.get(kills_remaining, 1) > 0 do
      :counters.put(kills_remaining, 1, 0)
      Process.exit(self(), :kill)
    end
  end

  defp start_supervisor! do
    name = Module.concat(__MODULE__, "Sup#{System.unique_integer([:positive])}")
    start_supervised!({Elixir.Task.Supervisor, name: name})
    Application.put_env(:geo_genius, :task_supervisor, name)
    name
  end

  defp poll_status!(context, run_id) do
    deadline = System.monotonic_time(:millisecond) + @poll_timeout
    poll_status!(context, run_id, deadline)
  end

  defp poll_status!(context, run_id, deadline) do
    run = Catalog.import_run(context, run_id)

    cond do
      run.status in ["completed", "failed"] ->
        run.status

      System.monotonic_time(:millisecond) > deadline ->
        flunk("run #{run_id} did not finish within #{@poll_timeout}ms (status: #{run.status})")

      true ->
        Process.sleep(@poll_interval)
        poll_status!(context, run_id, deadline)
    end
  end
end
