defmodule GeoGenius.Published.Prefix do
  @moduledoc false

  # The schema prefix every `GeoGenius.Published` schema installs into
  # `@schema_prefix`. It is read and validated once, here, so the four schemas
  # share a single compile-time read rather than each recording one of their
  # own. `GeoGenius.Published`'s moduledoc explains why `:prefix` has to be set
  # in `config/config.exs`.

  alias GeoGenius.Config

  @prefix Application.compile_env(:geo_genius, :prefix, "geo_genius") |> Config.validate_prefix!()

  @doc "The validated compile-time `:prefix`."
  @spec get() :: String.t()
  def get, do: @prefix
end
