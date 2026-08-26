import Config

config :geo_genius, ecto_repos: [GeoGenius.TestRepo]

# The fallback `GeoGenius.Config.repo!/1` reaches when a caller drops an
# explicit `repo:` option. `GeoGenius.SandboxedRepo` runs in `:manual` sandbox
# mode, so that fallback raises `DBConnection.OwnershipError` naming this repo
# instead of quietly working. `GeoGenius.TestRepo` here would be actively
# harmful: every dropped `repo:` would succeed silently. Leaving the key unset
# is only marginally better -- the resulting absent-key `ArgumentError` pins
# nothing a real host would ever see, since a real host always configures this.
# Tests that override the key must restore it (`GeoGenius.AppEnv`), never
# `Application.delete_env/2`, which would erase this default for the rest of
# the VM.
config :geo_genius, repo: GeoGenius.SandboxedRepo

config :geo_genius, GeoGenius.TestRepo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "54326")),
  database: System.get_env("PGDATABASE", "geo_genius_test"),
  pool_size: 5,
  priv: "test/support",
  types: GeoGenius.PostgresTypes

config :geo_genius, GeoGenius.SandboxedRepo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "54326")),
  database: System.get_env("PGDATABASE", "geo_genius_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  priv: "test/support",
  types: GeoGenius.PostgresTypes

config :logger, level: :warning
