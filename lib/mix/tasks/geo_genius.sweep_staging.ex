defmodule Mix.Tasks.GeoGenius.SweepStaging do
  @moduledoc """
  Drops per-run staging tables left behind by runs that have already finished.

  ## Options

    * `--yes` - actually drop the tables
    * `--repo` - the Ecto Repo to run against
    * `--prefix` - the PostgreSQL schema GeoGenius is installed in

  The pipeline drops a run's staging table in an `after` clause, and that drop
  is deliberately rescued so a database failure during cleanup cannot destroy
  the run's own failure record. A host whose database dies mid-cleanup
  therefore leaks a table, nothing else reclaims it, and the schema down
  migration's teardown refuses to drop a non-empty schema -- so a leak eventually blocks an
  uninstall. This reclaims them.

  A table whose `import_run` row is gone entirely is reclaimed too. That is
  the case nothing else can reach: with no run row to read a status from,
  such a table is invisible to anything that starts from `import_run`, and it
  would otherwise sit in the schema until an operator found it by hand.

  Like `mix geo_genius.rollback`, it prints what it would drop and does nothing
  without `--yes`.
  """

  use Mix.Task

  alias GeoGenius.Context
  alias GeoGenius.MixHelpers
  alias GeoGenius.Staging

  @shortdoc "Drops leaked per-run staging tables"

  @switches [yes: :boolean, repo: :string, prefix: :string]

  @impl Mix.Task
  def run(args) do
    parsed = parse_args(args)
    Mix.Task.run("app.config", args)
    repo = parsed.repo |> MixHelpers.resolve_repo() |> Mix.Ecto.ensure_repo(args)
    {started?, pid} = MixHelpers.start_repo(repo)

    try do
      sweep(Context.new(repo: repo, prefix: parsed.prefix), parsed)
    after
      if started?, do: GenServer.stop(pid)
    end
  end

  @doc false
  @spec parse_args([String.t()]) :: %{
          repo: module() | nil,
          prefix: String.t(),
          yes?: boolean()
        }
  def parse_args(args) do
    opts = MixHelpers.parse_strict!(args, @switches)

    %{
      repo: MixHelpers.repo_option(opts[:repo]),
      prefix: MixHelpers.validate_prefix!(opts[:prefix] || "geo_genius"),
      yes?: opts[:yes] || false
    }
  end

  defp sweep(context, parsed) do
    case Staging.leaked(context) do
      [] ->
        Mix.shell().info("GeoGenius found no leaked staging tables at prefix #{parsed.prefix}")
        :ok

      leaked ->
        report(context, parsed, leaked)
    end
  end

  defp report(context, %{yes?: true} = parsed, leaked) do
    case drop_each(context, leaked) do
      {dropped, :ok} ->
        Mix.shell().info(
          "GeoGenius dropped #{length(dropped)} leaked staging table(s) at " <>
            "prefix #{parsed.prefix}:\n" <> listing(dropped)
        )

        :ok

      {dropped, {:error, exception}} ->
        Mix.raise(
          "GeoGenius dropped #{length(dropped)} of #{length(leaked)} leaked staging table(s) " <>
            "at prefix #{parsed.prefix} before failing: #{Exception.message(exception)}" <>
            already_dropped(dropped)
        )
    end
  end

  defp report(_context, %{yes?: false} = parsed, leaked) do
    Mix.shell().info("""
    -- Review carefully. These tables belong to runs that have already finished,
    -- or to no run at all.
    #{length(leaked)} leaked staging table(s) at prefix #{parsed.prefix}:
    #{listing(leaked)}
    Pass --yes to drop them.
    """)

    :ok
  end

  # A sweep that stops partway has already dropped everything before the table
  # it stopped on, and those drops are committed. Raising the driver's reason
  # alone reads as a sweep that did nothing, which sends an operator looking
  # for tables that are already gone.
  defp drop_each(context, leaked) do
    {dropped, outcome} =
      Enum.reduce_while(leaked, {[], :ok}, fn {run_id, _table} = entry, {dropped, :ok} ->
        case drop_one(context, run_id) do
          :ok -> {:cont, {[entry | dropped], :ok}}
          {:error, exception} -> {:halt, {dropped, {:error, exception}}}
        end
      end)

    {Enum.reverse(dropped), outcome}
  end

  defp drop_one(context, run_id) do
    Staging.drop(context, run_id)
    :ok
  rescue
    exception -> {:error, exception}
  end

  defp already_dropped([]), do: ""

  defp already_dropped(dropped), do: "\nAlready dropped:\n" <> listing(dropped)

  defp listing(leaked) do
    Enum.map_join(leaked, "\n", fn {run_id, table} -> "  #{table} (run #{run_id})" end)
  end
end
