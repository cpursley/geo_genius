defmodule GeoGenius.Pipeline.Normalize do
  @moduledoc """
  The import phase that turns staged rows into catalog rows.

  This is the only part of the pipeline that knows
  `GeoGenius.Provider.Area` -- what a provider may describe, and what each
  part of it becomes: an area, its names and external codes, its membership in
  the release, and its boundary.

  **A provider's result is checked before it reaches SQL.** The four legal
  name kinds are atoms so a provider pattern-matches them, but Dialyzer does
  not catch a misspelled one: `normalize/2` returns a union and `names` is a
  list, so a mis-typed success typing always overlaps the spec and
  `invalid_contract` never fires. This is therefore the only place a bad kind
  can be caught while the provider and the row are still known; one row
  further on it is a Postgrex encode or check error naming neither.

  Staging is read in pages, so no connection is held across the phase, and
  each page is one heartbeat: a batch is well inside the lease's staleness
  window, so no background heartbeat process is needed -- and not having one
  means there is no second process whose death could be mistaken for a dead
  worker.

  **A page is written as a set, not as rows.** The page is turned into areas
  first and written afterwards, as one statement for the batch's areas, one
  for its names, one for its codes and one for its memberships, through the
  `*_many` counterparts of the scalar catalog writes. A source that
  denormalises a hierarchy describes the same county in every city row of it,
  so a batch names far fewer distinct areas than it has rows, and one statement
  per area would spend a round trip on every repeat. Boundaries stay one call per
  boundary: `GeoGenius.Catalog.put_boundary/4` validates and repairs a
  geometry, replaces the area's boundary and its subdivided parts, and
  recomputes the centroid from what it stored.

  Collecting the whole page before writing any of it also means a provider's
  own errors -- an illegal name kind, an unstaged artifact -- are found before
  the batch is written rather than partway through it.
  """

  alias GeoGenius.Catalog
  alias GeoGenius.Pipeline.State
  alias GeoGenius.Provider.Area
  alias GeoGenius.Staging

  @name_kinds ~w(official alias mailing abbreviation)a
  @empty_counts %{"areas" => 0, "boundaries" => 0, "skipped" => 0}

  @doc """
  Streams the run's staged rows through the provider that staged each one and
  writes what comes back.

  Measures `"areas"`, `"boundaries"`, and `"skipped"`.
  """
  @spec normalize(State.t()) :: State.result()
  def normalize(%State{} = state) do
    state.context
    |> Staging.stream(state.run.run_id, batch_size: state.batch_size)
    |> Stream.chunk_every(state.batch_size)
    |> Enum.reduce_while({:ok, @empty_counts}, &normalize_batch(&1, state, &2))
    |> State.with_metrics(fn {:ok, counts} -> %{state | metrics: counts} end)
  end

  # The page is collected first and written afterwards: the four set writes
  # below each need the whole batch, and the collecting pass is where a
  # provider's own errors surface, before any of the batch has been written.
  defp normalize_batch(rows, state, {:ok, counts}) do
    case Enum.reduce_while(rows, {:ok, {counts, []}}, &collect_row(&1, state, &2)) do
      {:ok, {counts, collected}} ->
        collected |> Enum.reverse() |> write_batch(state)
        heartbeat(state, counts)

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp heartbeat(state, counts) do
    Catalog.heartbeat_import(state.context, state.run.run_id, counts)
    {:cont, {:ok, counts}}
  end

  defp collect_row(row, state, {:ok, {counts, collected}}) do
    case Map.fetch(state.artifact_providers, row.artifact) do
      {:ok, provider} -> collect_with(provider, row, state, counts, collected)
      :error -> {:halt, {:error, unknown_artifact(row)}}
    end
  end

  defp collect_with(provider, row, state, counts, collected) do
    case provider.normalize(state.manifest, row) do
      :skip ->
        {:cont, {:ok, {bump(counts, "skipped"), collected}}}

      {:ok, %Area{} = area} ->
        continue(collect_areas(provider, state, row, [area], counts, collected))

      {:ok, areas} when is_list(areas) ->
        continue(collect_areas(provider, state, row, areas, counts, collected))

      {:error, reason} ->
        {:halt, {:error, "#{inspect(provider)} could not normalize a row: #{reason}"}}
    end
  end

  # A staged row names the artifact it came from, and the run's providers are
  # keyed by that name. A row naming an artifact this run did not stage is a
  # resumed run whose manifest changed underneath it, not a provider defect, so
  # it fails naming the artifact rather than raising a `KeyError`.
  defp unknown_artifact(row) do
    "staged row names artifact #{inspect(row.artifact)}, which no provider in this run stages"
  end

  defp continue({:ok, _collected} = accumulated), do: {:cont, accumulated}
  defp continue({:error, _reason} = error), do: {:halt, error}

  # Folds the row's areas in order, stopping at the first that cannot be
  # collected so a later area never masks an earlier failure.
  defp collect_areas(provider, state, row, areas, counts, collected) do
    Enum.reduce_while(areas, {:ok, {counts, collected}}, fn area, {:ok, accumulated} ->
      case collect_area(provider, state, row, area, accumulated) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # `Area.key/1` is the one Elixir-side statement of the format PostgreSQL
  # composes `area_key` from, and every write after the area itself takes that
  # key rather than the id `upsert_area_many/3` returns. The pipeline test
  # asserts the two agree rather than trusting that they do.
  defp collect_area(provider, state, row, area, {counts, collected}) do
    area_key = Area.key(area)

    with :ok <- validate_names(provider, area, area_key),
         :ok <- validate_codes(provider, area, area_key),
         {:ok, source_release_id} <- boundary_source(state, row, area) do
      {:ok, {count_area(counts, area), [{area_key, area, source_release_id} | collected]}}
    end
  end

  defp validate_names(provider, %Area{names: names}, area_key) do
    case Enum.find(names, &invalid_kind?/1) do
      nil ->
        :ok

      %Area.Name{kind: kind} ->
        {:error,
         "#{inspect(provider)} returned name kind #{inspect(kind)} for area " <>
           "#{area_key}; expected one of #{Enum.map_join(@name_kinds, ", ", &inspect/1)}"}
    end
  end

  defp invalid_kind?(%Area.Name{kind: kind}), do: kind not in @name_kinds

  # A code type is deliberately open -- FIPS, GNIS, ZIP, and whatever the next
  # authority calls its own identifier -- so only its shape can be checked.
  defp validate_codes(provider, %Area{codes: codes}, area_key) do
    case Enum.find(codes, &invalid_code_type?/1) do
      nil ->
        :ok

      %Area.Code{code_type: code_type} ->
        {:error,
         "#{inspect(provider)} returned code type #{inspect(code_type)} for area " <>
           "#{area_key}; a code type must be a string"}
    end
  end

  defp invalid_code_type?(%Area.Code{code_type: code_type}), do: not is_binary(code_type)

  # An area carrying no geometry is attributed to no source release: its
  # membership is written and no boundary is.
  defp boundary_source(_state, _row, %Area{geometry: nil}), do: {:ok, nil}

  # A boundary is attributed to the source release the artifact it was staged
  # from belongs to, which is why the download phase carries that mapping
  # forward.
  defp boundary_source(state, row, %Area{}) do
    case Map.fetch(state.sources, row.artifact) do
      {:ok, source_release_id} ->
        {:ok, source_release_id}

      :error ->
        {:error,
         "staged row names artifact #{inspect(row.artifact)}, which this run did not stage"}
    end
  end

  defp count_area(counts, %Area{geometry: nil}), do: bump(counts, "areas")
  defp count_area(counts, %Area{}), do: counts |> bump("areas") |> bump("boundaries")

  # The order the catalog needs: an area exists before its names, codes and
  # membership name it, and `put_boundary/4` recomputes the centroid
  # `put_area_in_release_many/3` has just written, so boundaries come last.
  defp write_batch(collected, state) do
    Catalog.upsert_area_many(
      state.context,
      state.run.collection_key,
      Enum.map(collected, &area_attrs/1)
    )

    Catalog.put_area_name_many(state.context, Enum.flat_map(collected, &name_attrs/1))
    Catalog.put_area_code_many(state.context, Enum.flat_map(collected, &code_attrs/1))

    Catalog.put_area_in_release_many(
      state.context,
      state.run.release_id,
      Enum.map(collected, &membership_attrs/1)
    )

    Enum.each(collected, &put_boundary(state, &1))
  end

  defp area_attrs({_area_key, %Area{} = area, _source_release_id}) do
    %{
      authority_key: area.authority_key,
      area_type_key: area.area_type_key,
      code: area.code
    }
  end

  defp name_attrs({area_key, %Area{names: names}, _source_release_id}) do
    Enum.map(names, fn %Area.Name{} = name ->
      %{
        area_key: area_key,
        name: name.name,
        kind: Atom.to_string(name.kind),
        locale: name.locale
      }
    end)
  end

  defp code_attrs({area_key, %Area{codes: codes}, _source_release_id}) do
    Enum.map(codes, fn %Area.Code{} = code ->
      %{area_key: area_key, code_type: code.code_type, code_value: code.code_value}
    end)
  end

  defp membership_attrs({area_key, %Area{} = area, _source_release_id}) do
    %{area_key: area_key, centroid: area.centroid, attributes: area.attributes}
  end

  defp put_boundary(_state, {_area_key, %Area{geometry: nil}, _source_release_id}), do: :ok

  defp put_boundary(state, {area_key, %Area{} = area, source_release_id}) do
    Catalog.put_boundary(state.context, state.run.release_id, area_key, %{
      source_release_id: source_release_id,
      geometry: area.geometry
    })
  end

  defp bump(counts, key), do: Map.update!(counts, key, &(&1 + 1))
end
