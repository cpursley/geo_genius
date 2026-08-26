defmodule GeoGenius.TestRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :geo_genius, adapter: Ecto.Adapters.Postgres
end
