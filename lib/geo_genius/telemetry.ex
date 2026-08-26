defmodule GeoGenius.Telemetry do
  @moduledoc """
  Telemetry events GeoGenius emits.

  Each catalog read is one span:

    * `[:geo_genius, :read, :start]` with `%{system_time: integer()}`
    * `[:geo_genius, :read, :stop]` with `%{duration: integer()}`
    * `[:geo_genius, :read, :exception]` with `%{duration: integer()}`

  Metadata carries `:function`, the SQL function called, and `:prefix`, the
  schema it was called in. A stop event also carries `:result_count`, so a
  host can tell a read that found nothing from a read that found thousands
  without instrumenting its own callers.

  Each phase of an import is one span of its own:

    * `[:geo_genius, :import, :start]` with `%{system_time: integer()}`
    * `[:geo_genius, :import, :stop]` with `%{duration: integer()}`
    * `[:geo_genius, :import, :exception]` with `%{duration: integer()}`

  Metadata carries `:phase`, `:run_id`, `:release_id`, `:collection_key`, and
  `:prefix`. `:collection_key` is the low-cardinality dimension a host charts
  an import against; `:run_id` is unique per run and belongs in a log line
  rather than in a metrics tag.

  A stop event also carries `:metrics`, what that phase measured, and
  `:status`, `:ok` or `:error`. A phase that fails by returning an error is a
  normal return and so emits `:stop`, not `:exception` -- without `:status` a
  host counting stop events would count every failed import as a completed
  phase, and empty `:metrics` cannot tell them apart, since two phases measure
  nothing even when they succeed.
  """

  @doc "Wraps a read in a telemetry span, counting the rows it returned."
  @spec span(String.t(), map(), (-> result)) :: result when result: term()
  def span(function, metadata, fun) when is_function(fun, 0) do
    emit([:geo_genius, :read], Map.put(metadata, :function, function), fn ->
      result = fun.()
      {result, %{result_count: count(result)}}
    end)
  end

  @doc """
  Wraps one import phase in a telemetry span, carrying what it measured and
  how it ended.

  `fun` returns `{result, metrics, status}`; `result` is what this returns,
  and the other two become the stop event's `:metrics` and `:status`
  metadata.
  """
  @spec import_span(String.t(), map(), (-> {result, map(), :ok | :error})) :: result
        when result: term()
  def import_span(phase, metadata, fun) when is_function(fun, 0) do
    emit([:geo_genius, :import], Map.put(metadata, :phase, phase), fn ->
      {result, metrics, status} = fun.()
      {result, %{metrics: metrics, status: status}}
    end)
  end

  # Both spans differ only in their event name, the metadata key that names
  # the work, and the one key their stop event adds. Everything else -- the
  # start/stop/exception shape and merging the stop key onto the metadata the
  # start event carried -- is the same, and is here once rather than twice.
  defp emit(event, metadata, fun) do
    :telemetry.span(event, metadata, fn ->
      {result, stop_metadata} = fun.()
      {result, Map.merge(metadata, stop_metadata)}
    end)
  end

  defp count(result) when is_list(result), do: length(result)
  defp count(nil), do: 0
  defp count(_result), do: 1
end
