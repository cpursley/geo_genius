defmodule Mix.Tasks.GeoGenius.ReconciliationSql do
  @moduledoc "Renders one explicit GeoGenius v01 contract reconciliation edge."

  use Mix.Task

  alias GeoGenius.Migration
  alias GeoGenius.MixHelpers

  @shortdoc "Renders a GeoGenius contract reconciliation"
  @switches [prefix: :string, from: :string, to: :string]

  @impl Mix.Task
  def run(args) do
    opts = MixHelpers.parse_strict!(args, @switches)

    sql =
      Migration.render_reconciliation_sql(
        prefix: MixHelpers.required!(opts, :prefix),
        from: MixHelpers.required!(opts, :from),
        to: MixHelpers.required!(opts, :to)
      )

    Mix.shell().info(sql)
    :ok
  end
end
