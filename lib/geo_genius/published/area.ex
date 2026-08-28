defmodule GeoGenius.Published.Area do
  @moduledoc """
  One area of a release, as `published_areas` and its release-scoped base
  `release_areas` project it.

  Read-only. `published_areas` resolves through the publication pointer, so a
  row read through it belongs to whichever release its collection publishes
  right now. Build queries with `GeoGenius.Published`, or compose directly
  against this schema.

  There is no primary key: a view has none to declare, and `area_id` is unique
  only because at most one release per collection is published at a time.
  """

  use Ecto.Schema

  @primary_key false
  @schema_prefix GeoGenius.Published.Prefix.get()

  @type t :: %__MODULE__{
          collection_key: String.t() | nil,
          release_id: Ecto.UUID.t() | nil,
          area_id: Ecto.UUID.t() | nil,
          area_key: String.t() | nil,
          authority: String.t() | nil,
          area_type: String.t() | nil,
          type_rank: integer() | nil,
          name: String.t() | nil,
          centroid: Geo.Point.t() | nil,
          attributes: map() | nil,
          retired_at: DateTime.t() | nil
        }

  schema "published_areas" do
    field(:collection_key, :string)
    field(:release_id, Ecto.UUID)
    field(:area_id, Ecto.UUID)
    field(:area_key, :string)
    field(:authority, :string)
    field(:area_type, :string)
    field(:type_rank, :integer)
    field(:name, :string)
    field(:centroid, Geo.PostGIS.Geometry)
    field(:attributes, :map)
    field(:retired_at, :utc_datetime_usec)
  end
end
