defmodule GeoGenius.PublicIngestionTest do
  # Never sets `config :geo_genius, :repo` (or `:store`): every call below
  # passes `repo:`/`prefix:` explicitly. `Context.new/1`'s repo resolution
  # falls back to the configured default, `GeoGenius.SandboxedRepo`, which is
  # pooled through `Ecto.Adapters.SQL.Sandbox` in `:manual` mode and so raises
  # `DBConnection.OwnershipError` for a process holding no checked-out
  # connection. A function whose `Context.new(opts)` were replaced with
  # `Context.new([])` therefore fails on its very first call here, naming the
  # repo it wrongly fell back to, rather than quietly ignoring the option --
  # the discriminator "every one of the six functions honours :repo and
  # :prefix in opts" needs.
  use ExUnit.Case, async: false

  alias GeoGenius.AppEnv
  alias GeoGenius.Cache
  alias GeoGenius.Caches.FileSystem
  alias GeoGenius.Catalog
  alias GeoGenius.Context
  alias GeoGenius.ImportFixture
  alias GeoGenius.Manifest
  alias GeoGenius.RecordingNotifier
  alias GeoGenius.RecordingRepo
  alias GeoGenius.Runners
  alias GeoGenius.TestRepo

  defmodule NoopRunner do
    @moduledoc "A runner backend that claims to accept work but never runs it."
    @behaviour GeoGenius.Runner

    @impl GeoGenius.Runner
    def name, do: "noop"

    @impl GeoGenius.Runner
    def available?, do: true

    @impl GeoGenius.Runner
    def enqueue(_context, _run_id, _args), do: :ok
  end

  defmodule RecordingRunner do
    @moduledoc "A runner backend that records the args it was enqueued with, in the caller."
    @behaviour GeoGenius.Runner

    @impl GeoGenius.Runner
    def name, do: "recording"

    @impl GeoGenius.Runner
    def available?, do: true

    @impl GeoGenius.Runner
    def enqueue(_context, run_id, args) do
      send(self(), {:enqueued, run_id, args})
      :ok
    end
  end

  defmodule FailingRunner do
    @moduledoc "A runner backend that always refuses to accept work."
    @behaviour GeoGenius.Runner

    @impl GeoGenius.Runner
    def name, do: "failing"

    @impl GeoGenius.Runner
    def available?, do: true

    @impl GeoGenius.Runner
    def enqueue(_context, _run_id, _args), do: {:error, "refused to enqueue"}
  end

  @repo_opts [repo: TestRepo, prefix: "geo_genius"]

  setup do
    unique = System.unique_integer([:positive])
    cache_dir = Path.join(System.tmp_dir!(), "geo_genius_public_ingestion_cache_#{unique}")
    AppEnv.put(:cache_dir, cache_dir)
    on_exit(fn -> File.rm_rf(cache_dir) end)

    :ok
  end

  test "import/1 with the inline runner returns {:ok, run_id} for an already-completed run" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)
    seed_cache!(manifest)

    assert {:ok, run_id} =
             GeoGenius.import(
               Keyword.merge(@repo_opts, manifest: manifest, runner: Runners.Inline)
             )

    assert %GeoGenius.ImportRun{status: "completed"} = GeoGenius.status(run_id, @repo_opts)
  end

  test "registers the collection, authority, area types, source, source release, artifacts, " <>
         "and release-source link" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)

    assert {:ok, run_id} =
             GeoGenius.import(Keyword.merge(@repo_opts, manifest: manifest, runner: NoopRunner))

    release_id = GeoGenius.status(run_id, @repo_opts).release_id
    ctx = context()

    %Postgrex.Result{rows: [[name, description, requires_geometry]]} =
      TestRepo.query!(
        "SELECT name, description, requires_geometry FROM geo_genius.collection WHERE key = $1",
        [collection]
      )

    assert name == manifest.collection_name
    assert description == manifest.description
    assert requires_geometry == manifest.requires_geometry

    %Postgrex.Result{rows: [[authority_name]]} =
      TestRepo.query!(
        """
        SELECT authority.name FROM geo_genius.authority
        JOIN geo_genius.collection ON collection.id = authority.collection_id
        WHERE collection.key = $1 AND authority.key = $2
        """,
        [collection, hd(manifest.authorities).key]
      )

    assert authority_name == hd(manifest.authorities).name

    %Postgrex.Result{rows: [[rank]]} =
      TestRepo.query!(
        """
        SELECT area_type.rank FROM geo_genius.area_type
        JOIN geo_genius.collection ON collection.id = area_type.collection_id
        WHERE collection.key = $1 AND area_type.key = $2
        """,
        [collection, "territory"]
      )

    assert rank == 100

    # release_artifacts joins release_source -> source_release -> source ->
    # collection -> artifact with INNER JOINs throughout, so this coming back
    # non-empty proves upsert_source, upsert_source_release,
    # attach_source_release, and put_artifact all ran -- not just open_release
    # storing the manifest document.
    assert [artifact_row] = Catalog.release_artifacts(ctx, release_id)
    assert artifact_row["collection_key"] == collection
    assert artifact_row["source_key"] == "#{collection}:territories"
    assert artifact_row["source_release_key"] == release
    assert artifact_row["logical_name"] == "territories.geojson"
    assert artifact_row["format"] == "geojson"

    [%Manifest.Source{artifacts: [manifest_artifact]}] = manifest.sources
    assert artifact_row["expected_sha256"] == manifest_artifact.sha256
  end

  test "folds a manifest's members, required, and cache_key into the stored artifact's metadata" do
    {collection, release} = fresh_collection!()
    cache_key = "#{collection}/custom-cache-key"

    manifest =
      build_manifest(collection, release, %{
        "required" => false,
        "members" => ["territories.geojson", "territories.geojson.aux"],
        "cache_key" => cache_key
      })

    assert {:ok, run_id} =
             GeoGenius.import(Keyword.merge(@repo_opts, manifest: manifest, runner: NoopRunner))

    release_id = GeoGenius.status(run_id, @repo_opts).release_id
    assert [artifact_row] = Catalog.release_artifacts(context(), release_id)

    # None of the three is the struct default (`required: true`, `members:
    # []`, no `cache_key` at all), so a fold that hardcodes
    # `%{"members" => [], "required" => true}` fails here where it would
    # pass against the fixture's own defaults elsewhere in this file. And
    # `cache_key` already lives inside `%Manifest.Artifact{}.metadata`
    # before registration -- put there by `Manifest.build_artifact/1` -- so
    # a fold that replaces `metadata` outright instead of merging over it
    # drops `cache_key` while still getting `members` and `required` right;
    # this is the assertion that catches that.
    assert artifact_row["metadata"]["required"] == false

    assert artifact_row["metadata"]["members"] == [
             "territories.geojson",
             "territories.geojson.aux"
           ]

    assert artifact_row["metadata"]["cache_key"] == cache_key
  end

  test "importing the same release twice registers no duplicates" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)
    ctx = context()

    assert {:ok, run_id_1} =
             GeoGenius.import(Keyword.merge(@repo_opts, manifest: manifest, runner: NoopRunner))

    release_id_1 = GeoGenius.status(run_id_1, @repo_opts).release_id
    count_1 = length(Catalog.release_artifacts(ctx, release_id_1))

    assert {:ok, run_id_2} =
             GeoGenius.import(Keyword.merge(@repo_opts, manifest: manifest, runner: NoopRunner))

    release_id_2 = GeoGenius.status(run_id_2, @repo_opts).release_id
    count_2 = length(Catalog.release_artifacts(ctx, release_id_2))

    assert release_id_2 == release_id_1
    assert count_1 == 1
    assert count_2 == 1
  end

  test "an unknown collection or release returns a ManifestError rather than raising" do
    collection = "public_ingestion_nope_#{System.unique_integer([:positive])}"

    assert {:error, %GeoGenius.ManifestError{}} =
             GeoGenius.import(Keyword.merge(@repo_opts, collection: collection, release: "r1"))
  end

  test "an already-published release returns an error naming a new release key" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)
    seed_cache!(manifest)

    assert {:ok, _run_id} =
             GeoGenius.import(
               Keyword.merge(@repo_opts,
                 manifest: manifest,
                 runner: Runners.Inline,
                 publish: true
               )
             )

    assert {:error, exception} =
             GeoGenius.import(
               Keyword.merge(@repo_opts, manifest: manifest, runner: Runners.Inline)
             )

    assert %GeoGenius.CatalogError{} = exception
    assert exception.message =~ "new release key"
  end

  test "status/2 returns the run, and nil for an unknown run id" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)

    assert {:ok, run_id} =
             GeoGenius.import(Keyword.merge(@repo_opts, manifest: manifest, runner: NoopRunner))

    assert %GeoGenius.ImportRun{run_id: ^run_id} = GeoGenius.status(run_id, @repo_opts)
    assert GeoGenius.status(Ecto.UUID.generate(), @repo_opts) == nil
  end

  test "await/3 returns {:ok, run} immediately for an already-completed run" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)
    seed_cache!(manifest)

    assert {:ok, run_id} =
             GeoGenius.import(
               Keyword.merge(@repo_opts, manifest: manifest, runner: Runners.Inline)
             )

    assert {:ok, %GeoGenius.ImportRun{status: "completed"}} =
             GeoGenius.await(run_id, 5_000, @repo_opts)
  end

  test "await/3 returns {:error, run} for a failed run" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)
    seed_cache!(manifest, true)

    assert {:ok, run_id} =
             GeoGenius.import(
               Keyword.merge(@repo_opts, manifest: manifest, runner: Runners.Inline)
             )

    assert {:error, %GeoGenius.ImportRun{status: "failed"}} =
             GeoGenius.await(run_id, 5_000, @repo_opts)
  end

  test "await/3 returns {:error, :timeout} for a run that never finishes" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)

    assert {:ok, run_id} =
             GeoGenius.import(Keyword.merge(@repo_opts, manifest: manifest, runner: NoopRunner))

    assert GeoGenius.await(run_id, 300, @repo_opts) == {:error, :timeout}
  end

  test "publish/2 publishes a verified release and published_release/2 reflects it" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)
    seed_cache!(manifest)

    assert {:ok, run_id} =
             GeoGenius.import(
               Keyword.merge(@repo_opts, manifest: manifest, runner: Runners.Inline)
             )

    release_id = GeoGenius.status(run_id, @repo_opts).release_id
    assert GeoGenius.published_release(collection, @repo_opts) == nil

    assert {:ok, ^release_id} = GeoGenius.publish(release_id, @repo_opts)
    assert GeoGenius.published_release(collection, @repo_opts) == release_id
  end

  test "publish/2 on a release that fails verification returns an error and leaves " <>
         "publication unchanged" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)

    assert {:ok, run_id} =
             GeoGenius.import(Keyword.merge(@repo_opts, manifest: manifest, runner: NoopRunner))

    release_id = GeoGenius.status(run_id, @repo_opts).release_id

    # NoopRunner never runs the pipeline, so the release carries no areas --
    # verify_release fails it with "release contains no areas" before
    # publish_release ever updates the publication row.
    assert {:error, %GeoGenius.CatalogError{} = exception} =
             GeoGenius.publish(release_id, @repo_opts)

    assert exception.message =~ "no areas"
    assert GeoGenius.published_release(collection, @repo_opts) == nil
  end

  test "publish/2 reports a publication that committed even when the confirmation read fails" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)
    seed_cache!(manifest)

    assert {:ok, run_id} =
             GeoGenius.import(
               Keyword.merge(@repo_opts, manifest: manifest, runner: Runners.Inline)
             )

    release_id = GeoGenius.status(run_id, @repo_opts).release_id

    # The publication commits; only the collection-key read that follows it
    # fails, which is what a connection dying between the two looks like. A
    # rescue drawn around both reports the committed publication as an error
    # and drops the event.
    RecordingRepo.fail_on("SELECT manifest FROM")

    assert {:ok, ^release_id} =
             GeoGenius.publish(release_id,
               repo: RecordingRepo,
               prefix: "geo_genius",
               notifier: RecordingNotifier,
               test_pid: self()
             )

    assert_received {:notified, :release_published,
                     %{release_id: ^release_id, collection_key: nil}}

    assert GeoGenius.published_release(collection, @repo_opts) == release_id
  end

  test "publish/2 gives the publication statement a timeout, and :timeout overrides it" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)
    seed_cache!(manifest)

    assert {:ok, run_id} =
             GeoGenius.import(
               Keyword.merge(@repo_opts, manifest: manifest, runner: Runners.Inline)
             )

    release_id = GeoGenius.status(run_id, @repo_opts).release_id
    publish_opts = [repo: RecordingRepo, prefix: "geo_genius"]

    assert {:ok, ^release_id} = GeoGenius.publish(release_id, publish_opts)

    # `publish_release` re-runs `verify_release` inside itself, so on
    # DBConnection's fifteen-second default a release large enough to need
    # `Pipeline`'s timeout cannot be published at all.
    opts = RecordingRepo.options_for(RecordingRepo.recorded(), "publish_release")
    assert opts != nil, "no query recorded for publish_release"
    assert opts[:timeout] == 900_000

    assert {:ok, ^release_id} =
             GeoGenius.publish(release_id, Keyword.put(publish_opts, :timeout, 4_242))

    assert RecordingRepo.options_for(RecordingRepo.recorded(), "publish_release")[:timeout] ==
             4_242

    assert GeoGenius.published_release(collection, @repo_opts) == release_id
  end

  test "rollback/2 returns the previous release and published_release/2 reflects it" do
    {collection, release_a} = fresh_collection!()
    manifest_a = build_manifest(collection, release_a)
    seed_cache!(manifest_a)

    assert {:ok, run_a} =
             GeoGenius.import(
               Keyword.merge(@repo_opts,
                 manifest: manifest_a,
                 runner: Runners.Inline,
                 publish: true
               )
             )

    release_id_a = GeoGenius.status(run_a, @repo_opts).release_id

    release_b = "#{release_a}_b"
    manifest_b = build_manifest(collection, release_b)
    seed_cache!(manifest_b)

    assert {:ok, run_b} =
             GeoGenius.import(
               Keyword.merge(@repo_opts,
                 manifest: manifest_b,
                 runner: Runners.Inline,
                 publish: true
               )
             )

    release_id_b = GeoGenius.status(run_b, @repo_opts).release_id
    assert GeoGenius.published_release(collection, @repo_opts) == release_id_b

    assert {:ok, ^release_id_a} = GeoGenius.rollback(collection, @repo_opts)
    assert GeoGenius.published_release(collection, @repo_opts) == release_id_a
  end

  test "rollback/2 on a collection with no previous release returns an error" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)
    seed_cache!(manifest)

    assert {:ok, run_id} =
             GeoGenius.import(
               Keyword.merge(@repo_opts,
                 manifest: manifest,
                 runner: Runners.Inline,
                 publish: true
               )
             )

    release_id = GeoGenius.status(run_id, @repo_opts).release_id

    assert {:error, %GeoGenius.CatalogError{}} = GeoGenius.rollback(collection, @repo_opts)

    # A failed rollback must not have cleared or altered the publication.
    assert GeoGenius.published_release(collection, @repo_opts) == release_id
  end

  test "rollback/2 names the rollback as done when the confirmation read fails" do
    {collection, release_a} = fresh_collection!()
    manifest_a = build_manifest(collection, release_a)
    seed_cache!(manifest_a)

    assert {:ok, run_a} =
             GeoGenius.import(
               Keyword.merge(@repo_opts,
                 manifest: manifest_a,
                 runner: Runners.Inline,
                 publish: true
               )
             )

    release_id_a = GeoGenius.status(run_a, @repo_opts).release_id

    manifest_b = build_manifest(collection, "#{release_a}_b")
    seed_cache!(manifest_b)

    assert {:ok, run_b} =
             GeoGenius.import(
               Keyword.merge(@repo_opts,
                 manifest: manifest_b,
                 runner: Runners.Inline,
                 publish: true
               )
             )

    assert GeoGenius.status(run_b, @repo_opts).status == "completed"

    # The rollback commits; the read that names the release it rolled back to
    # is what fails. The publication moved either way, so the caller is told
    # that rather than told the rollback failed.
    RecordingRepo.fail_on("published_release($1)")

    # A shape of its own, not the plain string an unknown collection returns
    # and not the exception a failed rollback returns: a caller pattern
    # matching on it knows the publication moved and must not retry.
    assert {:error, {:unread, message}} =
             GeoGenius.rollback(collection,
               repo: RecordingRepo,
               prefix: "geo_genius",
               notifier: RecordingNotifier,
               test_pid: self()
             )

    assert message =~ "rolled collection"
    assert message =~ "but reading the release it now publishes failed"

    assert_received {:notified, :release_rolled_back,
                     %{collection_key: ^collection, release_id: nil}}

    assert GeoGenius.published_release(collection, @repo_opts) == release_id_a
  end

  test "import/1 forwards publish: true to the runner" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)
    seed_cache!(manifest)

    assert {:ok, run_id} =
             GeoGenius.import(
               Keyword.merge(@repo_opts,
                 manifest: manifest,
                 runner: Runners.Inline,
                 publish: true
               )
             )

    release_id = GeoGenius.status(run_id, @repo_opts).release_id
    assert GeoGenius.published_release(collection, @repo_opts) == release_id
  end

  test "import/1 puts :stale_after_seconds into the args a runner is enqueued with" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)

    assert {:ok, run_id} =
             GeoGenius.import(
               Keyword.merge(@repo_opts,
                 manifest: manifest,
                 runner: RecordingRunner,
                 stale_after_seconds: 120,
                 publish: true
               )
             )

    # Neither end of this chain was pinned before: an implementation that
    # built args without :stale_after_seconds -- or defaulted it away --
    # would still return {:ok, run_id} and pass every other case in this
    # file. Only reading back what the runner actually received catches it.
    assert_received {:enqueued, ^run_id, args}
    assert args.stale_after_seconds == 120
    assert args.publish == true
  end

  test "import/1 surfaces a runner's enqueue failure rather than {:ok, run_id}" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)

    assert {:error, "refused to enqueue"} =
             GeoGenius.import(
               Keyword.merge(@repo_opts, manifest: manifest, runner: FailingRunner)
             )
  end

  test "await/3 polls: observes a run that transitions to completed after the first read" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)

    assert {:ok, run_id} =
             GeoGenius.import(Keyword.merge(@repo_opts, manifest: manifest, runner: NoopRunner))

    ctx = context()

    Task.start(fn ->
      Process.sleep(150)
      Catalog.advance_import(ctx, run_id, "completed", %{})
    end)

    # A read-once implementation -- check the run once, and return
    # {:error, :timeout} immediately if it is not yet finished -- would see
    # "pending" at t=0 and never look again. Only genuine polling catches a
    # transition forced after the first read, comfortably inside this 2s
    # timeout.
    assert {:ok, %GeoGenius.ImportRun{status: "completed"}} =
             GeoGenius.await(run_id, 2_000, @repo_opts)
  end

  test "await/3 accepts :infinity without crashing and still observes a later transition" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)

    assert {:ok, run_id} =
             GeoGenius.import(Keyword.merge(@repo_opts, manifest: manifest, runner: NoopRunner))

    ctx = context()

    Task.start(fn ->
      Process.sleep(400)
      Catalog.advance_import(ctx, run_id, "completed", %{})
    end)

    # `timeout()` permits `:infinity`; `System.monotonic_time(:millisecond) +
    # :infinity` raises `ArithmeticError`, so a naive deadline computation
    # would crash this call instead of waiting.
    assert {:ok, %GeoGenius.ImportRun{status: "completed"}} =
             GeoGenius.await(run_id, :infinity, @repo_opts)
  end

  test "rollback/2 on an unknown collection returns an error rather than raising" do
    collection = "public_ingestion_no_such_collection_#{System.unique_integer([:positive])}"

    assert {:error, reason} = GeoGenius.rollback(collection, @repo_opts)
    assert reason =~ collection
  end

  test "an explicit :prefix reaches the SQL GeoGenius issues, not just a default that matches" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)

    assert {:ok, run_id} =
             GeoGenius.import(Keyword.merge(@repo_opts, manifest: manifest, runner: NoopRunner))

    # The default :prefix ("geo_genius") equals what every other test in
    # this file passes explicitly, so a function that silently ignored
    # :prefix would still pass every assertion elsewhere here. A prefix
    # naming a schema GeoGenius is not installed in forces the underlying
    # query to fail -- only possible if the schema qualifier in that SQL
    # actually came from the option.
    assert_raise GeoGenius.CatalogError, fn ->
      GeoGenius.status(run_id, repo: RecordingRepo, prefix: "public_ingestion_missing_schema")
    end

    recorded = RecordingRepo.recorded()

    assert Enum.any?(recorded, fn {sql, _opts} ->
             sql =~ ~s("public_ingestion_missing_schema".import_run_status)
           end)
  end

  test "every one of the six functions honours :repo and :prefix in opts" do
    {collection, release} = fresh_collection!()
    manifest = build_manifest(collection, release)
    seed_cache!(manifest)

    assert {:ok, run_id} =
             GeoGenius.import(
               Keyword.merge(@repo_opts,
                 manifest: manifest,
                 runner: Runners.Inline,
                 publish: true
               )
             )

    run = GeoGenius.status(run_id, @repo_opts)
    assert %GeoGenius.ImportRun{status: "completed"} = run
    release_id = run.release_id

    assert {:ok, %GeoGenius.ImportRun{status: "completed"}} =
             GeoGenius.await(run_id, 5_000, @repo_opts)

    assert GeoGenius.published_release(collection, @repo_opts) == release_id

    # publish/2 on an already-published release is a no-op success.
    assert {:ok, ^release_id} = GeoGenius.publish(release_id, @repo_opts)

    release_b = "#{release}_b"
    manifest_b = build_manifest(collection, release_b)
    seed_cache!(manifest_b)

    assert {:ok, run_b} =
             GeoGenius.import(
               Keyword.merge(@repo_opts,
                 manifest: manifest_b,
                 runner: Runners.Inline,
                 publish: true
               )
             )

    release_id_b = GeoGenius.status(run_b, @repo_opts).release_id
    assert GeoGenius.published_release(collection, @repo_opts) == release_id_b

    assert {:ok, ^release_id} = GeoGenius.rollback(collection, @repo_opts)
    assert GeoGenius.published_release(collection, @repo_opts) == release_id
  end

  defp context, do: Context.new(@repo_opts)

  defp fresh_collection! do
    unique = System.unique_integer([:positive])
    collection = "public_ingestion_#{unique}"
    release = "r#{unique}"

    ExUnit.Callbacks.on_exit({ImportFixture, collection}, fn ->
      ImportFixture.teardown!(collection)
    end)

    {collection, release}
  end

  defp build_manifest(collection, release, artifact_overrides \\ %{}) do
    body = ImportFixture.body()

    artifact =
      Map.merge(
        %{
          "logical_name" => "territories.geojson",
          "operator_supplied" => true,
          "format" => "geojson",
          "required" => true,
          "sha256" => Base.encode16(:crypto.hash(:sha256, body), case: :lower),
          "bytes" => byte_size(body)
        },
        artifact_overrides
      )

    {:ok, manifest} =
      Manifest.from_map(%{
        "collection" => collection,
        "collection_name" => "Public Ingestion Fixture",
        "description" => "Registration coverage for GeoGenius.import/1",
        "release" => release,
        "provider" => "geojson",
        "requires_geometry" => false,
        "source_date" => "2026-01-15",
        "authorities" => [%{"key" => collection, "name" => "Public Ingestion Ops"}],
        "area_types" => [%{"key" => "territory", "rank" => 100}],
        "sources" => [
          %{
            "source_key" => "#{collection}:territories",
            "provider" => "geojson",
            "license" => "CC0-1.0",
            "release_key" => release,
            "source_date" => "2026-01-15",
            "artifacts" => [artifact]
          }
        ],
        "options" => %{
          "code_property" => "territory_id",
          "name_property" => "territory_name",
          "area_type" => "territory",
          "attribute_properties" => ["short_name", "population"]
        }
      })

    manifest
  end

  defp seed_cache!(%Manifest{} = manifest, corrupt? \\ false) do
    [source] = manifest.sources
    [artifact] = source.artifacts

    key =
      Cache.key([
        manifest.collection,
        source.source_key,
        source.release_key,
        artifact.logical_name
      ])

    path = FileSystem.path(key, [])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, if(corrupt?, do: "not the reviewed bytes", else: ImportFixture.body()))
  end
end
