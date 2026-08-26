defmodule GeoGenius.Runners.PgFlow do
  @moduledoc """
  Runs an import as a durable PgFlow background job.

  Built against `pgflow` 0.3.1's documented job API -- `use PgFlow.Job`,
  `@job`, `perform`, and `PgFlow.enqueue/2` -- verified against the
  installed package, not guessed at. That job definition lives in
  `GeoGenius.Runners.PgFlow.Job`, a second module in this same file, defined
  only when `PgFlow.Job` is loaded: a single-step job (`@job queue:
  :geo_genius_import`) whose `perform :execute` block calls
  `GeoGenius.Pipeline.execute/3` through `run/1`, `job_context/1`,
  `job_input_opts/1`, and `job_outcome/2` below.

  **`:pgflow` is not a dependency of this library.** `mix.exs` does not
  declare it, in either the `optional: true` or the ordinary form: as of
  0.3.1, `pgflow` does not compile at all unless `phoenix` and
  `phoenix_live_view` are also present, because ten files under its own
  `lib/pgflow_dashboard/components/` call `use Phoenix.Component` with no
  `Code.ensure_loaded?/1` guard, despite `phoenix` and `phoenix_live_view`
  being declared `optional: true` in `pgflow`'s own `mix.exs`. A host that
  adds `{:pgflow, "~> 0.3"}` to their own `mix.exs` will hit that exact
  compile failure themselves unless they also add Phoenix and Phoenix
  LiveView -- this module does not, and cannot, change that; it is a
  property of the `pgflow` package a host chooses to install.

  **This backend is therefore not exercised by this library's test suite.**
  No test in this repository loads `pgflow`, starts a `PgFlow.Supervisor`,
  or calls `GeoGenius.Runners.PgFlow.Job.run/1`. What the suite does verify
  is the behaviour a host without `pgflow` actually experiences: `name/0`,
  `available?/0` reporting `false`, `enqueue/3` returning `{:error, reason}`
  naming the package rather than raising, and `GeoGenius.Runner.configured/1`
  skipping past this backend to `Runners.Task` or `Runners.Inline` -- plus
  `job_outcome/2`, `job_input_opts/1`, and `job_context/1` below, which
  together cover everything `Job.run/1` does even though `Job.run/1` itself
  cannot be. A host that installs
  `pgflow` (and accepts the Phoenix requirement that comes with it) is
  relying on the job-API contract described here and confirmed once against
  the real package during development -- not on this repository's CI.

  `available?/0` reports whether this backend can actually accept work right
  now, and `enqueue/3` says so plainly rather than raising deep inside
  `PgFlow.enqueue/2`. Being available takes three things, all checked at
  runtime rather than assumed from configuration:

    * `pgflow` itself is loaded;
    * `GeoGenius.Runners.PgFlow.Job` -- this project's own submodule, not
      `pgflow`'s -- is loaded too. A host normally installs `geo_genius`
      first and adds `pgflow` to `mix.exs` afterward, and adding a
      dependency to a host's `mix.exs` does not invalidate `geo_genius`'s
      already-compiled `_build` artifacts. Without this check,
      `Code.ensure_loaded?(PgFlow)` could answer `true` (the package is
      fetched and compiled) while this project's own `Job` submodule --
      compiled back when `PgFlow.Job` did not yet exist in the build --
      stays stale and uncompiled, and `enqueue/3` would hand
      `PgFlow.enqueue/2` a module that is not there;
    * `PgFlow.Supervisor` -- the process PgFlow's own supervision tree
      registers itself under once `{PgFlow, repo: ..., jobs: [...]}` has
      actually started -- is running.

  A host that satisfies the first two but never started that supervisor
  gets the same "unavailable" answer as a host that never added `pgflow` at
  all, exactly as `GeoGenius.Runners.Task` treats a configured but dead
  `Task.Supervisor` name.

  `enqueue/3` hands `GeoGenius.Runners.PgFlow.Job` a JSON-serializable
  input: `run_id`, `publish`, `stale_after_seconds`, and `prefix`. It never
  sends `repo`. A durable
  job outlives the process that enqueued it, so its handler resolves the
  repo from application environment when
  it actually runs, rather than reviving a module atom decoded out of
  storage a host never intended as a code-execution surface. `prefix`
  carries no such risk -- it is a plain string, already validated once when
  this context was built -- so it travels
  through the job input as given instead of being re-defaulted from
  configuration on the other side.

  A host that installs `pgflow` wires this up once:

    1. Add `{:pgflow, "~> 0.3"}`, `{:phoenix, "~> 1.7"}`, and
       `{:phoenix_live_view, "~> 1.0"}` to `mix.exs`, then `mix deps.get`.
    2. Run `mix deps.compile geo_genius --force` -- the stale-`Job`
       hazard described above; skip this and `available?/0` may see an
       uncompiled `Job` and correctly refuse to enqueue, or, on an older
       build of this file without that check, silently enqueue a module
       that does not exist.
    3. Compile the job into the database with `mix pgflow.gen.job_migration
       GeoGenius.Runners.PgFlow.Job` followed by `mix ecto.migrate`.
    4. Start `{PgFlow, repo: MyApp.Repo, jobs: [GeoGenius.Runners.PgFlow.Job]}`
       under its own supervision tree.
  """

  @behaviour GeoGenius.Runner

  @compile {:no_warn_undefined, PgFlow}

  # Dialyzer's `:unknown` flag (enabled project-wide in `mix.exs`) reports a
  # call to a module absent from the PLT as `unknown_function`. That is
  # accurate and expected on a build with no `:pgflow` -- `submit/3` calling
  # `PgFlow.enqueue/2` is exactly the optional call `available?/0` exists to
  # guard at runtime -- so it is silenced here rather than by removing the
  # `:unknown` flag project-wide and losing that check for every other call.
  @dialyzer {:no_unknown, submit: 3}

  alias GeoGenius.Config
  alias GeoGenius.Context
  alias GeoGenius.Runner
  alias GeoGenius.Runners.PgFlow.Job

  @impl GeoGenius.Runner
  @doc "Returns `\"pgflow\"`."
  @spec name() :: String.t()
  def name, do: "pgflow"

  @impl GeoGenius.Runner
  @doc """
  Reports whether `pgflow`, this project's own `Job` submodule, and a
  running `PgFlow.Supervisor` are all present right now.

  All three are checked live rather than assumed from configuration. A host
  that installed `pgflow` but never force-recompiled `geo_genius` afterward
  (`Code.ensure_loaded?(Job)`), or that added the dependency but never
  started `{PgFlow, repo: ..., jobs: [...]}` (`Process.whereis/1`), gets the
  same `false` a host that never touched `pgflow` at all gets -- the same
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
  queued it.

  Returns `:ok` once `PgFlow.enqueue/2` has written the job's own run row --
  the import's outcome will be recorded in the catalog once a worker picks
  the job up, so the caller reads it back from there rather than polling
  this call. Returns `{:error, reason}` when PgFlow is unavailable or could
  not accept the job at all: nothing was queued, and nothing about this
  import exists anywhere for a caller to read back.
  """
  @spec enqueue(Context.t(), Ecto.UUID.t(), Runner.args()) :: :ok | {:error, String.t()}
  def enqueue(context, run_id, args) do
    if available?() do
      submit(context, run_id, args)
    else
      {:error, unavailable_message()}
    end
  end

  @doc """
  Maps one `GeoGenius.Pipeline.execute/3` result to the plain,
  JSON-serializable outcome `GeoGenius.Runners.PgFlow.Job`'s `perform` step
  hands back to PgFlow.

  Lives here, on the module that always compiles, rather than inside `Job`
  itself, specifically so it is covered by this repository's own test
  suite: `Job` never compiles in this repository (`pgflow` is not
  installed), so nothing here would otherwise notice if
  `GeoGenius.Pipeline.execute/3` gained or renamed a return shape --
  `Job.run/1` would keep its stale clauses, and the first host running this
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
          | {:error, GeoGenius.ImportRun.t()}
          | {:error, {:unrecorded, String.t()}},
          Ecto.UUID.t()
        ) :: %{String.t() => String.t()}
  def job_outcome(result, run_id) do
    case result do
      {:ok, _run} ->
        %{"outcome" => "completed"}

      {:error, %GeoGenius.ImportRun{}} ->
        %{"outcome" => "failed"}

      {:error, {:unrecorded, reason}} ->
        raise "GeoGenius import run #{run_id} was not recorded: #{reason}"
    end
  end

  @doc """
  Builds the `Pipeline.execute/3` opts a job runs with, from its decoded input.

  Lives here, on the module that always compiles, for the same reason
  `job_outcome/2` does: `Job` never compiles in this repository, so nothing
  here would otherwise notice a renamed key or a dropped conversion. Reads
  both `"publish"` and `"stale_after_seconds"` through `Runner.publish?/1`
  and `Runner.stale_after_seconds/1` rather than `Map.get/2` directly, since
  `input` has already round-tripped through PgFlow's own JSON storage and
  carries string keys, not the atom keys a `Runner.args()` built in-process
  would.
  """
  @spec job_input_opts(map()) :: keyword()
  def job_input_opts(input) do
    [publish: Runner.publish?(input), stale_after_seconds: Runner.stale_after_seconds(input)]
  end

  @doc """
  Rebuilds the `Context` a job runs under, from its decoded input.

  Lives here for the same reason `job_input_opts/1` does. `:repo` is
  resolved fresh from application environment rather than from a module
  atom carried in `input` -- a durable job outlives the
  process that enqueued it, and `enqueue/3` never sends `repo` in the first
  place (see the moduledoc above). `:prefix` travels through `input` as
  given, already validated once when the enqueuing context was built.
  """
  @spec job_context(map()) :: Context.t()
  def job_context(input) do
    Context.new(repo: Config.repo!([]), prefix: Map.fetch!(input, "prefix"))
  end

  defp submit(context, run_id, args) do
    input = %{
      "run_id" => run_id,
      "publish" => Runner.publish?(args),
      "stale_after_seconds" => Runner.stale_after_seconds(args),
      "prefix" => context.prefix
    }

    case PgFlow.enqueue(Job, input) do
      {:ok, _pgflow_run_id} -> :ok
      {:error, reason} -> {:error, "PgFlow could not enqueue the import: #{inspect(reason)}"}
    end
  end

  @doc false
  @spec unavailable_message() :: String.t()
  def unavailable_message do
    ~s|GeoGenius cannot enqueue through PgFlow: :pgflow is not installed, not fully | <>
      ~s|compiled for this project, or its supervisor is not running. Add | <>
      ~s|{:pgflow, "~> 0.3"} to your deps -- along with {:phoenix, "~> 1.7"} and | <>
      ~s|{:phoenix_live_view, "~> 1.0"}, both required for pgflow 0.3 to compile at | <>
      ~s|all -- run `mix deps.get`, then `mix deps.compile geo_genius --force` (adding | <>
      ~s|a dependency to your own mix.exs does not recompile geo_genius's already-built | <>
      ~s|artifacts). Compile the job with `mix pgflow.gen.job_migration | <>
      ~s|GeoGenius.Runners.PgFlow.Job` and `mix ecto.migrate`, then start {PgFlow, repo: | <>
      ~s|MyApp.Repo, jobs: [GeoGenius.Runners.PgFlow.Job]} under your own supervision | <>
      ~s|tree, or configure a different GeoGenius.Runner.|
  end
end

if Code.ensure_loaded?(PgFlow.Job) do
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

    `timeout: 3_900` (seconds) is computed, not guessed: `GeoGenius.Pipeline`
    derives its own per-statement timeout from the run's
    `stale_after_seconds` (900s at the default), and four statements can
    each run that long before succeeding -- the staging insert,
    `rebuild_relations`, `analyze_release`, and `verify_release`. `4 * 900 =
    3600` seconds covers every one of them running right up to its own
    ceiling in turn, plus the same 300-second margin the original
    single-statement figure (`1_200` against a 900s ceiling) carried. Two
    things this does not cover: a caller that claims with a
    `stale_after_seconds` larger than the 900s default gets a per-statement
    timeout this constant knows nothing about, and PgFlow could kill a
    legitimately running import in that case; and a release large enough to
    need many staging batches, each up to its own timeout in turn, has no
    hard bound here at all -- a risk this figure inherited from the original
    constant rather than introduced.

    Deliberately thin: the mapping from `Pipeline.execute/3`'s result to
    this job's plain, JSON-serializable outcome, the opts it runs with, and
    the context it rebuilds all live on `GeoGenius.Runners.PgFlow` --
    `job_outcome/2`, `job_input_opts/1`, and `job_context/1` -- instead of
    here, because that module compiles (and is tested) in every build of
    this library, while this one compiles in none of them.
    """

    use PgFlow.Job

    alias GeoGenius.Pipeline
    alias GeoGenius.Runners.PgFlow, as: PgFlowRunner

    @job queue: :geo_genius_import, timeout: 3_900

    perform :execute do
      fn input, _ctx -> GeoGenius.Runners.PgFlow.Job.run(input) end
    end

    @doc """
    Runs one import to completion on behalf of the compiled `perform` block.

    Rebuilds the context and the `Pipeline.execute/3` opts through
    `GeoGenius.Runners.PgFlow.job_context/1` and `.job_input_opts/1`, then
    hands the result to `GeoGenius.Runners.PgFlow.job_outcome/2` -- all
    three the only parts of this behaviour ever covered by a test, since
    they live on the module that compiles unconditionally.
    """
    @spec run(map()) :: %{String.t() => String.t()}
    def run(input) do
      context = PgFlowRunner.job_context(input)
      run_id = Map.fetch!(input, "run_id")
      opts = PgFlowRunner.job_input_opts(input)

      result = Pipeline.execute(context, run_id, opts)

      PgFlowRunner.job_outcome(result, run_id)
    end
  end
end
