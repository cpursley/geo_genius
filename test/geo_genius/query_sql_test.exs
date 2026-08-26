defmodule GeoGenius.QuerySqlTest do
  # Creates and drops a schema named after a reserved word, so it must not run
  # alongside another test doing the same.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias GeoGenius.{Query, TestRepo}

  # `Config.validate_prefix!/1` accepts any lowercase identifier GeoGenius is
  # allowed to own, reserved words included, so a host can install at
  # `prefix: "user"` and get a working struct API. These fragments are the one
  # place the prefix reaches SQL as Elixir-built text rather than through the
  # migration's escaped identifier, and an unquoted reserved word there is a
  # syntax error the host meets only on its first `GeoGenius.Query` call.
  defp sql(query) do
    {statement, _params} = SQL.to_sql(:all, TestRepo, query)
    statement
  end

  test "children_of names its function through a quoted prefix" do
    assert sql(Query.children_of("demo:city:a", [])) =~ ~s("geo_genius".children_of()
  end

  test "ancestors_of names its function through a quoted prefix" do
    assert sql(Query.ancestors_of("demo:city:a", [])) =~ ~s("geo_genius".ancestors_of()
  end

  test "areas_by_code names its function through a quoted prefix" do
    assert sql(Query.areas_by_code("fips", "42", [])) =~ ~s("geo_genius".areas_by_code()
  end

  test "search_areas names its function through a quoted prefix" do
    assert sql(Query.search_areas("charlie", [])) =~ ~s("geo_genius".search_areas()
  end

  test "a reserved word is a callable schema qualifier only once it is quoted" do
    TestRepo.query!(~s(DROP SCHEMA IF EXISTS "order" CASCADE))
    on_exit(fn -> TestRepo.query!(~s(DROP SCHEMA IF EXISTS "order" CASCADE)) end)

    TestRepo.query!(~s(CREATE SCHEMA "order"))

    TestRepo.query!(
      "CREATE FUNCTION \"order\".probe() RETURNS integer LANGUAGE sql AS $probe$SELECT 1$probe$"
    )

    assert %{rows: [[1]]} = TestRepo.query!("SELECT * FROM \"order\".probe()")

    assert {:error, %Postgrex.Error{postgres: %{code: :syntax_error}}} =
             TestRepo.query("SELECT * FROM order.probe()")
  end
end
