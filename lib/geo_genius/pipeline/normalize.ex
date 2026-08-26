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
  """

  alias GeoGenius.Catalog
  alias GeoGenius.Pipeline.State
  alias GeoGenius.Provider.Area
  alias GeoGenius.Staging

  @name_kinds ~w(official alias mailing abbreviation)a
  @empty_counts %{"areas" => 0, "boundaries" => 0, "skipped" => 0}

  @doc """
  Streams the run's staged rows through the provider and writes what comes
  back.

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

  defp normalize_batch(rows, state, {:ok, counts}) do
    case Enum.reduce_while(rows, {:ok, counts}, &normalize_row(&1, state, &2)) do
      {:ok, counts} -> heartbeat(state, counts)
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp heartbeat(state, counts) do
    Catalog.heartbeat_import(state.context, state.run.run_id, counts)
    {:cont, {:ok, counts}}
  end

  defp normalize_row(row, state, {:ok, counts}) do
    case state.provider.normalize(state.manifest, row) do
      :skip ->
        {:cont, {:ok, bump(counts, "skipped")}}

      {:ok, %Area{} = area} ->
        continue(write_area(state, row, area, counts))

      {:error, reason} ->
        {:halt, {:error, "#{inspect(state.provider)} could not normalize a row: #{reason}"}}
    end
  end

  defp continue({:ok, _counts} = written), do: {:cont, written}
  defp continue({:error, _reason} = error), do: {:halt, error}

  defp write_area(state, row, area, counts) do
    area_key = area_key(area)

    with :ok <- validate_names(state, area, area_key),
         :ok <- validate_codes(state, area, area_key) do
      put_area(state, row, area, area_key, counts)
    end
  end

  # `upsert_area/3` returns a uuid, but every write after it takes the area
  # key, so it is composed here from the same three parts PostgreSQL composes
  # `area_key` from. The pipeline test asserts the two agree rather than
  # trusting that they do.
  defp area_key(%Area{} = area) do
    "#{area.authority_key}:#{area.area_type_key}:#{area.code}"
  end

  defp validate_names(state, %Area{names: names}, area_key) do
    case Enum.find(names, &invalid_kind?/1) do
      nil ->
        :ok

      %Area.Name{kind: kind} ->
        {:error,
         "#{inspect(state.provider)} returned name kind #{inspect(kind)} for area " <>
           "#{area_key}; expected one of #{Enum.map_join(@name_kinds, ", ", &inspect/1)}"}
    end
  end

  defp invalid_kind?(%Area.Name{kind: kind}), do: kind not in @name_kinds

  # A code type is deliberately open -- FIPS, GNIS, ZIP, and whatever the next
  # authority calls its own identifier -- so only its shape can be checked.
  defp validate_codes(state, %Area{codes: codes}, area_key) do
    case Enum.find(codes, &invalid_code_type?/1) do
      nil ->
        :ok

      %Area.Code{code_type: code_type} ->
        {:error,
         "#{inspect(state.provider)} returned code type #{inspect(code_type)} for area " <>
           "#{area_key}; a code type must be a string"}
    end
  end

  defp invalid_code_type?(%Area.Code{code_type: code_type}), do: not is_binary(code_type)

  defp put_area(state, row, area, area_key, counts) do
    Catalog.upsert_area(state.context, state.run.collection_key, %{
      authority_key: area.authority_key,
      area_type_key: area.area_type_key,
      code: area.code
    })

    Enum.each(area.names, &put_name(state, area_key, &1))
    Enum.each(area.codes, &put_code(state, area_key, &1))

    Catalog.put_area_in_release(state.context, state.run.release_id, area_key, %{
      centroid: area.centroid,
      attributes: area.attributes
    })

    put_boundary(state, row, area, area_key, counts)
  end

  defp put_name(state, area_key, %Area.Name{} = name) do
    Catalog.put_area_name(state.context, area_key, %{
      name: name.name,
      kind: Atom.to_string(name.kind),
      locale: name.locale
    })
  end

  defp put_code(state, area_key, %Area.Code{} = code) do
    Catalog.put_area_code(state.context, area_key, %{
      code_type: code.code_type,
      code_value: code.code_value
    })
  end

  defp put_boundary(_state, _row, %Area{geometry: nil}, _area_key, counts) do
    {:ok, bump(counts, "areas")}
  end

  # A boundary is attributed to the source release the artifact it was staged
  # from belongs to, which is why the download phase carries that mapping
  # forward. `put_boundary/4` also recomputes the centroid from the geometry,
  # so it runs after `put_area_in_release/4` rather than before it.
  defp put_boundary(state, row, area, area_key, counts) do
    case Map.fetch(state.sources, row.artifact) do
      {:ok, source_release_id} ->
        Catalog.put_boundary(state.context, state.run.release_id, area_key, %{
          source_release_id: source_release_id,
          geometry: area.geometry
        })

        {:ok, counts |> bump("areas") |> bump("boundaries")}

      :error ->
        {:error,
         "staged row names artifact #{inspect(row.artifact)}, which this run did not stage"}
    end
  end

  defp bump(counts, key), do: Map.update!(counts, key, &(&1 + 1))
end
