defmodule GeoGenius.Stores.PostgresSpatialTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias GeoGenius.{Context, QueryError, Stores.Postgres, TestRepo}

  setup do
    TestRepo.query!("SELECT geo_genius_test.demo_fixture()", [])
    on_exit(fn -> TestRepo.query!("SELECT geo_genius_test.demo_teardown()", []) end)
    {:ok, context: Context.new(repo: TestRepo, prefix: "geo_genius")}
  end

  test "areas_for_point returns containment matches", %{context: context} do
    matches = Postgres.areas_for_point(context, 0.25, 0.25, [])

    assert matches |> Enum.map(& &1.area_key) |> Enum.sort() ==
             ["demo_auth:inner:B", "demo_auth:outer:A"]

    assert Enum.all?(matches, &(&1.match_method == "containment"))
    assert %Geo.Point{srid: 4326} = hd(matches).centroid
  end

  test "areas_for_point honours the type filter", %{context: context} do
    assert [match] = Postgres.areas_for_point(context, 0.25, 0.25, types: ["outer"])
    assert match.area_key == "demo_auth:outer:A"
  end

  test "areas_for_geometry takes a Geo struct and measures overlap", %{context: context} do
    polygon = %Geo.Polygon{
      coordinates: [[{0.0, 0.0}, {0.3, 0.0}, {0.3, 0.3}, {0.0, 0.3}, {0.0, 0.0}]],
      srid: 4326
    }

    matches = Postgres.areas_for_geometry(context, polygon, [])

    assert matches |> Enum.map(& &1.area_key) |> Enum.sort() ==
             ["demo_auth:inner:B", "demo_auth:outer:A"]

    # coverage_of_input is a percentage, so a polygon wholly inside an area is 100.
    assert Enum.all?(matches, &(&1.coverage_of_input == 100.0))
    assert Enum.all?(matches, &is_float(&1.intersection_area_m2))
  end

  test "areas_near measures distance as a float", %{context: context} do
    assert [nearest | _] = Postgres.areas_near(context, 0.6, 0.6, 200_000.0, [])
    assert is_float(nearest.distance_m)
    assert nearest.distance_m >= 0.0
  end

  test "areas_near respects the result limit", %{context: context} do
    assert [_one] = Postgres.areas_near(context, 0.6, 0.6, 200_000.0, limit: 1)
  end

  describe "the shared option keys" do
    test "collections matches on the collection key and excludes anything else", %{
      context: context
    } do
      assert [_, _] = Postgres.areas_for_point(context, 0.25, 0.25, collections: ["demo"])
      assert [] == Postgres.areas_for_point(context, 0.25, 0.25, collections: ["absent"])
    end

    test "include_retired decides whether a retired area is returned", %{context: context} do
      TestRepo.query!(
        "UPDATE geo_genius.area SET retired_at = now() WHERE area_key = $1",
        ["demo_auth:inner:B"]
      )

      assert ["demo_auth:outer:A"] ==
               context |> Postgres.areas_for_point(0.25, 0.25, []) |> Enum.map(& &1.area_key)

      assert ["demo_auth:inner:B", "demo_auth:outer:A"] ==
               context
               |> Postgres.areas_for_point(0.25, 0.25, include_retired: true)
               |> Enum.map(& &1.area_key)
               |> Enum.sort()
    end

    # release_at/3 returns a hyphenated string, so a release_id read off a match
    # has to be the same shape or a caller cannot feed one read's answer into
    # the next read's :release_id.
    test "release_id reads back as a hyphenated string", %{context: context} do
      assert [match | _] = Postgres.areas_for_point(context, 0.25, 0.25, [])

      # Ecto.UUID.cast/1 accepts the raw 16-byte form too, so casting to itself
      # is what pins the hyphenated string rather than merely a valid UUID.
      assert byte_size(match.release_id) == 36
      assert Ecto.UUID.cast!(match.release_id) == match.release_id
    end

    test "a release_id read off a match pins a later read", %{context: context} do
      assert [match | _] = Postgres.areas_for_point(context, 0.25, 0.25, [])

      assert [_, _] = Postgres.areas_for_point(context, 0.25, 0.25, release_id: match.release_id)

      assert [_, _] =
               Postgres.areas_for_geometry(
                 context,
                 %Geo.Polygon{
                   coordinates: [[{0.0, 0.0}, {0.3, 0.0}, {0.3, 0.3}, {0.0, 0.3}, {0.0, 0.0}]],
                   srid: 4326
                 },
                 release_id: match.release_id
               )
    end

    test "a release_id already in Postgrex's 16-byte form is passed through", %{context: context} do
      assert [match | _] = Postgres.areas_for_point(context, 0.25, 0.25, [])
      dumped = Ecto.UUID.dump!(match.release_id)

      assert byte_size(dumped) == 16
      assert [_, _] = Postgres.areas_for_point(context, 0.25, 0.25, release_id: dumped)
    end

    test "a release_id no release carries matches nothing", %{context: context} do
      assert [] == Postgres.areas_for_point(context, 0.25, 0.25, release_id: Ecto.UUID.generate())
    end
  end

  # Coordinates reach a read in whatever shape the host held them. An integer
  # is the ordinary way to write a whole-degree coordinate, and Ecto hands back
  # a %Decimal{} for a numeric column, so both convert rather than being
  # refused. Anything else has to name the read and the argument: multiplying
  # by 1.0 raises an ArithmeticError that names neither.
  describe "coordinate arguments" do
    test "an integer coordinate converts", %{context: context} do
      assert [_ | _] = Postgres.areas_near(context, 0, 0, 200_000, [])
    end

    test "a %Decimal{} coordinate, the shape a numeric column loads as, converts", %{
      context: context
    } do
      matches = Postgres.areas_for_point(context, Decimal.new("0.25"), Decimal.new("0.25"), [])

      assert matches |> Enum.map(& &1.area_key) |> Enum.sort() ==
               ["demo_auth:inner:B", "demo_auth:outer:A"]
    end

    test "a nil coordinate names GeoGenius, the read, and the argument", %{context: context} do
      error =
        assert_raise ArgumentError, fn -> Postgres.areas_for_point(context, nil, 0.25, []) end

      assert error.message =~ "GeoGenius"
      assert error.message =~ "areas_for_point"
      assert error.message =~ "lon"
    end

    test "a string coordinate names the argument it arrived as", %{context: context} do
      error =
        assert_raise ArgumentError, fn -> Postgres.areas_for_point(context, 0.25, "30.5", []) end

      assert error.message =~ "lat"
      assert error.message =~ ~s("30.5")
    end

    test "a non-numeric radius names areas_near and radius_m", %{context: context} do
      error =
        assert_raise ArgumentError, fn -> Postgres.areas_near(context, 0.25, 0.25, nil, []) end

      assert error.message =~ "areas_near"
      assert error.message =~ "radius_m"
    end
  end

  describe "failures" do
    test "a database error names the read that produced it", %{context: context} do
      error =
        assert_raise QueryError, fn ->
          Postgres.areas_for_point(context, 0.25, 0.25, types: "outer")
        end

      assert error.function == "areas_for_point"
      assert error.message =~ "areas_for_point"
      assert error.reason != nil
    end

    test "a read the database rejects is a QueryError too", %{context: context} do
      error =
        assert_raise QueryError, fn -> Postgres.areas_for_point(context, 500.0, 0.25, []) end

      assert error.function == "areas_for_point"
    end
  end
end
