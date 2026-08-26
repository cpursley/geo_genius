defmodule GeoGenius.AreaMatchTest do
  use ExUnit.Case, async: true

  alias GeoGenius.AreaMatch

  defp result(columns, rows),
    do: %Postgrex.Result{columns: columns, rows: rows, num_rows: length(rows)}

  test "maps a full row by column name" do
    point = %Geo.Point{coordinates: {0.5, 0.5}, srid: 4326}

    [match] =
      AreaMatch.from_result(
        result(
          ~w(collection_key release_id area_key authority area_type type_rank name codes
             centroid attributes match_method distance_m intersection_area_m2
             coverage_of_input coverage_of_area score),
          [
            [
              "demo",
              "0f9d0d4e-1d3f-4a2f-9a1b-2c3d4e5f6071",
              "demo_auth:outer:A",
              "demo_auth",
              "outer",
              10,
              "Alpha",
              %{"postal" => ["30309", "30310"]},
              point,
              %{"pop" => 5},
              "containment",
              nil,
              nil,
              nil,
              nil,
              nil
            ]
          ]
        )
      )

    assert match.collection_key == "demo"
    assert match.area_key == "demo_auth:outer:A"
    assert match.type_rank == 10
    assert match.codes == %{"postal" => ["30309", "30310"]}
    assert match.centroid == point
    assert match.attributes == %{"pop" => 5}
    assert match.match_method == "containment"
    assert match.score == nil
  end

  test "column order is irrelevant" do
    [match] =
      AreaMatch.from_result(result(~w(area_key collection_key score), [["k", "demo", 0.42]]))

    assert match.area_key == "k"
    assert match.collection_key == "demo"
    assert match.score == 0.42
  end

  # The moduledoc's claim is that mapping by name is what keeps two adjacent
  # same-typed columns from being exchanged. Nothing else asserts that a name
  # reaches the field of the same name, so this walks all sixteen. Each cell
  # carries its own column name as its value, which makes any exchange read
  # back as the wrong name rather than as a plausible value.
  @names ~w(collection_key release_id area_key authority area_type type_rank name codes
            centroid attributes match_method distance_m intersection_area_m2
            coverage_of_input coverage_of_area score)

  test "every column name lands in the field of the same name" do
    [match] = AreaMatch.from_result(result(@names, [@names]))

    for column <- @names do
      field = String.to_existing_atom(column)

      assert Map.fetch!(match, field) == column,
             "column #{column} landed in a field holding #{inspect(Map.fetch!(match, field))}"
    end
  end

  test "the mapped names are exactly the struct's fields" do
    [match] = AreaMatch.from_result(result(@names, [@names]))

    assert match |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
             @names |> Enum.map(&String.to_existing_atom/1) |> Enum.sort()
  end

  test "returns an empty list for no rows" do
    assert AreaMatch.from_result(result(~w(area_key), [])) == []
  end
end
