defmodule Mix.Tasks.GeoGenius.Gen.Migration do
  @moduledoc "Generates a pinned wrapper for one supported adjacent GeoGenius schema upgrade."

  use Mix.Task

  alias GeoGenius.MixHelpers

  @shortdoc "Generates one adjacent GeoGenius upgrade migration"

  @impl Mix.Task
  def run(args) do
    %{repo: requested_repo, prefix: prefix, from: from, to: to} =
      MixHelpers.parse_upgrade_args(args)

    Mix.Task.run("app.config", args)
    MixHelpers.validate_transition!(from, to, GeoGenius.Migration.current_version())
    repo = MixHelpers.resolve_repo(requested_repo)

    name = "upgrade_geo_genius_v#{to}"
    path = MixHelpers.generate_wrapper!(repo, name, prefix, from, to)

    Mix.shell().info("Generated GeoGenius upgrade migration: #{Path.relative_to_cwd(path)}")
    :ok
  end
end
