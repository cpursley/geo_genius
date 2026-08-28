defmodule GeoGenius.Pipeline.Artifacts do
  @moduledoc """
  The import phases that obtain a release's files: `download/1` and
  `validate/1`.

  This is the only part of the pipeline that touches the cache, the
  downloader, or a checksum. Every artifact is resolved the same way -- look
  in the cache first, download a miss, hash whatever came back, and record
  that observation -- so a cached copy and a fresh download reach
  `record_artifact_observation/3` through the same check.

  **A cache hit is hashed on every run**, including one whose artifact row
  already carries a `validated_at`. Trusting that column would mean a
  corrupted or swapped cache entry is never noticed again: every later run
  would import it, and the release it produced would pass verification on
  bytes nobody reviewed.
  """

  alias GeoGenius.Catalog
  alias GeoGenius.CatalogError
  alias GeoGenius.Context
  alias GeoGenius.Downloader
  alias GeoGenius.Manifest
  alias GeoGenius.Pipeline.State
  alias GeoGenius.ReleaseArtifacts

  @doc """
  Resolves every artifact the release composes to a local file, recording what
  each one hashed to.

  Measures `"artifacts"`, `"downloaded"`, `"cached"`, and `"bytes"`, and
  carries each artifact's local path and attributed source release forward on
  the state.
  """
  @spec download(State.t()) :: State.result()
  def download(%State{} = state) do
    artifacts = Catalog.release_artifacts(state.context, state.run.release_id)

    artifacts
    |> Enum.reduce_while({:ok, empty_downloads()}, &collect_artifact(&1, state, &2))
    |> State.with_metrics(fn {:ok, acc} -> downloaded(state, acc, length(artifacts)) end)
  end

  @doc """
  Checks that every required artifact carries a `validated_at`, and counts the
  optional ones nothing could obtain.

  Re-reads the artifacts rather than trusting what `download/1` collected:
  `validated_at` is set by PostgreSQL, and reading it back is what makes this
  a check rather than a restatement of what the previous phase believed.
  """
  @spec validate(State.t()) :: State.result()
  def validate(%State{} = state) do
    artifacts = Catalog.release_artifacts(state.context, state.run.release_id)
    {required, optional} = Enum.split_with(artifacts, &required?(state, &1))
    unvalidated = Enum.filter(required, &is_nil(&1["validated_at"]))

    metrics = %{
      "required" => length(required),
      "optional_missing" => Enum.count(optional, &(not resolved?(state, &1)))
    }

    if unvalidated == [] do
      {:ok, %{state | metrics: metrics}}
    else
      {:error, "no validated copy of " <> Enum.map_join(unvalidated, ", ", & &1["logical_name"])}
    end
  end

  defp empty_downloads do
    %{resolved: %{}, sources: %{}, downloaded: 0, cached: 0, bytes: 0}
  end

  defp collect_artifact(artifact, state, {:ok, acc}) do
    case resolve_artifact(state, artifact) do
      {:ok, outcome} -> {:cont, {:ok, record_outcome(acc, artifact, outcome)}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp downloaded(state, acc, count) do
    metrics = %{
      "artifacts" => count,
      "downloaded" => acc.downloaded,
      "cached" => acc.cached,
      "bytes" => acc.bytes
    }

    %{state | resolved: acc.resolved, sources: acc.sources, metrics: metrics}
  end

  defp record_outcome(acc, _artifact, :missing), do: acc

  defp record_outcome(acc, artifact, {origin, path, bytes}) do
    %{
      acc
      | resolved: Map.put(acc.resolved, artifact["logical_name"], path),
        sources: Map.put(acc.sources, artifact["logical_name"], artifact["source_release_id"]),
        bytes: acc.bytes + bytes
    }
    |> Map.update!(origin, &(&1 + 1))
  end

  defp resolve_artifact(state, artifact) do
    with {:ok, key} <- cache_key(artifact) do
      cache = Context.adapter(state.context, :cache)

      case cache.fetch(key, state.opts) do
        {:ok, path} -> from_cache(state, artifact, path)
        :miss -> from_source(state, artifact, key)
      end
    end
  end

  # `GeoGenius.ReleaseArtifacts.cache_key/1` owns the derivation, so an
  # artifact a host later resolves is addressed exactly as the import that
  # wrote it addressed it. It returns the detail alone; the artifact's own name
  # is added here, where the message reaches a run's `error` column.
  defp cache_key(artifact) do
    case ReleaseArtifacts.cache_key(artifact) do
      {:ok, key} ->
        {:ok, key}

      {:error, detail} ->
        {:error, "artifact #{artifact["logical_name"]} has no usable cache key: #{detail}"}
    end
  end

  defp from_cache(state, artifact, path) do
    case Downloader.hash_file(path) do
      {:ok, observed} ->
        observe(state, artifact, path, observed, :cached)

      {:error, reason} ->
        {:error, "could not read cached artifact #{artifact["logical_name"]}: #{inspect(reason)}"}
    end
  end

  defp from_source(state, artifact, key) do
    cond do
      is_binary(artifact["url"]) -> fetch_artifact(state, artifact, key)
      required?(state, artifact) -> {:error, missing_artifact(artifact, key)}
      true -> {:ok, :missing}
    end
  end

  defp missing_artifact(artifact, key) do
    "operator-supplied artifact #{artifact["logical_name"]} is not in the cache under " <>
      "#{key}; place the file there and run the import again"
  end

  defp fetch_artifact(state, artifact, key) do
    downloader = Context.adapter(state.context, :downloader)
    destination = Path.join(state.work_dir, artifact["logical_name"])

    case downloader.fetch(artifact["url"], destination, state.opts) do
      {:ok, observed} ->
        cache_and_observe(state, artifact, key, destination, observed)

      {:error, reason} ->
        {:error,
         "could not download #{artifact["logical_name"]} from #{artifact["url"]}: " <>
           "#{inspect(reason)}"}
    end
  end

  defp cache_and_observe(state, artifact, key, path, observed) do
    cache = Context.adapter(state.context, :cache)

    case cache.put(key, path, state.opts) do
      {:ok, cached} ->
        observe(state, artifact, cached, observed, :downloaded)

      {:error, reason} ->
        {:error, "could not cache #{artifact["logical_name"]} under #{key}: #{inspect(reason)}"}
    end
  end

  # `record_artifact_observation/3` is where expectation meets observation, and
  # it refuses a mismatch. That refusal arrives as a check violation naming an
  # artifact uuid, so it is turned into a message naming the artifact an
  # operator knows.
  defp observe(state, artifact, path, observed, origin) do
    Catalog.record_artifact_observation(state.context, artifact["artifact_id"], %{
      observed_sha256: observed.sha256,
      observed_bytes: observed.bytes
    })

    {:ok, {origin, path, observed.bytes}}
  rescue
    error in CatalogError ->
      {:error,
       "artifact #{artifact["logical_name"]} does not match its manifest: " <>
         "#{Exception.message(error)}"}
  end

  defp required?(state, artifact) do
    case Map.fetch(state.manifest_artifacts, artifact["logical_name"]) do
      {:ok, %Manifest.Artifact{required: required}} -> required != false
      :error -> true
    end
  end

  defp resolved?(state, artifact), do: Map.has_key?(state.resolved, artifact["logical_name"])
end
