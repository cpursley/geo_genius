defmodule GeoGenius.Providers.GeoJSONGeometry do
  @moduledoc """
  Decodes the optional `"geometry"` member shared by GeoJSON Feature readers.
  """

  @doc "Returns a decoded Geo geometry, `nil`, or a provider-facing error message."
  @spec decode(term()) :: {:ok, struct() | nil} | {:error, String.t()}
  def decode(nil), do: {:ok, nil}

  def decode(geometry) when is_map(geometry) do
    case Geo.JSON.decode(geometry) do
      {:ok, geom} -> {:ok, geom}
      {:error, error} -> {:error, "invalid geometry: #{Exception.message(error)}"}
    end
  end

  def decode(other) do
    {:error, "expected \"geometry\" to be a JSON object or null, got: #{inspect(other)}"}
  end
end
