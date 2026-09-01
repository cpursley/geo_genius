defmodule GeoGenius.Runners.PgFlow do
  @moduledoc """
  Runs an import as a durable PgFlow background job.

  `pgflow` `>= 0.3.4 and < 0.4.0` is an optional dependency. It establishes
  compile order when a host opts into PgFlow, so `PgFlow.Job` is available
  before this file conditionally defines `GeoGenius.Runners.PgFlow.Job`.
  Hosts that do not install PgFlow do not receive it or compile the job.

  PgFlow 0.3's dashboard code also compiles against its optional Phoenix,
  Phoenix LiveView, and LiveFilter packages when those packages are present.
  GeoGenius declares matching optional edges so its own integration build can
  exercise the real job module once that build supplies its job deadline. A
  host using a PgFlow release that compiles those dashboard modules
  unconditionally must opt into those packages too; they are not made
  mandatory by GeoGenius.

  The job is a single-step definition (`@job queue: :geo_genius_import`)
  whose `perform :execute` block calls `GeoGenius.Pipeline.execute/3` through
  `run/2`, `job_context/2`, `job_input_opts/1`, and `job_outcome/2` below.

  `available?/0` reports whether the PgFlow engine is present, and `enqueue/3`
  verifies the host obligations required to accept this particular job. The
  engine probe takes three things, all checked at runtime
  rather than assumed from configuration:

    * `pgflow` itself is loaded;
    * `GeoGenius.Runners.PgFlow.Job` -- this project's own submodule, not
      `pgflow`'s -- is loaded too;
    * `PgFlow.Supervisor` -- the process PgFlow's own supervision tree
      registers itself under once `{PgFlow, repo: ..., jobs: [...]}` has
      actually started -- is running.

  Before enqueueing, the runner also verifies that the job's flow was compiled
  into PgFlow's catalog and that at least one healthy worker is polling its
  queue. A half-wired PgFlow host therefore fails immediately with the exact
  setup remedy instead of raising a database error or leaving an import queued
  until a distant await timeout.

  A host that satisfies the first two but never started that supervisor
  gets the same "unavailable" answer as a host that never added `pgflow` at
  all, exactly as `GeoGenius.Runners.Task` treats a configured but dead
  `Task.Supervisor` name.

  `enqueue/3` hands `GeoGenius.Runners.PgFlow.Job` a JSON-serializable
  input: `run_id`, `publish`, `stale_after_seconds`, and `prefix`. It never
  sends `repo`. A durable job outlives the process that enqueued it, so its
  handler uses the Repo in the `%PgFlow.Context{}` supplied by the worker
  instead of reviving a module atom decoded out of storage or resolving a
  second application-global Repo. Before enqueueing, this runner verifies
  that the operation's Repo is the same Repo PgFlow is configured to use.
  `prefix` carries no code-execution risk -- it is a validated string -- so
  it travels through the job input unchanged.

  PgFlow's `@job timeout:` is compile-time definition data, not a per-enqueue
  option. GeoGenius therefore does not choose a universal deadline for work
  whose size it cannot know. A host opting into this runner must set a
  positive `config :geo_genius, :pgflow_job_timeout_seconds` before compiling
  GeoGenius, then compile and migrate the job definition. Each import must
  also carry an explicit `:stale_after_seconds` smaller than that deadline.
  That relation is a necessary safety floor, not an estimate of total import
  duration; the host remains responsible for choosing a job deadline that
  covers its complete workload.

  A host that installs `pgflow` wires this up once:

    1. Add `{:pgflow, "~> 0.3.4"}` to `mix.exs`. For PgFlow releases whose
       dashboard compiles unconditionally, also add `:phoenix`,
       `:phoenix_live_view`, and `:livefilter` at PgFlow's supported versions.
    2. Set `config :geo_genius, pgflow_job_timeout_seconds: seconds` at compile
       time, choosing a deadline for the host's bounded workload.
    3. Compile the job into the database with `mix pgflow.gen.job_migration
       GeoGenius.Runners.PgFlow.Job` followed by `mix ecto.migrate`.
    4. Start `{PgFlow, repo: MyApp.Repo, jobs: [GeoGenius.Runners.PgFlow.Job]}`
       under its own supervision tree.
  """

  @behaviour GeoGenius.Runner

  @compile {:no_warn_undefined, PgFlow}
  @compile {:no_warn_undefined, PgFlow.Definitions}
  @compile {:no_warn_undefined, PgFlow.Workers}

  # Dialyzer's `:unknown` flag (enabled project-wide in `mix.exs`) reports a
  # call to a module absent from the PLT as `unknown_function`. That is
  # accurate and expected on a build with no `:pgflow` -- `submit/3` calling
  # `PgFlow.enqueue/2` is exactly the optional call `available?/0` exists to
  # guard at runtime -- so it is silenced here rather than by removing the
  # `:unknown` flag project-wide and losing that check for every other call.
  @dialyzer {:no_unknown, submit: 3}

  alias GeoGenius.Context
  alias GeoGenius.Runner
  alias GeoGenius.Runners.PgFlow.Job

  @flow_slug "geo_genius_import"
  @job_timeout_seconds Application.compile_env(
                         :geo_genius,
                         :pgflow_job_timeout_seconds,
                         nil
                       )

  unless is_nil(@job_timeout_seconds) or
           (is_integer(@job_timeout_seconds) and @job_timeout_seconds > 0) do
    raise ArgumentError,
          "config :geo_genius, :pgflow_job_timeout_seconds must be a positive integer " <>
            "number of seconds, got: #{inspect(@job_timeout_seconds)}"
  end

  @impl GeoGenius.Runner
  @doc "Returns `\"pgflow\"`."
  @spec name() :: String.t()
  def name, do: "pgflow"

  @doc "Returns the host's compile-time PgFlow job deadline, or `nil` when none was chosen."
  @spec job_timeout_seconds() :: pos_integer() | nil
  def job_timeout_seconds, do: @job_timeout_seconds

  @impl GeoGenius.Runner
  @doc """
  Reports whether `pgflow`, this project's own `Job` submodule, and a
  running `PgFlow.Supervisor` are all present right now.

  All three are checked live rather than assumed from configuration. A host
  that added the dependency but never chose a compile-time job deadline, or
  compiled the job but never started
  `{PgFlow, repo: ..., jobs: [...]}` (`Process.whereis/1`) gets the same
  `false` a host that never touched `pgflow` at all gets -- the same
  distinction `GeoGenius.Runners.Task` draws between a configured `Task.Supervisor`
  name and one that is dead.
  """
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(PgFlow) and function_exported?(PgFlow, :enqueue, 2) and
      Code.ensure_loaded?(Job) and Process.whereis(PgFlow.Supervisor) != nil
  end

  @impl GeoGenius.Runner
  @doc """
  Enqueues the import as a PgFlow job and returns once PgFlow has durably
  queued it. Before writing the job, verifies that its flow is compiled and a
  healthy worker is polling the queue.

  Returns `:ok` once `PgFlow.enqueue/2` has written the job's own run row --
  the import's outcome will be recorded in the catalog once a worker picks
  the job up, so the caller reads it back from there rather than polling
  this call. Missing runtime availability, flow registration, or worker
  readiness is a definite `:not_enqueued` rejection. A generic error after
  calling `PgFlow.enqueue/2` is `:outcome_unknown`, because its durable write
  may have committed before the caller lost confirmation.
  """
  @spec enqueue(Context.t(), Ecto.UUID.t(), Runner.args()) ::
          :ok | {:error, Runner.enqueue_error()}
  def enqueue(%Context{} = context, run_id, args) when is_binary(run_id) and is_map(args) do
    if available?() do
      submit(context, run_id, args)
    else
      {:error, {:not_enqueued, unavailable_message()}}
    end
  end

  @doc """
  Maps one `GeoGenius.Pipeline.execute/3` result to the plain,
  JSON-serializable outcome `GeoGenius.Runners.PgFlow.Job`'s `perform` step
  hands back to PgFlow.

  Lives here, on the module that always compiles, rather than inside `Job`
  itself, so the mapping remains covered even in a no-optional-dependencies
  build. Otherwise nothing there would notice if
  `GeoGenius.Pipeline.execute/3` gained or renamed a return shape --
  `Job.run/2` would keep its stale clauses, and the first host running this
  backend under real `pgflow` would get a `CaseClauseError` inside a
  worker instead of a clean, tested outcome.

  Both a completed run and one that ran and recorded its own failure return
  a plain outcome map -- either way the catalog already holds what
  happened, and that is where a caller reads it back from. Raises only when
  `Pipeline.execute/3` reports nothing was recorded at all, since that is
  the one case nothing durable exists for a later reader to find.
  """
  @spec job_outcome(
          {:ok, GeoGenius.ImportRun.t()}
          | {:noop, GeoGenius.ImportRun.t()}
          | {:error, GeoGenius.ImportRun.t()}
          | {:error, {:unrecorded, :not_started | :outcome_unknown, String.t()}},
          Ecto.UUID.t()
        ) :: %{String.t() => String.t()}
  def job_outcome({:ok, %GeoGenius.ImportRun{}}, _run_id) do
    %{"outcome" => "completed"}
  end

  def job_outcome({:noop, %GeoGenius.ImportRun{}}, _run_id) do
    %{"outcome" => "already_running"}
  end

  def job_outcome({:error, %GeoGenius.ImportRun{}}, _run_id) do
    %{"outcome" => "failed"}
  end

  def job_outcome({:error, {:unrecorded, _certainty, reason}}, run_id) do
    raise "GeoGenius import run #{run_id} was not recorded: #{reason}"
  end

  def job_outcome(result, run_id) do
    raise "GeoGenius import run #{run_id} returned an invalid pipeline outcome: " <>
            inspect(result)
  end

  @doc """
  Builds the `Pipeline.execute/3` opts a job runs with, from its decoded input.

  Lives here, on the module that always compiles, for the same reason
  `job_outcome/2` does: `Job` does not compile in the no-optional-dependencies
  build, so that gate would otherwise miss a renamed key or dropped conversion. Reads
  both `"publish"` and `"stale_after_seconds"` through `Runner.publish?/1`
  and `Runner.stale_after_seconds/1` rather than `Map.get/2` directly, since
  `input` has already round-tripped through PgFlow's own JSON storage and
  carries string keys, not the atom keys a `Runner.args()` built in-process
  would.
  """
  @spec job_input_opts(map()) :: keyword()
  def job_input_opts(input), do: Runner.pipeline_opts(input)

  @doc """
  Rebuilds the `Context` a job runs under, from its decoded input.

  Lives here for the same reason `job_input_opts/1` does. `repo` comes from
  the `%PgFlow.Context{}` PgFlow builds for the executing worker rather than
  from a module atom carried in `input` or a second application-global
  lookup. `:prefix` travels through `input` as given, already validated once
  when the enqueuing context was built.
  """
  @spec job_context(map(), module()) :: Context.t()
  def job_context(input, repo) when is_map(input) and is_atom(repo) do
    Context.new(repo: repo, prefix: Map.fetch!(input, "prefix"))
  end

  @doc false
  @spec repository_alignment(Context.t(), module() | nil) ::
          :ok | {:error, Runner.enqueue_error()}
  def repository_alignment(%Context{repo: repo}, repo), do: :ok

  def repository_alignment(%Context{repo: operation_repo}, nil) do
    {:error,
     {:not_enqueued,
      "GeoGenius cannot enqueue through PgFlow because its configured Repo is not available. " <>
        "Start PgFlow with repo: #{inspect(operation_repo)} and retry."}}
  end

  def repository_alignment(%Context{repo: operation_repo}, pgflow_repo) do
    {:error,
     {:not_enqueued,
      "GeoGenius cannot enqueue through PgFlow with operation Repo " <>
        "#{inspect(operation_repo)} because PgFlow uses #{inspect(pgflow_repo)}. " <>
        "Both systems must use the same Repo for this job."}}
  end

  @doc false
  @spec timeout_readiness(pos_integer() | nil, pos_integer() | nil) ::
          :ok | {:error, Runner.enqueue_error()}
  def timeout_readiness(nil, _stale_after_seconds) do
    {:error,
     {:not_enqueued,
      "GeoGenius cannot enqueue through PgFlow until the host sets a positive compile-time " <>
        "config :geo_genius, :pgflow_job_timeout_seconds, recompiles GeoGenius, and migrates " <>
        "the job definition."}}
  end

  def timeout_readiness(timeout_seconds, nil) when is_integer(timeout_seconds) do
    {:error,
     {:not_enqueued,
      "GeoGenius cannot enqueue through PgFlow without an explicit positive " <>
        "stale_after_seconds for this import. It must be smaller than the host's compiled " <>
        "PgFlow job timeout of #{timeout_seconds} seconds."}}
  end

  def timeout_readiness(timeout_seconds, stale_after_seconds)
      when is_integer(timeout_seconds) and is_integer(stale_after_seconds) and
             timeout_seconds > stale_after_seconds,
      do: :ok

  def timeout_readiness(timeout_seconds, stale_after_seconds)
      when is_integer(timeout_seconds) and is_integer(stale_after_seconds) do
    {:error,
     {:not_enqueued,
      "GeoGenius cannot enqueue through PgFlow because its compiled job timeout " <>
        "(#{timeout_seconds} seconds) must exceed stale_after_seconds " <>
        "(#{stale_after_seconds} seconds)."}}
  end

  @doc false
  @spec job_definition_readiness({:ok, map()} | {:error, term()}, pos_integer()) ::
          :ok | {:error, Runner.enqueue_error()}
  def job_definition_readiness({:ok, %{opt_timeout: timeout}}, timeout), do: :ok

  def job_definition_readiness({:ok, %{opt_timeout: stored_timeout}}, compiled_timeout) do
    {:error,
     {:not_enqueued,
      "GeoGenius cannot enqueue through PgFlow because the stored job timeout " <>
        "(#{stored_timeout} seconds) differs from the compiled host timeout " <>
        "(#{compiled_timeout} seconds). Generate and run a PgFlow job migration before " <>
        "retrying."}}
  end

  def job_definition_readiness({:error, :not_found}, _compiled_timeout) do
    {:error, {:not_enqueued, flow_not_compiled_message()}}
  end

  def job_definition_readiness({:error, reason}, _compiled_timeout) do
    {:error,
     {:not_enqueued,
      "GeoGenius could not verify the stored PgFlow job definition: #{inspect(reason)}"}}
  end

  @doc false
  @spec job_step_readiness({:ok, map()} | {:error, term()}, pos_integer()) ::
          :ok | {:error, Runner.enqueue_error()}
  def job_step_readiness({:ok, %{opt_timeout: timeout}}, timeout), do: :ok

  def job_step_readiness({:ok, %{opt_timeout: stored_timeout}}, compiled_timeout) do
    {:error,
     {:not_enqueued,
      "GeoGenius cannot enqueue through PgFlow because the stored execute-step timeout " <>
        "(#{stored_timeout} seconds) differs from the compiled host timeout " <>
        "(#{compiled_timeout} seconds). Generate and run a PgFlow job migration before " <>
        "retrying."}}
  end

  def job_step_readiness({:error, :not_found}, _compiled_timeout) do
    {:error, {:not_enqueued, flow_not_compiled_message()}}
  end

  def job_step_readiness({:error, reason}, _compiled_timeout) do
    {:error,
     {:not_enqueued,
      "GeoGenius could not verify the stored PgFlow execute step: #{inspect(reason)}"}}
  end

  @doc false
  @spec flow_registration({:ok, boolean()} | {:error, term()}) ::
          :ok | {:error, Runner.enqueue_error()}
  def flow_registration({:ok, true}), do: :ok

  def flow_registration({:ok, false}),
    do: {:error, {:not_enqueued, flow_not_compiled_message()}}

  def flow_registration({:error, reason}) do
    {:error,
     {:not_enqueued, "GeoGenius could not verify the PgFlow job registration: #{inspect(reason)}"}}
  end

  @doc false
  @spec worker_readiness({:ok, boolean()} | {:error, term()}) ::
          :ok | {:error, Runner.enqueue_error()}
  def worker_readiness({:ok, true}), do: :ok

  def worker_readiness({:ok, false}) do
    {:error,
     {:not_enqueued,
      "GeoGenius cannot enqueue through PgFlow: no healthy worker is polling " <>
        "geo_genius_import. Start {PgFlow, repo: MyApp.Repo, " <>
        "jobs: [GeoGenius.Runners.PgFlow.Job]} and retry once its worker is healthy."}}
  end

  def worker_readiness({:error, reason}) do
    {:error,
     {:not_enqueued, "GeoGenius could not verify the PgFlow worker readiness: #{inspect(reason)}"}}
  end

  @doc false
  @spec enqueue_result({:ok, term()} | {:error, term()}) ::
          :ok | {:error, Runner.enqueue_error()}
  def enqueue_result({:ok, _pgflow_run_id}), do: :ok

  def enqueue_result({:error, {:flow_not_compiled, _flow_slug}}) do
    {:error, {:not_enqueued, flow_not_compiled_message()}}
  end

  def enqueue_result({:error, reason}) do
    {:error, {:outcome_unknown, reason}}
  end

  @doc false
  @spec flow_not_compiled_message() :: String.t()
  def flow_not_compiled_message do
    "GeoGenius cannot enqueue through PgFlow because geo_genius_import is not compiled. " <>
      "Run `mix pgflow.gen.job_migration GeoGenius.Runners.PgFlow.Job`, then " <>
      "`mix ecto.migrate`."
  end

  defp submit(context, run_id, args) do
    timeout_seconds = job_timeout_seconds()
    stale_after_seconds = Runner.stale_after_seconds(args)

    input = %{
      "run_id" => run_id,
      "publish" => Runner.publish?(args),
      "stale_after_seconds" => stale_after_seconds,
      "prefix" => context.prefix
    }

    with :ok <- repository_alignment(context, configured_pgflow_repo()),
         :ok <- timeout_readiness(timeout_seconds, stale_after_seconds),
         :ok <- flow_registration(PgFlow.flow_exists?(@flow_slug)),
         :ok <- job_definition_readiness(stored_job_definition(context.repo), timeout_seconds),
         :ok <- job_step_readiness(stored_job_step(context.repo), timeout_seconds),
         :ok <- worker_readiness(PgFlow.Workers.healthy?(context.repo, @flow_slug)) do
      Job
      |> PgFlow.enqueue(input)
      |> enqueue_result()
    end
  end

  # PgFlow 0.3's Client uses this exact configured Repo resolution for
  # `flow_exists?/1` and `enqueue/2`; its worker supervisor stores the running
  # configuration in persistent_term and the application value is the
  # documented fallback when the client is used without that supervisor.
  defp configured_pgflow_repo do
    :persistent_term.get({PgFlow, :repo}, Application.get_env(:pgflow, :repo))
  end

  defp stored_job_definition(repo) do
    PgFlow.Definitions.get_job(repo, @flow_slug)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp stored_job_step(repo) do
    PgFlow.Definitions.get_step(repo, @flow_slug, "execute")
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  @spec unavailable_message() :: String.t()
  def unavailable_message do
    ~s|GeoGenius cannot enqueue through PgFlow: :pgflow or this integration is not | <>
      ~s|compiled, or its supervisor is not running. Add {:pgflow, "~> 0.3.4"} to your | <>
      ~s|deps. If that PgFlow release compiles its dashboard unconditionally, also add | <>
      ~s|{:phoenix, "~> 1.7"}, {:phoenix_live_view, "~> 1.0"}, and | <>
      ~s|{:livefilter, "~> 0.2"}, then run `mix deps.get`. Compile the job with | <>
      ~s|a positive compile-time `config :geo_genius, :pgflow_job_timeout_seconds`, then | <>
      ~s|`mix pgflow.gen.job_migration | <>
      ~s|GeoGenius.Runners.PgFlow.Job` and `mix ecto.migrate`, then start {PgFlow, repo: | <>
      ~s|MyApp.Repo, jobs: [GeoGenius.Runners.PgFlow.Job]} under your own supervision | <>
      ~s|tree, or configure a different GeoGenius.Runner.|
  end
end

if Code.ensure_loaded?(PgFlow.Job) and
     is_integer(GeoGenius.Runners.PgFlow.job_timeout_seconds()) do
  defmodule GeoGenius.Runners.PgFlow.Job do
    @moduledoc """
    The PgFlow job `GeoGenius.Runners.PgFlow` enqueues under.

    Defined only when `PgFlow.Job` is loaded -- that is, only once a host
    has added `pgflow` to their own project and it has compiled -- so a
    host without `pgflow` never compiles a job definition it has no engine
    to run. A host that does install `pgflow` compiles this exact module
    into its own database once with `mix pgflow.gen.job_migration
    GeoGenius.Runners.PgFlow.Job`.

    `max_attempts` stays at PgFlow's own default of `1`: the one failure
    mode `GeoGenius.Runners.PgFlow.job_outcome/2` raises for -- the run id
    does not exist at all -- can never succeed on a second attempt, so a
    retry would only delay the same permanent failure.

    The job timeout is the positive
    `config :geo_genius, :pgflow_job_timeout_seconds` value the host chose
    before compiling GeoGenius. PgFlow's DSL records that value in generated
    migration data, so changing it requires recompiling this dependency and
    applying a new PgFlow job migration. There is no per-enqueue timeout in
    PgFlow 0.3's Job API.

    Deliberately thin: the mapping from `Pipeline.execute/3`'s result to
    this job's plain, JSON-serializable outcome, the opts it runs with, and
    the context it rebuilds all live on `GeoGenius.Runners.PgFlow` --
    `job_outcome/2`, `job_input_opts/1`, and `job_context/2` -- instead of
    here, because that module compiles (and is tested) in every build of
    this library, while this one exists only when the optional integration is present.
    """

    use PgFlow.Job

    alias GeoGenius.Pipeline
    alias GeoGenius.Runners.PgFlow, as: PgFlowRunner

    @job queue: :geo_genius_import, timeout: PgFlowRunner.job_timeout_seconds()

    perform :execute do
      fn input, %PgFlow.Context{} = context ->
        GeoGenius.Runners.PgFlow.Job.run(input, context)
      end
    end

    @doc """
    Runs one import to completion on behalf of the compiled `perform` block.

    Rebuilds the context and the `Pipeline.execute/3` opts through
    `GeoGenius.Runners.PgFlow.job_context/2` and `.job_input_opts/1`, then
    hands the result to `GeoGenius.Runners.PgFlow.job_outcome/2` -- all
    three to logic that remains covered in both integration and no-optional-dependencies builds.
    """
    @spec run(map(), PgFlow.Context.t()) :: %{String.t() => String.t()}
    def run(input, %PgFlow.Context{repo: repo}) do
      context = PgFlowRunner.job_context(input, repo)
      run_id = Map.fetch!(input, "run_id")
      opts = PgFlowRunner.job_input_opts(input)

      result = Pipeline.execute(context, run_id, opts)

      PgFlowRunner.job_outcome(result, run_id)
    end
  end
end
