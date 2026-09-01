defmodule GeoGenius.PublishedTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  import Ecto.Query
  import GeoGenius.GraphFixture, only: [retire!: 1]

  alias Ecto.Adapters.SQL
  alias GeoGenius.{Context, GraphFixture, ImportFixture, Manifest, Published, Query, TestRepo}

  # r2's membership, sorted the way `keys/1` returns a result: every demo area
  # except E, which stays r1-only so an area set alone separates the two
  # releases.
  @staged_area_keys ~w(demo_auth:city:C demo_auth:district:D demo_auth:inner:B
                       demo_auth:outer:A)

  setup do
    GraphFixture.build!()
    on_exit(&GraphFixture.teardown!/0)
    :ok
  end

  defp publish!, do: TestRepo.query!("SELECT geo_genius_test.demo_publish()", [])

  defp keys(rows), do: rows |> Enum.map(& &1.area_key) |> Enum.sort()

  defp release_id! do
    %{rows: [[id]]} =
      TestRepo.query!("SELECT id::text FROM geo_genius.release WHERE release_key = 'r1'", [])

    id
  end

  # A second release of the demo collection, deliberately left unpublished, and
  # deliberately *not* a copy of r1: it leaves E out of its membership and
  # holds one edge, A contains C, where r1 holds A contains B and A overlaps D
  # over the same areas. Every assertion below that distinguishes the two
  # releases rests on those two differences, and a read that mixed them would
  # return r1's children under r2's id. `demo_teardown/0` drops its partitions
  # along with r1's.
  defp stage_unpublished_release! do
    context = Context.new(repo: TestRepo, prefix: "geo_genius")
    {:ok, manifest} = Manifest.from_map(demo_manifest("r2"))
    candidate = ImportFixture.prepare!(context, manifest)
    executor_id = ImportFixture.claim_executor!(context, candidate.run_id)

    ImportFixture.advance_to!(context, candidate.run_id, executor_id, "normalizing")

    raw_run = Ecto.UUID.dump!(candidate.run_id)
    raw_executor = Ecto.UUID.dump!(executor_id)

    for area_key <- @staged_area_keys do
      TestRepo.query!(
        """
        SELECT geo_genius.put_area_in_release(
          $1, $2, $3, ST_GeogFromText('POINT(0.25 0.25)'), '{}'::jsonb)
        """,
        [raw_run, raw_executor, area_key]
      )
    end

    for {area_key, name} <- [
          {"demo_auth:outer:A", "Alpha"},
          {"demo_auth:inner:B", "Bravo"},
          {"demo_auth:city:C", "Charlie"},
          {"demo_auth:district:D", "Delta"}
        ] do
      GeoGenius.Catalog.put_area_name(context, candidate.run_id, executor_id, area_key, %{
        name: name,
        kind: "official",
        locale: nil
      })
    end

    for {area_key, code_value} <- [
          {"demo_auth:inner:B", "shared"},
          {"demo_auth:city:C", "deep"}
        ] do
      GeoGenius.Catalog.put_area_code(context, candidate.run_id, executor_id, area_key, %{
        code_type: "slug",
        code_value: code_value
      })
    end

    GeoGenius.Catalog.advance_import(context, candidate.run_id, executor_id, "relating", %{})

    TestRepo.query!("SELECT geo_genius.put_relation($1, $2, $3, $4, 'contains')", [
      raw_run,
      raw_executor,
      "demo_auth:outer:A",
      "demo_auth:city:C"
    ])

    {candidate.release_id, Ecto.UUID.dump!(candidate.release_id)}
  end

  # A release of a second collection, so an id valid for one catalog can be
  # shown not to reach another's rows.
  defp stage_other_collection! do
    context = Context.new(repo: TestRepo, prefix: "geo_genius")
    {:ok, manifest} = Manifest.from_map(other_manifest())
    candidate = ImportFixture.prepare!(context, manifest)
    executor_id = ImportFixture.claim_executor!(context, candidate.run_id)

    ImportFixture.advance_to!(context, candidate.run_id, executor_id, "normalizing")

    for statement <- [
          "SELECT geo_genius.upsert_area('other', 'other_auth', 'region', 'Z')"
        ] do
      TestRepo.query!(statement, [])
    end

    TestRepo.query!(
      "SELECT geo_genius.put_area_in_release($1, $2, 'other_auth:region:Z', NULL, '{}'::jsonb)",
      [Ecto.UUID.dump!(candidate.run_id), Ecto.UUID.dump!(executor_id)]
    )

    TestRepo.query!(
      "SELECT geo_genius.put_area_name($1, $2, 'other_auth:region:Z', 'Zulu', 'official', NULL)",
      [Ecto.UUID.dump!(candidate.run_id), Ecto.UUID.dump!(executor_id)]
    )

    on_exit(&teardown_other_collection!/0)

    candidate.release_id
  end

  defp demo_manifest(release_key) do
    %{
      "collection" => "demo",
      "collection_name" => "Demo",
      "release" => release_key,
      "provider" => "geojson",
      "requires_geometry" => false,
      "authorities" => [%{"key" => "demo_auth", "name" => "Demo Authority"}],
      "area_types" => [
        %{"key" => "outer", "rank" => 10, "requires_geometry" => false},
        %{"key" => "inner", "rank" => 20, "requires_geometry" => false},
        %{"key" => "city", "rank" => 50, "requires_geometry" => false},
        %{"key" => "district", "rank" => 60, "requires_geometry" => false}
      ],
      "sources" => [
        %{
          "source_key" => "demo:src-#{release_key}",
          "provider" => "geojson",
          "license" => "test",
          "release_key" => "v1",
          "artifacts" => [fixture_artifact("demo-#{release_key}.geojson")]
        }
      ],
      "options" => %{"area_type" => "outer", "code_property" => "code"}
    }
  end

  defp other_manifest do
    %{
      "collection" => "other",
      "collection_name" => "Other",
      "release" => "o1",
      "provider" => "geojson",
      "requires_geometry" => false,
      "authorities" => [%{"key" => "other_auth", "name" => "Other Authority"}],
      "area_types" => [%{"key" => "region", "rank" => 10, "requires_geometry" => false}],
      "sources" => [
        %{
          "source_key" => "other:src",
          "provider" => "geojson",
          "license" => "test",
          "release_key" => "v1",
          "artifacts" => [fixture_artifact("other.geojson")]
        }
      ],
      "options" => %{"area_type" => "region", "code_property" => "code"}
    }
  end

  defp fixture_artifact(logical_name) do
    %{
      "logical_name" => logical_name,
      "operator_supplied" => true,
      "format" => "geojson",
      "sha256" => String.duplicate("0", 64),
      "bytes" => 1
    }
  end

  defp teardown_other_collection! do
    TestRepo.query!(
      """
      DO $$
      DECLARE
        target_id uuid;
        target_release_id uuid;
      BEGIN
        SELECT id INTO target_id FROM geo_genius.collection WHERE key = 'other';
        IF target_id IS NULL THEN RETURN; END IF;

        DELETE FROM geo_genius.import_run_lease
         WHERE release_id IN (
           SELECT id FROM geo_genius.release WHERE collection_id = target_id
         );

        FOR target_release_id IN
          SELECT id FROM geo_genius.release WHERE collection_id = target_id
        LOOP
          PERFORM geo_genius.drop_release_partitions(target_release_id);
        END LOOP;

        DELETE FROM geo_genius.publication WHERE collection_id = target_id;

        DELETE FROM geo_genius.import_run
         WHERE release_id IN (
           SELECT id FROM geo_genius.release WHERE collection_id = target_id);

        DELETE FROM geo_genius.release_artifact
         WHERE release_id IN (
           SELECT id FROM geo_genius.release WHERE collection_id = target_id);

        DELETE FROM geo_genius.release_source
         WHERE release_id IN (
           SELECT id FROM geo_genius.release WHERE collection_id = target_id);

        DELETE FROM geo_genius.release
         WHERE collection_id = target_id;

        DELETE FROM geo_genius.source_release
         WHERE source_id IN (
           SELECT id FROM geo_genius.source WHERE collection_id = target_id);

        DELETE FROM geo_genius.collection WHERE id = target_id;
      END;
      $$
      """,
      []
    )
  end

  describe "areas/1" do
    test "returns every column the view carries, release_id included" do
      publish!()

      assert [area] = TestRepo.all(Published.areas(area_keys: ["demo_auth:city:C"]))

      assert %Published.Area{
               collection_key: "demo",
               area_key: "demo_auth:city:C",
               authority: "demo_auth",
               area_type: "city",
               type_rank: 50,
               name: "Charlie",
               attributes: %{},
               retired_at: nil
             } = area

      assert area.release_id == release_id!()
      assert %Geo.Point{srid: 4326} = area.centroid
      assert is_binary(area.area_id)
    end

    test "filters by collection, by type, and by area key set" do
      publish!()

      assert keys(TestRepo.all(Published.areas(collections: ["demo"]))) ==
               ~w(demo_auth:city:C demo_auth:city:E demo_auth:district:D demo_auth:inner:B
                  demo_auth:outer:A)

      assert [] == TestRepo.all(Published.areas(collections: ["absent"]))

      assert keys(TestRepo.all(Published.areas(types: ["city"]))) ==
               ["demo_auth:city:C", "demo_auth:city:E"]

      assert keys(
               TestRepo.all(
                 Published.areas(area_keys: ["demo_auth:outer:A", "demo_auth:district:D"])
               )
             ) == ["demo_auth:district:D", "demo_auth:outer:A"]
    end

    test "excludes retired areas until asked for them" do
      publish!()
      retire!("demo_auth:city:E")

      refute "demo_auth:city:E" in keys(TestRepo.all(Published.areas()))
      assert "demo_auth:city:E" in keys(TestRepo.all(Published.areas(include_retired: true)))
    end

    test "reads the published release by default and an explicit one on request" do
      publish!()

      assert keys(TestRepo.all(Published.areas(release_id: release_id!()))) ==
               keys(TestRepo.all(Published.areas()))

      assert [] == TestRepo.all(Published.areas(release_id: Ecto.UUID.generate()))
    end

    test "shows nothing until a release is published" do
      assert [] == TestRepo.all(Published.areas())
    end
  end

  describe "children_of/2" do
    test "walks one relation hop from a single parent" do
      publish!()

      assert keys(TestRepo.all(Published.children_of("demo_auth:outer:A"))) ==
               ["demo_auth:district:D", "demo_auth:inner:B"]
    end

    test "resolves a set of parents in one query, and says which parent each child came from" do
      publish!()

      pairs =
        Published.children_of(["demo_auth:outer:A", "demo_auth:inner:B"])
        |> select([area: area, relation: relation], {relation.parent_area_key, area.area_key})
        |> order_by([area: area], area.area_key)
        |> TestRepo.all()

      assert pairs == [
               {"demo_auth:inner:B", "demo_auth:city:C"},
               {"demo_auth:outer:A", "demo_auth:district:D"},
               {"demo_auth:outer:A", "demo_auth:inner:B"}
             ]
    end

    test "filters by relation classification and by area type independently" do
      publish!()

      assert keys(TestRepo.all(Published.children_of("demo_auth:outer:A", types: ["inner"]))) ==
               ["demo_auth:inner:B"]

      assert keys(
               TestRepo.all(
                 Published.children_of("demo_auth:outer:A", classifications: ["overlaps"])
               )
             ) == ["demo_auth:district:D"]
    end

    test "excludes a retired child, and scopes to an explicit release" do
      publish!()
      retire!("demo_auth:inner:B")

      assert keys(TestRepo.all(Published.children_of("demo_auth:outer:A"))) ==
               ["demo_auth:district:D"]

      assert keys(TestRepo.all(Published.children_of("demo_auth:outer:A", include_retired: true))) ==
               ["demo_auth:district:D", "demo_auth:inner:B"]

      assert [] ==
               TestRepo.all(
                 Published.children_of("demo_auth:outer:A", release_id: Ecto.UUID.generate())
               )
    end
  end

  describe "ancestors_of/2" do
    test "walks one relation hop upward, set-keyed" do
      publish!()

      assert keys(TestRepo.all(Published.ancestors_of("demo_auth:city:C"))) ==
               ["demo_auth:inner:B"]

      assert keys(TestRepo.all(Published.ancestors_of(["demo_auth:city:C", "demo_auth:inner:B"]))) ==
               ["demo_auth:inner:B", "demo_auth:outer:A"]
    end

    test "filters by classification and excludes a retired ancestor" do
      publish!()

      assert [] ==
               TestRepo.all(
                 Published.ancestors_of("demo_auth:inner:B", classifications: ["overlaps"])
               )

      retire!("demo_auth:outer:A")

      assert [] == TestRepo.all(Published.ancestors_of("demo_auth:inner:B"))

      assert keys(
               TestRepo.all(Published.ancestors_of("demo_auth:inner:B", include_retired: true))
             ) ==
               ["demo_auth:outer:A"]
    end
  end

  describe "areas_by_code/3" do
    test "matches a set of code values in one query" do
      publish!()

      assert keys(TestRepo.all(Published.areas_by_code("slug", "shared"))) ==
               ["demo_auth:city:E", "demo_auth:inner:B"]

      assert keys(TestRepo.all(Published.areas_by_code("slug", ["shared", "deep"]))) ==
               ["demo_auth:city:C", "demo_auth:city:E", "demo_auth:inner:B"]

      assert [] == TestRepo.all(Published.areas_by_code("fips", ["shared"]))
    end

    test "composes with the area filters and exposes the matched code" do
      publish!()

      assert keys(TestRepo.all(Published.areas_by_code("slug", "shared", types: ["city"]))) ==
               ["demo_auth:city:E"]

      assert [{"demo_auth:city:C", "deep"}] ==
               Published.areas_by_code("slug", "deep")
               |> select([area: area, code: code], {area.area_key, code.code_value})
               |> TestRepo.all()
    end
  end

  describe "codes/1, names/1 and relations/1" do
    test "codes/1 answers a whole area set in one query" do
      publish!()

      rows =
        Published.codes(area_keys: ["demo_auth:inner:B", "demo_auth:city:C"])
        |> order_by([code], code.area_key)
        |> TestRepo.all()

      assert [
               %Published.AreaCode{area_key: "demo_auth:city:C", code_value: "deep"},
               %Published.AreaCode{area_key: "demo_auth:inner:B", code_value: "shared"}
             ] = rows

      assert [] == TestRepo.all(Published.codes(code_types: ["fips"]))
    end

    test "names/1 returns every name kind an area carries" do
      publish!()

      assert [%Published.AreaName{name: "Charlie", kind: "official"}] =
               TestRepo.all(Published.names(area_keys: ["demo_auth:city:C"]))

      assert [] == TestRepo.all(Published.names(kinds: ["alias"]))
    end

    test "relations/1 exposes the measurement columns and filters both ends" do
      publish!()

      assert [%Published.AreaRelation{relation_type: "overlaps", child_area_key: key}] =
               TestRepo.all(
                 Published.relations(
                   parent_area_keys: ["demo_auth:outer:A"],
                   classifications: ["overlaps"]
                 )
               )

      assert key == "demo_auth:district:D"

      assert [%Published.AreaRelation{parent_area_key: "demo_auth:inner:B"}] =
               TestRepo.all(Published.relations(child_area_keys: ["demo_auth:city:C"]))
    end
  end

  # A release that exists, carries areas and an edge, and is simply not the
  # one its collection publishes -- the state a host is in when it wants to
  # verify a release or fill a projection ahead of go-live. An explicit
  # `:release_id` reads it through every function; the published release stays
  # what a read with no `:release_id` sees.
  describe "reading a release before it is published" do
    setup do
      publish!()
      {staged, raw} = stage_unpublished_release!()

      refute staged == release_id!()

      %{staged: staged, raw: raw, published: release_id!()}
    end

    test "every function reads the staged release, and the fixture separates it from r1",
         %{staged: staged, raw: raw} do
      assert %{rows: [[4]]} =
               TestRepo.query!(
                 "SELECT count(*) FROM geo_genius.release_areas WHERE release_id = $1",
                 [raw]
               )

      assert keys(TestRepo.all(Published.areas(release_id: staged))) == @staged_area_keys

      assert keys(TestRepo.all(Published.children_of("demo_auth:outer:A", release_id: staged))) ==
               ["demo_auth:city:C"]

      assert keys(TestRepo.all(Published.ancestors_of("demo_auth:city:C", release_id: staged))) ==
               ["demo_auth:outer:A"]

      assert keys(TestRepo.all(Published.areas_by_code("slug", "shared", release_id: staged))) ==
               ["demo_auth:inner:B"]

      assert Enum.sort(
               Enum.map(TestRepo.all(Published.codes(release_id: staged)), & &1.code_value)
             ) == ["deep", "shared"]

      assert TestRepo.all(Published.names(release_id: staged))
             |> Enum.map(& &1.name)
             |> Enum.sort() == ["Alpha", "Bravo", "Charlie", "Delta"]

      assert [%Published.AreaRelation{child_area_key: "demo_auth:city:C"}] =
               TestRepo.all(Published.relations(release_id: staged))
    end

    test "the published release stays the default for every function", %{published: published} do
      assert keys(TestRepo.all(Published.areas())) ==
               Enum.sort(["demo_auth:city:E" | @staged_area_keys])

      assert keys(TestRepo.all(Published.children_of("demo_auth:outer:A"))) ==
               ["demo_auth:district:D", "demo_auth:inner:B"]

      assert keys(TestRepo.all(Published.areas_by_code("slug", "shared"))) ==
               ["demo_auth:city:E", "demo_auth:inner:B"]

      assert Enum.map(TestRepo.all(Published.codes()), & &1.release_id) |> Enum.uniq() ==
               [published]

      assert Enum.map(TestRepo.all(Published.names()), & &1.release_id) |> Enum.uniq() ==
               [published]

      assert TestRepo.all(Published.relations())
             |> Enum.map(&{&1.parent_area_key, &1.child_area_key, &1.release_id})
             |> Enum.sort() == [
               {"demo_auth:inner:B", "demo_auth:city:C", published},
               {"demo_auth:outer:A", "demo_auth:district:D", published},
               {"demo_auth:outer:A", "demo_auth:inner:B", published}
             ]
    end

    # The release-mixing guard, behaviourally. r1 and r2 hold different edges
    # over the same areas, so dropping `relation.release_id == area.release_id`
    # from relation_hop/4 returns r1's children under r2's id, and dropping
    # `code.release_id == area.release_id` from areas_by_code/3 returns the
    # same area once per release that carries its code.
    test "a read of one release never picks up a row of the other", %{staged: staged} do
      children = TestRepo.all(Published.children_of("demo_auth:outer:A", release_id: staged))

      assert keys(children) == ["demo_auth:city:C"]
      assert Enum.map(children, & &1.release_id) == [staged]

      edges =
        Published.children_of("demo_auth:outer:A", release_id: staged)
        |> select([relation: relation], relation.release_id)
        |> TestRepo.all()

      assert edges == [staged]

      assert TestRepo.all(Published.areas_by_code("slug", "shared", release_id: staged))
             |> keys() == ["demo_auth:inner:B"]

      assert TestRepo.all(Published.areas(release_id: staged))
             |> Enum.map(& &1.release_id)
             |> Enum.uniq() == [staged]
    end

    test "a release id of another collection reads that collection and nothing else" do
      other = stage_other_collection!()

      assert keys(TestRepo.all(Published.areas(release_id: other))) == ["other_auth:region:Z"]

      assert [%Published.AreaName{name: "Zulu"}] =
               TestRepo.all(Published.names(release_id: other))

      assert [] == TestRepo.all(Published.areas(collections: ["demo"], release_id: other))
      assert [] == TestRepo.all(Published.children_of("demo_auth:outer:A", release_id: other))
      assert [] == TestRepo.all(Published.ancestors_of("demo_auth:city:C", release_id: other))
      assert [] == TestRepo.all(Published.areas_by_code("slug", "shared", release_id: other))
      assert [] == TestRepo.all(Published.relations(release_id: other))
      assert [] == TestRepo.all(Published.codes(release_id: other))
    end

    test "an unknown release id still reads nothing" do
      unknown = Ecto.UUID.generate()

      for query <- [
            Published.areas(release_id: unknown),
            Published.children_of("demo_auth:outer:A", release_id: unknown),
            Published.ancestors_of("demo_auth:city:C", release_id: unknown),
            Published.areas_by_code("slug", "shared", release_id: unknown),
            Published.codes(release_id: unknown),
            Published.names(release_id: unknown),
            Published.relations(release_id: unknown)
          ] do
        assert [] == TestRepo.all(query)
      end
    end

    test "retired areas are excluded on the unpublished path too", %{staged: staged} do
      retire!("demo_auth:district:D")

      refute "demo_auth:district:D" in keys(TestRepo.all(Published.areas(release_id: staged)))

      assert keys(TestRepo.all(Published.areas(release_id: staged, include_retired: true))) ==
               @staged_area_keys

      refute "demo_auth:district:D" in keys(
               TestRepo.all(
                 Published.children_of("demo_auth:outer:A",
                   release_id: staged,
                   include_retired: true
                 )
               )
             )
    end
  end

  # The case the library's own design describes and the function-backed API
  # cannot serve: a host projection keyed (release_id, area_key). The join
  # needs release_id on both sides, and GeoGenius.Query never projects it.
  test "joins a host projection table keyed on release_id and area_key" do
    publish!()
    release_id = release_id!()

    TestRepo.query!(
      """
      CREATE TABLE public.published_test_projection (
        release_id uuid NOT NULL, area_key text NOT NULL, listings integer NOT NULL)
      """,
      []
    )

    on_exit(fn ->
      TestRepo.query!("DROP TABLE IF EXISTS public.published_test_projection", [])
    end)

    TestRepo.query!(
      """
      INSERT INTO public.published_test_projection (release_id, area_key, listings)
      VALUES ($1, $2, 7), ($1, $3, 3)
      """,
      [Ecto.UUID.dump!(release_id), "demo_auth:inner:B", "demo_auth:district:D"]
    )

    rows =
      from([area: area] in Published.children_of("demo_auth:outer:A"),
        left_join: projection in "published_test_projection",
        on:
          projection.area_key == area.area_key and
            projection.release_id == area.release_id,
        order_by: area.area_key,
        select: {area.area_key, projection.listings}
      )
      |> TestRepo.all()

    assert rows == [{"demo_auth:district:D", 3}, {"demo_auth:inner:B", 7}]
  end

  # The measurement this module exists for. The catalog here is tiny, so the
  # assertion is on plan shape: a plpgsql SETOF function is an optimizer
  # barrier and shows up as a Function Scan, the view path does not have one.
  test "the view-backed plan carries no Function Scan where the function-backed plan does" do
    publish!()

    TestRepo.query!(
      "CREATE TABLE public.published_test_listings (id serial primary key, area_key text not null)",
      []
    )

    on_exit(fn -> TestRepo.query!("DROP TABLE IF EXISTS public.published_test_listings", []) end)

    TestRepo.query!(
      "INSERT INTO public.published_test_listings (area_key) VALUES ($1), ($1), ($2)",
      ["demo_auth:inner:B", "demo_auth:district:D"]
    )

    view_counts =
      from([area: area] in Published.children_of("demo_auth:outer:A"),
        left_join: listing in "published_test_listings",
        on: listing.area_key == area.area_key,
        group_by: area.area_key,
        order_by: area.area_key,
        select: {area.area_key, count(listing.id)}
      )

    function_counts =
      from(area in subquery(Query.children_of("demo_auth:outer:A", [])),
        left_join: listing in "published_test_listings",
        on: listing.area_key == area.area_key,
        group_by: area.area_key,
        order_by: area.area_key,
        select: {area.area_key, count(listing.id)}
      )

    assert TestRepo.all(view_counts) == TestRepo.all(function_counts)

    refute explain(view_counts) =~ "Function Scan"
    assert explain(function_counts) =~ "Function Scan"
  end

  defp explain(query) do
    {sql, params} = SQL.to_sql(:all, TestRepo, query)
    %{rows: rows} = TestRepo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> sql, params)

    rows |> List.flatten() |> List.first() |> Jason.encode!()
  end
end
