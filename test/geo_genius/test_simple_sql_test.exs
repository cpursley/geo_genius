defmodule GeoGenius.TestSimpleSQLTest do
  use ExUnit.Case, async: false

  alias GeoGenius.{TestRepo, TestSimpleSQL}

  test "executes multiple statements through PostgreSQL's simple query protocol" do
    assert [first, second] = TestSimpleSQL.query!(TestRepo, "SELECT 1; SELECT 2;")
    assert first.rows == [["1"]]
    assert second.rows == [["2"]]
  end
end
