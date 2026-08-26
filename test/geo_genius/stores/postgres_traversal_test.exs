defmodule GeoGenius.Stores.PostgresTraversalTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias GeoGenius.{Context, Stores.Postgres, TestRepo}

  setup do
    TestRepo.query!("SELECT geo_genius_test.demo_fixture_build()", [])

    TestRepo.query!(
      "SELECT geo_genius.rebuild_relations((SELECT id FROM geo_genius.release WHERE release_key = 'r1'))",
      []
    )

    TestRepo.query!("SELECT geo_genius_test.demo_publish()", [])
    on_exit(fn -> TestRepo.query!("SELECT geo_genius_test.demo_teardown()", []) end)
    {:ok, context: Context.new(repo: TestRepo, prefix: "geo_genius")}
  end

  test "children_of walks down", %{context: context} do
    assert [child] = Postgres.children_of(context, "demo_auth:outer:A", [])
    assert child.area_key == "demo_auth:inner:B"
    assert child.match_method == "relation"
  end

  test "ancestors_of walks up", %{context: context} do
    assert [parent] = Postgres.ancestors_of(context, "demo_auth:inner:B", [])
    assert parent.area_key == "demo_auth:outer:A"
  end

  test "related_areas reaches both directions", %{context: context} do
    assert [related] = Postgres.related_areas(context, "demo_auth:inner:B", [])
    assert related.area_key == "demo_auth:outer:A"
  end

  test "traversal leaves measurement fields empty", %{context: context} do
    assert [child] = Postgres.children_of(context, "demo_auth:outer:A", [])
    assert child.distance_m == nil
    assert child.coverage_of_area == nil
    assert child.score == nil
  end

  test "release_at resolves the currently published release", %{context: context} do
    published =
      TestRepo.query!(
        "SELECT release_id::text FROM geo_genius.publication p " <>
          "JOIN geo_genius.collection c ON c.id = p.collection_id WHERE c.key = 'demo'",
        []
      ).rows
      |> List.flatten()
      |> List.first()

    assert Postgres.release_at(context, DateTime.utc_now(), collection: "demo") == published
  end

  test "release_at returns nil before the collection published anything", %{context: context} do
    past = DateTime.add(DateTime.utc_now(), -86_400, :second)
    assert Postgres.release_at(context, past, collection: "demo") == nil
  end

  # A collection key the catalog does not carry is the same answer as a
  # collection that has published nothing: there is no release to pin. A host
  # taking the key from configuration or a URL segment gets nil rather than an
  # exception from the documented `if release_id = ...` shape.
  test "release_at returns nil for a collection key the catalog does not carry", %{
    context: context
  } do
    assert Postgres.release_at(context, DateTime.utc_now(), collection: "no_such_collection") ==
             nil
  end

  test "release_at without :collection raises ArgumentError carrying the remedy", %{
    context: context
  } do
    error =
      assert_raise ArgumentError, fn -> Postgres.release_at(context, DateTime.utc_now(), []) end

    assert error.message =~ ":collection"
    assert error.message =~ "release_at"
  end
end
