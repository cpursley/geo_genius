defmodule GeoGenius.MigrationSQL do
  @moduledoc false

  alias EctoEvolver.Adapters.Postgres

  @sql_path "geo_genius/sql/versions"

  @doc "Renders SQL for a GeoGenius schema transition."
  @spec render!(keyword()) :: String.t()
  def render!(opts) when is_list(opts) do
    prefix = opts |> Keyword.fetch!(:prefix) |> GeoGenius.SchemaContract.validate_prefix!()
    from = opts |> Keyword.fetch!(:from) |> validate_version!(:from)
    to = opts |> Keyword.fetch!(:to) |> validate_version!(:to)
    current = GeoGenius.Migration.current_version()

    validate_range!(from, to, current)

    prefix
    |> render_versions(versions(from, to), direction(from, to))
    |> append_version_marker(prefix, to)
  end

  defp validate_version!(version, _name) when is_integer(version) and version >= 0, do: version

  defp validate_version!(_version, name) do
    raise ArgumentError, "#{name} must be a non-negative integer"
  end

  defp validate_range!(from, to, _current) when from == to do
    raise ArgumentError, "from and to must differ"
  end

  defp validate_range!(from, to, current) when from > current or to > current do
    raise ArgumentError, "versions must not exceed current version #{current}"
  end

  defp validate_range!(_from, _to, _current), do: :ok

  defp versions(from, to) when from < to, do: (from + 1)..to
  defp versions(from, to), do: from..(to + 1)//-1

  defp direction(from, to) when from < to, do: :up
  defp direction(_from, _to), do: :down

  defp render_versions(prefix, versions, direction) do
    escaped_prefix = Postgres.escape_identifier(prefix)

    Enum.map_join(versions, "\n\n", &read_version!(&1, direction, escaped_prefix))
  end

  defp read_version!(version, direction, escaped_prefix) do
    :geo_genius
    |> EctoEvolver.SqlRunner.build_file_path(@sql_path, version_name(version), direction)
    |> File.read!()
    |> String.replace("$SCHEMA$", escaped_prefix)
    |> String.replace("--SPLIT--", "")
    |> String.trim()
  end

  defp version_name(version), do: version |> Integer.to_string() |> String.pad_leading(2, "0")

  defp append_version_marker(sql, _prefix, 0), do: sql

  defp append_version_marker(sql, prefix, version) do
    escaped_prefix = Postgres.escape_identifier(prefix)
    escaped_comment = Postgres.escape_string("GeoGenius version=#{version}")

    sql <> "\n\nCOMMENT ON VIEW #{escaped_prefix}.geo_genius_version IS #{escaped_comment};"
  end
end
