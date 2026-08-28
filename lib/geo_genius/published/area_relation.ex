defmodule GeoGenius.Published.AreaRelation do
  @moduledoc """
  One parent-to-child edge among areas of a release, as
  `published_area_relations` and its release-scoped base `release_relations`
  project it.

  Read-only. `intersection_area_m2`, `parent_coverage` and `child_coverage`
  carry a value only for a measured relation; all three are null for one
  asserted from source data. `parent_coverage` and `child_coverage` are ratios
  from 0 to 1, not the percentages `GeoGenius.AreaMatch` reports.
  """

  use Ecto.Schema

  @primary_key false
  @schema_prefix GeoGenius.Published.Prefix.get()

  @type t :: %__MODULE__{
          collection_key: String.t() | nil,
          release_id: Ecto.UUID.t() | nil,
          parent_area_id: Ecto.UUID.t() | nil,
          parent_area_key: String.t() | nil,
          child_area_id: Ecto.UUID.t() | nil,
          child_area_key: String.t() | nil,
          relation_type: String.t() | nil,
          intersection_area_m2: Decimal.t() | nil,
          parent_coverage: Decimal.t() | nil,
          child_coverage: Decimal.t() | nil
        }

  schema "published_area_relations" do
    field(:collection_key, :string)
    field(:release_id, Ecto.UUID)
    field(:parent_area_id, Ecto.UUID)
    field(:parent_area_key, :string)
    field(:child_area_id, Ecto.UUID)
    field(:child_area_key, :string)
    field(:relation_type, :string)
    field(:intersection_area_m2, :decimal)
    field(:parent_coverage, :decimal)
    field(:child_coverage, :decimal)
  end
end
