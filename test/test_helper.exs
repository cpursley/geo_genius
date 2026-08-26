ExUnit.configure(exclude: [:integration])

{:ok, _} = GeoGenius.TestRepo.start_link()
{:ok, _} = GeoGenius.SandboxedRepo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(GeoGenius.SandboxedRepo, :manual)

Code.require_file("support/migrations/20260824185926_install_geo_genius.exs", __DIR__)

ExUnit.start()
