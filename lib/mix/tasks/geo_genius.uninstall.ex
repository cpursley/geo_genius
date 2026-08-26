defmodule Mix.Tasks.GeoGenius.Uninstall do
  @moduledoc """
  Drops the GeoGenius schema and all of its data at a prefix.

  This is destructive and irreversible, so by default it only prints the
  statements for review; pass `--yes` to execute them. The drop runs directly
  against the repo rather than through `Ecto.Migrator`, since
  `GeoGenius.Migration.down/1` only runs inside an active `Ecto.Migration`
  process and routing it through the migrator would write a fabricated,
  irreversible version row into `schema_migrations` -- a table this library
  does not own.

  Dropping the schema leaves the host's setup migration recorded as applied,
  which would make `mix ecto.migrate` skip reinstalling it. So the host's
  `schema_migrations` row for that wrapper is deleted alongside the schema.
  """

  use Mix.Task

  alias GeoGenius.MixHelpers

  @shortdoc "Drops the installed GeoGenius schema and its data"

  @impl Mix.Task
  def run(args) do
    %{repo: requested_repo, prefix: prefix, yes?: yes?} = parse_args(args)

    Mix.Task.run("app.config", args)
    repo = requested_repo |> MixHelpers.resolve_repo() |> Mix.Ecto.ensure_repo(args)

    versions = wrapper_versions(repo)

    if yes? do
      drop!(repo, prefix, versions)
      Mix.shell().info("Dropped GeoGenius schema at prefix #{prefix}")
    else
      Mix.shell().info(statements(prefix, versions))
    end

    :ok
  end

  defp statements(prefix, versions) do
    unrecord =
      case versions do
        [] ->
          "-- No setup migration wrapper was found, so no schema_migrations row is removed."

        versions ->
          "DELETE FROM schema_migrations WHERE version IN (#{Enum.join(versions, ", ")});"
      end

    """
    -- Review carefully before running. This destroys all GeoGenius data at this prefix.
    DROP SCHEMA IF EXISTS "#{prefix}" CASCADE;
    #{unrecord}
    """
  end

  defp drop!(repo, prefix, versions) do
    {started?, pid} = MixHelpers.start_repo(repo)

    try do
      repo.query!(~s(DROP SCHEMA IF EXISTS "#{prefix}" CASCADE))

      if versions != [] do
        repo.query!("DELETE FROM schema_migrations WHERE version = ANY($1)", [versions])
      end
    after
      if started?, do: GenServer.stop(pid)
    end
  end

  # The setup wrapper is the host migration that installed GeoGenius. Its
  # version has to leave schema_migrations with the schema, or a later
  # geo_genius.setup refuses to regenerate the wrapper and ecto.migrate skips
  # the existing one as already applied -- leaving no way to reinstall.
  defp wrapper_versions(repo) do
    Mix.EctoSQL.source_repo_priv(repo)
    |> Path.join("migrations")
    |> Path.join("*_setup_geo_genius.exs")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename() |> String.split("_", parts: 2) |> hd()))
    |> Enum.flat_map(fn version ->
      case Integer.parse(version) do
        {parsed, ""} -> [parsed]
        _ -> []
      end
    end)
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: [repo: :string, prefix: :string, yes: :boolean]) do
      {opts, [], []} ->
        prefix = MixHelpers.validate_prefix!(opts[:prefix] || "geo_genius")

        %{
          repo: if(opts[:repo], do: Module.concat([opts[:repo]])),
          prefix: prefix,
          yes?: opts[:yes] || false
        }

      {_opts, [arg | _], []} ->
        Mix.raise("unexpected positional argument: #{arg}")

      {_opts, _args, [{option, _value} | _]} ->
        Mix.raise("unknown option: #{option}")
    end
  end
end
