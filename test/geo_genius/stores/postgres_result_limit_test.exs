defmodule GeoGenius.Stores.PostgresResultLimitTest do
  @moduledoc """
  What `:limit` means at each of its three distinct values on the reads that
  take one.

  A host that narrows what a read answered -- by a scope the catalog does not
  model, a state or a minimum population -- cannot let the read cut first, and
  says so by passing `:limit` as nil. Sixty probe areas is what tells that
  apart from the default of 50: at fewer, an absent limit and an explicit nil
  answer with the same rows and either could be mistaken for the other.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Ecto.Adapters.SQL
  alias GeoGenius.{Context, Query, Stores.Postgres, TestRepo}

  @probes 60
  @run "SELECT geo_genius_test.demo_run_id()"
  @executor "SELECT geo_genius_test.demo_executor_id()"

  setup do
    TestRepo.query!("SELECT geo_genius_test.demo_fixture_build()", [])

    TestRepo.query!(
      "SELECT geo_genius.upsert_area('demo', 'demo_auth', 'outer', 'PROBE-' || to_char(g, 'FM00')) FROM generate_series(1, $1) AS g",
      [@probes]
    )

    # The probes sit far from the fixture's own areas, so a radius drawn around
    # them holds the probes and nothing else.
    TestRepo.query!(
      "SELECT geo_genius.put_area_in_release((#{@run}), (#{@executor}), 'demo_auth:outer:PROBE-' || to_char(g, 'FM00'), ST_GeogFromText('POINT(' || (100 + g * 0.001)::text || ' 40)'), '{}'::jsonb) FROM generate_series(1, $1) AS g",
      [@probes]
    )

    TestRepo.query!(
      "SELECT geo_genius.put_area_name((#{@run}), (#{@executor}), 'demo_auth:outer:PROBE-' || to_char(g, 'FM00'), 'Probeton ' || to_char(g, 'FM00'), 'official', NULL) FROM generate_series(1, $1) AS g",
      [@probes]
    )

    TestRepo.query!("SELECT geo_genius_test.demo_publish()", [])
    on_exit(fn -> TestRepo.query!("SELECT geo_genius_test.demo_teardown()", []) end)
    {:ok, context: Context.new(repo: TestRepo, prefix: "geo_genius")}
  end

  describe "search_areas" do
    test "an explicit nil limit answers with every match", %{context: context} do
      assert length(Postgres.search_areas(context, "Probeton", limit: nil)) == @probes
    end

    test "an absent limit answers with the default 50", %{context: context} do
      assert length(Postgres.search_areas(context, "Probeton", [])) == 50
    end

    test "a numeric limit cuts to it", %{context: context} do
      assert length(Postgres.search_areas(context, "Probeton", limit: 5)) == 5
    end
  end

  describe "areas_near" do
    test "an explicit nil limit answers with every area in the radius", %{context: context} do
      assert length(Postgres.areas_near(context, 100.03, 40.0, 20_000.0, limit: nil)) == @probes
    end

    test "an absent limit answers with the default 50", %{context: context} do
      assert length(Postgres.areas_near(context, 100.03, 40.0, 20_000.0, [])) == 50
    end

    test "a numeric limit cuts to it", %{context: context} do
      assert length(Postgres.areas_near(context, 100.03, 40.0, 20_000.0, limit: 5)) == 5
    end
  end

  describe "Query.search_areas" do
    test "an explicit nil limit answers with every match" do
      assert length(TestRepo.all(Query.search_areas("Probeton", limit: nil))) == @probes
    end

    test "an absent limit answers with the default 50" do
      assert length(TestRepo.all(Query.search_areas("Probeton", []))) == 50
    end

    # The composable API binds the limit as a parameter of the statement rather
    # than reading it inside a function, so what reaches PostgreSQL is readable
    # off the statement itself: nil is bound as nil, not resolved to a default
    # on the way.
    test "binds nil rather than substituting the default" do
      assert nil == limit_param(Query.search_areas("Probeton", limit: nil))
      assert 50 == limit_param(Query.search_areas("Probeton", []))
    end
  end

  # `result_limit` is the fourth argument of search_areas, so it is the fourth
  # bound parameter of the fragment.
  defp limit_param(query) do
    {_statement, params} = SQL.to_sql(:all, TestRepo, query)
    Enum.at(params, 3)
  end
end
