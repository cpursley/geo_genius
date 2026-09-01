defmodule GeoGenius.RegistrationTest do
  use ExUnit.Case, async: false

  alias GeoGenius.{CandidateError, Catalog, Context, ImportFixture, Manifest, Registration}

  setup context do
    if context[:catalog_translation] do
      :ok
    else
      collection = "registration_test_#{System.unique_integer([:positive])}"
      on_exit(fn -> ImportFixture.teardown!(collection) end)

      {:ok,
       context: Context.new(repo: GeoGenius.TestRepo, prefix: "geo_genius"),
       collection: collection}
    end
  end

  describe "prepare_import/3" do
    test "returns an enqueue decision with both identifiers for a new candidate", %{
      context: context,
      collection: collection
    } do
      manifest = manifest!(collection)

      assert {:enqueue,
              %{
                run_id: run_id,
                release_id: release_id,
                attempt: 1,
                reason: :registered
              }} = Registration.prepare_import(context, manifest, claim("owner-a"))

      assert is_binary(run_id)
      assert is_binary(release_id)
      assert Catalog.import_run(context, run_id).release_id == release_id
    end

    test "same-owner replay re-enqueues the same attempt", %{
      context: context,
      collection: collection
    } do
      manifest = manifest!(collection)

      assert {:enqueue, first} =
               Registration.prepare_import(context, manifest, claim("owner-a"))

      assert {:enqueue, second} =
               Registration.prepare_import(context, manifest, claim("owner-a"))

      assert second.reason == :same_owner
      assert second.run_id == first.run_id
      assert second.release_id == first.release_id
      assert second.attempt == first.attempt
    end

    test "completed unpublished candidates return existing instead of enqueue", %{
      context: context,
      collection: collection
    } do
      manifest = manifest!(collection)
      assert {:enqueue, first} = Registration.prepare_import(context, manifest, claim("owner-a"))
      ImportFixture.claim_executor!(context, first.run_id)

      # The registration branch under test starts from a historical terminal
      # fixture; completion validation itself is covered by the catalog and
      # pipeline suites.
      GeoGenius.TestRepo.query!(
        "UPDATE geo_genius.import_run SET status = 'completed', completed_at = now() WHERE id = $1",
        [Ecto.UUID.dump!(first.run_id)]
      )

      GeoGenius.TestRepo.query!("DELETE FROM geo_genius.import_run_lease WHERE run_id = $1", [
        Ecto.UUID.dump!(first.run_id)
      ])

      assert {:existing, existing} =
               Registration.prepare_import(context, manifest, claim("owner-b"))

      assert existing.reason == :completed
      assert existing.run_id == first.run_id
      assert existing.release_id == first.release_id
      assert existing.attempt == first.attempt
    end

    test "a different owner of a live attempt receives a structured refusal", %{
      context: context,
      collection: collection
    } do
      manifest = manifest!(collection)
      assert {:enqueue, first} = Registration.prepare_import(context, manifest, claim("owner-a"))

      assert {:error,
              %CandidateError{
                reason: :live_import,
                run_id: run_id,
                release_id: release_id
              }} = Registration.prepare_import(context, manifest, claim("owner-b"))

      assert run_id == first.run_id
      assert release_id == first.release_id
    end

    test "an identical failed candidate requires explicit retry", %{
      context: context,
      collection: collection
    } do
      manifest = manifest!(collection)
      assert {:enqueue, first} = Registration.prepare_import(context, manifest, claim("owner-a"))
      executor_id = ImportFixture.claim_executor!(context, first.run_id)

      :ok =
        Catalog.fail_import(context, first.run_id, executor_id, %{
          "reason" => "fixture failure"
        })

      assert {:error,
              %CandidateError{
                reason: :failed,
                run_id: run_id,
                release_id: release_id,
                message: message
              }} = Registration.prepare_import(context, manifest, claim("owner-b"))

      assert run_id == first.run_id
      assert release_id == first.release_id
      assert message =~ "GeoGenius.retry_failed/2"

      assert [%GeoGenius.ImportRun{run_id: ^run_id, attempt: 1, status: "failed"}] =
               Catalog.import_runs(context, collection)
    end
  end

  describe "retry_failed/4" do
    test "returns a new enqueue attempt for a corrected exact candidate", %{
      context: context,
      collection: collection
    } do
      original = manifest!(collection)
      assert {:enqueue, first} = Registration.prepare_import(context, original, claim("owner-a"))
      executor_id = ImportFixture.claim_executor!(context, first.run_id)

      :ok =
        Catalog.fail_import(context, first.run_id, executor_id, %{"reason" => "fixture failure"})

      corrected = corrected_manifest!(original)

      assert {:enqueue, retry} =
               Registration.retry_failed(context, first.run_id, corrected, claim("owner-b"))

      assert retry.reason == :retried
      assert retry.release_id == first.release_id
      assert retry.run_id != first.run_id
      assert retry.attempt == first.attempt + 1
    end

    test "returns a structured refusal when the target is not failed", %{
      context: context,
      collection: collection
    } do
      manifest = manifest!(collection)
      assert {:enqueue, first} = Registration.prepare_import(context, manifest, claim("owner-a"))

      assert {:error,
              %CandidateError{
                reason: :not_failed,
                run_id: run_id,
                release_id: release_id
              }} = Registration.retry_failed(context, first.run_id, manifest, claim("owner-b"))

      assert run_id == first.run_id
      assert release_id == first.release_id
    end
  end

  describe "translate/1" do
    @tag :catalog_translation
    test "returns an invalid-catalog-response error when required catalog fields are missing" do
      assert {:error,
              %CandidateError{
                reason: :invalid_catalog_response,
                release_id: nil,
                run_id: nil,
                message: message
              }} = Registration.translate(%{decision: "enqueue"})

      assert message =~ "invalid candidate lifecycle response"
      assert message =~ ~s(%{decision: "enqueue"})
    end

    @tag :catalog_translation
    test "returns an invalid-catalog-response error for a malformed catalog result" do
      malformed = {:unexpected, "catalog result"}

      assert {:error,
              %CandidateError{
                reason: :invalid_catalog_response,
                release_id: nil,
                run_id: nil,
                message: message
              }} = Registration.translate(malformed)

      assert message =~ "invalid candidate lifecycle response"
      assert message =~ inspect(malformed)
    end
  end

  defp claim(owner) do
    %{owner: owner, runner_backend: "registration-test", stale_after_seconds: 900}
  end

  defp corrected_manifest!(manifest) do
    corrected = Map.put(Manifest.to_map(manifest), "description", "Corrected release policy")

    {:ok, manifest} = Manifest.from_map(corrected)
    manifest
  end

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
        "area_types" => [
          %{"key" => "bounded_zone", "rank" => 100, "requires_geometry" => true},
          %{"key" => "metadata_record", "rank" => 200}
        ],
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
          "area_type" => "metadata_record"
        }
      })

    manifest
  end
end
