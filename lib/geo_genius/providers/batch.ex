defmodule GeoGenius.Providers.Batch do
  @moduledoc """
  Turns a list of raw items into staged rows, one `fun` call per item,
  stopping at the first error.

  Shared by every provider's per-chunk staging step: `GeoGenius.Providers.GeoJSON`
  builds one `GeoGenius.Staging.Row` per GeoJSON feature, `GeoGenius.Providers.CSV`
  one per delimited data row, and both need the same collect-or-halt, then-reverse
  machinery -- previously duplicated between them as `rows_for/2`,
  `collect_row/3`, and `finish_rows/1`, divergent only in how many extra
  arguments each provider's own `row_for` needed.
  """

  alias GeoGenius.Staging

  @doc """
  Applies `fun` to every item in `items`, returning the staged rows in the
  original order.

  Stops at the first `{:error, reason}` `fun` returns, propagating it rather
  than staging the remaining items.
  """
  @spec rows([term()], (term() -> {:ok, Staging.Row.t()} | {:error, term()})) ::
          {:ok, [Staging.Row.t()]} | {:error, term()}
  def rows(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, &collect(&1, fun, &2))
    |> finish()
  end

  defp collect(item, fun, {:ok, acc}) do
    case fun.(item) do
      {:ok, row} -> {:cont, {:ok, [row | acc]}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp finish({:ok, rows}), do: {:ok, Enum.reverse(rows)}
  defp finish({:error, _reason} = error), do: error
end
