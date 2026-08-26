defmodule GeoGenius.Stores.PostgresOptionsTest do
  use ExUnit.Case, async: false

  @moduledoc """
  One discriminating assertion per option binding on every store read.

  `call/4` builds each read's parameter list positionally, so a binding that is
  dropped, hardcoded, or exchanged with its neighbour still produces a valid
  statement. `:types` and `:classifications` are the sharp pair: both are
  `text[]`, they sit side by side on the traversal reads, and Postgres accepts
  either order. Every assertion here is chosen so that value belongs in exactly
  one slot -- an area type is never a relation type, and a relation type is
  never an area type -- which is what makes an exchange fail rather than pass
  quietly.
  """

  @moduletag :integration

  import GeoGenius.GraphFixture, only: [keys: 1, retire!: 1]

  alias GeoGenius.{Context, GraphFixture, Stores.Postgres, TestRepo}

  setup do
    GraphFixture.build_and_publish!()
    on_exit(&GraphFixture.teardown!/0)
    {:ok, context: Context.new(repo: TestRepo, prefix: "geo_genius")}
  end

  describe "children_of" do
    test ":types keeps the child of that area type and drops the others", %{context: context} do
      assert keys(Postgres.children_of(context, "demo_auth:outer:A", types: ["inner"])) ==
               ["demo_auth:inner:B"]

      assert keys(Postgres.children_of(context, "demo_auth:outer:A", types: ["district"])) ==
               ["demo_auth:district:D"]
    end

    test ":classifications keeps the edge of that relation type", %{context: context} do
      assert keys(
               Postgres.children_of(context, "demo_auth:outer:A", classifications: ["contains"])
             ) == ["demo_auth:inner:B"]

      assert keys(
               Postgres.children_of(context, "demo_auth:outer:A", classifications: ["overlaps"])
             ) == ["demo_auth:district:D"]
    end

    test ":max_depth decides whether the grandchild is reached", %{context: context} do
      assert keys(Postgres.children_of(context, "demo_auth:outer:A", [])) ==
               ["demo_auth:district:D", "demo_auth:inner:B"]

      assert keys(Postgres.children_of(context, "demo_auth:outer:A", max_depth: 2)) ==
               ["demo_auth:city:C", "demo_auth:district:D", "demo_auth:inner:B"]
    end

    test ":include_retired decides whether a retired child is returned", %{context: context} do
      retire!("demo_auth:inner:B")

      assert keys(Postgres.children_of(context, "demo_auth:outer:A", [])) ==
               ["demo_auth:district:D"]

      assert keys(Postgres.children_of(context, "demo_auth:outer:A", include_retired: true)) ==
               ["demo_auth:district:D", "demo_auth:inner:B"]
    end

    test ":release_id pins the read to that release", %{context: context} do
      assert [] ==
               Postgres.children_of(context, "demo_auth:outer:A",
                 release_id: Ecto.UUID.generate()
               )
    end
  end

  describe "ancestors_of" do
    test ":types keeps the ancestor of that area type", %{context: context} do
      assert keys(Postgres.ancestors_of(context, "demo_auth:inner:B", types: ["outer"])) ==
               ["demo_auth:outer:A"]

      assert [] == Postgres.ancestors_of(context, "demo_auth:inner:B", types: ["city"])
    end

    test ":classifications keeps the edge of that relation type", %{context: context} do
      assert keys(
               Postgres.ancestors_of(context, "demo_auth:inner:B", classifications: ["contains"])
             ) == ["demo_auth:outer:A"]

      assert [] ==
               Postgres.ancestors_of(context, "demo_auth:inner:B", classifications: ["overlaps"])
    end

    test ":max_depth decides whether the grandparent is reached", %{context: context} do
      assert keys(Postgres.ancestors_of(context, "demo_auth:city:C", [])) == ["demo_auth:inner:B"]

      assert keys(Postgres.ancestors_of(context, "demo_auth:city:C", max_depth: 2)) ==
               ["demo_auth:inner:B", "demo_auth:outer:A"]
    end

    test ":include_retired decides whether a retired ancestor is returned", %{context: context} do
      retire!("demo_auth:outer:A")

      assert [] == Postgres.ancestors_of(context, "demo_auth:inner:B", [])

      assert keys(Postgres.ancestors_of(context, "demo_auth:inner:B", include_retired: true)) ==
               ["demo_auth:outer:A"]
    end

    test ":release_id pins the read to that release", %{context: context} do
      assert [] ==
               Postgres.ancestors_of(context, "demo_auth:inner:B",
                 release_id: Ecto.UUID.generate()
               )
    end
  end

  describe "related_areas" do
    test ":classifications keeps the edge of that relation type", %{context: context} do
      assert keys(
               Postgres.related_areas(context, "demo_auth:outer:A", classifications: ["overlaps"])
             ) == ["demo_auth:district:D"]

      assert keys(
               Postgres.related_areas(context, "demo_auth:outer:A", classifications: ["contains"])
             ) == ["demo_auth:inner:B"]
    end

    test ":include_retired decides whether a retired relation target is returned", %{
      context: context
    } do
      retire!("demo_auth:district:D")

      assert [] ==
               Postgres.related_areas(context, "demo_auth:outer:A", classifications: ["overlaps"])

      assert keys(
               Postgres.related_areas(context, "demo_auth:outer:A",
                 classifications: ["overlaps"],
                 include_retired: true
               )
             ) == ["demo_auth:district:D"]
    end

    test ":release_id pins the read to that release", %{context: context} do
      assert [] ==
               Postgres.related_areas(context, "demo_auth:outer:A",
                 release_id: Ecto.UUID.generate()
               )
    end
  end

  describe "areas_by_code" do
    test ":collections restricts to the named collection", %{context: context} do
      assert keys(Postgres.areas_by_code(context, "slug", "shared", collections: ["demo"])) ==
               ["demo_auth:city:E", "demo_auth:inner:B"]

      assert [] == Postgres.areas_by_code(context, "slug", "shared", collections: ["absent"])
    end

    test ":types restricts to the named area type", %{context: context} do
      assert keys(Postgres.areas_by_code(context, "slug", "shared", types: ["inner"])) ==
               ["demo_auth:inner:B"]

      assert keys(Postgres.areas_by_code(context, "slug", "shared", types: ["city"])) ==
               ["demo_auth:city:E"]
    end

    test ":parent_max_depth decides how far the parent scope reaches", %{context: context} do
      assert [] ==
               Postgres.areas_by_code(context, "slug", "deep",
                 parent_area_key: "demo_auth:outer:A"
               )

      assert keys(
               Postgres.areas_by_code(context, "slug", "deep",
                 parent_area_key: "demo_auth:outer:A",
                 parent_max_depth: 2
               )
             ) == ["demo_auth:city:C"]
    end

    test ":include_retired decides whether a retired area carrying the code is returned", %{
      context: context
    } do
      retire!("demo_auth:inner:B")

      assert keys(Postgres.areas_by_code(context, "slug", "shared", [])) ==
               ["demo_auth:city:E"]

      assert keys(Postgres.areas_by_code(context, "slug", "shared", include_retired: true)) ==
               ["demo_auth:city:E", "demo_auth:inner:B"]
    end

    test ":release_id pins the read to that release", %{context: context} do
      assert [] ==
               Postgres.areas_by_code(context, "slug", "shared", release_id: Ecto.UUID.generate())
    end
  end

  describe "search_areas" do
    test ":collections restricts to the named collection", %{context: context} do
      assert keys(Postgres.search_areas(context, "Alpha", collections: ["demo"])) ==
               ["demo_auth:outer:A"]

      assert [] == Postgres.search_areas(context, "Alpha", collections: ["absent"])
    end

    test ":types restricts to the named area type", %{context: context} do
      assert keys(Postgres.search_areas(context, "Alpha", types: ["outer"])) ==
               ["demo_auth:outer:A"]

      assert [] == Postgres.search_areas(context, "Alpha", types: ["city"])
    end

    test ":include_retired decides whether a retired area is ranked", %{context: context} do
      retire!("demo_auth:outer:A")

      assert [] == Postgres.search_areas(context, "Alpha", [])

      assert keys(Postgres.search_areas(context, "Alpha", include_retired: true)) ==
               ["demo_auth:outer:A"]
    end

    test ":release_id pins the read to that release", %{context: context} do
      assert [] == Postgres.search_areas(context, "Alpha", release_id: Ecto.UUID.generate())
    end
  end

  describe "resolve" do
    test ":collections restricts to the named collection", %{context: context} do
      assert keys(Postgres.resolve(context, %{"name" => "Alpha"}, collections: ["demo"])) ==
               ["demo_auth:outer:A"]

      assert [] == Postgres.resolve(context, %{"name" => "Alpha"}, collections: ["absent"])
    end

    test ":types restricts to the named area type", %{context: context} do
      assert keys(Postgres.resolve(context, %{"name" => "Alpha"}, types: ["outer"])) ==
               ["demo_auth:outer:A"]

      assert [] == Postgres.resolve(context, %{"name" => "Alpha"}, types: ["city"])
    end

    test ":include_retired decides whether a retired area resolves", %{context: context} do
      retire!("demo_auth:outer:A")

      assert [] == Postgres.resolve(context, %{"name" => "Alpha"}, [])

      assert keys(Postgres.resolve(context, %{"name" => "Alpha"}, include_retired: true)) ==
               ["demo_auth:outer:A"]
    end

    test ":release_id pins the read to that release", %{context: context} do
      assert [] ==
               Postgres.resolve(context, %{"name" => "Alpha"}, release_id: Ecto.UUID.generate())
    end

    test "a parent-scoped code input narrows the cascade's code strategy", %{context: context} do
      # B and E both carry slug/shared, and only B descends from A.
      assert keys(
               Postgres.resolve(
                 context,
                 %{
                   "code_type" => "slug",
                   "code_value" => "shared",
                   "parent_area_key" => "demo_auth:outer:A"
                 },
                 []
               )
             ) == ["demo_auth:inner:B"]

      assert keys(
               Postgres.resolve(
                 context,
                 %{"code_type" => "slug", "code_value" => "shared"},
                 []
               )
             ) == ["demo_auth:city:E", "demo_auth:inner:B"]
    end
  end

  describe "areas_for_geometry" do
    @polygon %Geo.Polygon{
      coordinates: [[{0.0, 0.0}, {0.3, 0.0}, {0.3, 0.3}, {0.0, 0.3}, {0.0, 0.0}]],
      srid: 4326
    }

    test ":collections restricts to the named collection", %{context: context} do
      assert keys(Postgres.areas_for_geometry(context, @polygon, collections: ["demo"])) ==
               ["demo_auth:inner:B", "demo_auth:outer:A"]

      assert [] == Postgres.areas_for_geometry(context, @polygon, collections: ["absent"])
    end

    test ":types restricts to the named area type", %{context: context} do
      assert keys(Postgres.areas_for_geometry(context, @polygon, types: ["outer"])) ==
               ["demo_auth:outer:A"]
    end

    test ":include_retired decides whether a retired area overlaps", %{context: context} do
      retire!("demo_auth:inner:B")

      assert keys(Postgres.areas_for_geometry(context, @polygon, [])) == ["demo_auth:outer:A"]

      assert keys(Postgres.areas_for_geometry(context, @polygon, include_retired: true)) ==
               ["demo_auth:inner:B", "demo_auth:outer:A"]
    end

    test ":release_id pins the read to that release", %{context: context} do
      assert [] ==
               Postgres.areas_for_geometry(context, @polygon, release_id: Ecto.UUID.generate())
    end
  end

  describe "areas_near" do
    test ":collections restricts to the named collection", %{context: context} do
      assert "demo_auth:outer:A" in keys(
               Postgres.areas_near(context, 0.25, 0.25, 200_000.0, collections: ["demo"])
             )

      assert [] == Postgres.areas_near(context, 0.25, 0.25, 200_000.0, collections: ["absent"])
    end

    test ":types restricts to the named area type", %{context: context} do
      assert keys(Postgres.areas_near(context, 0.25, 0.25, 200_000.0, types: ["district"])) ==
               ["demo_auth:district:D"]
    end

    test ":include_retired decides whether a retired area is measured", %{context: context} do
      retire!("demo_auth:district:D")

      assert [] == Postgres.areas_near(context, 0.25, 0.25, 200_000.0, types: ["district"])

      assert keys(
               Postgres.areas_near(context, 0.25, 0.25, 200_000.0,
                 types: ["district"],
                 include_retired: true
               )
             ) == ["demo_auth:district:D"]
    end

    test ":release_id pins the read to that release", %{context: context} do
      assert [] ==
               Postgres.areas_near(context, 0.25, 0.25, 200_000.0,
                 release_id: Ecto.UUID.generate()
               )
    end
  end

  describe "areas_for_point" do
    test ":types restricts to the named area type", %{context: context} do
      assert keys(Postgres.areas_for_point(context, 0.25, 0.25, types: ["inner"])) ==
               ["demo_auth:inner:B"]
    end

    test ":collections restricts to the named collection", %{context: context} do
      assert keys(Postgres.areas_for_point(context, 0.25, 0.25, collections: ["demo"])) ==
               ["demo_auth:inner:B", "demo_auth:outer:A"]

      assert [] == Postgres.areas_for_point(context, 0.25, 0.25, collections: ["absent"])
    end
  end
end
