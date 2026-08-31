defmodule Mix.Tasks.GeoGenius.MigrationSqlTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.GeoGenius.MigrationSql

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn -> Mix.shell(shell) end)
    :ok
  end

  test "writes only the requested migration SQL to stdout" do
    Mix.Task.reenable("geo_genius.migration_sql")
    MigrationSql.run(["--prefix", "geo_genius", "--from", "0", "--to", "1"])

    assert_received {:mix_shell, :info, [sql]}
    assert sql =~ "CREATE SCHEMA IF NOT EXISTS geo_genius"
    assert sql =~ "COMMENT ON VIEW geo_genius.geo_genius_version IS 'GeoGenius version=1'"
    refute sql =~ "Generated"
  end

  test "requires a prefix" do
    assert_raise Mix.Error, ~r/--prefix is required/, fn ->
      MigrationSql.run(["--from", "0", "--to", "1"])
    end
  end

  test "rejects unknown switches" do
    assert_raise Mix.Error, ~r/unknown option: --unknown/, fn ->
      MigrationSql.run(["--prefix", "geo_genius", "--from", "0", "--to", "1", "--unknown"])
    end
  end

  test "rejects positional arguments" do
    assert_raise Mix.Error, ~r/unexpected positional argument: extra/, fn ->
      MigrationSql.run(["--prefix", "geo_genius", "--from", "0", "--to", "1", "extra"])
    end
  end
end
