defmodule GeoGenius.RegistrationTest do
  @moduledoc """
  Pins the catalog rows a manifest registers, through the one function both
  `GeoGenius.import/1` and the test fixtures call.

  Registration used to be written out four times -- once in `GeoGenius` and
  once more in each of three test helpers. A test registering through a copy
  cannot fail when the production line is wrong, which is how a manifest that
  registered only its first authority reached a green suite. These cases drive
  `GeoGenius.Registration.register/2` itself, so there is one implementation
  left to be wrong.
  """
  use ExUnit.Case, async: false

  alias GeoGenius.{Context, ImportFixture, Manifest, Registration, TestRepo}

  setup do
    collection = "registration_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> ImportFixture.teardown!(collection) end)

    context = Context.new(repo: GeoGenius.TestRepo, prefix: "geo_genius")
    {:ok, context: context, collection: collection}
  end

  describe "register/2" do
    test "registers every authority the manifest declares, not just the first",
         %{context: context, collection: collection} do
      manifest = manifest!(collection)

      Registration.register(context, manifest)

      assert authority_keys(collection) == ["census", "simplemaps", "usps"]
    end

    test "merges members and required into each artifact's metadata",
         %{context: context, collection: collection} do
      manifest = manifest!(collection)

      Registration.register(context, manifest)

      assert %{"members" => [], "required" => true} = artifact_metadata(collection)
    end

    test "returns the id of the release it opened",
         %{context: context, collection: collection} do
      manifest = manifest!(collection)

      release_id = Registration.register(context, manifest)

      assert release_id == sole_release_id(collection)
    end

    test "is idempotent, so re-registering the same manifest adds no rows",
         %{context: context, collection: collection} do
      manifest = manifest!(collection)

      first = Registration.register(context, manifest)
      second = Registration.register(context, manifest)

      assert first == second
      assert authority_keys(collection) == ["census", "simplemaps", "usps"]
    end
  end

  # Three authorities so a single-authority regression is visible, and one
  # artifact carrying `required` so the metadata merge is visible.
  defp manifest!(collection) do
    {:ok, manifest} =
      Manifest.from_map(%{
        "collection" => collection,
        "collection_name" => "Registration Test",
        "release" => "r1",
        "provider" => "geojson",
        "requires_geometry" => false,
        "source_date" => "2026-01-15",
        "authorities" => [
          %{"key" => "simplemaps", "name" => "SimpleMaps"},
          %{"key" => "census", "name" => "US Census Bureau"},
          %{"key" => "usps", "name" => "US Postal Service"}
        ],
        "area_types" => [%{"key" => "territory", "rank" => 100}],
        "sources" => [
          %{
            "source_key" => "#{collection}:territories",
            "provider" => "geojson",
            "license" => "CC0-1.0",
            "release_key" => "2026-01",
            "source_date" => "2026-01-15",
            "artifacts" => [
              %{
                "logical_name" => "territories.geojson",
                "url" => "https://example.test/territories.geojson",
                "operator_supplied" => false,
                "format" => "geojson",
                "required" => true,
                "sha256" => String.duplicate("a", 64),
                "bytes" => 1024
              }
            ]
          }
        ],
        "options" => %{
          "code_property" => "territory_id",
          "name_property" => "territory_name",
          "area_type" => "territory"
        }
      })

    manifest
  end

  defp authority_keys(collection) do
    %{rows: rows} =
      TestRepo.query!(
        """
        SELECT authority.key
          FROM geo_genius.authority
          JOIN geo_genius.collection ON collection.id = authority.collection_id
         WHERE collection.key = $1
         ORDER BY authority.key
        """,
        [collection]
      )

    Enum.map(rows, fn [key] -> key end)
  end

  defp artifact_metadata(collection) do
    %{rows: [[metadata]]} =
      TestRepo.query!(
        """
        SELECT artifact.metadata
          FROM geo_genius.artifact
          JOIN geo_genius.source_release ON source_release.id = artifact.source_release_id
          JOIN geo_genius.source ON source.id = source_release.source_id
          JOIN geo_genius.collection ON collection.id = source.collection_id
         WHERE collection.key = $1
        """,
        [collection]
      )

    metadata
  end

  defp sole_release_id(collection) do
    %{rows: [[release_id]]} =
      TestRepo.query!(
        """
        SELECT release.id::text
          FROM geo_genius.release
          JOIN geo_genius.collection ON collection.id = release.collection_id
         WHERE collection.key = $1
        """,
        [collection]
      )

    release_id
  end
end
