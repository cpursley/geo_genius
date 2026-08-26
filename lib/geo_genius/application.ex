defmodule GeoGenius.Application do
  @moduledoc """
  Starts GeoGenius's own supervision tree: at most one child, a
  `Task.Supervisor` registered as `GeoGenius.TaskSupervisor`.

  `GeoGenius.Runners.Task` uses that supervisor when a host has configured
  nothing of its own, so an asynchronous import works with zero host
  configuration. When `config :geo_genius, :task_supervisor` is already set
  at boot, this tree starts no child at all: the host has committed to
  supplying its own, and an idle supervisor nobody will ever reach is not
  worth leaving in the tree -- one a host could not otherwise remove short
  of disabling the runner entirely.

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
  does not trap exits, so it dies the instant its supervisor tells it to,
  mid-statement if that is where it happens to be -- the standard shutdown
  timeout is never actually spent, because there is no cleanup phase to
  spend it on. Nothing here should be made to trap exits either: a trapping
  task would need to finish or abort a phase inside that window, and no
  phase can. Neither arrangement lets a task write
  `GeoGenius.Catalog.fail_import/3` or drop its own staging table on the
  way out: under the default ordering it keeps running and both calls fail
  against a Repo that is already gone; under the override it is killed
  before it gets the chance to make either call at all. What the correct
  ordering buys is narrower than a graceful shutdown: the task dies while
  the Repo can still be reached rather than while it cannot, so it fails
  cleanly instead of failing repeatedly against a connection that is
  already gone. Either way, what actually recovers the run is what it has
  always been: the lease, reclaimed once `stale_after` elapses. See
  `GeoGenius.Runners.Task`'s moduledoc.

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
    if Application.get_env(:geo_genius, :task_supervisor) do
      []
    else
      [{Task.Supervisor, name: GeoGenius.TaskSupervisor}]
    end
  end

  @impl Application
  @doc false
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: GeoGenius.Supervisor)
  end
end
