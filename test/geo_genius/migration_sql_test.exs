defmodule GeoGenius.MigrationSQLTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Migration

  test "renders a deterministic upgrade with escaped prefix and version marker" do
    assert sql = Migration.render_sql(prefix: "geo-genius", from: 0, to: 1)

    assert sql =~ ~s(CREATE SCHEMA IF NOT EXISTS "geo-genius")
    assert sql =~ ~s(COMMENT ON VIEW "geo-genius".geo_genius_version IS 'GeoGenius version=1')
    refute sql =~ "$SCHEMA$"
    refute sql =~ "--SPLIT--"
    assert sql == Migration.render_sql(prefix: "geo-genius", from: 0, to: 1)

    assert position(sql, "CREATE SCHEMA") < position(sql, "CREATE OR REPLACE VIEW")
  end

  test "renders the version down SQL without a stale version marker" do
    assert sql = Migration.render_sql(prefix: "geo_genius", from: 1, to: 0)

    assert sql =~
             "DROP FUNCTION IF EXISTS geo_genius.put_boundaries(uuid, uuid, text[], uuid[], geometry[], integer[], jsonb[])"

    assert sql =~ "DROP FUNCTION IF EXISTS geo_genius.fail_import(uuid, uuid, jsonb)"
    assert sql =~ "DROP FUNCTION IF EXISTS geo_genius.publish_import(uuid, uuid)"
    assert sql =~ "DROP FUNCTION IF EXISTS geo_genius.create_staging(uuid, uuid)"

    assert sql =~ "DROP VIEW IF EXISTS geo_genius.geo_genius_version"
    refute sql =~ "COMMENT ON VIEW geo_genius.geo_genius_version IS 'GeoGenius version=1'"
    refute sql =~ "$SCHEMA$"
    refute sql =~ "--SPLIT--"
  end

  test "rejects invalid migration ranges" do
    assert_raise ArgumentError, ~r/from and to must differ/, fn ->
      Migration.render_sql(prefix: "geo_genius", from: 0, to: 0)
    end

    assert_raise ArgumentError, ~r/non-negative/, fn ->
      Migration.render_sql(prefix: "geo_genius", from: -1, to: 0)
    end

    assert_raise ArgumentError, ~r/current version/, fn ->
      Migration.render_sql(prefix: "geo_genius", from: 0, to: 2)
    end
  end

  test "rejects invalid PostgreSQL prefixes" do
    assert_raise ArgumentError, ~r/reserved/, fn ->
      Migration.render_sql(prefix: "public", from: 0, to: 1)
    end

    assert_raise ArgumentError, ~r/invalid PostgreSQL prefix/, fn ->
      Migration.render_sql(prefix: "", from: 0, to: 1)
    end
  end

  defp position(string, needle) do
    {index, _length} = :binary.match(string, needle)
    index
  end
end
