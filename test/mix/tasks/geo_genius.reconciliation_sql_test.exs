defmodule Mix.Tasks.GeoGenius.ReconciliationSqlTest do
  use ExUnit.Case, async: false

  alias GeoGenius.Migration
  alias Mix.Tasks.GeoGenius.ReconciliationSql

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn -> Mix.shell(shell) end)
    :ok
  end

  test "writes only a literal pinned reconciliation edge to stdout" do
    Mix.Task.reenable("geo_genius.reconciliation_sql")

    ReconciliationSql.run([
      "--prefix",
      "geo-genius",
      "--from",
      "legacy_v01_aebc28a",
      "--to",
      Migration.current_contract_revision()
    ])

    assert_received {:mix_shell, :info, [sql]}
    assert String.starts_with?(sql, "BEGIN;")
    assert sql =~ ~s("geo-genius".put_boundaries)
    assert sql =~ Migration.current_contract_revision()
    refute sql =~ "Generated"
  end

  test "requires every identity instead of assuming a moving current target" do
    assert_raise Mix.Error, ~r/--to is required/, fn ->
      ReconciliationSql.run([
        "--prefix",
        "geo_genius",
        "--from",
        "legacy_v01_aebc28a"
      ])
    end
  end

  test "rejects unknown switches" do
    assert_raise Mix.Error, ~r/unknown option: --unknown/, fn ->
      ReconciliationSql.run([
        "--prefix",
        "geo_genius",
        "--from",
        "legacy_v01_aebc28a",
        "--to",
        Migration.current_contract_revision(),
        "--unknown"
      ])
    end
  end
end
