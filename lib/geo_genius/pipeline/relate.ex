defmodule GeoGenius.Pipeline.Relate do
  @moduledoc """
  The import phase that rebuilds measured relations and writes every edge a
  provider asserts.

  The two paths compose rather than one replacing the other: a provider
  whose areas nest spatially or by code returns `:rebuild` from
  `relations/1`, and a provider whose source carries a hierarchy no overlap
  test can derive -- a parent column on every row, or a source with no
  geometry at all -- returns edges from `asserted_relations/2`. A provider
  can do both, and both land in the same release.

  `rebuild_relations/1` runs first, so a rebuilt measured relation is on the
  release before any asserted edge is written. If a provider asserts an edge
  for a pair the rebuild also measured, the assertion wins: it upserts onto
  the same row, nulling the measured overlap columns and overwriting the
  geometry-classified `relation_type` with no warning that a measurement was
  replaced. A well-behaved provider keeps its asserted edges disjoint from
  the pairs its own geometry would measure.

  Asserted edges are written after normalization, so an edge may name any
  area the run produced rather than only the ones its own row emitted --
  `GeoGenius.Catalog.put_relation_many/3` requires both areas to already be
  members of the release, which every area `GeoGenius.Pipeline.Normalize`
  wrote already is by the time this phase runs.

  Staging is read in pages, and each page is one heartbeat, the same as
  `GeoGenius.Pipeline.Normalize.normalize/1`: the import this exists to
  serve stages tens of thousands of rows, and before asserted edges existed
  this phase was a single SQL call under `:timeout` -- streaming rows with no
  heartbeat between them would let a long asserting pass outrun the run's
  lease with nothing renewing it.

  A provider's own defect -- an edge naming an area absent from the release,
  an unknown `relation_type` -- raises out of `Catalog.put_relation_many/3` and is
  left to propagate. It is not rescued here: `GeoGenius.Pipeline` catches
  whatever a phase raises and records it as `{:exception, exception,
  stacktrace}`, the same structured detail every other phase's provider call
  is recorded with. Catching it again here first would only discard the
  exception's type and stacktrace in favor of a flatter string.
  """

  alias GeoGenius.Catalog
  alias GeoGenius.Pipeline.State
  alias GeoGenius.Staging

  @doc """
  Rebuilds measured relations, writes every edge the release's providers
  assert, and merges both into one metrics map.

  Measures `"relations"` (present only when at least one provider's
  `relations/1` returns `:rebuild`) and `"asserted_relations"`, which counts
  edges asserted rather
  than distinct edges written: two rows asserting the same edge each add
  one, even though `put_relation_many/3` deduplicates and the edge itself
  converges to a single row.
  """
  @spec relate(State.t()) :: State.result()
  def relate(%State{} = state) do
    measured =
      if rebuild?(state) do
        %{"relations" => rebuild_relations(state)}
      else
        %{}
      end

    count = write_asserted_relations(state)
    {:ok, %{state | metrics: Map.put(measured, "asserted_relations", count)}}
  end

  # A release with several providers gets one answer, and it is the union: a
  # source whose areas nest spatially needs its containment measured whether or
  # not another source in the same release carries geometry at all. Requiring
  # every provider to agree would silently drop the measurement the moment a
  # release gained a source with no boundaries.
  defp rebuild?(%State{} = state) do
    Enum.any?(state.providers, &(&1.relations(state.manifest) == :rebuild))
  end

  defp rebuild_relations(state) do
    Catalog.rebuild_relations(state.context, state.run.release_id, timeout: state.timeout)
  end

  defp write_asserted_relations(%State{} = state) do
    state.context
    |> Staging.stream(state.run.run_id, batch_size: state.batch_size)
    |> Stream.chunk_every(state.batch_size)
    |> Enum.reduce(0, &assert_batch(&1, state, &2))
  end

  # A page's edges are written as one set, the same way
  # `GeoGenius.Pipeline.Normalize` writes a page's areas: a hierarchy asserted
  # from a column repeats the same edge on every row beneath it, and each
  # repeat was its own round trip before.
  defp assert_batch(rows, state, count) do
    edges = Enum.flat_map(rows, &asserted_edges(&1, state))
    Catalog.put_relation_many(state.context, state.run.release_id, edges)

    count = count + length(edges)
    heartbeat(state, count)
    count
  end

  defp heartbeat(state, count) do
    Catalog.heartbeat_import(state.context, state.run.run_id, %{"asserted_relations" => count})
  end

  # A row's edges come from the provider that staged it, the same dispatch
  # normalizing uses. A row naming an artifact no provider in this run stages
  # asserts nothing rather than raising: `GeoGenius.Pipeline.Normalize` runs
  # first and fails the release on exactly that row, so this is unreachable in
  # a run that got here.
  defp asserted_edges(row, state) do
    case Map.fetch(state.artifact_providers, row.artifact) do
      {:ok, provider} -> mapped_edges(provider, row, state)
      :error -> []
    end
  end

  defp mapped_edges(provider, row, state) do
    state.manifest
    |> provider.asserted_relations(row)
    |> Enum.map(fn {parent_key, child_key, relation_type} ->
      %{
        parent_area_key: parent_key,
        child_area_key: child_key,
        relation_type: relation_type
      }
    end)
  end
end
