defmodule GeoGenius.ResultMapper do
  @moduledoc """
  Maps a `Postgrex.Result` into structs by column name.

  `GeoGenius.AreaMatch` and `GeoGenius.ImportRun` both project a query result
  with more than a dozen columns, several of them same-typed neighbours, into
  their own struct. Both need the same rule -- map by column name, never by
  position -- so it lives here once rather than as two copies that could
  drift apart.
  """

  @doc """
  Maps a query result into structs of `module`, using `fields` to translate
  column names to struct keys.

  Mapping is by column name rather than position. Both projections that use
  this declare more than a dozen columns with several same-typed neighbours,
  so a positional mapping would transpose two of them silently the first time
  a projection changed.

  Raises if a column in the result has no entry in `fields`: an unmapped
  column is a projection bug to fix, not a value to drop silently.
  """
  @spec to_structs(Postgrex.Result.t(), %{optional(String.t()) => atom()}, module()) :: [
          struct()
        ]
  def to_structs(%Postgrex.Result{columns: columns, rows: rows}, fields, module) do
    keys = Enum.map(columns, &Map.fetch!(fields, &1))
    Enum.map(rows, &struct!(module, Enum.zip(keys, &1)))
  end
end
