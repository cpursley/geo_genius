defmodule GeoGenius.Providers.SimpleMaps.ValidationTest do
  use ExUnit.Case, async: false

  alias GeoGenius.AppEnv
  alias GeoGenius.Catalog
  alias GeoGenius.Context
  alias GeoGenius.ImportFixture
  alias GeoGenius.ImportRun
  alias GeoGenius.Manifest
  alias GeoGenius.Pipeline
  alias GeoGenius.Providers.SimpleMaps
  alias GeoGenius.Providers.SimpleMaps.Validation
  alias GeoGenius.Staging
  alias GeoGenius.TestRepo

  @cities Path.expand("../../../support/fixtures/simplemaps/uscities_sample.csv", __DIR__)
  @zips Path.expand("../../../support/fixtures/simplemaps/uszips_sample.csv", __DIR__)

  test "a primary county_fips missing from county_fips_all fails" do
    payload = %{city_payload() | "county_fips" => "06037", "county_fips_all" => "06075"}

    assert {:error, message} = Validation.check(row("uscities", payload))
    assert message =~ "county_fips 06037"
    assert message =~ "county_fips_all"
  end

  test "county_fips_all and county_name_all of differing length fails" do
    # Kansas City's real primary is "29095" (Jackson), so the shortened list
    # below still carries its primary and the failure is the length
    # mismatch this test is about, not the primary-inclusion rule.
    payload = %{
      city_payload("Kansas City")
      | "county_fips_all" => "29095|29037",
        "county_name_all" => "Jackson"
    }

    assert {:error, message} = Validation.check(row("uscities", payload))
    assert message =~ "2 county FIPS"
    assert message =~ "1 county name"
  end

  test "a zip whose county_weights keys differ from its county set fails" do
    payload = %{
      zip_payload()
      | "county_fips_all" => "06037",
        "county_weights" => ~s({"06075": 100})
    }

    assert {:error, message} = Validation.check(row("uszips", payload))
    assert message =~ "county_weights"
  end

  test "a county_weights that is not valid JSON fails" do
    payload = %{zip_payload() | "county_weights" => ~s({"06037": )}

    assert {:error, message} = Validation.check(row("uszips", payload))
    assert message =~ "county_weights"
    assert message =~ "could not be parsed"
  end

  test "a county_weights that decodes to something other than an object fails" do
    payload = %{zip_payload() | "county_weights" => "[1, 2]"}

    assert {:error, message} = Validation.check(row("uszips", payload))
    assert message =~ "county_weights"
    assert message =~ "did not decode to an object"
  end

  # The one self-contradiction the pairing rules cannot see: two blank
  # columns are an equal, zero length, and a blank `county_fips` is skipped,
  # so this row passes every other rule and then normalizes into a city filed
  # directly under its state, a tier above where it belongs. The rule rests
  # on the measurement: every one of the file's 109,071 rows names a county.
  test "a uscities row naming no county fails" do
    payload = %{
      city_payload()
      | "county_fips" => "",
        "county_fips_all" => "",
        "county_name_all" => ""
    }

    assert {:error, message} = Validation.check(row("uscities", payload))
    assert message =~ "county_fips_all names no county"
    assert message =~ "city=Los Angeles"
  end

  # A military APO ZIP delivers to an overseas address in no US county, so
  # its county columns and its `county_weights` are all blank. 617 of the
  # real file's 41,551 rows look like this; failing them would abort a real
  # import on the first one.
  test "a uszips row naming no county passes" do
    payload = zip_payload("09002")

    assert payload["county_fips_all"] == ""
    assert payload["county_weights"] == ""
    assert payload["military"] == "TRUE"

    assert Validation.check(row("uszips", payload)) == :ok
  end

  # The other side of the same column: counties are named and their weights
  # have vanished, which no sound row looks like.
  test "a uszips row naming counties with blank county_weights fails" do
    payload = %{zip_payload() | "county_weights" => ""}

    assert {:error, message} = Validation.check(row("uszips", payload))
    assert message =~ "county_weights is blank"
    assert message =~ "06037"
  end

  # The fourth combination of the two columns, and the only one with no rule
  # of its own: no counties named, yet weights naming one. It fails through
  # the set comparison, since an empty county set does not match a populated
  # weights map.
  test "a uszips row with no counties but populated county_weights fails" do
    payload = %{
      zip_payload()
      | "county_fips" => "",
        "county_fips_all" => "",
        "county_names_all" => ""
    }

    assert {:error, message} = Validation.check(row("uszips", payload))
    assert message =~ "county_weights keys"
  end

  # Not decoration: without this, `check/1` returning `{:error, ...}`
  # unconditionally would pass every test above it.
  test "a well-formed row passes" do
    assert Validation.check(row("uscities", city_payload())) == :ok
    assert Validation.check(row("uszips", zip_payload())) == :ok
  end

  test "a county_fips that is blank is not checked against county_fips_all" do
    payload = %{city_payload() | "county_fips" => ""}

    assert Validation.check(row("uscities", payload)) == :ok
  end

  test "an artifact this provider does not parse is not this module's concern" do
    assert Validation.check(%Staging.Row{artifact: "uscounties", payload: %{}, geom: nil}) == :ok
  end

  describe "an import staged with one contradictory row" do
    test "halts in normalizing and records the reason on the run's error column" do
      collection = "simplemaps_validation_e2e_#{System.unique_integer([:positive])}"
      url = "https://example.test/#{collection}/uszips.csv"
      body = invalid_uszips_csv()

      context =
        Context.new(repo: TestRepo, prefix: "geo_genius", downloader: GeoGenius.StubDownloader)

      AppEnv.put(:providers, %{"simplemaps" => SimpleMaps})

      on_exit(fn -> ImportFixture.teardown!(collection) end)

      {:ok, manifest} = Manifest.from_map(uszips_manifest_map(collection, url, body))
      release_id = register!(context, manifest)

      run_id =
        Catalog.begin_or_resume_import(context, release_id, %{
          owner: "validation-e2e",
          runner_backend: "test",
          stale_after_seconds: 300
        })

      unique = System.unique_integer([:positive])
      cache_dir = Path.join(System.tmp_dir!(), "gg_validation_e2e_cache_#{unique}")
      work_dir = Path.join(System.tmp_dir!(), "gg_validation_e2e_work_#{unique}")
      on_exit(fn -> File.rm_rf(cache_dir) && File.rm_rf(work_dir) end)

      opts = [bodies: %{url => body}, cache_dir: cache_dir, work_dir: work_dir]

      assert {:error, %ImportRun{} = run} = Pipeline.execute(context, run_id, opts)

      assert run.status == "failed"
      assert run.error["phase"] == "normalizing"
      assert run.error["reason"] =~ "county_weights"
    end
  end

  # Mirrors the shape `Manifest.from_map/1` expects: the JSON-shaped document
  # a manifest file itself carries, one source with the single artifact this
  # test needs staged.
  defp uszips_manifest_map(collection, url, body) do
    %{
      "collection" => collection,
      "collection_name" => "SimpleMaps Validation Fixture",
      "release" => "r1",
      "provider" => "simplemaps",
      "requires_geometry" => false,
      "source_date" => "2026-01-15",
      "authorities" => [%{"key" => "simplemaps", "name" => "SimpleMaps"}],
      "area_types" => [
        %{"key" => "state", "rank" => 10},
        %{"key" => "county", "rank" => 20},
        %{"key" => "zip", "rank" => 40}
      ],
      "sources" => [
        %{
          "source_key" => "#{collection}:uszips",
          "provider" => "simplemaps",
          "license" => "CC0-1.0",
          "release_key" => "r1",
          "source_date" => "2026-01-15",
          "artifacts" => [
            %{
              "logical_name" => "uszips",
              "url" => url,
              "operator_supplied" => false,
              "format" => "csv",
              "required" => true,
              "sha256" => Base.encode16(:crypto.hash(:sha256, body), case: :lower),
              "bytes" => byte_size(body)
            }
          ]
        }
      ],
      "options" => %{}
    }
  end

  # A minimal uszips document: a header and one row whose county_weights
  # names a county the row's own county_fips_all does not.
  defp invalid_uszips_csv do
    header =
      ~w(zip lat lng city state_id state_name county_fips county_name county_weights county_names_all county_fips_all)

    row = [
      "99999",
      "40.0",
      "-105.0",
      "Nowhere",
      "CO",
      "Colorado",
      "08001",
      "Adams",
      ~s({"08999": 100}),
      "Adams",
      "08001"
    ]

    Enum.join(header, ",") <> "\n" <> Enum.map_join(row, ",", &csv_field/1) <> "\n"
  end

  # RFC4180 quoting: every field quoted, with an embedded quote doubled --
  # the same shape a real SimpleMaps download carries for `county_weights`
  # values.
  defp csv_field(value), do: ~s("#{String.replace(value, "\"", "\"\"")}")

  # What `GeoGenius.import/1` does before it calls the pipeline, mirrored
  # here rather than driving that public entry point, since this test claims
  # a run directly the way `GeoGenius.PipelineTest` does.
  defp register!(context, %Manifest{} = manifest) do
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

    Enum.each(manifest.sources, &register_source!(context, manifest, release_id, &1))
    release_id
  end

  defp register_source!(context, manifest, release_id, source) do
    Catalog.upsert_source(context, manifest.collection, %{
      source_key: source.source_key,
      provider: source.provider,
      license: source.license
    })

    source_release_id =
      Catalog.upsert_source_release(context, manifest.collection, %{
        source_key: source.source_key,
        release_key: source.release_key,
        source_date: source.source_date,
        metadata: %{}
      })

    Catalog.attach_source_release(context, release_id, source_release_id)

    Enum.each(source.artifacts, fn artifact ->
      Catalog.put_artifact(context, source_release_id, %{
        logical_name: artifact.logical_name,
        url: artifact.url,
        operator_supplied: artifact.operator_supplied,
        format: artifact.format,
        expected_sha256: artifact.sha256,
        expected_bytes: artifact.bytes,
        metadata: artifact.metadata
      })
    end)
  end

  defp row(artifact, payload), do: %Staging.Row{artifact: artifact, payload: payload, geom: nil}

  defp city_payload(city \\ "Los Angeles"), do: staged_payload(@cities, "uscities", "city", city)
  defp zip_payload(zip \\ "90001"), do: staged_payload(@zips, "uszips", "zip", zip)

  # Payloads come from staging the real sample files rather than being
  # written by hand, so a payload this test mutates still starts from every
  # column a real row carries -- the same guarantee `SimpleMapsTest` relies
  # on for its own fixtures.
  defp staged_payload(path, artifact, column, value) do
    {:ok, rows} =
      collect(fn emit ->
        SimpleMaps.stage(manifest_fixture(), artifact_fixture(artifact), path, emit, [])
      end)

    Enum.find(rows, &(&1.payload[column] == value)).payload
  end

  defp collect(fun) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    emit = fn rows -> Agent.update(agent, &(&1 ++ rows)) end
    result = fun.(emit)
    {result, Agent.get(agent, & &1)}
  end

  defp manifest_fixture do
    %Manifest{
      collection: "simplemaps",
      release: "r1",
      provider: "simplemaps",
      authorities: [%{key: "simplemaps", name: "SimpleMaps"}],
      area_types: SimpleMaps.area_types(),
      sources: [],
      options: %{}
    }
  end

  defp artifact_fixture(logical_name) do
    %Manifest.Artifact{logical_name: logical_name, format: "csv", sha256: "x", bytes: 1}
  end
end
