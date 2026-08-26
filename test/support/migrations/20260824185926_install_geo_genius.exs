defmodule GeoGenius.TestMigrations.Install do
  use Ecto.Migration

  # The target prefix comes from application environment, NOT from
  # `Ecto.Migrator`'s `:prefix` option. That option also relocates Ecto's own
  # `schema_migrations` table into the target prefix, so a migration that drops
  # that prefix deadlocks against its own bookkeeping. Reading the prefix here
  # keeps `schema_migrations` in the repo's default schema, where it belongs,
  # and lets both `up` and `down` work at any prefix.
  defp target_prefix, do: Application.get_env(:geo_genius, :test_prefix, "geo_genius")

  def up, do: GeoGenius.Migration.up(prefix: target_prefix())
  def down, do: GeoGenius.Migration.down(prefix: target_prefix())
end
