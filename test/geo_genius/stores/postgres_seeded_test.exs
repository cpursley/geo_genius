defmodule GeoGenius.Stores.PostgresSeededTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias GeoGenius.{AreaMatch, Context, QueryError, SeededMatch, Stores.Postgres, TestRepo}

  setup do
    TestRepo.query!("SELECT geo_genius_test.demo_fixture_build()", [])

    # A second parent/child pair, asserted rather than measured, plus one
    # childless area: a plural read has to keep three seeds apart, and a seed
    # that matches nothing is what separates dropping it from padding it.
    for statement <- [
          "SELECT geo_genius.upsert_area('demo', 'demo_auth', 'outer', 'P')",
          "SELECT geo_genius.upsert_area('demo', 'demo_auth', 'inner', 'Q')",
          "SELECT geo_genius.upsert_area('demo', 'demo_auth', 'outer', 'Z')",
          run_write("put_area_in_release($1, $2, 'demo_auth:outer:P', NULL, '{}'::jsonb)"),
          run_write("put_area_in_release($1, $2, 'demo_auth:inner:Q', NULL, '{}'::jsonb)"),
          run_write("put_area_in_release($1, $2, 'demo_auth:outer:Z', NULL, '{}'::jsonb)"),
          run_write("put_area_name($1, $2, 'demo_auth:outer:P', 'Papa', 'official', NULL)"),
          run_write("put_area_name($1, $2, 'demo_auth:inner:Q', 'Quebec', 'official', NULL)"),
          run_write("put_area_name($1, $2, 'demo_auth:outer:Z', 'Zulu', 'official', NULL)"),
          run_write("put_area_code($1, $2, 'demo_auth:outer:A', 'fips', '01')"),
          run_write("put_area_code($1, $2, 'demo_auth:outer:P', 'fips', '02')")
        ] do
      TestRepo.query!(statement, statement_params(statement))
    end

    TestRepo.query!(
      "SELECT geo_genius.advance_import(geo_genius_test.demo_run_id(), geo_genius_test.demo_executor_id(), 'relating', '{}'::jsonb)",
      []
    )

    TestRepo.query!(
      run_write("put_relation($1, $2, 'demo_auth:outer:P', 'demo_auth:inner:Q', 'contains')"),
      [run_id(), executor_id()]
    )

    TestRepo.query!(
      "SELECT geo_genius.rebuild_relations(geo_genius_test.demo_run_id(), geo_genius_test.demo_executor_id())",
      []
    )

    TestRepo.query!("SELECT geo_genius_test.demo_publish()", [])
    on_exit(fn -> TestRepo.query!("SELECT geo_genius_test.demo_teardown()", []) end)
    {:ok, context: Context.new(repo: TestRepo, prefix: "geo_genius")}
  end

  defp run_write(call), do: "SELECT geo_genius.#{call}"

  defp statement_params(statement) do
    if String.contains?(statement, "$1"), do: [run_id(), executor_id()], else: []
  end

  defp run_id do
    %{rows: [[id]]} = TestRepo.query!("SELECT geo_genius_test.demo_run_id()", [])

    id
  end

  defp executor_id do
    %{rows: [[id]]} = TestRepo.query!("SELECT geo_genius_test.demo_executor_id()", [])

    id
  end

  test "children_of_many attributes every row to the seed that produced it", %{context: context} do
    assert [%SeededMatch{} = first, %SeededMatch{} = second] =
             Postgres.children_of_many(context, ["demo_auth:outer:A", "demo_auth:outer:P"], [])

    assert first.seed_key == "demo_auth:outer:A"
    assert %AreaMatch{area_key: "demo_auth:inner:B"} = first.match
    assert second.seed_key == "demo_auth:outer:P"
    assert %AreaMatch{area_key: "demo_auth:inner:Q"} = second.match
  end

  test "the nested match carries the same projection the singular read does", %{
    context: context
  } do
    assert [singular] = Postgres.children_of(context, "demo_auth:outer:A", [])
    assert [seeded] = Postgres.children_of_many(context, ["demo_auth:outer:A"], [])
    assert seeded.match == singular
  end

  test "a seed with no children contributes no row at all", %{context: context} do
    assert [only] =
             Postgres.children_of_many(context, ["demo_auth:outer:Z", "demo_auth:outer:A"], [])

    assert only.seed_key == "demo_auth:outer:A"
  end

  test "an empty seed list is one call returning nothing", %{context: context} do
    assert Postgres.children_of_many(context, [], []) == []
  end

  test "a nil seed list raises rather than reading the whole catalog", %{context: context} do
    assert_raise QueryError, fn -> Postgres.children_of_many(context, nil, []) end
  end

  test "ancestors_of_many attributes each ancestor to its seed", %{context: context} do
    assert [first, second] =
             Postgres.ancestors_of_many(context, ["demo_auth:inner:B", "demo_auth:inner:Q"], [])

    assert {first.seed_key, first.match.area_key} ==
             {"demo_auth:inner:B", "demo_auth:outer:A"}

    assert {second.seed_key, second.match.area_key} ==
             {"demo_auth:inner:Q", "demo_auth:outer:P"}
  end

  test "related_areas_many attributes each relation to its seed", %{context: context} do
    assert [first, second] =
             Postgres.related_areas_many(context, ["demo_auth:inner:B", "demo_auth:inner:Q"], [])

    assert {first.seed_key, first.match.area_key} ==
             {"demo_auth:inner:B", "demo_auth:outer:A"}

    assert {second.seed_key, second.match.area_key} ==
             {"demo_auth:inner:Q", "demo_auth:outer:P"}
  end

  test "areas_by_code_many seeds on the code value, not an area key", %{context: context} do
    assert [first, second] = Postgres.areas_by_code_many(context, "fips", ["01", "02"], [])

    assert {first.seed_key, first.match.area_key} == {"01", "demo_auth:outer:A"}
    assert {second.seed_key, second.match.area_key} == {"02", "demo_auth:outer:P"}
  end

  test "the public entry points reach the same rows", %{context: _context} do
    opts = [repo: TestRepo, prefix: "geo_genius"]

    assert [%SeededMatch{seed_key: "demo_auth:outer:A"}] =
             GeoGenius.children_of_many(["demo_auth:outer:A"], opts)

    assert [%SeededMatch{seed_key: "demo_auth:inner:B"}] =
             GeoGenius.ancestors_of_many(["demo_auth:inner:B"], opts)

    assert [%SeededMatch{seed_key: "demo_auth:inner:B"}] =
             GeoGenius.related_areas_many(["demo_auth:inner:B"], opts)

    assert [%SeededMatch{seed_key: "01"}] = GeoGenius.areas_by_code_many("fips", ["01"], opts)
  end
end
