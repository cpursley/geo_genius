defmodule GeoGenius.Published.AreaName do
  @moduledoc """
  One name held by an area of a release, as `published_area_names` and its
  release-scoped base `release_area_names` project it.

  Read-only, and every name of every kind, where `GeoGenius.Published.Area`'s
  `name` is the single official one a trigger keeps current. Names hang off the
  area rather than off a release, and an area belongs to as many releases as
  carry it, so both views stamp `release_id` on every row: it says which
  release the row is speaking for, and it is the second half of any join back
  to `GeoGenius.Published.Area`. Neither view carries `retired_at`, because
  retirement is a property of the area.
  """

  use Ecto.Schema

  @primary_key false
  @schema_prefix GeoGenius.Published.Prefix.get()

  @type t :: %__MODULE__{
          collection_key: String.t() | nil,
          release_id: Ecto.UUID.t() | nil,
          area_key: String.t() | nil,
          area_id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          kind: String.t() | nil,
          locale: String.t() | nil
        }

  schema "published_area_names" do
    field(:collection_key, :string)
    field(:release_id, Ecto.UUID)
    field(:area_key, :string)
    field(:area_id, Ecto.UUID)
    field(:name, :string)
    field(:kind, :string)
    field(:locale, :string)
  end
end
