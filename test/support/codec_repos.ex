defmodule GeoGenius.NoJsonRepo do
  @moduledoc false

  # A Repo whose Postgrex types module registers PostGIS but names a JSON
  # library that does not exist. Geography decodes and jsonb raises, which is
  # exactly the shape a host lands in when Postgrex has no usable JSON library
  # -- the case `GeoGenius.Preflight`'s jsonb probe exists to move from the
  # first real read to boot. Configured at runtime by the test that starts it,
  # not in `config/test.exs`: nothing else in the suite should ever resolve to
  # a Repo that cannot decode jsonb.
  use Ecto.Repo, otp_app: :geo_genius, adapter: Ecto.Adapters.Postgres
end

defmodule GeoGenius.StockTypesRepo do
  @moduledoc false

  # A Repo left on Postgrex's default types module, with no
  # `Geo.PostGIS.Extension` registered. Every read GeoGenius offers projects a
  # centroid, so this Repo disconnects on the first one; the geometry probe is
  # what turns that into an explanation at boot. Configured at runtime for the
  # same reason as the Repo above.
  use Ecto.Repo, otp_app: :geo_genius, adapter: Ecto.Adapters.Postgres
end
