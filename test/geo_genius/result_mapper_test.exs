defmodule GeoGenius.ResultMapperTest do
  use ExUnit.Case, async: true

  alias GeoGenius.ResultMapper

  defmodule Fixture do
    @moduledoc false
    @enforce_keys [:one]
    defstruct [:one, :two, :three]
  end

  @fields %{"one" => :one, "two" => :two, "three" => :three}

  defp result(columns, rows),
    do: %Postgrex.Result{columns: columns, rows: rows, num_rows: length(rows)}

  test "maps a result by column name, not by position" do
    # The column list is shuffled relative to the fields map's declaration
    # order, so a positional mapping would land "two" in :one and "one" in
    # :two the first time a caller's projection reordered its columns.
    [mapped] =
      ResultMapper.to_structs(
        result(~w(three one two), [["c", "a", "b"]]),
        @fields,
        Fixture
      )

    assert mapped.one == "a"
    assert mapped.two == "b"
    assert mapped.three == "c"
  end

  test "maps every row in the result" do
    mapped =
      ResultMapper.to_structs(
        result(~w(one two three), [["a1", "b1", "c1"], ["a2", "b2", "c2"]]),
        @fields,
        Fixture
      )

    assert [
             %Fixture{one: "a1", two: "b1", three: "c1"},
             %Fixture{one: "a2", two: "b2", three: "c2"}
           ] =
             mapped
  end

  test "returns an empty list for no rows" do
    assert ResultMapper.to_structs(result(~w(one), []), @fields, Fixture) == []
  end

  test "raises for a column with no entry in fields rather than dropping it" do
    assert_raise KeyError, fn ->
      ResultMapper.to_structs(result(~w(one unmapped_column), [["a", "z"]]), @fields, Fixture)
    end
  end
end
