defmodule GeoGenius.AreaMatch do
  @moduledoc """
  One area returned by a catalog read, with whatever the read measured about it.

  Every row-returning SQL function returns this shape. Which measurement fields
  carry a value depends on how the area was found: a containment match measures
  nothing, a proximity match sets `distance_m`, a geometry overlap sets the
  intersection and coverage fields, and a name search sets `score`.

  `coverage_of_input` and `coverage_of_area` are percentages, 0 to 100. Only
  `areas_for_geometry` populates them. They are not the same scale as
  `relation.parent_coverage`, which is a 0-to-1 ratio and never reaches this
  struct.
  """

  @enforce_keys [:area_key]
  defstruct [
    :collection_key,
    :release_id,
    :area_key,
    :authority,
    :area_type,
    :type_rank,
    :name,
    :codes,
    :centroid,
    :attributes,
    :match_method,
    :distance_m,
    :intersection_area_m2,
    :coverage_of_input,
    :coverage_of_area,
    :score
  ]

  @type t :: %__MODULE__{
          collection_key: String.t() | nil,
          release_id: Ecto.UUID.t() | nil,
          area_key: String.t(),
          authority: String.t() | nil,
          area_type: String.t() | nil,
          type_rank: integer() | nil,
          name: String.t() | nil,
          codes: %{optional(String.t()) => [String.t()]} | nil,
          centroid: Geo.Point.t() | nil,
          attributes: map() | nil,
          match_method: String.t() | nil,
          distance_m: float() | nil,
          intersection_area_m2: float() | nil,
          coverage_of_input: float() | nil,
          coverage_of_area: float() | nil,
          score: float() | nil
        }

  @fields %{
    "collection_key" => :collection_key,
    "release_id" => :release_id,
    "area_key" => :area_key,
    "authority" => :authority,
    "area_type" => :area_type,
    "type_rank" => :type_rank,
    "name" => :name,
    "codes" => :codes,
    "centroid" => :centroid,
    "attributes" => :attributes,
    "match_method" => :match_method,
    "distance_m" => :distance_m,
    "intersection_area_m2" => :intersection_area_m2,
    "coverage_of_input" => :coverage_of_input,
    "coverage_of_area" => :coverage_of_area,
    "score" => :score
  }

  @doc """
  Maps a query result into structs.

  Mapping is by column name. `area_match` declares sixteen columns, several of
  them the same type and adjacent, so a positional mapping would transpose two
  of them silently the first time the projection changed.
  """
  @spec from_result(Postgrex.Result.t()) :: [t()]
  def from_result(%Postgrex.Result{} = result) do
    GeoGenius.ResultMapper.to_structs(result, @fields, __MODULE__)
  end
end
