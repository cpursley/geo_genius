defmodule GeoGenius.Registration do
  @moduledoc """
  Writes the catalog rows a manifest describes: the collection, its
  authorities and area types, the release opened against its reviewed
  manifest, and every source, source release and artifact it composes.

  This is steps 2 through 6 of `GeoGenius.import/1`, lifted out so there is
  one implementation rather than one per caller. Tests that claim an import
  run directly -- rather than driving `GeoGenius.import/1` -- register through
  this module too, so a mistake here fails them. Written out separately in
  each test helper, it could not: a manifest that registered only its first
  authority passed a green suite, because every test that touched
  registration touched its own copy of it.

  Registration is idempotent end to end, so a release re-imported under the
  same key re-registers the same rows rather than duplicating them.
  """

  alias GeoGenius.{Catalog, Context, Manifest}

  @doc """
  Registers `manifest` and returns the id of the release it opened.

  Every authority the manifest declares is registered, not only the first: a
  collection may key its areas under several, and `upsert_area` resolves an
  authority with `SELECT ... INTO STRICT`, so one missing here raises
  `:no_data_found` deep in normalization rather than at registration.
  """
  @spec register(Context.t(), Manifest.t()) :: Ecto.UUID.t()
  def register(%Context{} = context, %Manifest{} = manifest) do
    Catalog.upsert_collection(context, %{
      key: manifest.collection,
      name: manifest.collection_name || manifest.collection,
      description: manifest.description,
      requires_geometry: manifest.requires_geometry
    })

    Enum.each(manifest.authorities, &Catalog.upsert_authority(context, manifest.collection, &1))
    Enum.each(manifest.area_types, &Catalog.upsert_area_type(context, manifest.collection, &1))

    release_id =
      Catalog.open_release(context, manifest.collection, %{
        release_key: manifest.release,
        manifest: Manifest.to_map(manifest),
        source_date: manifest.source_date
      })

    Enum.each(manifest.sources, &register_source(context, manifest.collection, release_id, &1))
    release_id
  end

  defp register_source(context, collection_key, release_id, source) do
    Catalog.upsert_source(context, collection_key, %{
      source_key: source.source_key,
      provider: source.provider,
      license: source.license
    })

    source_release_id =
      Catalog.upsert_source_release(context, collection_key, %{
        source_key: source.source_key,
        release_key: source.release_key,
        source_date: source.source_date,
        metadata: %{}
      })

    Catalog.attach_source_release(context, release_id, source_release_id)
    Enum.each(source.artifacts, &register_artifact(context, source_release_id, &1))
  end

  defp register_artifact(context, source_release_id, artifact) do
    Catalog.put_artifact(context, source_release_id, %{
      logical_name: artifact.logical_name,
      url: artifact.url,
      operator_supplied: artifact.operator_supplied,
      format: artifact.format,
      expected_sha256: artifact.sha256,
      expected_bytes: artifact.bytes,
      metadata: artifact_metadata(artifact)
    })
  end

  # `members` and `required` are top-level fields on `%Manifest.Artifact{}`,
  # not entries in its own `metadata` map, so preserving them on the stored
  # row means folding them in here -- `put_artifact/3` takes one `:metadata`
  # map. Neither has a reader in this codebase today: `Artifacts.required?/2`
  # consults `state.manifest_artifacts`, the manifest held in memory for the
  # run, not this row; `Providers.Shapefile` derives its archive members by
  # unzipping rather than reading them back. They are stored for data
  # completeness -- a reader working from the catalog alone, with no manifest
  # or archive at hand, still finds them -- not because anything consumes
  # them yet. `Map.merge` over `artifact.metadata` rather than a fresh map is
  # what keeps a manifest-supplied `cache_key` (already inside
  # `artifact.metadata`, placed there by `Manifest.build_artifact/1`) on the
  # row alongside them.
  defp artifact_metadata(%Manifest.Artifact{} = artifact) do
    Map.merge(artifact.metadata || %{}, %{
      "members" => artifact.members,
      "required" => artifact.required
    })
  end
end
