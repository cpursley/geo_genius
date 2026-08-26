defmodule Mix.Tasks.GeoGenius.CheckSchema do
  @moduledoc """
  Checks that the installed GeoGenius schema version matches the version
  shipped by this package.

  Exits non-zero on a mismatch, so it can be used as a CI or deploy gate.
  """

  use Mix.Task

  alias GeoGenius.MixHelpers

  @shortdoc "Checks the installed GeoGenius schema version"

  @impl Mix.Task
  def run(args) do
    %{repo: requested_repo, prefix: prefix} = parse_args(args)
    Mix.Task.run("app.config", args)
    repo = requested_repo |> MixHelpers.resolve_repo() |> Mix.Ecto.ensure_repo(args)
    {started?, pid} = MixHelpers.start_repo(repo)

    try do
      current = GeoGenius.Migration.current_version()
      installed = GeoGenius.Migration.installed_version(repo, prefix)

      Mix.shell().info("""
      GeoGenius prefix #{prefix}
      installed version: #{installed}
      expected version: #{current}
      """)

      if installed == current do
        :ok
      else
        Mix.raise(
          "GeoGenius schema mismatch for prefix #{prefix}: installed #{installed}, expected #{current}"
        )
      end
    after
      if started?, do: GenServer.stop(pid)
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: [repo: :string, prefix: :string]) do
      {opts, [], []} ->
        prefix = MixHelpers.validate_prefix!(opts[:prefix] || "geo_genius")
        %{repo: if(opts[:repo], do: Module.concat([opts[:repo]])), prefix: prefix}

      {_opts, [arg | _], []} ->
        Mix.raise("unexpected positional argument: #{arg}")

      {_opts, _args, [{option, _value} | _]} ->
        Mix.raise("unknown option: #{option}")
    end
  end
end
