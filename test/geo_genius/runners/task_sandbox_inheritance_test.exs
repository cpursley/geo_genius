defmodule GeoGenius.Runners.TaskSandboxInheritanceTest do
  # Proves guides/installation.md's "Runners.Task needs no sandbox setup,
  # with two real caveats" is actually true, rather than merely documented:
  # the supervised task a sandboxed test enqueues inherits the test's
  # checked-out connection through $callers, and it does so from a second,
  # supervised process running concurrently with the test -- not by quietly
  # running the import inline in the caller, which would satisfy a
  # completion assertion just as well. GeoGenius.SandboxedRepo stands in
  # for a host Repo pooled through Ecto.Adapters.SQL.Sandbox --
  # GeoGenius.TestRepo (this suite's own Repo) is not pooled that way, so
  # it cannot exercise this at all.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias GeoGenius.Catalog
  alias GeoGenius.Context
  alias GeoGenius.GraphFixture
  alias GeoGenius.ImportFixture
  alias GeoGenius.Runners
  alias GeoGenius.SandboxedRepo

  @import_start [:geo_genius, :import, :start]
  @paused_flag :task_sandbox_inheritance_paused
  @pause_timeout 5_000
  @poll_interval 20
  @poll_timeout 2_000

  setup do
    GraphFixture.teardown!()
    on_exit(&GraphFixture.teardown!/0)

    :ok = Sandbox.checkout(SandboxedRepo)
    on_exit(fn -> Sandbox.checkin(SandboxedRepo) end)

    {:ok, context: Context.new(repo: SandboxedRepo, prefix: "geo_genius")}
  end

  test "a supervised import completes under a plain :manual-mode checkout, with no allow/3 and no shared mode",
       %{context: context} do
    {_collection, _release_id, run_id} = ImportFixture.claim_run!(context)

    # No Sandbox.allow/3, no Sandbox.mode(SandboxedRepo, {:shared, self()}) --
    # nothing beyond the checkout setup/1 already did. The task
    # Runners.Task.enqueue/3 starts inherits this test's checked-out
    # connection through $callers, which Task.Supervisor.start_child/2 seeds
    # automatically and DBConnection.Ownership honours in :manual mode.
    assert :ok = Runners.Task.enqueue(context, run_id, %{publish: false})
    assert poll_status!(context, run_id) == "completed"
  end

  test "enqueue/3 returns while the import is still running, in a task under the library's supervisor whose $callers reaches this test",
       %{context: context} do
    {_collection, _release_id, run_id} = ImportFixture.claim_run!(context)
    pause_run_at_first_phase(run_id)

    assert :ok = Runners.Task.enqueue(context, run_id, %{publish: false})

    # The executing process is stopped at its first phase's :start event, so
    # everything below observes a moment when enqueue/3 has already returned
    # and the import cannot have finished -- the asynchronous contract, with
    # no timing window. An implementation that ran the import inline in the
    # calling process fails `refute executor == self()` (the handler's own
    # guard keeps that mutation from deadlocking on its paused self); one
    # that ran it in an unsupervised or wrongly-parented process fails the
    # $ancestors assertion; one that blocked the caller until the run
    # finished fails the terminal-status refutation once the pause times
    # out and the run completes.
    assert_receive {:import_started, executor, callers, ancestors}, 2_000

    refute executor == self()
    assert self() in List.wrap(callers)

    supervisor = GenServer.whereis(GeoGenius.TaskSupervisor)
    assert is_pid(supervisor)
    assert hd(List.wrap(ancestors)) in [supervisor, GeoGenius.TaskSupervisor]

    refute Catalog.import_run(context, run_id).status in ["completed", "failed"]

    send(executor, {:proceed, run_id})
    assert poll_status!(context, run_id) == "completed"
  end

  # Attaches a handler that stops the pipeline's executing process at the
  # run's first [:geo_genius, :import, :start] event, after reporting that
  # process's identity, $callers, and $ancestors to the test. Telemetry
  # handlers run in the emitting process, so the report reads the executing
  # process's own dictionary, not a reconstruction of it. The pause fails
  # open after @pause_timeout so a corrupted implementation cannot wedge
  # the suite -- it fails the test's assertions instead.
  defp pause_run_at_first_phase(run_id) do
    handler_id = {__MODULE__, run_id}

    :telemetry.attach(
      handler_id,
      @import_start,
      &__MODULE__.pause_and_report/4,
      %{run_id: run_id, test_pid: self()}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  @doc false
  def pause_and_report(_event, _measurements, metadata, config) do
    %{run_id: run_id, test_pid: test_pid} = config

    if metadata.run_id == run_id and not Process.get(@paused_flag, false) do
      Process.put(@paused_flag, true)
      identity = {:import_started, self(), Process.get(:"$callers"), Process.get(:"$ancestors")}
      send(test_pid, identity)

      # An inline implementation emits this event in the test process
      # itself, which could never receive :proceed while paused here --
      # skipping the pause lets that mutation run on and fail the pid
      # assertion instead of deadlocking.
      if self() != test_pid do
        receive do
          {:proceed, ^run_id} -> :ok
        after
          @pause_timeout -> :ok
        end
      end
    end

    :ok
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
