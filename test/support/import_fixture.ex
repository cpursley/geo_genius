defmodule GeoGenius.ImportFixture do
  @moduledoc """
  Registers a minimal, operator-supplied GeoJSON release and claims an import
  run against it.

  Runner tests hand a real run id to a `GeoGenius.Runner` backend and need the
  pipeline to actually complete without touching the network: the artifact is
  declared operator-supplied and seeded straight into the configured cache
  under its derived key, so `GeoGenius.Pipeline.Artifacts.download/1` finds it
  on a cache hit and never reaches for a downloader. That matters here because
  a runner's `enqueue/3` forwards only `%{publish: boolean()}` to
  `GeoGenius.Pipeline.execute/3` -- there is no channel for a test-only
  `:bodies` map the way `GeoGenius.StubDownloader` needs.
  """

  alias GeoGenius.Caches.FileSystem
  alias GeoGenius.Catalog
  alias GeoGenius.Context
  alias GeoGenius.Manifest
  alias GeoGenius.TestRepo

  @artifact Path.expand("artifacts/territories.geojson", __DIR__)

  @doc "The bytes of the seeded GeoJSON fixture."
  @spec body() :: binary()
  def body, do: File.read!(@artifact)

  @doc """
  Registers a one-source, one-artifact GeoJSON release and claims a run
  against it, seeding the artifact into the cache under its derived key so
  the run can complete with no downloader involved.

  `opts` accepts `:collection` and `:release` (each defaulting to a value
  unique to the call, so repeat calls in one test do not collide),
  `:owner` (default `"runner-fixture"`) and `:runner_backend` (default
  `"test"`), both forwarded to
  `Catalog.begin_or_resume_import/3`, and `:corrupt_artifact` (default
  `false`) -- when `true`, the cache is seeded with bytes that do not match
  the manifest's own checksum, so the run genuinely fails in the
  `"downloading"` phase instead of completing. That is how a caller drives a
  real, catalog-recorded failure through a runner without a stub provider.

  Registers an `on_exit/1` callback that removes the collection this call
  creates -- and everything cascading off it -- so a runner test leaves no
  row behind for `GeoGenius.PipelineTest`'s single-row catalog queries to
  trip over. This only works called from inside a running test.

  Returns `{collection, release_id, run_id}`.
  """
  @spec claim_run!(Context.t(), keyword()) :: {String.t(), Ecto.UUID.t(), Ecto.UUID.t()}
  def claim_run!(%Context{} = context, opts \\ []) do
    unique = System.unique_integer([:positive])
    collection = Keyword.get(opts, :collection, "runner_fixture_#{unique}")
    release_key = Keyword.get(opts, :release, "r#{unique}")
    corrupt? = Keyword.get(opts, :corrupt_artifact, false)

    # Registered before anything is written: `register!/2` creates the
    # collection with its very first statement, so a raise partway through
    # it -- or through `seed_cache!/2` -- still leaves a row only this
    # callback knows to remove. `teardown!/1` looks its releases up by
    # collection key rather than taking a captured id, so it has nothing to
    # be called with the wrong (or no) value for.
    ExUnit.Callbacks.on_exit({__MODULE__, collection}, fn -> teardown!(collection) end)

    {:ok, manifest} = Manifest.from_map(manifest_map(collection, release_key))
    release_id = register!(context, manifest)
    seed_cache!(manifest, corrupt?)

    run_id =
      Catalog.begin_or_resume_import(context, release_id, %{
        owner: Keyword.get(opts, :owner, "runner-fixture"),
        runner_backend: Keyword.get(opts, :runner_backend, "test"),
        stale_after_seconds: 300
      })

    {collection, release_id, run_id}
  end

  # Mirrors `geo_genius_test.demo_teardown()`'s order (`test/pgtap_support/fixtures.sql`):
  # release-scoped geometry lives in partitions that carry no cascade back to
  # `area`, and `publication`, `release_source`, and `source_release` each
  # carry a foreign key that does not cascade either. All four go before the
  # collection -- the rest (`release`, `source`, `import_run`, `area`, and so
  # on) cascades cleanly off that final delete.
  #
  # Looks its releases up by collection key rather than taking a captured
  # release id, so it works whether `claim_run!/2` finished, raised before
  # opening a release, or raised any time after: at most one collection row
  # ever carries this key, and a collection nothing created (`register!/2`
  # never ran) matches nothing here and deletes nothing, without erroring.
  #
  # Public so a caller that registers its own manifest without going through
  # `claim_run!/2` -- `GeoGenius.import/1`'s own test suite, which exercises
  # registration directly rather than through this fixture -- can reuse the
  # same cleanup instead of a second copy of this cascade order.
  @doc "Removes a collection and everything registered under it."
  @spec teardown!(String.t()) :: :ok
  def teardown!(collection) do
    Enum.each(release_ids(collection), fn dumped_release_id ->
      TestRepo.query!("SELECT geo_genius.drop_release_partitions($1)", [dumped_release_id])
    end)

    TestRepo.query!(
      """
      DELETE FROM geo_genius.publication
       WHERE collection_id IN (SELECT id FROM geo_genius.collection WHERE key = $1)
      """,
      [collection]
    )

    TestRepo.query!(
      """
      DELETE FROM geo_genius.release_source
       WHERE release_id IN (
         SELECT release.id
           FROM geo_genius.release
           JOIN geo_genius.collection ON collection.id = release.collection_id
          WHERE collection.key = $1
       )
      """,
      [collection]
    )

    TestRepo.query!(
      """
      DELETE FROM geo_genius.source_release
       WHERE source_id IN (
         SELECT source.id
           FROM geo_genius.source
           JOIN geo_genius.collection ON collection.id = source.collection_id
          WHERE collection.key = $1
       )
      """,
      [collection]
    )

    TestRepo.query!("DELETE FROM geo_genius.collection WHERE key = $1", [collection])
    :ok
  end

  defp release_ids(collection) do
    %Postgrex.Result{rows: rows} =
      TestRepo.query!(
        """
        SELECT release.id
          FROM geo_genius.release
          JOIN geo_genius.collection ON collection.id = release.collection_id
         WHERE collection.key = $1
        """,
        [collection]
      )

    Enum.map(rows, fn [id] -> id end)
  end

  defp register!(context, %Manifest{} = manifest) do
    Catalog.upsert_collection(context, %{
      key: manifest.collection,
      name: manifest.collection_name || manifest.collection,
      description: manifest.description,
      requires_geometry: manifest.requires_geometry
    })

    Catalog.upsert_authority(context, manifest.collection, manifest.authority)
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

  defp seed_cache!(%Manifest{} = manifest, corrupt?) do
    [source] = manifest.sources
    [artifact] = source.artifacts

    key =
      Enum.join(
        [manifest.collection, source.source_key, source.release_key, artifact.logical_name],
        "/"
      )

    path = FileSystem.path(key, [])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, if(corrupt?, do: "not the reviewed bytes", else: body()))
  end

  defp manifest_map(collection, release_key) do
    body = body()

    %{
      "collection" => collection,
      "collection_name" => "Runner Fixture",
      "release" => release_key,
      "provider" => "geojson",
      "requires_geometry" => false,
      "source_date" => "2026-01-15",
      "authority" => %{"key" => collection, "name" => "Runner Fixture Operations"},
      "area_types" => [%{"key" => "territory", "rank" => 100}],
      "sources" => [
        %{
          "source_key" => "#{collection}:territories",
          "provider" => "geojson",
          "license" => "CC0-1.0",
          "release_key" => release_key,
          "source_date" => "2026-01-15",
          "artifacts" => [
            %{
              "logical_name" => "territories.geojson",
              "operator_supplied" => true,
              "format" => "geojson",
              "required" => true,
              "sha256" => Base.encode16(:crypto.hash(:sha256, body), case: :lower),
              "bytes" => byte_size(body)
            }
          ]
        }
      ],
      "options" => %{
        "code_property" => "territory_id",
        "name_property" => "territory_name",
        "area_type" => "territory",
        "attribute_properties" => ["short_name", "population"]
      }
    }
  end
end
