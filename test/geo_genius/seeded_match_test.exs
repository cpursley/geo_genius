defmodule GeoGenius.SeededMatchTest do
  use ExUnit.Case, async: true

  alias GeoGenius.{AreaMatch, SeededMatch}

  @area_columns ~w(collection_key release_id area_key authority area_type type_rank name codes
                   centroid attributes match_method distance_m intersection_area_m2
                   coverage_of_input coverage_of_area score)

  defp result(columns, rows),
    do: %Postgrex.Result{columns: columns, rows: rows, num_rows: length(rows)}

  test "splits the seed off and maps the rest into an AreaMatch" do
    [seeded] =
      SeededMatch.from_result(
        result(["seed_key" | @area_columns], [["demo_auth:outer:A" | @area_columns]])
      )

    assert seeded.seed_key == "demo_auth:outer:A"
    assert %AreaMatch{} = seeded.match
    assert seeded.match.area_key == "area_key"
    assert seeded.match.score == "score"
  end

  test "keeps each row with its own seed" do
    rows = [
      ["seed-one" | @area_columns],
      ["seed-two" | @area_columns]
    ]

    assert [one, two] = SeededMatch.from_result(result(["seed_key" | @area_columns], rows))
    assert one.seed_key == "seed-one"
    assert two.seed_key == "seed-two"
  end

  # The seed is found by name, not by position, for the same reason
  # AreaMatch maps by name: a projection that moved the seed column would
  # otherwise put an area_key in :seed_key and a seed in :area_key, both of
  # them plausible strings.
  test "finds the seed column wherever it sits in the projection" do
    columns = @area_columns ++ ["seed_key"]
    values = @area_columns ++ ["demo_auth:outer:A"]

    [seeded] = SeededMatch.from_result(result(columns, [values]))

    assert seeded.seed_key == "demo_auth:outer:A"
    assert seeded.match.area_key == "area_key"
  end

  test "returns an empty list for no rows" do
    assert SeededMatch.from_result(result(["seed_key" | @area_columns], [])) == []
  end

  test "raises for a result carrying no seed column rather than guessing one" do
    assert_raise ArgumentError, ~r/seed_key/, fn ->
      SeededMatch.from_result(result(@area_columns, [@area_columns]))
    end
  end
end
