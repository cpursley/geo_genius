defmodule Mix.Tasks.GeoGenius.Publish do
  @moduledoc """
  Publishes a verified release, so reads that name no release id resolve to it.

  ## Options

    * `--release-id` - the release to publish, by id
    * `--collection` and `--release` - the release to publish, by key
    * `--repo` - the Ecto Repo to run against
    * `--prefix` - the PostgreSQL schema GeoGenius is installed in
    * `--timeout` - milliseconds the publication statement is allowed
      (default 900000)

  `--release-id` and `--collection` are mutually exclusive: supplying both
  would make one silently win over the other, and the two can name different
  releases. A release that fails verification exits non-zero through
  `Mix.raise/1`, so this gates a deploy rather than reporting a publication
  that did not happen.

  Publishing re-runs the release's verification inside the publication, which
  on a national release is minutes of work in one statement. `--timeout` is
  what a release too large for the default asks with, so a publication does
  not need the host's whole Repo raised to succeed.
  """

  use Mix.Task

  alias GeoGenius.Catalog
  alias GeoGenius.Context
  alias GeoGenius.ImportRun
  alias GeoGenius.MixHelpers

  @shortdoc "Publishes a verified release"

  @switches [
    release_id: :string,
    collection: :string,
    release: :string,
    repo: :string,
    prefix: :string,
    timeout: :integer
  ]

  @default_timeout 900_000

  @impl Mix.Task
  def run(args) do
    parsed = parse_args(args)
    Mix.Task.run("app.config", args)
    repo = parsed.repo |> MixHelpers.resolve_repo() |> Mix.Ecto.ensure_repo(args)
    {started?, pid} = MixHelpers.start_repo(repo)

    try do
      publish(repo, parsed)
    after
      if started?, do: GenServer.stop(pid)
    end
  end

  @doc false
  @spec parse_args([String.t()]) :: %{
          repo: module() | nil,
          prefix: String.t(),
          release_id: String.t() | nil,
          collection: String.t() | nil,
          release: String.t() | nil,
          timeout: pos_integer()
        }
  def parse_args(args) do
    opts = MixHelpers.parse_strict!(args, @switches)
    validate_selection!(opts)

    %{
      repo: MixHelpers.repo_option(opts[:repo]),
      prefix: MixHelpers.validate_prefix!(opts[:prefix] || "geo_genius"),
      release_id: opts[:release_id],
      collection: opts[:collection],
      release: opts[:release],
      timeout: opts[:timeout] || @default_timeout
    }
  end

  defp validate_selection!(opts) do
    cond do
      opts[:release_id] && (opts[:collection] || opts[:release]) ->
        Mix.raise("--release-id and --collection are mutually exclusive; pass one or the other")

      opts[:release_id] || (opts[:collection] && opts[:release]) ->
        :ok

      opts[:collection] ->
        Mix.raise("--release is required alongside --collection")

      opts[:release] ->
        Mix.raise("--collection is required alongside --release")

      true ->
        Mix.raise("--release-id is required, or --collection and --release together")
    end
  end

  defp publish(repo, parsed) do
    release_id = release_id(repo, parsed)

    case GeoGenius.publish(release_id,
           repo: repo,
           prefix: parsed.prefix,
           timeout: parsed.timeout
         ) do
      {:ok, published} ->
        Mix.shell().info("GeoGenius published release #{published}")
        :ok

      {:error, reason} ->
        Mix.raise("GeoGenius publish failed: #{MixHelpers.reason_message(reason)}")
    end
  end

  defp release_id(_repo, %{release_id: release_id}) when is_binary(release_id), do: release_id

  # A release key is unique within its collection but carries no id of its own,
  # and the catalog's only key-to-id projection is `import_run_status` -- every
  # release GeoGenius opens is opened by an import, so a release key with no run
  # behind it is a key nothing ever imported.
  defp release_id(repo, %{collection: collection, release: release, prefix: prefix}) do
    context = Context.new(repo: repo, prefix: prefix)

    case Enum.find(Catalog.import_runs(context, collection), &(&1.release_key == release)) do
      %ImportRun{release_id: release_id} ->
        release_id

      nil ->
        Mix.raise("GeoGenius has no imported release #{release} in collection #{collection}")
    end
  end
end
