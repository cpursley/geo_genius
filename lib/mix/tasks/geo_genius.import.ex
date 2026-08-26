defmodule Mix.Tasks.GeoGenius.Import do
  @moduledoc """
  Registers a collection release from its manifest and enqueues its import.

  ## Options

    * `--collection` - the collection key to import (required)
    * `--release` - the release key to import (required)
    * `--publish` - publish the release once the import completes
    * `--await` - wait for the run to finish instead of returning its id
    * `--timeout` - how long `--await` waits, in milliseconds (default 300000)
    * `--owner` - the owner recorded on the run's lease (default the node name)
    * `--repo` - the Ecto Repo to run against
    * `--prefix` - the PostgreSQL schema GeoGenius is installed in

  Without `--await` the task prints the run id and returns as soon as the run
  is enqueued: the work may be executing on another node entirely. With
  `--await` it polls the catalog and exits non-zero for a run that failed or
  did not finish in time, so a deploy step can wait on the outcome.

  A `--timeout` that elapses stops the waiting, not the run. The named run is
  still executing wherever its backend put it, and `mix geo_genius.status
  --run-id` reads its outcome afterwards. Re-running the import instead is
  safe but pointless: the same owner resumes the same run rather than starting
  a second one.

  `--publish` publishes through the pipeline's own publishing phase, which
  bounds its statement by the window the run was claimed under (900 seconds by
  default). There is no switch here to move that bound, unlike
  `mix geo_genius.publish --timeout`; a release needing more than the default
  is imported without `--publish` and published by that task afterwards.
  """

  use Mix.Task

  alias GeoGenius.ImportRun
  alias GeoGenius.MixHelpers

  @shortdoc "Imports a collection release and enqueues its run"

  @switches [
    collection: :string,
    release: :string,
    publish: :boolean,
    await: :boolean,
    timeout: :integer,
    owner: :string,
    repo: :string,
    prefix: :string
  ]

  @default_timeout 300_000

  @impl Mix.Task
  def run(args) do
    parsed = parse_args(args)
    Mix.Task.run("app.config", args)
    repo = parsed.repo |> MixHelpers.resolve_repo() |> Mix.Ecto.ensure_repo(args)
    {started?, pid} = MixHelpers.start_repo(repo)

    try do
      start(repo, parsed)
    after
      if started?, do: GenServer.stop(pid)
    end
  end

  @doc false
  @spec parse_args([String.t()]) :: %{
          repo: module() | nil,
          prefix: String.t(),
          collection: String.t(),
          release: String.t(),
          publish: boolean(),
          await: boolean(),
          timeout: pos_integer(),
          owner: String.t() | nil
        }
  def parse_args(args) do
    opts = MixHelpers.parse_strict!(args, @switches)

    %{
      repo: MixHelpers.repo_option(opts[:repo]),
      prefix: MixHelpers.validate_prefix!(opts[:prefix] || "geo_genius"),
      collection: MixHelpers.required!(opts, :collection),
      release: MixHelpers.required!(opts, :release),
      publish: opts[:publish] || false,
      await: opts[:await] || false,
      timeout: opts[:timeout] || @default_timeout,
      owner: opts[:owner]
    }
  end

  defp start(repo, parsed) do
    case GeoGenius.import(import_opts(repo, parsed)) do
      {:ok, run_id} ->
        report(repo, parsed, run_id)

      {:error, reason} ->
        Mix.raise("GeoGenius import failed: #{MixHelpers.reason_message(reason)}")
    end
  end

  # `:owner` is omitted rather than passed as nil when `--owner` is absent, so
  # `GeoGenius.import/1`'s own default -- the node name, which is what lets a
  # worker restarting on the same node resume its own run -- still applies.
  # A literal nil would override that default and fail the run's NOT NULL owner.
  defp import_opts(repo, parsed) do
    opts = [
      repo: repo,
      prefix: parsed.prefix,
      collection: parsed.collection,
      release: parsed.release,
      publish: parsed.publish
    ]

    if parsed.owner, do: Keyword.put(opts, :owner, parsed.owner), else: opts
  end

  defp report(_repo, %{await: false}, run_id) do
    Mix.shell().info("GeoGenius enqueued import run #{run_id}")
    :ok
  end

  defp report(repo, %{await: true} = parsed, run_id) do
    case GeoGenius.await(run_id, parsed.timeout, repo: repo, prefix: parsed.prefix) do
      {:ok, %ImportRun{}} ->
        Mix.shell().info("GeoGenius import run #{run_id} completed")
        :ok

      {:error, :timeout} ->
        Mix.raise("GeoGenius import run #{run_id} did not finish within #{parsed.timeout}ms")

      {:error, %ImportRun{} = run} ->
        Mix.raise("GeoGenius import run #{run_id} failed: #{inspect(run.error)}")
    end
  end
end
