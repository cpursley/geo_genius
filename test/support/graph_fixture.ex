defmodule GeoGenius.GraphFixture do
  @moduledoc """
  A demo collection shaped so that every option binding has something to keep
  and something to drop.

  The `geo_genius_test.demo_fixture_build/0` fixture gives two areas of two
  types and no relations. That is enough to prove a read runs, but not enough
  to prove a read bound `:types` rather than `:classifications`, or `:max_depth`
  rather than a constant. This adds:

  - two more area types (`city`, `district`) and three more areas, so a type
    filter separates areas that a relation filter cannot, and vice versa;
  - asserted relations `A contains B`, `B contains C`, `A overlaps D`, giving
    one grandchild reachable only at depth two and one edge reachable only
    through a second classification;
  - the slug `shared` on `B` and `E`, only one of which descends from `A`, and
    the slug `deep` on `C`, reachable only when a parent scope reaches two
    levels down.
  """

  alias GeoGenius.TestRepo

  @release "SELECT id FROM geo_genius.release WHERE release_key = 'r1'"

  @doc "Builds the graph into the unpublished `r1` release. Does not publish."
  @spec build!() :: :ok
  def build! do
    TestRepo.query!("SELECT geo_genius_test.demo_fixture_build()", [])

    run!("SELECT geo_genius.upsert_area_type('demo', 'city', 50)")
    run!("SELECT geo_genius.upsert_area_type('demo', 'district', 60)")

    area!("city", "C", "Charlie", "POINT(10 10)")
    area!("district", "D", "Delta", "POINT(0.25 0.25)")
    area!("city", "E", "Echo", "POINT(20 20)")

    relation!("demo_auth:outer:A", "demo_auth:inner:B", "contains")
    relation!("demo_auth:inner:B", "demo_auth:city:C", "contains")
    relation!("demo_auth:outer:A", "demo_auth:district:D", "overlaps")

    code!("demo_auth:inner:B", "shared")
    code!("demo_auth:city:E", "shared")
    code!("demo_auth:city:C", "deep")

    :ok
  end

  @doc "Builds the graph and publishes `r1`."
  @spec build_and_publish!() :: :ok
  def build_and_publish! do
    build!()
    run!("SELECT geo_genius_test.demo_publish()")
    :ok
  end

  @doc "Removes the demo collection and everything hanging off it."
  @spec teardown!() :: :ok
  def teardown! do
    run!("SELECT geo_genius_test.demo_teardown()")
    :ok
  end

  @doc "Marks one area retired, so `:include_retired` has something to decide."
  @spec retire!(String.t()) :: :ok
  def retire!(area_key) do
    TestRepo.query!("UPDATE geo_genius.area SET retired_at = now() WHERE area_key = $1", [
      area_key
    ])

    :ok
  end

  @doc "The sorted `area_key` of every match in a read's result."
  @spec keys([%{area_key: String.t()}]) :: [String.t()]
  def keys(matches), do: matches |> Enum.map(& &1.area_key) |> Enum.sort()

  defp area!(type, code, name, centroid_wkt) do
    run!("SELECT geo_genius.upsert_area('demo', 'demo_auth', '#{type}', '#{code}')")

    run!(
      "SELECT geo_genius.put_area_name('demo_auth:#{type}:#{code}', '#{name}', 'official', NULL)"
    )

    run!("""
    SELECT geo_genius.put_area_in_release(
      (#{@release}), 'demo_auth:#{type}:#{code}',
      ST_GeogFromText('#{centroid_wkt}'), '{}'::jsonb)
    """)
  end

  defp relation!(parent, child, classification) do
    run!(
      "SELECT geo_genius.put_relation((#{@release}), '#{parent}', '#{child}', '#{classification}')"
    )
  end

  defp code!(area_key, value) do
    run!("SELECT geo_genius.put_area_code('#{area_key}', 'slug', '#{value}')")
  end

  defp run!(sql), do: TestRepo.query!(sql, [])
end
