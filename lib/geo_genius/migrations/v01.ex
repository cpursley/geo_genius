defmodule GeoGenius.Migrations.V01 do
  @moduledoc "Initial prefix-safe GeoGenius catalog schema."

  use EctoEvolver.Version,
    otp_app: :geo_genius,
    version: "01",
    sql_path: "geo_genius/sql/versions"
end
