defmodule GeoGenius.ReleaseArtifactsTest do
  @moduledoc """
  Pins the artifact-resolution seam a host builds a projection on.

  A projection is a host-owned table keyed `(release_id, area_key)`, populated
  from the same files the import consumed. Finding those files is library
  knowledge: an artifact lives in the cache, under a key the manifest either
  supplied or the catalog derives, and an operator-supplied artifact carries no
  `url` to fall back on. A resolver that read from `priv/` instead of the cache
  would still pass every test that hands a fixture path straight in, so every
  case here seeds a cache root of its own and asserts the resolved path is
  inside it.
  """
  use ExUnit.Case, async: false

  alias GeoGenius.ArtifactError
  alias GeoGenius.Catalog
  alias GeoGenius.Context
  alias GeoGenius.ImportFixture
  alias GeoGenius.Manifest
  alias GeoGenius.Registration
  alias GeoGenius.ReleaseArtifacts
  alias GeoGenius.Stores.Postgres
  alias GeoGenius.TestRepo

  @downloaded "downloaded.dat"
  @supplied "supplied.dat"
  @absent "absent.dat"
  @second_only "second_only.dat"

  setup do
    unique = System.unique_integer([:positive])
    collection = "release_artifacts_test_#{unique}"
    cache_dir = Path.join(System.tmp_dir!(), "geo_genius_release_artifacts_#{unique}")

    on_exit(fn ->
      ImportFixture.teardown!(collection)
      File.rm_rf!(cache_dir)
    end)

    context = Context.new(repo: TestRepo, prefix: "geo_genius")
    opts = [repo: TestRepo, prefix: "geo_genius", cache_dir: cache_dir]

    {:ok, collection: collection, context: context, opts: opts, cache_dir: cache_dir}
  end

  describe "path/3" do
    test "resolves an operator-supplied artifact through the cache key its manifest gave it",
         %{collection: collection, context: context, opts: opts, cache_dir: cache_dir} do
      publish_release!(context, collection)
      seeded = seed_cache!(cache_dir, supplied_key(collection), body(@supplied))

      assert {:ok, path} = ReleaseArtifacts.path(collection, @supplied, opts)
      assert path == seeded
      assert File.read!(path) == body(@supplied)
    end

    test "resolves a downloaded artifact through the key the import cached it under",
         %{collection: collection, context: context, opts: opts, cache_dir: cache_dir} do
      publish_release!(context, collection)
      seeded = seed_cache!(cache_dir, derived_key(collection, @downloaded), body(@downloaded))

      assert {:ok, path} = ReleaseArtifacts.path(collection, @downloaded, opts)
      assert path == seeded
    end

    test "reports an artifact with no local file as a typed error naming the path and the key",
         %{collection: collection, context: context, opts: opts, cache_dir: cache_dir} do
      publish_release!(context, collection)

      assert {:error, %ArtifactError{} = error} =
               ReleaseArtifacts.path(collection, @absent, opts)

      assert error.reason == :not_cached
      assert error.logical_name == @absent
      assert error.cache_key == absent_key(collection)
      assert error.path == Path.join(cache_dir, absent_key(collection))
      assert Exception.message(error) =~ error.path
      assert Exception.message(error) =~ error.cache_key
    end

    test "reports a logical name the release does not compose",
         %{collection: collection, context: context, opts: opts} do
      publish_release!(context, collection)

      assert {:error, %ArtifactError{reason: :unknown_artifact} = error} =
               ReleaseArtifacts.path(collection, "nothing.dat", opts)

      assert error.logical_name == "nothing.dat"
      assert Exception.message(error) =~ @supplied
    end
  end

  describe "list/2" do
    test "returns every artifact of the published release, with where each one resolves",
         %{collection: collection, context: context, opts: opts, cache_dir: cache_dir} do
      publish_release!(context, collection)
      seed_cache!(cache_dir, supplied_key(collection), body(@supplied))

      assert {:ok, artifacts} = ReleaseArtifacts.list(collection, opts)
      names = Enum.map(artifacts, & &1.logical_name)

      # Which artifacts came back is what this case is really pinning. The
      # ordering below restates the documented contract, but it cannot fail on
      # its own: `artifact_logical_name_key` returns rows in logical-name order
      # whether or not the read asks for it, which is exactly why the ORDER BY
      # lives in `Catalog.release_artifacts/2` rather than in a sort here.
      assert Enum.sort(names) == [@absent, @downloaded, @supplied]
      assert names == Enum.sort(names)

      supplied = Enum.find(artifacts, &(&1.logical_name == @supplied))
      assert supplied.cache_key == supplied_key(collection)
      assert supplied.path == Path.join(cache_dir, supplied_key(collection))
      assert supplied.present?
      assert supplied.operator_supplied
      assert is_nil(supplied.url)

      downloaded = Enum.find(artifacts, &(&1.logical_name == @downloaded))
      assert downloaded.cache_key == derived_key(collection, @downloaded)
      refute downloaded.present?
      assert downloaded.url == "https://example.invalid/downloaded.dat"
    end

    test "refuses a collection that has published nothing",
         %{collection: collection, context: context, opts: opts} do
      register!(context, collection, "r1", [@supplied])

      assert {:error, %ArtifactError{reason: :no_published_release} = error} =
               ReleaseArtifacts.list(collection, opts)

      assert error.collection_key == collection
    end

    test "reads the release :release_id names, published or not",
         %{collection: collection, context: context, opts: opts} do
      publish_release!(context, collection)
      second = register!(context, collection, "r2", [@second_only])

      assert {:ok, published} = ReleaseArtifacts.list(collection, opts)
      refute Enum.any?(published, &(&1.logical_name == @second_only))

      assert {:ok, named} = ReleaseArtifacts.list(collection, [{:release_id, second} | opts])
      assert Enum.map(named, & &1.logical_name) == [@second_only]
      assert Enum.all?(named, &(&1.release_id == second))
    end

    test "refuses a :release_id the catalog does not carry",
         %{collection: collection, context: context, opts: opts} do
      publish_release!(context, collection)
      stale = Ecto.UUID.generate()

      assert {:error, %ArtifactError{reason: :unknown_release} = error} =
               ReleaseArtifacts.list(collection, [{:release_id, stale} | opts])

      assert error.release_id == stale
      assert error.collection_key == collection
      assert Exception.message(error) =~ stale
    end

    test "refuses a :release_id that is not a uuid at all",
         %{collection: collection, context: context, opts: opts} do
      publish_release!(context, collection)

      assert {:error, %ArtifactError{reason: :unknown_release} = error} =
               ReleaseArtifacts.list(collection, [{:release_id, "not-a-uuid"} | opts])

      assert error.release_id == "not-a-uuid"
    end

    test "refuses a :release_id belonging to another collection",
         %{collection: collection, context: context, opts: opts} do
      publish_release!(context, collection)
      {other, other_release} = register_other!(context, collection)

      assert {:error, %ArtifactError{reason: :foreign_release} = error} =
               ReleaseArtifacts.list(collection, [{:release_id, other_release} | opts])

      assert error.collection_key == collection
      assert error.release_id == other_release
      assert Exception.message(error) =~ other
    end

    test "refuses an artifact row whose stored cache key is not a string",
         %{collection: collection, context: context, opts: opts} do
      publish_release!(context, collection)

      TestRepo.query!(
        "UPDATE geo_genius.artifact SET metadata = $1 WHERE logical_name = $2",
        [%{"cache_key" => 12}, @supplied]
      )

      assert {:error, %ArtifactError{reason: :invalid_cache_key} = error} =
               ReleaseArtifacts.list(collection, opts)

      assert error.logical_name == @supplied
      assert Exception.message(error) =~ "cache_key"
    end
  end

  describe "fetch/3" do
    test "says so plainly when the release composes no artifacts at all",
         %{collection: collection, context: context, opts: opts} do
      release_id = publish_release!(context, collection)

      TestRepo.query!(
        """
        DELETE FROM geo_genius.artifact
         WHERE source_release_id IN (
           SELECT source_release_id FROM geo_genius.release_source WHERE release_id = $1)
        """,
        [Postgres.dump_uuid(release_id)]
      )

      assert {:error, %ArtifactError{reason: :unknown_artifact} = error} =
               ReleaseArtifacts.fetch(collection, @supplied, opts)

      message = Exception.message(error)
      assert message =~ "composes no artifacts"
      refute String.ends_with?(message, "composes ")
    end
  end

  describe "cache_key/1" do
    test "derives a key from the catalog columns when the row supplies none" do
      row = %{
        "logical_name" => "places.csv",
        "collection_key" => "demo",
        "source_key" => "demo:places",
        "source_release_key" => "2026-01",
        "metadata" => %{}
      }

      assert ReleaseArtifacts.cache_key(row) == {:ok, "demo/demo:places/2026-01/places.csv"}
    end

    test "prefers the key the row carries over the one its columns would derive" do
      row = %{
        "logical_name" => "places.csv",
        "collection_key" => "demo",
        "source_key" => "demo:places",
        "source_release_key" => "2026-01",
        "metadata" => %{"cache_key" => "operator_drop/places.csv"}
      }

      assert ReleaseArtifacts.cache_key(row) == {:ok, "operator_drop/places.csv"}
    end

    test "refuses a carried key whose segments would escape the cache root" do
      row = %{
        "logical_name" => "places.csv",
        "metadata" => %{"cache_key" => "demo/../../secrets"}
      }

      assert {:error, detail} = ReleaseArtifacts.cache_key(row)
      assert detail =~ "segment"
    end
  end

  defp publish_release!(context, collection) do
    release_id = register!(context, collection, "r1", [@supplied, @downloaded, @absent])
    area_key = "#{collection}:territory:A"

    Catalog.upsert_area(context, collection, %{
      authority_key: collection,
      area_type_key: "territory",
      code: "A"
    })

    Catalog.put_area_name(context, area_key, %{name: "Alpha", kind: "official", locale: nil})

    TestRepo.query!(
      """
      SELECT geo_genius.put_area_in_release(
        $1, $2, ST_GeogFromText('POINT(0 0)'), '{}'::jsonb)
      """,
      [Postgres.dump_uuid(release_id), area_key]
    )

    Catalog.publish_release(context, release_id)
    release_id
  end

  # A second collection, torn down with the first, so a release id that is
  # perfectly valid but belongs somewhere else has somewhere else to be.
  defp register_other!(context, collection) do
    other = "#{collection}_other"
    ExUnit.Callbacks.on_exit({__MODULE__, other}, fn -> ImportFixture.teardown!(other) end)
    {other, register!(context, other, "r1", [@supplied])}
  end

  defp register!(context, collection, release_key, logical_names) do
    {:ok, manifest} = Manifest.from_map(manifest_map(collection, release_key, logical_names))
    Registration.register(context, manifest)
  end

  defp manifest_map(collection, release_key, logical_names) do
    %{
      "collection" => collection,
      "collection_name" => "Release Artifacts Test",
      "release" => release_key,
      "provider" => "geojson",
      "requires_geometry" => false,
      "source_date" => "2026-01-15",
      "authorities" => [%{"key" => collection, "name" => "Release Artifacts Operations"}],
      "area_types" => [%{"key" => "territory", "rank" => 100}],
      "sources" => [
        %{
          "source_key" => source_key(collection),
          "provider" => "geojson",
          "license" => "CC0-1.0",
          "release_key" => source_release_key(release_key),
          "source_date" => "2026-01-15",
          "artifacts" => Enum.map(logical_names, &artifact_map(collection, &1))
        }
      ],
      "options" => %{
        "code_property" => "territory_id",
        "name_property" => "territory_name",
        "area_type" => "territory"
      }
    }
  end

  # The downloaded artifact carries a url and no cache_key, so its key is the
  # one the catalog derives; both operator-supplied ones carry a key of their
  # own, which is the case a derived-key-only resolver gets wrong.
  defp artifact_map(_collection, @downloaded = logical_name) do
    logical_name
    |> base_artifact_map()
    |> Map.put("url", "https://example.invalid/#{logical_name}")
  end

  defp artifact_map(collection, logical_name) do
    logical_name
    |> base_artifact_map()
    |> Map.merge(%{
      "operator_supplied" => true,
      "cache_key" => "operator_drop/#{collection}/#{logical_name}"
    })
  end

  defp base_artifact_map(logical_name) do
    body = body(logical_name)

    %{
      "logical_name" => logical_name,
      "format" => "geojson",
      "required" => true,
      "sha256" => Base.encode16(:crypto.hash(:sha256, body), case: :lower),
      "bytes" => byte_size(body)
    }
  end

  defp seed_cache!(cache_dir, key, body) do
    path = Path.join(cache_dir, key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  defp body(logical_name), do: "bytes of #{logical_name}\n"

  defp source_key(collection), do: "#{collection}:vendor"

  # Each release of this collection gets a source release of its own, so the
  # two releases the :release_id case compares do not share one artifact set.
  defp source_release_key(release_key), do: "v_#{release_key}"

  defp derived_key(collection, logical_name) do
    Enum.join(
      [collection, source_key(collection), source_release_key("r1"), logical_name],
      "/"
    )
  end

  defp supplied_key(collection), do: "operator_drop/#{collection}/#{@supplied}"

  defp absent_key(collection), do: "operator_drop/#{collection}/#{@absent}"
end
