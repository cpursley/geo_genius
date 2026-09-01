defmodule GeoGenius.Application do
  @moduledoc """
  Starts GeoGenius's own supervision tree: an execution-guardian supervisor
  and, unless a host supplies one, a `Task.Supervisor` registered as
  `GeoGenius.TaskSupervisor`.

  `GeoGenius.Runners.Task` uses that supervisor when a host has configured
  nothing of its own, so an asynchronous import works with zero host
  configuration. When `config :geo_genius, :task_supervisor` is already set
  at boot, this tree omits only that task supervisor: the host has committed
  to supplying its own. The guardian remains package-owned because it
  monitors executions under every backend, including PgFlow and a host task
  supervisor.

  Do not add `GeoGenius.Preflight` to this tree. It must stay a child the
  *host* places, immediately after its own Repo, for two reasons this
  library has already paid to learn:

    * A dependency application starts before its host's, so `:geo_genius`
      cannot see a Repo that has not started yet. Placing `Preflight` here
      would run its verification query before any Repo exists to query.
    * `Preflight` skips itself for a Repo pooled through
      `Ecto.Adapters.SQL.Sandbox` because the supervisor starts it from a
      process holding no checked-out connection; started from here instead
      of the host's own tree, that same query would raise
      `DBConnection.OwnershipError` and abort the host's entire test suite
      before its first `setup` block runs.

  A `Task.Supervisor` carries neither risk at boot: it needs nothing to
  start, starts empty, and does no work until a host calls
  `GeoGenius.import/1` -- by which time the host's own Repo is already up.

  **Shutdown is the opposite story, and it is backwards by default.**
  Applications start in dependency order and stop in the reverse of that
  order: `:geo_genius` starts before its host, so it stops *after* it. On
  `System.stop/1` (or any ordinary release shutdown), the host's own
  supervision tree -- Repo included -- finishes stopping first, and only
  then is this tree told to stop. An import task still running at that
  moment keeps running, against a Repo that is already gone, for the entire
  length of the host's own shutdown: every phase call it makes fails,
  repeatedly, against a connection that no longer exists. This is not a
  hypothetical corner case -- it is what actually happens with no
  configuration at all, because the library's own supervisor sits outside
  the host's tree entirely and is stopped only after the host's tree
  already has been.

  A host that cares about shutdown order takes the override instead, and
  places the supervisor correctly:

      config :geo_genius, :task_supervisor, MyApp.TaskSupervisor

  with `MyApp.TaskSupervisor` listed *after* `MyApp.Repo` in the host's own
  children list. Supervisors terminate children in the reverse of their
  start order, so a later-listed `TaskSupervisor` -- and every task under it
  -- is stopped *before* `Repo` is, instead of after. For a host running
  import work under this backend, this is not merely a matter of taste in
  where the process lives; it is the only supervision arrangement whose
  shutdown ordering is actually correct, and this library cannot arrange it
  from the outside.

  Killing a running import task this way is still not graceful: a `Task`
  does not trap exits, so it dies wherever it happens to be and cannot clean
  up its staging table. The independently supervised execution guardian
  monitors that task, however. With the host-owned ordering above, the task
  dies while both the guardian and Repo are still alive, so the guardian
  records a durable failure using the exact executor identity before the
  Repo stops. The executor is never transferred or taken over.

  The package-owned default cannot make the same shutdown guarantee. The
  host Repo has already stopped by the time the dependency application's
  task and guardian supervisors shut down, so the guardian may be unable to
  record the task's death. Whole-VM or whole-node loss has the same limit:
  no surviving local process exists to write the outcome. In those cases a
  stale heartbeat remains diagnostic; an operator records the abandoned
  attempt's failure and starts a new one explicitly with
  `GeoGenius.retry_failed/2`. See `GeoGenius.Runners.Task`'s moduledoc.

  A host can list the pids of tasks currently running under either
  supervisor with `Task.Supervisor.children/1` -- bare pids, not run ids,
  and, under the override, potentially mixed with unrelated tasks the host
  started under that same supervisor itself. A host that wants to see
  actual import runs queries `import_run` (or `GeoGenius.status/2`)
  instead.
  """

  use Application

  @doc false
  @spec children() :: [Supervisor.child_spec() | {module(), keyword()}]
  def children do
    guardian =
      {DynamicSupervisor, strategy: :one_for_one, name: GeoGenius.ExecutionGuardianSupervisor}

    if Application.get_env(:geo_genius, :task_supervisor) do
      [guardian]
    else
      [guardian, {Task.Supervisor, name: GeoGenius.TaskSupervisor}]
    end
  end

  @impl Application
  @doc false
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: GeoGenius.Supervisor)
  end
end
