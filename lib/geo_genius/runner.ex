defmodule GeoGenius.Runner do
  @moduledoc """
  Behaviour for backends that start a claimed import run.

  A runner is the thing that decides *where* `GeoGenius.Pipeline.execute/3`
  actually runs -- in the calling process, in a supervised `Task`, or handed
  to a durable job framework such as PgFlow. It owns none of the run's state:
  `enqueue/3` starts the work and returns, and the run's progress, status, and
  error all live in PostgreSQL -- readable through the catalog regardless of
  which backend started it.

  **No status or await callback.** Putting one here would mean one query
  implemented once per backend, and would make a run started under one
  backend unreadable after the configuration changed -- the exact failure
  `import_run.runner_backend` exists to prevent by recording which backend a
  run was claimed under.

  **A runner must not call `GeoGenius.Catalog.fail_import/3`.** The pipeline
  owns the failure path end to end, including the case where its own cleanup
  or confirmation read fails after a phase already recorded an outcome.
  `fail_import/3` carries no terminal-state guard, so a runner calling it
  after the pipeline already finished could stamp `failed` over a completed
  run. A backend that wants to record a failure of its own -- it could not
  start the work at all, say -- returns `{:error, reason}` from `enqueue/3`
  instead and leaves the run exactly where the pipeline left it.
  """

  alias GeoGenius.Context

  @backends [GeoGenius.Runners.PgFlow, GeoGenius.Runners.Task, GeoGenius.Runners.Inline]
  @callbacks [name: 0, available?: 0, enqueue: 3]

  @typedoc "The reason a backend could not start a run, or could not be resolved."
  @type reason :: term()

  @typedoc """
  Job arguments, JSON-serializable so a durable backend can round-trip them
  through storage. Carries `:publish` and `:stale_after_seconds`; a backend
  reads each with its own reader (`publish?/1`, `stale_after_seconds/1`)
  rather than `Map.get(args, :publish, false)`, since a backend that decodes
  its own JSON hands back `%{"publish" => true, "stale_after_seconds" => 300}`,
  not atom keys.
  """
  @type args :: %{
          optional(:publish) => boolean(),
          optional(:stale_after_seconds) => pos_integer()
        }

  @doc "The name this backend is recorded under in `import_run.runner_backend`."
  @callback name() :: String.t()

  @doc "Reports whether this backend can accept work right now."
  @callback available?() :: boolean()

  @doc """
  Starts a claimed run.

  Returns `:ok` when the run's outcome is, or will be, recorded in the
  catalog -- including a run that has already failed and recorded that
  failure. Returns `{:error, reason}` only when nothing was recorded and
  nothing ever will be: the caller can read no run state back for this call
  and must not poll. Never return an error for a failure the pipeline itself
  recorded -- `Pipeline.execute/3` already wrote it, and the catalog is the
  only place a caller should look for it.
  """
  @callback enqueue(Context.t(), run_id :: Ecto.UUID.t(), args()) :: :ok | {:error, reason()}

  @doc """
  Reads `:publish` out of `args`, defaulting to `false`.

  Accepts both `%{publish: boolean()}` and `%{"publish" => boolean()}`, so a
  backend that round-trips `args` through its own JSON decoder -- handing
  back string keys -- still resolves the flag a caller actually set, rather
  than silently treating every job as `publish: false`.
  """
  @spec publish?(args() | map()) :: boolean()
  def publish?(%{publish: value}) when is_boolean(value), do: value
  def publish?(%{"publish" => value}) when is_boolean(value), do: value
  def publish?(_args), do: false

  @doc """
  Reads `:stale_after_seconds` out of `args`, defaulting to `nil`.

  Accepts both `%{stale_after_seconds: n}` and `%{"stale_after_seconds" => n}`,
  the same round-trip `publish?/1` handles. `nil` tells the caller no window
  was carried -- `GeoGenius.Pipeline` falls back to its own default rather
  than treating `nil` as a zero-second window.
  """
  @spec stale_after_seconds(args() | map()) :: pos_integer() | nil
  def stale_after_seconds(%{stale_after_seconds: value}) when is_integer(value) and value > 0,
    do: value

  def stale_after_seconds(%{"stale_after_seconds" => value})
      when is_integer(value) and value > 0,
      do: value

  def stale_after_seconds(_args), do: nil

  @doc """
  Resolves the runner backend for one call.

  Resolution order: `opts[:runner]`, then `config :geo_genius, :runner`, then
  the first of `Runners.PgFlow`, `Runners.Task`, `Runners.Inline` whose
  `available?/0` is true -- with one exception. `Runners.Task` is selected
  whenever `config :geo_genius, :task_supervisor` names anything at all,
  even a name that is not currently a live process. Setting that key is a
  host committing to `Runners.Task`, and `enqueue/3` already turns a dead
  supervisor into a named `{:error, reason}` rather than an exit (see
  `Runners.Task`'s moduledoc), so selecting it regardless of the configured
  name's current liveness surfaces a typo'd or not-yet-started supervisor as
  that named error instead of silently falling through to `Runners.Inline`
  and blocking the caller for the length of an import -- the worst available
  outcome, and what a merely-configured-but-dead `:task_supervisor` did
  before this exception existed. `Runners.Inline` is always available, so
  the chain always terminates -- a host that installed neither PgFlow nor
  configured `:task_supervisor` still gets a working runner, and with
  nothing configured at all `Runners.Task` is still reached because
  `GeoGenius.Application` starts a `Task.Supervisor` this package owns and
  `available?/0` finds it genuinely running.

  An explicit `opts[:runner]` or `config :geo_genius, :runner` is validated
  before it is returned: it must load and implement every `GeoGenius.Runner`
  callback, or this raises `ArgumentError` naming what is missing, rather
  than letting a typo surface as an `UndefinedFunctionError` several phases
  into a run. A module reached through the availability chain is one of this
  package's own, already proven to implement the behaviour, so it is not
  re-checked.
  """
  @spec configured(keyword()) :: module()
  def configured(opts \\ []) do
    case Keyword.get(opts, :runner) || Application.get_env(:geo_genius, :runner) do
      nil -> first_available(@backends)
      module -> validate!(module)
    end
  end

  @doc """
  Resolves a shipped backend's `name/0` back to its module.

  Searches only the shipped backends (`Runners.PgFlow`, `Runners.Task`,
  `Runners.Inline`). A host's own runner is not resolvable here -- a caller
  that stamps `import_run.runner_backend` with a host runner's name is
  responsible for resolving that name back to a module itself.

  A backend that has not loaded -- `Runners.PgFlow` before its optional
  dependency is installed -- is treated as unknown rather than probed, since
  calling `name/0` on it would raise.
  """
  @spec module_for_backend(String.t()) :: {:ok, module()} | {:error, :unknown_backend}
  def module_for_backend(name) when is_binary(name) do
    @backends
    |> Enum.filter(&Code.ensure_loaded?/1)
    |> Enum.find(&(&1.name() == name))
    |> case do
      nil -> {:error, :unknown_backend}
      module -> {:ok, module}
    end
  end

  defp first_available(backends) do
    Enum.find(backends, GeoGenius.Runners.Inline, &backend_selected?/1)
  end

  # Runners.Task is chosen here whenever :task_supervisor is configured,
  # regardless of whether that name is currently a live process -- see
  # configured/1's moduledoc for why a dead-but-configured name is safe to
  # select rather than skip. Every other backend still goes through its own
  # available?/0 unchanged.
  defp backend_selected?(GeoGenius.Runners.Task) do
    Application.get_env(:geo_genius, :task_supervisor) != nil or
      GeoGenius.Runners.Task.available?()
  end

  defp backend_selected?(backend), do: Code.ensure_loaded?(backend) and backend.available?()

  defp validate!(module) do
    unless Code.ensure_loaded?(module) do
      raise ArgumentError,
            "configured GeoGenius runner #{inspect(module)} does not load; check the module " <>
              "name in `runner:` or `config :geo_genius, :runner`"
    end

    case missing_callbacks(module) do
      [] ->
        module

      missing ->
        raise ArgumentError,
              "configured GeoGenius runner #{inspect(module)} does not implement " <>
                "GeoGenius.Runner: missing #{Enum.join(missing, ", ")}"
    end
  end

  defp missing_callbacks(module) do
    for {fun, arity} <- @callbacks, not function_exported?(module, fun, arity) do
      "#{fun}/#{arity}"
    end
  end
end
