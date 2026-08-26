defmodule Mix.Tasks.GeoGenius.Rollback do
  @moduledoc """
  Rolls a collection's publication back to its previous release.

  ## Options

    * `--collection` - the collection to roll back (required)
    * `--yes` - actually perform the rollback
    * `--repo` - the Ecto Repo to run against
    * `--prefix` - the PostgreSQL schema GeoGenius is installed in

  A rollback changes what every host reading this collection sees, so like
  `mix geo_genius.uninstall` it prints what it would do and does nothing
  without `--yes`. It does not happen from a typo.

  A rollback that committed exits zero even when the release it rolled back to
  could not be read afterwards. The publication has already moved by then, so
  exiting non-zero under a "failed" label would invite a deploy script that
  retries on exit code to roll the collection back a second step. The
  unreadable outcome is reported on stderr instead, naming the rollback as
  done.
  """

  use Mix.Task

  alias GeoGenius.MixHelpers

  @shortdoc "Rolls a collection back to its previous release"

  @switches [collection: :string, yes: :boolean, repo: :string, prefix: :string]

  @impl Mix.Task
  def run(args) do
    parsed = parse_args(args)
    Mix.Task.run("app.config", args)
    repo = parsed.repo |> MixHelpers.resolve_repo() |> Mix.Ecto.ensure_repo(args)
    {started?, pid} = MixHelpers.start_repo(repo)

    try do
      rollback(repo, parsed)
    after
      if started?, do: GenServer.stop(pid)
    end
  end

  @doc false
  @spec parse_args([String.t()]) :: %{
          repo: module() | nil,
          prefix: String.t(),
          collection: String.t(),
          yes?: boolean()
        }
  def parse_args(args) do
    opts = MixHelpers.parse_strict!(args, @switches)

    %{
      repo: MixHelpers.repo_option(opts[:repo]),
      prefix: MixHelpers.validate_prefix!(opts[:prefix] || "geo_genius"),
      collection: MixHelpers.required!(opts, :collection),
      yes?: opts[:yes] || false
    }
  end

  defp rollback(repo, %{yes?: true} = parsed) do
    case GeoGenius.rollback(parsed.collection, repo: repo, prefix: parsed.prefix) do
      {:ok, release_id} ->
        Mix.shell().info(
          "GeoGenius rolled collection #{parsed.collection} back to release #{release_id}"
        )

        :ok

      {:error, {:unread, message}} ->
        Mix.shell().error("GeoGenius rollback needs checking: #{message}")
        :ok

      {:error, reason} ->
        Mix.raise("GeoGenius rollback failed: #{MixHelpers.reason_message(reason)}")
    end
  end

  defp rollback(repo, %{yes?: false} = parsed) do
    published = GeoGenius.published_release(parsed.collection, repo: repo, prefix: parsed.prefix)

    Mix.shell().info("""
    -- Review carefully. This changes what every host reading this collection sees.
    Collection #{parsed.collection} at prefix #{parsed.prefix} currently publishes #{MixHelpers.release_label(published)}.
    Pass --yes to roll it back to the release published before that one.
    """)

    :ok
  end
end
