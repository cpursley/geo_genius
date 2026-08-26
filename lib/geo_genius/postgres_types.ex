Postgrex.Types.define(
  GeoGenius.PostgresTypes,
  [Geo.PostGIS.Extension] ++ Ecto.Adapters.Postgres.extensions(),
  moduledoc: """
  A Postgrex types module registering the PostGIS extension, for hosts that do
  not already define one.

  No `:json` option is passed, so Postgrex resolves the JSON library itself
  from `config :postgrex, :json_library`, defaulting to Jason. `:geo_genius`
  depends on Jason for its own manifest files but does not choose a library for
  its host: a host on Elixir 1.18 or later that configured the built-in `JSON`
  keeps it, and every read projects `codes` and `attributes` as jsonb through
  whichever library the host chose.

  A host with its own types module adds `Geo.PostGIS.Extension` to that
  instead and points its Repo at it; either way the Repo must be able to
  decode geometry and jsonb before `GeoGenius.Preflight` will let it boot. See
  [`guides/reading.md`](reading.md#configuring-the-repo-to-decode-geometry).
  """
)
