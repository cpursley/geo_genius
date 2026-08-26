# A types module that registers PostGIS but names a JSON library that does not
# exist, which is exactly the shape a host lands in when Postgrex has no usable
# JSON library: geography decodes, jsonb raises. It exists so the preflight
# jsonb probe can be exercised against a real Repo rather than a stub.
Postgrex.Types.define(
  GeoGenius.NoJsonTypes,
  [Geo.PostGIS.Extension] ++ Ecto.Adapters.Postgres.extensions(),
  json: GeoGenius.AbsentJsonLibrary,
  moduledoc: false
)
