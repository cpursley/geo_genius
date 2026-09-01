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
  library's default. `enqueue/3` never falls back to a bare `spawn/1`, which
  would provide no task-supervisor lifecycle or shutdown ordering for a host
  to inspect or control.

  A separate package-owned execution guardian monitors the task. If the task
  dies while the Repo remains reachable, the guardian records a durable
  failure with the exact claimed executor; it never restarts the task or
  transfers execution. A `Task` does not trap exits, so it dies wherever it
  happens to be when its supervisor stops and cannot clean up its staging
  table. A host-owned supervisor placed after Repo lets the guardian record
  that death before Repo shuts down. With the package-owned default, Repo may
  already be gone by the time the dependency application's task dies, and
  whole-node loss leaves no guardian alive; those cases remain stale,
  operator-visible abandoned attempts. `Task.Supervisor.children/1` lists
  currently running task pids, though only as bare pids and, under a shared
  host override, potentially mixed with unrelated tasks. Query `import_run`
  (or `GeoGenius.status/2`) for actual import state.
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

  Returns `{:error, {:not_enqueued, reason}}` naming the configured name when
  it is set but nothing is registered under it, naming
  `GeoGenius.TaskSupervisor` in the same way should that library-started
  supervisor ever not be running, or naming a live supervisor's refusal to
  start the child (a host-configured `:max_children` cap, say). Never falls
  back to an unsupervised process, and never reports `:ok` for a child that
  was not started.
  """
  @spec enqueue(GeoGenius.Context.t(), Ecto.UUID.t(), Runner.args()) ::
          :ok | {:error, Runner.enqueue_error()}
  def enqueue(context, run_id, args) do
    case resolve() do
      {:ok, supervisor} -> start(supervisor, context, run_id, args)
      {:error, reason} -> {:error, {:not_enqueued, reason}}
    end
  end

  # A live supervisor can still refuse the child -- a host-configured one
  # with :max_children, say -- and that refusal must surface as the named
  # error the spec promises, never be swallowed into :ok: nothing was
  # started, so nothing will ever record this run's outcome, and a caller
  # told :ok would poll a run that stays pending forever.
  defp start(supervisor, context, run_id, args) do
    fun = fn -> execute_supervised(context, run_id, args) end

    case TaskSupervisor.start_child(supervisor, fun) do
      {:ok, pid} when is_pid(pid) ->
        :ok

      {:error, reason} ->
        {:error,
         {:not_enqueued,
          "Task.Supervisor.start_child/2 could not start the import under " <>
            "#{inspect(supervisor)}: #{inspect(reason)}"}}
    end
  end

  defp execute_supervised(context, run_id, args) do
    case Pipeline.execute(context, run_id, Runner.pipeline_opts(args)) do
      {:ok, _run} ->
        :ok

      {:noop, _run} ->
        :ok

      {:error, %GeoGenius.ImportRun{}} ->
        :ok

      {:error, {:unrecorded, _certainty, reason}} ->
        raise "GeoGenius import run #{run_id} ended without a recorded outcome: #{reason}"
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
