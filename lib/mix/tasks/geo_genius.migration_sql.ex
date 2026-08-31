defmodule Mix.Tasks.GeoGenius.MigrationSql do
  @moduledoc "Renders a pinned GeoGenius SQL transition for non-Ecto migration hosts."

  use Mix.Task

  alias GeoGenius.Migration
  alias GeoGenius.MixHelpers

  @shortdoc "Renders a GeoGenius SQL migration"
  @switches [prefix: :string, from: :string, to: :string]

  @impl Mix.Task
  def run(args) do
    opts = MixHelpers.parse_strict!(args, @switches)

    sql =
      Migration.render_sql(
        prefix: MixHelpers.required!(opts, :prefix),
        from: required_integer!(opts, :from),
        to: required_integer!(opts, :to)
      )

    Mix.shell().info(sql)
    :ok
  end

  defp required_integer!(opts, key) do
    case opts |> MixHelpers.required!(key) |> Integer.parse() do
      {integer, ""} ->
        integer

      _ ->
        Mix.raise("--#{key |> Atom.to_string() |> String.replace("_", "-")} must be an integer")
    end
  end
end
