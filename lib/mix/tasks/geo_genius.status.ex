defmodule Mix.Tasks.GeoGenius.Status do
  @moduledoc """
  Reports import runs, and what a collection currently publishes.

  ## Options

    * `--run-id` - report one run
    * `--collection` - report every run for a collection, newest first, plus
      the release that collection currently publishes
    * `--repo` - the Ecto Repo to run against
    * `--prefix` - the PostgreSQL schema GeoGenius is installed in

  `--run-id` and `--collection` are mutually exclusive: a run id already names
  exactly one run, so pairing it with a collection could only contradict it.
  """

  use Mix.Task

  alias GeoGenius.Catalog
  alias GeoGenius.Context
  alias GeoGenius.ImportRun
  alias GeoGenius.MixHelpers

  @shortdoc "Reports GeoGenius import runs"

  @switches [run_id: :string, collection: :string, repo: :string, prefix: :string]

  @impl Mix.Task
  def run(args) do
    parsed = parse_args(args)
    Mix.Task.run("app.config", args)
    repo = parsed.repo |> MixHelpers.resolve_repo() |> Mix.Ecto.ensure_repo(args)
    {started?, pid} = MixHelpers.start_repo(repo)

    try do
      report(repo, parsed)
    after
      if started?, do: GenServer.stop(pid)
    end
  end

  @doc false
  @spec parse_args([String.t()]) :: %{
          repo: module() | nil,
          prefix: String.t(),
          run_id: String.t() | nil,
          collection: String.t() | nil
        }
  def parse_args(args) do
    opts = MixHelpers.parse_strict!(args, @switches)
    validate_selection!(opts)

    %{
      repo: MixHelpers.repo_option(opts[:repo]),
      prefix: MixHelpers.validate_prefix!(opts[:prefix] || "geo_genius"),
      run_id: opts[:run_id],
      collection: opts[:collection]
    }
  end

  defp validate_selection!(opts) do
    cond do
      opts[:run_id] && opts[:collection] ->
        Mix.raise("--run-id and --collection are mutually exclusive; pass one or the other")

      opts[:run_id] || opts[:collection] ->
        :ok

      true ->
        Mix.raise("--run-id is required, or --collection")
    end
  end

  defp report(repo, %{run_id: run_id} = parsed) when is_binary(run_id) do
    case GeoGenius.status(run_id, repo: repo, prefix: parsed.prefix) do
      %ImportRun{} = run -> Mix.shell().info(describe(run))
      nil -> Mix.shell().info("GeoGenius has no import run #{run_id} at prefix #{parsed.prefix}")
    end

    :ok
  end

  # Reads runs straight from `GeoGenius.Catalog`, which is this library's own
  # module and ships with this task: the public API deliberately exposes one
  # run by id and nothing wider, and a collection-wide listing is an operator
  # concern rather than a runtime read a host application makes.
  defp report(repo, %{collection: collection} = parsed) do
    context = Context.new(repo: repo, prefix: parsed.prefix)
    listing = runs(Catalog.import_runs(context, collection))
    published = GeoGenius.published_release(collection, repo: repo, prefix: parsed.prefix)

    Mix.shell().info("""
    Collection #{collection} at prefix #{parsed.prefix}
    published release: #{MixHelpers.release_label(published)}
    #{listing}
    """)

    :ok
  end

  defp runs([]), do: "no import runs"
  defp runs(runs), do: Enum.map_join(runs, "\n", &describe/1)

  defp describe(%ImportRun{} = run) do
    "#{run.run_id} #{run.collection_key}/#{run.release_key} attempt #{run.attempt} " <>
      "#{run.status} owner #{run.owner} via #{run.runner_backend} started #{run.started_at}"
  end
end
