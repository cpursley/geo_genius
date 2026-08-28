defmodule GeoGenius.SeededMatch do
  @moduledoc """
  One area returned by a plural catalog read, paired with the seed that found
  it.

  The plural reads -- `GeoGenius.children_of_many/2` and its siblings --
  resolve many seeds in one call, so the seed has to travel with each row:
  without it a caller cannot tell which of its thousands of inputs a given row
  answers. `match` is the ordinary `GeoGenius.AreaMatch` struct the singular
  reads return, unchanged, so everything documented about it still applies.

  `seed_key` holds whichever kind of seed the read takes: an area key for
  `children_of_many/2`, `ancestors_of_many/2`, and `related_areas_many/2`, and
  a code value for `areas_by_code_many/3`.

  Grouping a plural result back onto the caller's own list is one step:

      GeoGenius.children_of_many(county_keys)
      |> Enum.group_by(& &1.seed_key, & &1.match)

  A seed that matched nothing is absent from the result rather than present
  with a nil match, so a caller that needs every seed represented supplies its
  own default.
  """

  alias GeoGenius.AreaMatch

  @enforce_keys [:seed_key, :match]
  defstruct [:seed_key, :match]

  @seed_column "seed_key"

  @type t :: %__MODULE__{
          seed_key: String.t(),
          match: AreaMatch.t()
        }

  @doc """
  Maps a plural read's query result into structs.

  The seed column is located by name and split off; everything left is handed
  to `GeoGenius.AreaMatch.from_result/1`, which maps it by name in turn. A
  positional split would put an area key in `:seed_key` and a seed in
  `:area_key` the first time the projection moved, and both are plausible
  strings.

  Raises if the result carries no seed column: that is a projection bug to
  fix, not a value to invent.
  """
  @spec from_result(Postgrex.Result.t()) :: [t()]
  def from_result(%Postgrex.Result{columns: columns, rows: rows} = result) do
    index = seed_index!(columns)
    {_seed_column, area_columns} = List.pop_at(columns, index)
    {seeds, area_rows} = rows |> Enum.map(&List.pop_at(&1, index)) |> Enum.unzip()

    matches =
      AreaMatch.from_result(%Postgrex.Result{result | columns: area_columns, rows: area_rows})

    Enum.zip_with(seeds, matches, &%__MODULE__{seed_key: &1, match: &2})
  end

  defp seed_index!(columns) do
    Enum.find_index(columns, &(&1 == @seed_column)) ||
      raise ArgumentError,
            "GeoGenius plural read result carries no #{@seed_column} column, only: " <>
              inspect(columns)
  end
end
