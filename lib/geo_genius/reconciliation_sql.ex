defmodule GeoGenius.ReconciliationSQL do
  @moduledoc false

  alias EctoEvolver.Adapters.Postgres
  alias GeoGenius.SchemaContract

  @sql_path "geo_genius/sql/reconciliation"
  @legacy :legacy_v01_aebc28a
  @reviewed "sha256:8c5adea2c1fab08fdbc67137ff99ea0864c69a3dff5a3952dd9d6e62d971ab25"
  @target SchemaContract.revision()
  @placeholder ~r/\$(?:SCHEMA|PREFIX_LITERAL|REVIEWED_REVISION|TARGET_REVISION)\$/

  @doc false
  def render!(opts) when is_list(opts) do
    transaction? = Keyword.get(opts, :transaction, true)
    statements = statements!(opts)
    sql = Enum.join(statements, "\n\n")

    if transaction? do
      "BEGIN;\n\n#{sql}\n\nCOMMIT;\n"
    else
      sql <> "\n"
    end
  end

  @doc false
  def statements!(opts) when is_list(opts) do
    prefix = opts |> Keyword.fetch!(:prefix) |> SchemaContract.validate_prefix!()
    from = opts |> Keyword.fetch!(:from) |> identity!()
    to = opts |> Keyword.fetch!(:to) |> identity!()
    directions = directions!(from, to)

    replacements = %{
      "$SCHEMA$" => Postgres.escape_identifier(prefix),
      "$PREFIX_LITERAL$" => Postgres.escape_string(prefix),
      "$REVIEWED_REVISION$" => Postgres.escape_string(@reviewed),
      "$TARGET_REVISION$" => Postgres.escape_string(SchemaContract.revision())
    }

    directions
    |> Enum.flat_map(&statements_for_direction(&1, replacements))
  end

  defp identity!(@legacy), do: @legacy
  defp identity!("legacy_v01_aebc28a"), do: @legacy
  defp identity!(@reviewed), do: @reviewed
  defp identity!(@target), do: @target

  defp identity!(identity) do
    raise ArgumentError, "unsupported GeoGenius contract identity: #{inspect(identity)}"
  end

  defp directions!(@legacy, @reviewed), do: ["legacy_to_target", "target_to_reviewed"]
  defp directions!(@reviewed, @legacy), do: ["target_to_legacy"]
  defp directions!(@legacy, @target), do: ["legacy_to_target"]
  defp directions!(@reviewed, @target), do: ["legacy_to_target"]
  defp directions!(@target, @legacy), do: ["target_to_reviewed", "target_to_legacy"]
  defp directions!(@target, @reviewed), do: ["target_to_reviewed"]

  defp directions!(from, to) do
    raise ArgumentError,
          "unsupported GeoGenius reconciliation edge: #{inspect(from)} to #{inspect(to)}"
  end

  defp statements_for_direction(direction, replacements) do
    :geo_genius
    |> :code.priv_dir()
    |> Path.join(@sql_path)
    |> Path.join("#{direction}.sql")
    |> File.read!()
    |> String.split("--SPLIT--")
    |> Enum.map(&render_template(&1, replacements))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&empty_or_comment_only?/1)
  end

  defp empty_or_comment_only?(chunk) do
    chunk
    |> String.split("\n")
    |> Enum.reject(fn line ->
      trimmed = String.trim(line)
      trimmed == "" or String.starts_with?(trimmed, "--")
    end)
    |> Enum.empty?()
  end

  defp render_template(template, replacements) do
    String.replace(template, @placeholder, &Map.fetch!(replacements, &1))
  end
end
