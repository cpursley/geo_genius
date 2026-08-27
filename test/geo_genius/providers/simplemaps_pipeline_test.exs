defmodule GeoGenius.Providers.SimpleMapsPipelineTest do
  @moduledoc """
  Drives both real SimpleMaps fixture files through `GeoGenius.import/1` and
  into the catalog, from the manifest this package ships.

  The shipped `us_simplemaps` manifest is the one place the authority set can
  be got wrong for every host at once, so these cases take their authorities,
  area types and options from it rather than from a manifest written here, and
  substitute only what a fixture run has to substitute: a collection key
  unique to the test, and the two artifacts, served from the repository's own
  samples instead of an operator's licensed files.

  Every other SimpleMaps case exercises `normalize/2` and `edges/1` as pure
  functions, which can see the authority key an `Area` carries but not whether
  a row exists for it: `upsert_area` resolves an authority with
  `SELECT ... INTO STRICT` and raises `:no_data_found` when the collection
  carries none. SimpleMaps keys its areas under three -- `simplemaps` for
  cities, `census` for counties and most states, `usps` for ZIPs and the six
  state codes the Census assigns no ANSI code -- so a registration that writes
  only one of them fails on the first county.

  The entry point is `GeoGenius.import/1` rather than
  `GeoGenius.Pipeline.execute/3` because registration is what these cases are
  about, and registration belongs to the caller that opens the release, not to
  the pipeline. `GeoGenius.Runners.Inline` runs `execute/3` in this process,
  so the run is already durable when `import/1` returns.
  """

  use ExUnit.Case, async: false

  alias GeoGenius.AppEnv
  alias GeoGenius.ImportFixture
  alias GeoGenius.ImportRun
  alias GeoGenius.Manifest
  alias GeoGenius.Providers.SimpleMaps
  alias GeoGenius.Runners
  alias GeoGenius.TestRepo

  @cities Path.expand("../../support/fixtures/simplemaps/uscities_sample.csv", __DIR__)
  @zips Path.expand("../../support/fixtures/simplemaps/uszips_sample.csv", __DIR__)

  @cities_url "https://example.test/simplemaps/uscities.csv"
  @zips_url "https://example.test/simplemaps/uszips.csv"

  @repo_opts [repo: TestRepo, prefix: "geo_genius"]

  # The manifest this package ships, found on the search path's last entry.
  @shipped_collection "us_simplemaps"
  @shipped_release "2026-01"

  # The three authorities the two files key areas under: cities under the
  # vendor's own identifiers, counties and most states under the Census, ZIPs
  # and the six non-ANSI state codes under the USPS.
  @authority_keys ["census", "simplemaps", "usps"]

  defmodule FixtureDownloader do
    @moduledoc """
    Serves the repository's own SimpleMaps samples over a URL.

    A runner forwards only `:publish` and `:stale_after_seconds` to
    `GeoGenius.Pipeline.execute/3`, so there is no channel for
    `GeoGenius.StubDownloader`'s `:bodies` map on a run started through
    `GeoGenius.import/1`. This resolves a URL to a file on disk instead, which
    needs no options at all.
    """

    @behaviour GeoGenius.Downloader

    @bodies %{
      "https://example.test/simplemaps/uscities.csv" =>
        Path.expand("../../support/fixtures/simplemaps/uscities_sample.csv", __DIR__),
      "https://example.test/simplemaps/uszips.csv" =>
        Path.expand("../../support/fixtures/simplemaps/uszips_sample.csv", __DIR__)
    }

    @impl GeoGenius.Downloader
    @spec available?() :: boolean()
    def available?, do: true

    @impl GeoGenius.Downloader
    @spec fetch(String.t(), Path.t(), keyword()) ::
            {:ok, %{bytes: non_neg_integer(), sha256: String.t()}} | {:error, String.t()}
    def fetch(url, destination, _opts) do
      case Map.fetch(@bodies, url) do
        {:ok, source} ->
          File.mkdir_p!(Path.dirname(destination))
          File.cp!(source, destination)
          body = File.read!(destination)

          {:ok,
           %{
             bytes: byte_size(body),
             sha256: Base.encode16(:crypto.hash(:sha256, body), case: :lower)
           }}

        :error ->
          {:error, "no SimpleMaps fixture is served at #{url}"}
      end
    end
  end

  setup do
    unique = System.unique_integer([:positive])
    collection = "simplemaps_pipeline_#{unique}"
    cache_dir = Path.join(System.tmp_dir!(), "geo_genius_simplemaps_cache_#{unique}")

    AppEnv.put(:cache_dir, cache_dir)
    AppEnv.put(:providers, %{"simplemaps" => SimpleMaps})

    on_exit(fn ->
      ImportFixture.teardown!(collection)
      File.rm_rf(cache_dir)
    end)

    {:ok, collection: collection}
  end

  describe "an import of both SimpleMaps files" do
    test "completes and writes areas under every authority its rows key them to",
         %{collection: collection} do
      run = import!(collection)

      assert run.status == "completed"
      assert ImportRun.succeeded?(run)
      assert run.error == nil

      counts = area_counts(collection)

      assert counts |> Map.keys() |> Enum.sort() == @authority_keys
      assert counts["simplemaps"] > 0
      assert counts["census"] > 0
      assert counts["usps"] > 0
    end

    test "keys each area type under the authority that defines its codes",
         %{collection: collection} do
      assert %ImportRun{status: "completed"} = import!(collection)

      pairs = authority_type_pairs(collection)

      assert {"simplemaps", "city"} in pairs
      assert {"census", "county"} in pairs
      assert {"census", "state"} in pairs
      assert {"usps", "zip"} in pairs

      # The Freely Associated States and the military mail constructs carry no
      # ANSI code, so they key under the USPS rather than the Census. The ZIP
      # sample carries 96941 (Pohnpei, FM), which is what puts a state there.
      assert {"usps", "state"} in pairs
    end
  end

  describe "the shipped us_simplemaps manifest" do
    test "loads from the package's own manifest directory" do
      manifest = Manifest.load!(@shipped_collection, @shipped_release)

      assert manifest.collection == @shipped_collection
      assert manifest.release == @shipped_release
      assert manifest.provider == "simplemaps"

      # SimpleMaps carries centroids and no boundaries, so a release built
      # from it has no area with a boundary and `verify_release` would refuse
      # every one of them.
      assert manifest.requires_geometry == false
    end

    test "declares every authority its rows key an area under" do
      manifest = Manifest.load!(@shipped_collection, @shipped_release)

      assert manifest.authorities |> Enum.map(& &1.key) |> Enum.sort() == @authority_keys
      assert Enum.all?(manifest.authorities, &(&1.name not in [nil, ""]))
    end

    test "declares the provider's own ranked hierarchy" do
      manifest = Manifest.load!(@shipped_collection, @shipped_release)

      assert manifest.area_types == SimpleMaps.area_types()
    end

    test "names both artifacts the provider parses, as operator-supplied files" do
      manifest = Manifest.load!(@shipped_collection, @shipped_release)

      artifacts = SimpleMaps.artifacts(manifest)

      assert Enum.map(artifacts, & &1.logical_name) == ["uscities", "uszips"]

      for artifact <- artifacts do
        assert artifact.operator_supplied
        assert artifact.url == nil
        assert artifact.format == "csv"
        assert artifact.metadata["cache_key"] =~ artifact.logical_name

        # `required` is what makes an absent operator-supplied file an error:
        # `GeoGenius.Pipeline.Artifacts` answers a missing one with
        # `{:ok, :missing}` when it is false, and a release built from neither
        # file completes with nothing in it.
        assert artifact.required
      end
    end
  end

  defp import!(collection) do
    manifest = build_manifest!(collection)

    opts =
      @repo_opts ++
        [manifest: manifest, runner: Runners.Inline, downloader: FixtureDownloader]

    assert {:ok, run_id} = GeoGenius.import(opts)
    assert {:ok, %ImportRun{} = run} = GeoGenius.await(run_id, 60_000, @repo_opts)
    run
  end

  defp area_counts(collection) do
    %Postgrex.Result{rows: rows} =
      TestRepo.query!(
        """
        SELECT authority.key, count(*)
          FROM geo_genius.area
          JOIN geo_genius.authority ON authority.id = area.authority_id
          JOIN geo_genius.collection ON collection.id = area.collection_id
         WHERE collection.key = $1
         GROUP BY authority.key
        """,
        [collection]
      )

    Map.new(rows, fn [key, count] -> {key, count} end)
  end

  defp authority_type_pairs(collection) do
    %Postgrex.Result{rows: rows} =
      TestRepo.query!(
        """
        SELECT DISTINCT authority.key, area_type.key
          FROM geo_genius.area
          JOIN geo_genius.authority ON authority.id = area.authority_id
          JOIN geo_genius.area_type ON area_type.id = area.area_type_id
          JOIN geo_genius.collection ON collection.id = area.collection_id
         WHERE collection.key = $1
        """,
        [collection]
      )

    Enum.map(rows, fn [authority, area_type] -> {authority, area_type} end)
  end

  # The shipped manifest with a unique collection key and the fixture source
  # in place of the operator-supplied one. Everything registration reads --
  # the authorities, the ranked area types, the provider -- is the shipped
  # document's, so a shipped manifest that declares fewer authorities than its
  # rows key areas under fails these cases at `upsert_area`, which resolves an
  # authority with `SELECT ... INTO STRICT`.
  defp build_manifest!(collection) do
    {:ok, manifest} =
      @shipped_collection
      |> Manifest.load!(@shipped_release)
      |> Manifest.to_map()
      |> Map.merge(%{
        "collection" => collection,
        "release" => "r1",
        "sources" => [fixture_source(collection)]
      })
      |> Manifest.from_map()

    manifest
  end

  # One source carrying both files, since both are one vendor release. The
  # shipped manifest's own artifacts are operator-supplied licensed downloads;
  # these are the repository's samples, served over a URL by
  # `FixtureDownloader`.
  defp fixture_source(collection) do
    %{
      "source_key" => "#{collection}:simplemaps",
      "provider" => "simplemaps",
      "license" => "LicenseRef-SimpleMaps",
      "attribution" => "SimpleMaps (simplemaps.com)",
      "release_key" => "r1",
      "source_date" => "2026-01-15",
      "artifacts" => [
        artifact_map("uscities", @cities_url, File.read!(@cities)),
        artifact_map("uszips", @zips_url, File.read!(@zips))
      ]
    }
  end

  defp artifact_map(logical_name, url, body) do
    %{
      "logical_name" => logical_name,
      "url" => url,
      "operator_supplied" => false,
      "format" => "csv",
      "required" => true,
      "sha256" => Base.encode16(:crypto.hash(:sha256, body), case: :lower),
      "bytes" => byte_size(body)
    }
  end
end
