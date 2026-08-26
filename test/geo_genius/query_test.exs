defmodule GeoGenius.QueryTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  import Ecto.Query
  import GeoGenius.GraphFixture, only: [retire!: 1]

  alias GeoGenius.{GraphFixture, Query, TestRepo}

  # The documented result shape, which `guides/reading.md` presents as this
  # module's contract. Pinned as a sorted key list so a select that drops a
  # column, or grows one, fails rather than passing on the columns that
  # happen to be asserted elsewhere.
  @shape [:area_key, :area_type, :attributes, :centroid, :name]
  @search_shape Enum.sort([:score | @shape])

  # `build!/0` builds but does not publish, so a test that needs
  # release-scoped writes of its own can add them before the release becomes
  # immutable. Every test calls `publish!/0` once it is done with any such
  # writes.
  setup do
    GraphFixture.build!()
    on_exit(&GraphFixture.teardown!/0)
    :ok
  end

  defp publish!, do: TestRepo.query!("SELECT geo_genius_test.demo_publish()", [])

  defp keys(rows), do: rows |> Enum.map(& &1.area_key) |> Enum.sort()

  describe "the documented result shape" do
    test "children_of selects exactly the documented columns, each from its own field" do
      publish!()

      assert [row] = TestRepo.all(Query.children_of("demo_auth:inner:B", []))

      assert %{
               area_key: "demo_auth:city:C",
               area_type: "city",
               name: "Charlie",
               centroid: %Geo.Point{srid: 4326},
               attributes: %{}
             } = row

      assert row |> Map.keys() |> Enum.sort() == @shape
    end

    test "ancestors_of selects exactly the documented columns, each from its own field" do
      publish!()

      assert [row] = TestRepo.all(Query.ancestors_of("demo_auth:city:C", []))

      assert %{
               area_key: "demo_auth:inner:B",
               area_type: "inner",
               name: "Bravo",
               centroid: %Geo.Point{srid: 4326},
               attributes: %{}
             } = row

      assert row |> Map.keys() |> Enum.sort() == @shape
    end

    test "areas_by_code selects exactly the documented columns, each from its own field" do
      publish!()

      assert [row] = TestRepo.all(Query.areas_by_code("slug", "deep", []))

      assert %{
               area_key: "demo_auth:city:C",
               area_type: "city",
               name: "Charlie",
               centroid: %Geo.Point{srid: 4326},
               attributes: %{}
             } = row

      assert row |> Map.keys() |> Enum.sort() == @shape
    end

    test "search_areas selects exactly the documented columns plus score" do
      publish!()

      assert [row] = TestRepo.all(Query.search_areas("Charlie", []))

      assert %{
               area_key: "demo_auth:city:C",
               area_type: "city",
               name: "Charlie",
               centroid: %Geo.Point{srid: 4326},
               attributes: %{}
             } = row

      assert is_float(row.score)
      assert row |> Map.keys() |> Enum.sort() == @search_shape
    end
  end

  describe "children_of" do
    test "runs as an Ecto query" do
      publish!()

      assert keys(TestRepo.all(Query.children_of("demo_auth:outer:A", []))) ==
               ["demo_auth:district:D", "demo_auth:inner:B"]
    end

    test "binds :types, filtering out a real child of a different type" do
      publish!()

      assert [] == TestRepo.all(Query.children_of("demo_auth:outer:A", types: ["outer"]))

      assert keys(TestRepo.all(Query.children_of("demo_auth:outer:A", types: ["inner"]))) ==
               ["demo_auth:inner:B"]

      assert keys(TestRepo.all(Query.children_of("demo_auth:outer:A", types: ["district"]))) ==
               ["demo_auth:district:D"]
    end

    # `types` and `classifications` are adjacent `text[]` arguments, so an
    # exchange is silent in SQL. A relation type is never an area type, so a
    # classification asked for here comes back empty if it lands in `types`.
    test "binds :classifications, keeping the edge of that relation type" do
      publish!()

      assert keys(
               TestRepo.all(Query.children_of("demo_auth:outer:A", classifications: ["contains"]))
             ) == ["demo_auth:inner:B"]

      assert keys(
               TestRepo.all(Query.children_of("demo_auth:outer:A", classifications: ["overlaps"]))
             ) == ["demo_auth:district:D"]
    end

    test "binds :max_depth, deciding whether the grandchild is reached" do
      publish!()

      refute "demo_auth:city:C" in keys(TestRepo.all(Query.children_of("demo_auth:outer:A", [])))

      assert "demo_auth:city:C" in keys(
               TestRepo.all(Query.children_of("demo_auth:outer:A", max_depth: 2))
             )
    end

    test "binds :include_retired" do
      publish!()
      retire!("demo_auth:inner:B")

      assert keys(TestRepo.all(Query.children_of("demo_auth:outer:A", []))) ==
               ["demo_auth:district:D"]

      assert keys(TestRepo.all(Query.children_of("demo_auth:outer:A", include_retired: true))) ==
               ["demo_auth:district:D", "demo_auth:inner:B"]
    end

    test "binds :release_id given as the hyphenated string every read returns" do
      publish!()

      release_id =
        TestRepo.query!("SELECT id::text FROM geo_genius.release WHERE release_key = 'r1'", []).rows
        |> List.flatten()
        |> List.first()

      assert keys(TestRepo.all(Query.children_of("demo_auth:outer:A", release_id: release_id))) ==
               ["demo_auth:district:D", "demo_auth:inner:B"]

      assert [] ==
               TestRepo.all(
                 Query.children_of("demo_auth:outer:A", release_id: Ecto.UUID.generate())
               )
    end
  end

  describe "ancestors_of" do
    test "runs as an Ecto query and binds :types" do
      publish!()

      assert keys(TestRepo.all(Query.ancestors_of("demo_auth:inner:B", []))) ==
               ["demo_auth:outer:A"]

      assert [] == TestRepo.all(Query.ancestors_of("demo_auth:inner:B", types: ["inner"]))

      assert keys(TestRepo.all(Query.ancestors_of("demo_auth:inner:B", types: ["outer"]))) ==
               ["demo_auth:outer:A"]
    end

    test "binds :classifications, keeping the edge of that relation type" do
      publish!()

      assert keys(
               TestRepo.all(
                 Query.ancestors_of("demo_auth:inner:B", classifications: ["contains"])
               )
             ) == ["demo_auth:outer:A"]

      assert [] ==
               TestRepo.all(
                 Query.ancestors_of("demo_auth:inner:B", classifications: ["overlaps"])
               )
    end

    test "binds :max_depth, deciding whether the grandparent is reached" do
      publish!()

      assert keys(TestRepo.all(Query.ancestors_of("demo_auth:city:C", []))) ==
               ["demo_auth:inner:B"]

      assert keys(TestRepo.all(Query.ancestors_of("demo_auth:city:C", max_depth: 2))) ==
               ["demo_auth:inner:B", "demo_auth:outer:A"]
    end

    test "binds :include_retired" do
      publish!()
      retire!("demo_auth:outer:A")

      assert [] == TestRepo.all(Query.ancestors_of("demo_auth:inner:B", []))

      assert keys(TestRepo.all(Query.ancestors_of("demo_auth:inner:B", include_retired: true))) ==
               ["demo_auth:outer:A"]
    end

    test "binds :release_id" do
      publish!()

      assert [] ==
               TestRepo.all(
                 Query.ancestors_of("demo_auth:inner:B", release_id: Ecto.UUID.generate())
               )
    end
  end

  describe "areas_by_code" do
    test "composes with a parent scope, and excludes a match outside it" do
      publish!()

      assert keys(TestRepo.all(Query.areas_by_code("slug", "shared", []))) ==
               ["demo_auth:city:E", "demo_auth:inner:B"]

      assert keys(
               TestRepo.all(
                 Query.areas_by_code("slug", "shared", parent_area_key: "demo_auth:outer:A")
               )
             ) == ["demo_auth:inner:B"]

      assert [] ==
               TestRepo.all(
                 Query.areas_by_code("slug", "shared", parent_area_key: "demo_auth:city:E")
               )
    end

    test "binds :parent_max_depth, deciding how far the parent scope reaches" do
      publish!()

      assert [] ==
               TestRepo.all(
                 Query.areas_by_code("slug", "deep", parent_area_key: "demo_auth:outer:A")
               )

      assert keys(
               TestRepo.all(
                 Query.areas_by_code("slug", "deep",
                   parent_area_key: "demo_auth:outer:A",
                   parent_max_depth: 2
                 )
               )
             ) == ["demo_auth:city:C"]
    end

    test "binds :collections" do
      publish!()

      assert keys(TestRepo.all(Query.areas_by_code("slug", "shared", collections: ["demo"]))) ==
               ["demo_auth:city:E", "demo_auth:inner:B"]

      assert [] == TestRepo.all(Query.areas_by_code("slug", "shared", collections: ["absent"]))
    end

    test "binds :types" do
      publish!()

      assert keys(TestRepo.all(Query.areas_by_code("slug", "shared", types: ["inner"]))) ==
               ["demo_auth:inner:B"]

      assert keys(TestRepo.all(Query.areas_by_code("slug", "shared", types: ["city"]))) ==
               ["demo_auth:city:E"]
    end

    test "binds :include_retired and :release_id" do
      publish!()
      retire!("demo_auth:inner:B")

      assert keys(TestRepo.all(Query.areas_by_code("slug", "shared", []))) ==
               ["demo_auth:city:E"]

      assert keys(TestRepo.all(Query.areas_by_code("slug", "shared", include_retired: true))) ==
               ["demo_auth:city:E", "demo_auth:inner:B"]

      assert [] ==
               TestRepo.all(
                 Query.areas_by_code("slug", "shared", release_id: Ecto.UUID.generate())
               )
    end
  end

  describe "search_areas" do
    # A and B each get an alias with the same name, so both are an exact match
    # for the search query and score-tie at the top of the ranking. That makes
    # :limit's effect on row count deterministic instead of depending on
    # trigram scoring, and pins the argument at position 4 -- if it landed
    # somewhere else, either every row would still come back or Postgrex would
    # reject the bind outright, not silently keep working.
    test "binds :limit, and returns score as a float" do
      TestRepo.query!("SELECT geo_genius.put_area_name($1, $2, $3, $4)", [
        "demo_auth:outer:A",
        "Zephyr",
        "alias",
        nil
      ])

      TestRepo.query!("SELECT geo_genius.put_area_name($1, $2, $3, $4)", [
        "demo_auth:inner:B",
        "Zephyr",
        "alias",
        nil
      ])

      publish!()

      assert [
               %{area_key: "demo_auth:inner:B", score: score_b},
               %{area_key: "demo_auth:outer:A", score: score_a}
             ] = TestRepo.all(Query.search_areas("Zephyr", []))

      assert is_float(score_b)
      assert is_float(score_a)

      assert [%{area_key: "demo_auth:inner:B"}] =
               TestRepo.all(Query.search_areas("Zephyr", limit: 1))
    end

    test "binds :collections" do
      publish!()

      assert keys(TestRepo.all(Query.search_areas("Charlie", collections: ["demo"]))) ==
               ["demo_auth:city:C"]

      assert [] == TestRepo.all(Query.search_areas("Charlie", collections: ["absent"]))
    end

    test "binds :types" do
      publish!()

      assert keys(TestRepo.all(Query.search_areas("Charlie", types: ["city"]))) ==
               ["demo_auth:city:C"]

      assert [] == TestRepo.all(Query.search_areas("Charlie", types: ["inner"]))
    end

    test "binds :include_retired and :release_id" do
      publish!()
      retire!("demo_auth:city:C")

      assert [] == TestRepo.all(Query.search_areas("Charlie", []))

      assert keys(TestRepo.all(Query.search_areas("Charlie", include_retired: true))) ==
               ["demo_auth:city:C"]

      assert [] == TestRepo.all(Query.search_areas("Charlie", release_id: Ecto.UUID.generate()))
    end
  end

  test "each function rejects a :prefix option instead of silently ignoring it" do
    assert_raise ArgumentError, ~r/does not support a per-call :prefix/, fn ->
      Query.children_of("demo_auth:outer:A", prefix: "other")
    end

    assert_raise ArgumentError, ~r/does not support a per-call :prefix/, fn ->
      Query.ancestors_of("demo_auth:inner:B", prefix: "other")
    end

    assert_raise ArgumentError, ~r/does not support a per-call :prefix/, fn ->
      Query.areas_by_code("slug", "shared", prefix: "other")
    end

    assert_raise ArgumentError, ~r/does not support a per-call :prefix/, fn ->
      Query.search_areas("Zephyr", prefix: "other")
    end
  end

  # The reason this module exists: areas joined to host-owned rows, aggregated,
  # in one query rather than one query per area. `demo_auth:district:D` is a
  # child of A that no host row ever references, so one legitimate row in the
  # result is a zero rather than every row being a positive match. Two decoy
  # host rows -- one pointing at the parent (not a child at all) and one
  # pointing at an area key that does not exist -- exercise rows the join must
  # correctly exclude. The join target lives in `public`, unprefixed, the way a
  # host's own table actually does; there is no `prefix:` option on the repo
  # call.
  test "composes as a subquery joined to a host table in public, aggregating a real count including a zero" do
    publish!()

    TestRepo.query!(
      "CREATE TABLE public.query_test_listings (id serial primary key, area_key text not null)",
      []
    )

    on_exit(fn -> TestRepo.query!("DROP TABLE IF EXISTS public.query_test_listings", []) end)

    TestRepo.query!(
      "INSERT INTO public.query_test_listings (area_key) VALUES ($1), ($1)",
      ["demo_auth:inner:B"]
    )

    # Decoys: a host row on the parent (never a child, so never joined) and a
    # host row on an area key the catalog has never heard of.
    TestRepo.query!(
      "INSERT INTO public.query_test_listings (area_key) VALUES ($1)",
      ["demo_auth:outer:A"]
    )

    TestRepo.query!(
      "INSERT INTO public.query_test_listings (area_key) VALUES ($1)",
      ["nonexistent:area:key"]
    )

    counts =
      from(area in subquery(Query.children_of("demo_auth:outer:A", [])),
        left_join: listing in "query_test_listings",
        on: listing.area_key == area.area_key,
        group_by: area.area_key,
        order_by: area.area_key,
        select: {area.area_key, count(listing.id)}
      )

    assert [{"demo_auth:district:D", 0}, {"demo_auth:inner:B", 2}] = TestRepo.all(counts)
  end
end
