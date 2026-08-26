defmodule Mix.Tasks.GeoGenius.Setup do
  @moduledoc "Generates the host application's pinned initial GeoGenius migration wrapper."

  use Mix.Task

  alias GeoGenius.MixHelpers

  @shortdoc "Generates a host migration that installs GeoGenius"

  @impl Mix.Task
  def run(args) do
    %{repo: requested_repo, prefix: prefix, with_extensions: with_extensions} =
      MixHelpers.parse_setup_args(args)

    Mix.Task.run("app.config", args)
    repo = MixHelpers.resolve_repo(requested_repo)
    Mix.Ecto.ensure_repo(repo, args)
    migrations_path = Path.join(Mix.EctoSQL.source_repo_priv(repo), "migrations")

    if Path.wildcard(Path.join(migrations_path, "*_setup_geo_genius.exs")) != [] do
      Mix.raise("GeoGenius setup migration already exists in #{migrations_path}")
    end

    path =
      MixHelpers.generate_wrapper!(
        repo,
        "setup_geo_genius",
        prefix,
        0,
        GeoGenius.Migration.current_version(),
        with_extensions: with_extensions
      )

    Mix.shell().info("Generated GeoGenius setup migration: #{Path.relative_to_cwd(path)}")
    :ok
  end
end
