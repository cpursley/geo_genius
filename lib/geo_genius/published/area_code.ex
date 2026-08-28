defmodule GeoGenius.Published.AreaCode do
  @moduledoc """
  One external code held by an area of a release, as `published_area_codes`
  and its release-scoped base `release_area_codes` project it.

  Read-only, and one row per code an area carries rather than the `codes` JSON
  object `GeoGenius.AreaMatch` holds. Codes hang off the area rather than off a
  release, and an area belongs to as many releases as carry it, so both views
  stamp `release_id` on every row: it says which release the row is speaking
  for, and it is the second half of any join back to
  `GeoGenius.Published.Area`. Neither view carries `retired_at`, because
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
          code_type: String.t() | nil,
          code_value: String.t() | nil
        }

  schema "published_area_codes" do
    field(:collection_key, :string)
    field(:release_id, Ecto.UUID)
    field(:area_key, :string)
    field(:area_id, Ecto.UUID)
    field(:code_type, :string)
    field(:code_value, :string)
  end
end
