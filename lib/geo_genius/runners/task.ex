defmodule GeoGenius.Runners.Task do
  @moduledoc """
  Runs an import under a `Task.Supervisor`.

  `:geo_genius` starts a `Task.Supervisor` registered as
  `GeoGenius.TaskSupervisor` unless a host has already configured its own
  (see `GeoGenius.Application`). This backend uses that supervisor when a
  host has configured nothing, so an asynchronous import needs zero host
  configuration. A host that wants the supervisor inside its own tree
  instead sets:

      config :geo_genius, :task_supervisor, MyApp.TaskSupervisor

  with `MyApp.TaskSupervisor` started under the host's own supervision tree
  -- and, for a host that cares about shutdown order, listed *after*
  `MyApp.Repo` there. See `GeoGenius.Application`'s moduledoc for why that
  placement matters: the library's own default supervisor sits outside the
  host's tree and is stopped only after the host's own tree has already
  finished shutting down, so with no configuration an import task can
  outlive the host's Repo for the entire length of that shutdown. A
  supervisor the host places after Repo does not have that problem --
  supervisors stop children in the reverse of their start order, so a
  later-listed `TaskSupervisor` stops before `Repo` does.

  A configured name takes precedence over the library's own supervisor
  whether or not the configured one is actually running -- a host that set
  the key gets the gap named rather than silently redirected to the
  library's default. `enqueue/3` never falls back to a bare `spawn/1`: an
  unsupervised process that dies between phases would leave a run nothing
  can fail, recoverable only once its lease goes stale.

  Supervision here does not make a dying run fail sooner -- a supervised
  task that dies between phases leaves the run exactly as stale as an
  unsupervised process would, and it is the lease, not the supervisor, that
  eventually reclaims it. A `Task` does not trap exits, so it dies the
  instant its supervisor is told to stop, wherever it happens to be in a
  phase; the standard shutdown timeout is never actually spent, and nothing
  here should be made to trap exits, since a trapping task would need to
  finish or abort a phase inside that window and no phase can. What
  supervision buys is visibility -- `Task.Supervisor.children/1` lists the
  pids of tasks currently running under a supervisor, though only as bare
  pids, not run ids, and, under the override, potentially mixed with
  unrelated tasks a host started under the same name; a host wanting to see
  actual runs queries `import_run` (or `GeoGenius.status/2`) instead -- and,
  for a host that placed its own supervisor after Repo, a shutdown that
  kills a running task while the Repo can still be reached rather than
  after it is already gone.
  """

  @behaviour GeoGenius.Runner

  alias GeoGenius.Pipeline
  alias GeoGenius.Runner
  alias Task.Supervisor, as: TaskSupervisor

  @default_supervisor GeoGenius.TaskSupervisor

  @impl GeoGenius.Runner
  @doc "Returns `\"task\"`."
  @spec name() :: String.t()
  def name, do: "task"

  @impl GeoGenius.Runner
  @doc """
  Reports whether the resolved supervisor name is actually running.

  Resolved in order: `config :geo_genius, :task_supervisor`, then
  `GeoGenius.TaskSupervisor`, the supervisor `GeoGenius.Application` starts
  whenever the host has not configured one of its own. A configured but
  dead name -- the host set the key and never started the child -- is
  unavailable exactly like the library's own supervisor would be if
  something stopped it: `enqueue/3` cannot start a run under a supervisor
  that is not there to accept it.
  """
  @spec available?() :: boolean()
  def available?, do: match?({:ok, _name}, resolve())

  @impl GeoGenius.Runner
  @doc """
  Starts the import under the resolved `Task.Supervisor` and returns
  immediately.

  Returns `{:error, reason}` naming the configured name when it is set but
  nothing is registered under it, naming `GeoGenius.TaskSupervisor` in the
  same way should that library-started supervisor ever not be running, or
  naming a live supervisor's refusal to start the child (a host-configured
  `:max_children` cap, say). Never falls back to an unsupervised process,
  and never reports `:ok` for a child that was not started.
  """
  @spec enqueue(GeoGenius.Context.t(), Ecto.UUID.t(), Runner.args()) ::
          :ok | {:error, String.t()}
  def enqueue(context, run_id, args) do
    case resolve() do
      {:ok, supervisor} -> start(supervisor, context, run_id, args)
      {:error, reason} -> {:error, reason}
    end
  end

  # A live supervisor can still refuse the child -- a host-configured one
  # with :max_children, say -- and that refusal must surface as the named
  # error the spec promises, never be swallowed into :ok: nothing was
  # started, so nothing will ever record this run's outcome, and a caller
  # told :ok would poll a run that stays pending forever.
  defp start(supervisor, context, run_id, args) do
    opts = [publish: Runner.publish?(args), stale_after_seconds: Runner.stale_after_seconds(args)]
    fun = fn -> Pipeline.execute(context, run_id, opts) end

    case TaskSupervisor.start_child(supervisor, fun) do
      {:ok, pid} when is_pid(pid) ->
        :ok

      {:error, reason} ->
        {:error,
         "Task.Supervisor.start_child/2 could not start the import under " <>
           "#{inspect(supervisor)}: #{inspect(reason)}"}
    end
  end

  defp resolve do
    name = Application.get_env(:geo_genius, :task_supervisor) || @default_supervisor

    if GenServer.whereis(name) do
      {:ok, name}
    else
      {:error, not_running_message(name)}
    end
  end

  defp not_running_message(@default_supervisor) do
    "GeoGenius.TaskSupervisor is not running; this backend requires the :geo_genius " <>
      "application to be started, which starts it automatically unless :task_supervisor " <>
      "is already configured -- check that GeoGenius.Application was not skipped or stopped"
  end

  defp not_running_message(name) do
    "config :geo_genius, :task_supervisor names #{inspect(name)}, but nothing is " <>
      "registered under that name; start it under your own supervision tree"
  end
end
