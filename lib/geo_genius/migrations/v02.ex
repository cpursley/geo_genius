defmodule GeoGenius.Migrations.V02 do
  @moduledoc "Repaired display geometry on both boundary writes."

  use EctoEvolver.Version,
    otp_app: :geo_genius,
    version: "02",
    sql_path: "geo_genius/sql/versions"
end
