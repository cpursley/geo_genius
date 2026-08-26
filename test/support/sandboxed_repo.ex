defmodule GeoGenius.SandboxedRepo do
  @moduledoc false

  # A second Repo pointed at the same test database as GeoGenius.TestRepo,
  # pooled through Ecto.Adapters.SQL.Sandbox. GeoGenius.SandboxPoolRepo stands
  # in for a sandboxed host Repo without a real connection (its query!/3
  # raises); this one is a genuine connection, used to prove
  # guides/installation.md's claim that GeoGenius.Runners.Task needs no
  # sandbox setup -- the supervised task inherits the owner's checked-out
  # connection through $callers -- rather than merely documenting it. Not
  # part of :ecto_repos -- it shares GeoGenius.TestRepo's already-migrated
  # schema on the same physical database, so it has no storage of its own to
  # create or migrate.

  use Ecto.Repo, otp_app: :geo_genius, adapter: Ecto.Adapters.Postgres
end
