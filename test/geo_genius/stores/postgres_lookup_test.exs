defmodule GeoGenius.Stores.PostgresLookupTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias GeoGenius.{Context, Stores.Postgres, TestRepo}

  setup do
    TestRepo.query!("SELECT geo_genius_test.demo_fixture_build()", [])

    TestRepo.query!("SELECT geo_genius.put_area_code($1, $2, $3)", [
      "demo_auth:outer:A",
      "slug",
      "alpha"
    ])

    TestRepo.query!("SELECT geo_genius.put_area_code($1, $2, $3)", [
      "demo_auth:inner:B",
      "slug",
      "alpha"
    ])

    # A third, metadata-only area (no boundary, so it never enters the
    # spatial tests) whose name also starts with "a" -- the only way to give
    # search_areas' :limit option something to discriminate. Query "a"
    # matches both Alpha and Acme via the ILIKE 'a%' branch, so an unlimited
    # search and a limit of 1 return different counts.
    TestRepo.query!("SELECT geo_genius.upsert_area($1, $2, $3, $4)", [
      "demo",
      "demo_auth",
      "outer",
      "C"
    ])

    TestRepo.query!("SELECT geo_genius.put_area_name($1, $2, $3, $4)", [
      "demo_auth:outer:C",
      "Acme",
      "official",
      nil
    ])

    TestRepo.query!(
      "SELECT geo_genius.put_area_in_release((SELECT id FROM geo_genius.release WHERE release_key = 'r1'), $1, ST_GeogFromText('POINT(50 50)'), '{}'::jsonb)",
      ["demo_auth:outer:C"]
    )

    # Parent scoping walks relations, and the fixture attaches boundaries
    # without measuring them. B sits inside A, so one rebuild gives the
    # containment relation the scoped lookup traverses.
    TestRepo.query!(
      "SELECT geo_genius.rebuild_relations((SELECT id FROM geo_genius.release WHERE release_key = 'r1'))",
      []
    )

    TestRepo.query!("SELECT geo_genius_test.demo_publish()", [])
    on_exit(fn -> TestRepo.query!("SELECT geo_genius_test.demo_teardown()", []) end)
    {:ok, context: Context.new(repo: TestRepo, prefix: "geo_genius")}
  end

  test "a shared code returns every area carrying it", %{context: context} do
    matches = Postgres.areas_by_code(context, "slug", "alpha", [])

    assert length(matches) == 2
    assert Enum.all?(matches, &(&1.match_method == "code"))
  end

  test "scoping to a parent narrows a shared code to one area", %{context: context} do
    assert [match] =
             Postgres.areas_by_code(context, "slug", "alpha",
               parent_area_key: "demo_auth:outer:A"
             )

    assert match.area_key == "demo_auth:inner:B"
  end

  test "search_areas scores matches", %{context: context} do
    assert [match | _] = Postgres.search_areas(context, "Alpha", [])
    assert match.match_method == "name"
    assert is_float(match.score)
  end

  test "search_areas respects the limit", %{context: context} do
    assert [_one] = Postgres.search_areas(context, "a", limit: 1)
  end

  test "resolve runs the cascade and reports the winning strategy", %{context: context} do
    # The default cascade order is containment, code, name, proximity, and
    # this input carries both a code and a name -- so left unconstrained,
    # "code" wins first and returns both areas sharing "slug"/"alpha".
    # Constraining to ["name"] skips straight to the name strategy, which
    # "a" only matches on Alpha, proving :strategies actually reached the
    # SQL call rather than being silently dropped.
    input = %{"name" => "Alpha", "code_type" => "slug", "code_value" => "alpha"}

    assert [match] = Postgres.resolve(context, input, strategies: ["name"])
    assert match.match_method == "name"
    assert match.area_key == "demo_auth:outer:A"
  end

  test "resolve accepts a coordinate input", %{context: context} do
    matches = Postgres.resolve(context, %{"lon" => 0.25, "lat" => 0.25}, [])
    assert Enum.all?(matches, &(&1.match_method == "containment"))
  end
end
