defmodule GeoGenius.Providers.Fields do
  @moduledoc """
  Coerces a raw payload value -- read out of a GeoJSON feature's properties
  or a CSV row's cells -- into either a present string or `nil`.

  Every provider pulls a code, a name, an alias, or an external code's value
  out of a payload the same way, and needs the same answer for "is this cell
  actually present": a value is present when it is a non-blank string or a
  number, absent otherwise. Before this module, `GeoGenius.Providers.GeoJSON`
  passed an empty string through and re-checked `value in [nil, ""]` at every
  call site, while `GeoGenius.Providers.CSV` folded `""` into `nil` up front
  and checked `is_nil/1`. Same concern, two contracts -- a third-party
  provider author copying either exemplar got a different answer depending
  on which one they read.
  """

  @doc """
  Returns a trimmed string for a present value, `nil` otherwise.

  A binary is trimmed and turned to `nil` if the result is empty; an integer
  or float is stringified; anything else -- a list, a map, a boolean -- is
  `nil` rather than raising, since a payload value's shape is the source's
  to guarantee, not this function's.

  Trimming matters most for a code: `area_key` is
  `<authority>:<area_type>:<code>`, a stable, public identifier, so a code
  cell padded with spaces -- common in a fixed-width FIPS or ZIP export --
  must not carry that padding into it. Without trimming, a later re-import
  of the same source with the padding stripped would produce a different
  `code` and therefore a different `area_key`, creating a duplicate area
  instead of updating the existing one, and orphaning any `relation` rows
  keyed on the old code. A value that is entirely whitespace is treated the
  same as an absent one: a blank code skips the row, a blank name or alias
  is simply not added.
  """
  @spec presence(term()) :: String.t() | nil
  def presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def presence(value) when is_integer(value) or is_float(value), do: to_string(value)
  def presence(_other), do: nil
end
