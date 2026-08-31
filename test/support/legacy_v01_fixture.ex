defmodule GeoGenius.LegacyV01Fixture do
  @moduledoc false

  alias EctoEvolver.Adapters.Postgres

  @sql_path Path.expand("sql/legacy_v01_aebc28a.sql", __DIR__)

  @doc false
  @spec apply!(module(), String.t()) :: :ok
  def apply!(repo, prefix) do
    @sql_path
    |> File.read!()
    |> String.replace("$SCHEMA$", Postgres.escape_identifier(prefix))
    |> String.split("--SPLIT--")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(&repo.query!(&1, [], log: false, query_type: :text))

    :ok
  end
end
