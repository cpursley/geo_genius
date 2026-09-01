defmodule GeoGenius.PipelineTest do
  use ExUnit.Case, async: false

  alias GeoGenius.AppEnv
  alias GeoGenius.Caches.FileSystem
  alias GeoGenius.Catalog
  alias GeoGenius.Context
  alias GeoGenius.ExecutionGuardian
  alias GeoGenius.GraphFixture
  alias GeoGenius.ImportFixture
  alias GeoGenius.ImportRun
  alias GeoGenius.Manifest
  alias GeoGenius.Pipeline
  alias GeoGenius.Pipeline.Normalize
  alias GeoGenius.Pipeline.Relate
  alias GeoGenius.Pipeline.State
  alias GeoGenius.Provider.Area
  alias GeoGenius.Provider.Area.Name
  alias GeoGenius.Published
  alias GeoGenius.RecordingRepo
  alias GeoGenius.Staging
  alias GeoGenius.TestRepo

  import ExUnit.CaptureLog

  @artifact Path.expand("../support/artifacts/territories.geojson", __DIR__)
  @url "https://example.test/territories.geojson"
  @csv_url "https://example.test/places.csv"

  # One row per format, both naming code "A" under area type "place", so the
  # two sources converge on `demo:place:A`. Only the GeoJSON source carries a
  # geometry, so the converged area's boundary can only have come from it.
  @two_format_csv "code,name\nA,Alpha\n"

  # The four statements a national import can spend minutes inside, each
  # identified by a fragment of the SQL the catalog issues for it.
  @timed_statements [
    "insert_staging_many",
    "rebuild_relations",
    "analyze_import",
    "verify_import"
  ]

  # `Relate.relate/1` asks a provider only these two questions, so these carry
  # only them: they exist to differ in `relations/1` and nothing else.
  defmodule RebuildingProvider do
    @moduledoc false
    def relations(_manifest), do: :rebuild
    def asserted_relations(_manifest, _row), do: []
  end

  defmodule QuietProvider do
    @moduledoc false
    def relations(_manifest), do: :none
    def asserted_relations(_manifest, _row), do: []
  end

  defmodule PublishCommitLostReplyRepo do
    @moduledoc false

    def query(sql, params, opts \\ []) do
      result = GeoGenius.TestRepo.query(sql, params, opts)

      if sql =~ "publish_import" and Process.get({__MODULE__, :reply_lost?}) != true do
        Process.put({__MODULE__, :reply_lost?}, true)
        raise DBConnection.ConnectionError, "the publish committed but its reply was lost"
      end

      result
    end
  end

  defmodule CompleteCommitLostReplyRepo do
    @moduledoc false

    def query(sql, params, opts \\ []) do
      result = GeoGenius.TestRepo.query(sql, params, opts)

      if sql =~ "complete_import" and Process.get({__MODULE__, :reply_lost?}) != true do
        Process.put({__MODULE__, :reply_lost?}, true)
        raise DBConnection.ConnectionError, "the complete committed but its reply was lost"
      end

      result
    end
  end

  defmodule ClaimCommitLostReplyRepo do
    @moduledoc false

    def query(sql, params, opts \\ []) do
      result = GeoGenius.TestRepo.query(sql, params, opts)

      if sql =~ "claim_import_execution" and Process.get({__MODULE__, :reply_lost?}) != true do
        Process.put({__MODULE__, :reply_lost?}, true)
        raise "the executor claim committed but its reply was lost"
      end

      result
    end
  end

  defmodule ConvertingCommand do
    @moduledoc false
    @behaviour GeoGenius.Command

    @impl GeoGenius.Command
    def available?(_executable, _opts), do: true

    # Stands in for ogr2ogr: reports what it was asked to run and writes the
    # GeoJSON Sequence a real conversion would have produced.
    @impl GeoGenius.Command
    def run(executable, args, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:ran, executable, args})
      File.write!(Enum.at(args, -2), Keyword.fetch!(opts, :fixture))
      {:ok, ""}
    end
  end

  defmodule AssertingProvider do
    @moduledoc false
    @behaviour GeoGenius.Provider

    @impl true
    def required_options, do: []
    @impl true
    defdelegate artifacts(manifest), to: GeoGenius.Provider, as: :all_artifacts
    @impl true
    def stage(_manifest, _artifact, _path, _emit, _opts), do: :ok
    # Implemented directly rather than delegated to `always_rebuild/1`: the
    # relate-phase fixture drives `relate/1` with no manifest built, since
    # nothing on this path reads one.
    @impl true
    def relations(_manifest), do: :rebuild

    # Asserts one `contains` edge per row, from the row's parent state to its
    # child city, so a relate-phase test can pin both that the edge lands and
    # that it composes with `relations/1`'s `:rebuild`.
    @impl true
    def asserted_relations(_manifest, %{payload: %{"child" => child, "parent" => parent}}) do
      [{"demo_auth:state:#{parent}", "demo_auth:city:#{child}", "contains"}]
    end

    @impl true
    def normalize(_manifest, %{payload: %{"child" => child, "parent" => parent}}) do
      {:ok,
       [
         %Area{
           authority_key: "demo_auth",
           area_type_key: "city",
           code: child,
           centroid: nil,
           geometry: nil,
           names: [%Name{name: child, kind: :official}],
           codes: [],
           attributes: %{}
         },
         %Area{
           authority_key: "demo_auth",
           area_type_key: "state",
           code: parent,
           centroid: nil,
           geometry: nil,
           names: [%Name{name: parent, kind: :official}],
           codes: [],
           attributes: %{}
         }
       ]}
    end
  end

  setup do
    GraphFixture.teardown!()
    on_exit(&GraphFixture.teardown!/0)

    # `GeoGenius.areas_for_point/3` and its siblings build their own context
    # from application environment, and a manifest naming the stub provider
    # only resolves while that provider is registered.
    AppEnv.put(:repo, TestRepo)
    AppEnv.put(:providers, %{"stub" => GeoGenius.StubProvider})

    unique = System.unique_integer([:positive])
    cache_dir = Path.join(System.tmp_dir!(), "geo_genius_cache_#{unique}")
    work_dir = Path.join(System.tmp_dir!(), "geo_genius_work_#{unique}")

    on_exit(fn ->
      File.rm_rf(cache_dir)
      File.rm_rf(work_dir)
    end)

    context =
      Context.new(
        repo: TestRepo,
        prefix: "geo_genius",
        downloader: GeoGenius.StubDownloader,
        notifier: GeoGenius.RecordingNotifier
      )

    body = File.read!(@artifact)

    {:ok,
     context: context,
     cache_dir: cache_dir,
     work_dir: work_dir,
     body: body,
     opts: [
       cache_dir: cache_dir,
       work_dir: work_dir,
       bodies: %{@url => body},
       test_pid: self()
     ]}
  end

  describe "a full GeoJSON import" do
    test "reaches completed", %{context: context, opts: opts} = fixtures do
      {_manifest, _release_id, run_id} = prepare(fixtures)

      assert {:ok, %ImportRun{} = run} = Pipeline.execute(context, run_id, opts)
      assert run.status == "completed"
      assert ImportRun.succeeded?(run)
      assert run.completed_at != nil
      assert run.error == nil
    end

    test "executes the manifest snapshot claimed by the run", fixtures do
      {_manifest, release_id, run_id} = prepare(fixtures)

      TestRepo.query!(
        """
        UPDATE geo_genius.release
           SET manifest = jsonb_set(manifest, '{provider}', '"unregistered"'::jsonb)
         WHERE id = $1
        """,
        [Ecto.UUID.dump!(release_id)]
      )

      assert {:ok, %ImportRun{status: "completed"}} =
               Pipeline.execute(fixtures.context, run_id, fixtures.opts)
    end

    test "rejects an invalid manifest snapshot on the run", fixtures do
      {_manifest, _release_id, run_id} = prepare(fixtures)

      TestRepo.query!(
        "UPDATE geo_genius.import_run SET manifest = '{}'::jsonb WHERE id = $1",
        [Ecto.UUID.dump!(run_id)]
      )

      assert {:error, %ImportRun{} = run} =
               Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      assert run.status == "failed"
      assert run.error["phase"] == "pending"
      assert run.error["reason"] =~ "manifest"
    end

    test "lands the areas where a spatial read finds them", fixtures do
      {_manifest, release_id, run_id} = prepare(fixtures)

      assert {:ok, _run} = Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      assert [match] = GeoGenius.areas_for_point(0.5, 0.5, release_id: release_id)
      assert match.area_key == "demo:territory:west"
      assert match.name == "West Territory"

      assert [east] = GeoGenius.areas_for_point(1.5, 0.5, release_id: release_id)
      assert east.area_key == "demo:territory:east"
    end

    test "carries the attributes and the alias-free official name onto the area", fixtures do
      {_manifest, release_id, run_id} = prepare(fixtures)

      assert {:ok, _run} = Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      assert [match] = GeoGenius.areas_for_point(0.5, 0.5, release_id: release_id)
      assert match.attributes == %{"short_name" => "W", "population" => 1200}
    end

    test "lands a metadata-only feature with no boundary", fixtures do
      {_manifest, release_id, run_id} = prepare(fixtures)

      assert {:ok, run} = Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      assert [match] = GeoGenius.search_areas("Metadata Only", release_id: release_id)
      assert match.area_key == "demo:territory:nowhere"

      assert run.stage_metrics["area_count"] == 3
      assert run.stage_metrics["boundary_count"] == 2
    end

    # The single point where the Elixir composition and the SQL one are held
    # to each other. `GeoGenius.Provider.Area.key/1` is the only Elixir
    # statement of the format -- the pipeline and every provider compose keys
    # through it -- so the expected rows are built with it rather than written
    # out as literals, and a change to either side fails here.
    test "the derived area key is the one PostgreSQL stored", fixtures do
      {_manifest, _release_id, run_id} = prepare(fixtures)

      assert {:ok, _run} = Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      %Postgrex.Result{rows: rows} =
        TestRepo.query!(
          """
          SELECT area.area_key
            FROM geo_genius.area
            JOIN geo_genius.collection ON collection.id = area.collection_id
           WHERE collection.key = 'demo'
           ORDER BY area.area_key
          """,
          []
        )

      expected =
        for code <- ~w(east nowhere west) do
          [Area.key(%Area{authority_key: "demo", area_type_key: "territory", code: code})]
        end

      assert rows == expected

      assert rows == [
               ["demo:territory:east"],
               ["demo:territory:nowhere"],
               ["demo:territory:west"]
             ]
    end

    test "accumulates every phase's metrics onto the run", fixtures do
      {_manifest, _release_id, run_id} = prepare(fixtures)

      assert {:ok, run} = Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      assert run.stage_metrics == %{
               "artifacts" => 1,
               "downloaded" => 1,
               "cached" => 0,
               "bytes" => byte_size(fixtures.body),
               "required" => 1,
               "optional_missing" => 0,
               "staged" => 3,
               "areas" => 3,
               "boundaries" => 2,
               "skipped" => 0,
               "relations" => 0,
               "asserted_relations" => 0,
               "area_count" => 3,
               "boundary_count" => 2
             }
    end
  end

  describe "publication" do
    test "publish: false leaves the release unpublished", fixtures do
      {_manifest, _release_id, run_id} = prepare(fixtures)

      assert {:ok, _run} = Pipeline.execute(fixtures.context, run_id, fixtures.opts)
      assert Catalog.published_release(fixtures.context, "demo") == nil
    end

    test "publish: true publishes the release it just verified", fixtures do
      {_manifest, release_id, run_id} = prepare(fixtures)
      opts = Keyword.put(fixtures.opts, :publish, true)

      assert {:ok, run} = Pipeline.execute(fixtures.context, run_id, opts)
      assert run.status == "completed"
      assert Catalog.published_release(fixtures.context, "demo") == release_id

      assert_received {:notified, :release_published, %{release_id: ^release_id}}
    end

    test "a duplicate delivery returns a no-op and cannot replace the first executor's publish intent",
         fixtures do
      {_manifest, _release_id, run_id} = prepare(fixtures)
      first_executor = Ecto.UUID.generate()

      assert Catalog.claim_import_execution(fixtures.context, run_id, first_executor) == :claimed

      assert {:noop, %ImportRun{run_id: ^run_id, executor_id: ^first_executor}} =
               Pipeline.execute(
                 fixtures.context,
                 run_id,
                 Keyword.put(fixtures.opts, :publish, true)
               )

      assert Catalog.published_release(fixtures.context, "demo") == nil
      assert Catalog.import_run(fixtures.context, run_id).status == "pending"
      refute_received {:notified, :import_started, _payload}
      refute_received {:notified, :import_completed, _payload}
    end

    test "a lost executor-claim reply is resolved with the same executor identity", fixtures do
      {_manifest, _release_id, run_id} = prepare(fixtures)
      context = %{fixtures.context | repo: ClaimCommitLostReplyRepo}
      Process.delete({ClaimCommitLostReplyRepo, :reply_lost?})

      assert {:ok, %ImportRun{status: "completed"}} =
               Pipeline.execute(context, run_id, fixtures.opts)

      assert Catalog.import_run(fixtures.context, run_id).status == "completed"
    end

    test "a lost reply after non-publishing completion rereads completed instead of recording failure",
         fixtures do
      {_manifest, _release_id, run_id} = prepare(fixtures)
      context = %{fixtures.context | repo: CompleteCommitLostReplyRepo}
      Process.delete({CompleteCommitLostReplyRepo, :reply_lost?})

      assert {:ok, %ImportRun{status: "completed"}} =
               Pipeline.execute(context, run_id, fixtures.opts)

      assert Catalog.import_run(fixtures.context, run_id).status == "completed"
      refute_received {:notified, :import_failed, _payload}
    end

    test "a lost reply after atomic publication rereads completed instead of recording failure",
         fixtures do
      {_manifest, release_id, run_id} = prepare(fixtures)
      context = %{fixtures.context | repo: PublishCommitLostReplyRepo}
      Process.delete({PublishCommitLostReplyRepo, :reply_lost?})

      assert {:ok, %ImportRun{status: "completed"} = run} =
               Pipeline.execute(context, run_id, Keyword.put(fixtures.opts, :publish, true))

      assert run.release_id == release_id
      assert Catalog.published_release(fixtures.context, "demo") == release_id
      assert Catalog.import_run(fixtures.context, run_id).status == "completed"
      refute_received {:notified, :import_failed, _payload}
    end
  end

  describe "the artifact cache" do
    test "a cache hit skips the download entirely", fixtures do
      {manifest, _release_id, run_id} = prepare(fixtures)
      seed_cache!(fixtures, manifest, fixtures.body)

      # No bodies at all: a pipeline that downloads unconditionally has
      # nothing to fetch and fails.
      opts = Keyword.put(fixtures.opts, :bodies, %{})

      assert {:ok, run} = Pipeline.execute(fixtures.context, run_id, opts)
      assert run.stage_metrics["cached"] == 1
      assert run.stage_metrics["downloaded"] == 0
      refute_received {:downloaded, _url}

      assert observation() == {sha256(fixtures.body), byte_size(fixtures.body)}
    end

    test "a cache miss downloads once, and the next release reads the cached copy",
         fixtures do
      {_manifest, _release_id, first_run} = prepare(fixtures)

      assert {:ok, first} = Pipeline.execute(fixtures.context, first_run, fixtures.opts)
      assert first.stage_metrics["downloaded"] == 1
      assert_received {:downloaded, @url}

      # A download's own digest and `Downloader.hash_file/1`'s must agree:
      # both reach `record_artifact_observation/5`, which refuses a mismatch.
      assert observation() == {sha256(fixtures.body), byte_size(fixtures.body)}

      {_manifest, _second_release, second_run} = prepare(fixtures, release: "r2")

      assert {:ok, second} = Pipeline.execute(fixtures.context, second_run, fixtures.opts)
      assert second.stage_metrics["cached"] == 1
      assert second.stage_metrics["downloaded"] == 0
      refute_received {:downloaded, _url}
    end

    test "a checksum that contradicts the manifest fails the run in downloading",
         fixtures do
      {_manifest, _release_id, run_id} = prepare(fixtures)
      opts = Keyword.put(fixtures.opts, :bodies, %{@url => "not the reviewed bytes"})

      assert {:error, %ImportRun{} = run} = Pipeline.execute(fixtures.context, run_id, opts)
      assert run.status == "failed"
      assert run.error["phase"] == "downloading"
      assert run.error["reason"] =~ "territories.geojson"
      assert_received {:notified, :import_failed, %{phase: "downloading"}}
    end

    test "an operator-supplied artifact that is not in the cache names the key it looked under",
         fixtures do
      {_manifest, _release_id, run_id} = prepare(fixtures, operator_supplied: true)

      assert {:error, %ImportRun{} = run} =
               Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      assert run.error["phase"] == "downloading"
      assert run.error["reason"] =~ "demo/demo:territories/2026-01/territories.geojson"
    end

    test "an artifact whose manifest supplies a cache key is read from under that key",
         fixtures do
      {_manifest, _release_id, run_id} =
        prepare(fixtures, operator_supplied: true, cache_key: "operator/territories.geojson")

      # Only the supplied key holds the file. A pipeline that derives the key
      # regardless finds nothing and fails naming the derived one.
      seed_key!(fixtures, "operator/territories.geojson", fixtures.body)

      assert {:ok, run} = Pipeline.execute(fixtures.context, run_id, fixtures.opts)
      assert run.stage_metrics["cached"] == 1
      assert run.stage_metrics["staged"] == 3
    end

    test "a cached artifact whose bytes changed since it was validated fails the run",
         fixtures do
      {manifest, _release_id, first_run} = prepare(fixtures)
      assert {:ok, _run} = Pipeline.execute(fixtures.context, first_run, fixtures.opts)

      # The artifact row now carries a `validated_at`, and the cached file is
      # then swapped -- a truncated copy, a bad restore, another release's
      # bytes under the same key. Trusting `validated_at` would import this
      # silently, and every later run would too.
      seed_cache!(fixtures, manifest, "swapped bytes that nobody reviewed")

      {_manifest, _second_release, second_run} = prepare(fixtures, release: "r2")

      assert {:error, %ImportRun{} = run} =
               Pipeline.execute(fixtures.context, second_run, fixtures.opts)

      assert run.error["phase"] == "downloading"
      assert run.error["reason"] =~ "territories.geojson"
      assert run.error["reason"] =~ "does not match its manifest"
    end

    test "a cache key that is not a string fails the run naming the artifact", fixtures do
      {_manifest, _release_id, run_id} = prepare(fixtures)

      # `metadata` is jsonb, so its shape is whatever wrote the row rather than
      # whatever manifest validation accepted.
      TestRepo.query!("UPDATE geo_genius.artifact SET metadata = $1", [%{"cache_key" => 12}])

      assert {:error, %ImportRun{} = run} =
               Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      assert run.error["phase"] == "downloading"
      assert run.error["reason"] =~ "territories.geojson"
      assert run.error["reason"] =~ "cache_key"

      # Naming the artifact only happens if the shape was checked: splitting a
      # number raises a FunctionClauseError naming neither.
      refute Map.has_key?(run.error, "exception")
    end

    test "an optional artifact that is nowhere to be found is counted, not fatal",
         fixtures do
      {_manifest, _release_id, run_id} =
        prepare(fixtures, extra_artifacts: [optional_artifact()])

      assert {:ok, run} = Pipeline.execute(fixtures.context, run_id, fixtures.opts)
      assert run.status == "completed"
      assert run.stage_metrics["artifacts"] == 2
      assert run.stage_metrics["required"] == 1
      assert run.stage_metrics["optional_missing"] == 1
      assert run.stage_metrics["staged"] == 3
    end
  end

  describe "failure handling" do
    test "execute is idempotent for a completed run and starts no phases", fixtures do
      {_manifest, _release_id, run_id} = prepare(fixtures)
      executor_id = Ecto.UUID.generate()
      assert :claimed = Catalog.claim_import_execution(fixtures.context, run_id, executor_id)

      # This test starts from a terminal fixture to isolate execute/3's
      # idempotent read path from the completion operation itself.
      TestRepo.query!(
        "UPDATE geo_genius.import_run SET status = 'completed', completed_at = now() WHERE id = $1",
        [Ecto.UUID.dump!(run_id)]
      )

      TestRepo.query!("DELETE FROM geo_genius.import_run_lease WHERE run_id = $1", [
        Ecto.UUID.dump!(run_id)
      ])

      assert {:ok, %ImportRun{status: "completed", run_id: ^run_id}} =
               Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      refute_received {:notified, :import_started, _payload}
      refute_received {:notified, :phase_advanced, _payload}
    end

    test "execute is idempotent for a failed run and starts no phases", fixtures do
      {_manifest, _release_id, run_id} = prepare(fixtures)
      executor_id = Ecto.UUID.generate()
      assert :claimed = Catalog.claim_import_execution(fixtures.context, run_id, executor_id)
      Catalog.fail_import(fixtures.context, run_id, executor_id, %{"reason" => "fixture"})

      assert {:error, %ImportRun{status: "failed", run_id: ^run_id}} =
               Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      refute_received {:notified, :import_started, _payload}
      refute_received {:notified, :phase_advanced, _payload}
    end

    test "a verification failure fails the run in verifying and publishes nothing",
         fixtures do
      {_manifest, _release_id, run_id} = prepare_stub(fixtures, rows: [], mode: "default")
      opts = Keyword.put(fixtures.opts, :publish, true)

      assert {:error, %ImportRun{} = run} = Pipeline.execute(fixtures.context, run_id, opts)
      assert run.status == "failed"
      assert run.error["phase"] == "verifying"
      assert run.error["reason"] =~ "release contains no areas"
      assert Catalog.published_release(fixtures.context, "demo") == nil
    end

    test "a provider raising mid-normalize becomes a durable failure", fixtures do
      {_manifest, _release_id, run_id} = prepare_stub(fixtures, mode: "raise")

      assert {:error, %ImportRun{} = run} =
               Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      assert run.status == "failed"
      assert run.error["phase"] == "normalizing"
      assert run.error["exception"] =~ "RuntimeError"
      assert run.error["reason"] =~ "stub provider exploded"
      assert length(run.error["stacktrace"]) <= 20
      assert run.error["stacktrace"] != []
    end

    test "a provider returning an error fails the run in staging", fixtures do
      {_manifest, _release_id, run_id} = prepare_stub(fixtures, mode: "stage_error")

      assert {:error, %ImportRun{} = run} =
               Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      assert run.error["phase"] == "staging"
      assert run.error["reason"] =~ "stub provider refuses to stage"
      refute Map.has_key?(run.error, "exception")
    end

    test "execute/3 on an unknown run id returns an error rather than raising", fixtures do
      # There is no run to record a failure against, which is exactly what the
      # :unrecorded tag means: a caller matching {:error, run} never has to
      # discover a bare string in that position in production.
      assert {:error, {:unrecorded, :not_started, reason}} =
               Pipeline.execute(fixtures.context, Ecto.UUID.generate(), [])

      assert reason =~ "does not exist"
    end

    test "a phase that exits becomes a durable failure, not a run stuck mid-phase",
         fixtures do
      {_manifest, _release_id, run_id} = prepare_stub(fixtures, mode: "exit")

      # A `GenServer.call` timeout inside a host's cache or downloader, or a
      # dead task in a provider, exits rather than raises: a rescue alone would
      # let it past, leaving the run in `normalizing` with an empty error until
      # its lease went stale.
      assert {:error, %ImportRun{} = run} =
               Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      assert run.status == "failed"
      assert run.error["phase"] == "normalizing"
      assert run.error["exception"] == ":exit"
      assert run.error["reason"] =~ "stub_provider_left"
      assert run.error["stacktrace"] != []
    end

    test "a work-directory setup failure becomes durable after the executor is claimed",
         fixtures do
      {_manifest, _release_id, run_id} = prepare(fixtures)
      blocked_parent = Path.join(fixtures.work_dir, "not_a_directory")
      File.mkdir_p!(fixtures.work_dir)
      File.write!(blocked_parent, "occupied by a file")

      opts = Keyword.put(fixtures.opts, :work_dir, blocked_parent)

      assert {:error, %ImportRun{} = run} =
               Pipeline.execute(fixtures.context, run_id, opts)

      assert run.status == "failed"
      assert run.error["phase"] == "pending"
      assert run.error["exception"] =~ "File.Error"
      assert run.error["reason"] =~ "not_a_directory"
    end

    test "a forcibly killed executor is terminalized by its independent guardian", fixtures do
      {_manifest, _release_id, run_id} =
        prepare_stub(fixtures,
          mode: "block",
          rows: [
            %{
              "code" => "blocked",
              "name" => "Blocked",
              "area_type" => "region"
            }
          ]
        )

      {executor_pid, monitor_ref} =
        spawn_monitor(fn -> Pipeline.execute(fixtures.context, run_id, fixtures.opts) end)

      assert_receive {:stub_provider_blocked, ^executor_pid}, 5_000
      Process.exit(executor_pid, :kill)
      assert_receive {:DOWN, ^monitor_ref, :process, ^executor_pid, :killed}, 5_000

      assert %ImportRun{status: "failed", error: error} = await_terminal_run(run_id)
      assert error["phase"] == "execution"
      assert error["reason"] =~ "executor process terminated"
      assert error["exit_reason"] =~ "killed"
    end

    test "the guardian ignores unrelated messages until it is normally disarmed", fixtures do
      {_manifest, _release_id, run_id} = prepare(fixtures)
      executor_id = Ecto.UUID.generate()

      assert {:ok, guardian} =
               ExecutionGuardian.start(fixtures.context, run_id, executor_id, self())

      assert :claimed = Catalog.claim_import_execution(fixtures.context, run_id, executor_id)

      monitor_ref = Process.monitor(guardian)
      send(guardian, {:unrelated, :observer_message})

      assert %{executor_id: ^executor_id} = :sys.get_state(guardian)
      assert :ok = ExecutionGuardian.disarm(guardian)
      assert_receive {:DOWN, ^monitor_ref, :process, ^guardian, :normal}, 1_000
    end

    test "a cleanup that fails cannot destroy the failure the run already recorded",
         fixtures do
      context = %{fixtures.context | repo: RecordingRepo}
      {_manifest, _release_id, run_id} = prepare_stub(fixtures, mode: "raise")
      on_exit(fn -> drop_staging!(run_id) end)

      # The run issues two drops: the staging phase empties the table before
      # it writes to it, and the cleanup drops it afterwards. The cleanup is
      # the second, and it is the one this case is about -- failing the first
      # would fail the run in staging and never reach the provider's raise.
      RecordingRepo.fail_on("drop_staging", after: 1)

      # An exception raised inside `after` replaces the value of the whole
      # `try`, so an unguarded cleanup would turn this recorded failure into a
      # raise naming the cleanup rather than the import.
      log =
        capture_log(fn ->
          assert {:error, %ImportRun{} = run} = Pipeline.execute(context, run_id, fixtures.opts)
          assert run.status == "failed"
          assert run.error["reason"] =~ "stub provider exploded"
        end)

      # The table it could not drop is a leak, and that is the trade: losing
      # the outcome would be worse. Swallowing it silently is not part of the
      # trade -- an operator has to be told where the leaked table is.
      assert staging_table(run_id) != nil
      assert log =~ "could not drop the staging table"
      assert log =~ run_id
      assert log =~ Staging.table_name(run_id)
    end

    test "a confirmation read that fails after the advance leaves the run completed",
         fixtures do
      context = %{fixtures.context | repo: RecordingRepo, notifier: GeoGenius.ArmingNotifier}
      {_manifest, _release_id, run_id} = prepare(fixtures)

      # Armed from inside the pipeline's own process, at the one seam between
      # the advance that completes the run and the read that confirms it.
      opts =
        fixtures.opts
        |> Keyword.put(:arm_on, :import_completed)
        |> Keyword.put(:arm, fn -> RecordingRepo.fail_on("import_run_status") end)

      assert {:error, {:unrecorded, :outcome_unknown, reason}} =
               Pipeline.execute(context, run_id, opts)

      assert reason =~ "completed, but reading it back failed"

      # The advance succeeded, so the run is completed in PostgreSQL and only
      # the snapshot is missing. `fail_import/4` refuses a completed run,
      # so routing this to the failure path would rewrite a finished run as
      # failed -- and tell the host so, right after telling it the opposite.
      assert Catalog.import_run(fixtures.context, run_id).status == "completed"
      refute_received {:notified, :import_failed, _payload}
    end

    test "a failure that cannot itself be recorded returns the reason rather than a run",
         fixtures do
      context = %{fixtures.context | repo: RecordingRepo}
      {_manifest, _release_id, run_id} = prepare_stub(fixtures, mode: "raise")

      RecordingRepo.fail_on("fail_import")

      assert {:error, {:unrecorded, :outcome_unknown, reason}} =
               Pipeline.execute(context, run_id, fixtures.opts)

      # The original failure, not the one that happened while recording it.
      assert reason =~ "stub provider exploded"
    end

    test "the staging table is dropped after a success and after a failure", fixtures do
      {_manifest, _release_id, ok_run} = prepare(fixtures)
      assert {:ok, _run} = Pipeline.execute(fixtures.context, ok_run, fixtures.opts)
      assert staging_table(ok_run) == nil

      {_manifest, _release_id, failed_run} = prepare_stub(fixtures, mode: "raise", release: "r2")

      assert {:error, _run} = Pipeline.execute(fixtures.context, failed_run, fixtures.opts)
      assert staging_table(failed_run) == nil
    end

    # An execution killed before cleanup can leave staged rows behind. A
    # duplicate delivery must not resume that execution or mutate its staging
    # table while the original executor still owns the run.
    test "a duplicate delivery leaves the first executor's staging table untouched", fixtures do
      {_manifest, release_id, run_id} = prepare_stub(fixtures, [])
      first_executor = Ecto.UUID.generate()

      assert Catalog.claim_import_execution(fixtures.context, run_id, first_executor) == :claimed

      for phase <- ~w(downloading validating staging) do
        Catalog.advance_import(fixtures.context, run_id, first_executor, phase, %{})
      end

      Staging.create(fixtures.context, run_id, first_executor)

      Staging.insert(fixtures.context, run_id, first_executor, [
        %Staging.Row{
          artifact: "territories.geojson",
          payload: %{"code" => "ghost", "name" => "Ghost", "area_type" => "region"},
          geom: nil
        }
      ])

      assert Staging.count(fixtures.context, run_id) == 1

      assert {:noop,
              %ImportRun{
                run_id: ^run_id,
                executor_id: ^first_executor,
                status: "staging"
              }} = Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      assert Staging.count(fixtures.context, run_id) == 1
      assert release_area_keys(release_id) == []
    end
  end

  describe "provider contract enforcement" do
    test "a name kind outside the legal set fails the run naming the provider, area, and value",
         fixtures do
      {_manifest, _release_id, run_id} = prepare_stub(fixtures, mode: "bad_kind")

      assert {:error, %ImportRun{} = run} =
               Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      assert run.error["phase"] == "normalizing"
      assert run.error["reason"] =~ "GeoGenius.StubProvider"
      assert run.error["reason"] =~ "demo:region:north"
      assert run.error["reason"] =~ ":offical"
      assert run.error["reason"] =~ ":official"
    end

    test "a non-binary code type fails the run naming the provider, area, and value",
         fixtures do
      {_manifest, _release_id, run_id} = prepare_stub(fixtures, mode: "bad_code_type")

      assert {:error, %ImportRun{} = run} =
               Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      assert run.error["phase"] == "normalizing"
      assert run.error["reason"] =~ "GeoGenius.StubProvider"
      assert run.error["reason"] =~ "demo:region:north"
      assert run.error["reason"] =~ "code type"
      assert run.error["reason"] =~ "12"
    end

    test "the command adapter a provider is handed refuses anything but ogr2ogr",
         fixtures do
      {_manifest, _release_id, run_id} = prepare_stub(fixtures, mode: "command_probe")
      context = %{fixtures.context | command: GeoGenius.RecordingCommand}

      assert {:error, %ImportRun{} = run} = Pipeline.execute(context, run_id, fixtures.opts)

      assert run.error["phase"] == "staging"
      assert run.error["reason"] =~ "psql"
      assert run.error["reason"] =~ "ogr2ogr"

      # The refusal happens before the wrapped adapter is consulted: an
      # allowlist that delegated first and complained afterwards would have
      # already run the command it was meant to prevent.
      refute_received {:command_ran, "psql", _args, _opts}
    end

    test "every provider is handed one work directory per run, and it is gone afterwards",
         fixtures do
      {_manifest, _release_id, run_id} = prepare_stub(fixtures, mode: "default")

      assert {:ok, _run} = Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      assert_received {:staged, "territories.geojson", staged_work_dir}
      assert is_binary(staged_work_dir)

      # The run works inside its own directory beneath the one it was given,
      # never in that directory itself: what the caller pointed at may hold
      # another run's files, and this one is removed wholesale when it ends.
      assert FileSystem.within_root?(staged_work_dir, fixtures.work_dir)
      assert staged_work_dir != fixtures.work_dir
      refute File.exists?(staged_work_dir)
      assert File.exists?(fixtures.work_dir)
    end

    test "a shapefile release converts through the allowlisted adapter in the run's work dir",
         fixtures do
      zip = shapefile_archive()
      {_manifest, _release_id, run_id} = prepare_manifest(fixtures, shapefile_manifest(zip))
      seed_key!(fixtures, "demo/demo:territories/2026-01/shapes.zip", zip)

      context = %{fixtures.context | command: ConvertingCommand}
      opts = Keyword.put(fixtures.opts, :fixture, shapefile_sequence())

      assert {:ok, run} = Pipeline.execute(context, run_id, opts)
      assert run.status == "completed"
      assert run.stage_metrics["staged"] == 3
      assert run.stage_metrics["areas"] == 3

      # ogr2ogr is the one executable the allowlist passes through, and it
      # runs inside the directory the pipeline resolved for this run.
      assert_received {:ran, "ogr2ogr", args}
      assert String.starts_with?(Enum.at(args, -1), fixtures.work_dir)
    end

    test "relations/1 returning :none skips the rebuild", fixtures do
      context = %{fixtures.context | repo: RecordingRepo}

      {_manifest, _release_id, run_id} =
        prepare_stub(fixtures, mode: "default", relations: "none")

      assert {:ok, run} = Pipeline.execute(context, run_id, fixtures.opts)
      assert run.status == "completed"
      refute Map.has_key?(run.stage_metrics, "relations")

      # Omitting the metric is not the same as skipping the work: a phase that
      # rebuilt anyway and merely declined to report it would leave the metric
      # absent too, and would still have spent the minutes.
      assert RecordingRepo.options_for(RecordingRepo.recorded(), "rebuild_relations") == nil
    end

    test "relations/1 returning :rebuild records the relations the rebuild measured",
         fixtures do
      {_manifest, release_id, run_id} =
        prepare_stub(fixtures, mode: "default", rows: nested_rows())

      assert {:ok, run} = Pipeline.execute(fixtures.context, run_id, fixtures.opts)
      assert run.stage_metrics["relations"] == 1

      assert [child] = GeoGenius.children_of("demo:region:north", release_id: release_id)
      assert child.area_key == "demo:district:inner"
    end
  end

  describe "relations across a release's providers" do
    # `relations/1` is a release-level question and a release now has several
    # providers to ask. These override only `providers`, leaving
    # `artifact_providers` as the fixture built it, so the assertion isolates
    # the union in `rebuild?/1` from the per-row dispatch beside it.
    test "rebuilds when any provider asks, not only when every one does" do
      state = relation_fixture()

      assert {:ok, %{metrics: metrics}} =
               Relate.relate(%{state | providers: [QuietProvider, RebuildingProvider]})

      assert Map.has_key?(metrics, "relations")
    end

    # A release whose providers all decline measures nothing. Rebuilding
    # anyway would spend the most expensive statement in the pipeline on a
    # release with no geometry to measure.
    test "does not rebuild when no provider asks" do
      state = relation_fixture()

      assert {:ok, %{metrics: metrics}} =
               Relate.relate(%{state | providers: [QuietProvider, QuietProvider]})

      refute Map.has_key?(metrics, "relations")
    end
  end

  describe "asserted relations" do
    test "asserted edges are written and counted, and compose with a rebuild" do
      # AssertingProvider returns :rebuild from relations/1 AND one edge per
      # row, so this pins that the two paths compose rather than one
      # replacing the other.
      state =
        import_fixture(AssertingProvider, [%{key: "city", rank: 30}, %{key: "state", rank: 10}], [
          %{"child" => "LA", "parent" => "CA"}
        ])

      assert {:ok, %{metrics: metrics}} = Relate.relate(state)
      assert metrics["asserted_relations"] == 1
      assert Map.has_key?(metrics, "relations")

      assert relation_exists?(state, "demo_auth:state:CA", "demo_auth:city:LA", "contains")
    end

    test "the same edge asserted by two rows is written once" do
      # Two IDENTICAL rows -- not two rows that merely share a parent -- so
      # the same edge is asserted twice: `asserted_relations` counts both
      # assertions, but `relation_count` (a row count in `geo_genius.relation`)
      # stays at 1, since `put_relation` upserts and the edge converges.
      rows = [%{"child" => "LA", "parent" => "CA"}, %{"child" => "LA", "parent" => "CA"}]
      area_types = [%{key: "city", rank: 30}, %{key: "state", rank: 10}]
      state = import_fixture(AssertingProvider, area_types, rows)

      assert {:ok, %{metrics: metrics}} = Relate.relate(state)
      assert metrics["asserted_relations"] == 2
      assert relation_count(state, "demo_auth:state:CA") == 1
    end

    test "an edge naming an area absent from the release fails the run in relating", fixtures do
      {_manifest, _release_id, run_id} = prepare_stub(fixtures, mode: "bad_relation")

      assert {:error, %ImportRun{} = run} =
               Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      assert run.status == "failed"
      assert run.error["phase"] == "relating"
      assert run.error["exception"] == "GeoGenius.CatalogError"
      assert run.error["reason"] =~ "put_relation"
      assert run.error["reason"] =~ "no rows"
    end
  end

  describe "a release whose provider implies parent areas" do
    test "stages the implied areas and their edges alongside the rows' own areas",
         fixtures do
      # Two rows in the same cluster, so convergence on `area_key` is
      # exercised: the cluster must exist once, not twice.
      rows = [
        %{"code" => "A", "name" => "Alpha", "CLUSTER" => "1"},
        %{"code" => "B", "name" => "Beta", "CLUSTER" => "1"}
      ]

      release_id = import_rows_with_implied_areas(fixtures, rows)
      assert release_id != nil

      areas = release_area_keys(release_id)
      assert length(areas) == 3
      assert "auth:place:A" in areas
      assert "auth:place:B" in areas
      assert Enum.count(areas, &(&1 == "auth:cluster:1")) == 1

      relations = published_relations(release_id)
      assert {"auth:cluster:1", "auth:place:A", "contains"} in relations
      assert {"auth:cluster:1", "auth:place:B", "contains"} in relations
    end

    test "a row with a blank implied code still stages its own area", fixtures do
      rows = [
        %{"code" => "A", "name" => "Alpha", "CLUSTER" => "1"},
        %{"code" => "B", "name" => "Beta", "CLUSTER" => ""}
      ]

      release_id = import_rows_with_implied_areas(fixtures, rows)

      areas = release_area_keys(release_id)
      assert length(areas) == 3
      assert "auth:place:B" in areas
      assert "auth:cluster:1" in areas

      # The blank cluster column implies nothing, so the row's own area stands
      # alone: no edge names it as a child.
      relations = published_relations(release_id)
      assert relations == [{"auth:cluster:1", "auth:place:A", "contains"}]
      refute Enum.any?(relations, fn {_parent, child, _relation} -> child == "auth:place:B" end)
    end

    test "an implied code the names map does not cover fails the release before anything relates",
         fixtures do
      # Normalizing runs before relating and the pipeline halts on the first
      # phase that errors, so a row the provider cannot normalize must never
      # reach `Relate.relate/1`. Nothing else pins that ordering.
      #
      # The failure is data-dependent by construction: the manifest is well
      # formed and names cluster "1", while the row carries "2". A malformed
      # option cannot pin this ordering any more -- `validate_options/1`
      # rejects one at load, which the case below covers.
      body = implied_areas_document([%{"code" => "A", "name" => "Alpha", "CLUSTER" => "2"}])
      opts = Keyword.put(fixtures.opts, :bodies, %{@url => body})

      {_manifest, release_id, run_id} =
        prepare_manifest(fixtures, implied_areas_manifest(fixtures, body))

      assert {:error, %ImportRun{} = run} = Pipeline.execute(fixtures.context, run_id, opts)

      assert run.status == "failed"
      assert run.error["phase"] == "normalizing"
      assert run.error["reason"] =~ "implied_areas"
      assert run.error["reason"] =~ "no entry in names"
      assert run.error["reason"] =~ ~s("2")

      assert published_relations(release_id) == []
    end

    test "a malformed implied_areas option is rejected at load, before a run exists", fixtures do
      # The companion to the case above. Here the manifest itself is wrong, so
      # it never becomes a release at all: nothing is downloaded, nothing is
      # staged, and there is no run whose failure a caller has to interpret.
      body = implied_areas_document([%{"code" => "A", "name" => "Alpha", "CLUSTER" => "1"}])

      map =
        fixtures
        |> implied_areas_manifest(body)
        |> update_in(["options", "implied_areas", Access.at(0)], &Map.put(&1, "relation", "near"))

      assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
      assert reason =~ "implied_areas"
      assert reason =~ "relation"
      assert reason =~ "near"
    end
  end

  describe "a release whose sources name different providers" do
    test "stages each source through its own provider and converges the areas",
         fixtures do
      # The point of a per-source provider. A single-provider release cannot
      # express this at all: one parser would be handed both files, and the
      # delimited one would fail as GeoJSON or the GeoJSON one as delimited.
      geojson_body = two_format_geojson()

      opts =
        Keyword.put(fixtures.opts, :bodies, %{
          @url => geojson_body,
          @csv_url => @two_format_csv
        })

      {_manifest, release_id, run_id} =
        prepare_manifest(fixtures, two_format_manifest(geojson_body))

      assert {:ok, %ImportRun{status: "completed"} = run} =
               Pipeline.execute(fixtures.context, run_id, opts)

      assert release_area_keys(release_id) == ["demo:place:A"]

      # Both sources described the same area and it exists once. The boundary
      # can only have come from the GeoJSON source, so counting it proves the
      # tabular source did not overwrite what the spatial one contributed.
      assert run.stage_metrics["area_count"] == 1
      assert run.stage_metrics["boundary_count"] == 1
    end

    test "a source naming an unregistered provider fails at manifest load", fixtures do
      geojson_body = two_format_geojson()

      map =
        fixtures
        |> then(fn _ -> two_format_manifest(geojson_body) end)
        |> put_in(["sources", Access.at(0), "provider"], "no_such_provider")

      assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
      assert reason =~ "no_such_provider"
    end
  end

  describe "a release that both rebuilds and asserts relations" do
    test "keeps measured containment below and asserted membership above", fixtures do
      # The outer polygon contains the inner one, and both carry the same
      # cluster code: `relations/1` measures the containment from geometry
      # while `implied_areas` asserts the membership from the column.
      release_id = import_nested_rows_with_implied_cluster(fixtures)

      relations = published_relations(release_id)

      assert {"demo:outer:OUTER", "demo:inner:INNER", "contains"} in relations
      assert {"demo:cluster:1", "demo:outer:OUTER", "contains"} in relations
      assert {"demo:cluster:1", "demo:inner:INNER", "contains"} in relations
    end

    test "the asserted edges do not overwrite the measured one", fixtures do
      # `Catalog.put_relation_many/4` upserts on `(parent_area_id,
      # child_area_id)` and nulls the three measurement columns when an
      # asserted edge lands on a measured pair, with no warning. The two sets
      # here are disjoint, so the measurement must survive intact.
      release_id = import_nested_rows_with_implied_cluster(fixtures)

      measured = measured_relation(release_id, "demo:outer:OUTER", "demo:inner:INNER")

      refute is_nil(measured.intersection_area_m2)
      refute is_nil(measured.parent_coverage)
    end
  end

  describe "notifications and telemetry" do
    test "a raising notifier cannot fail an import, and the dropped event is logged",
         fixtures do
      context = %{fixtures.context | notifier: GeoGenius.RaisingNotifier}
      {_manifest, _release_id, run_id} = prepare(fixtures)

      log =
        capture_log(fn ->
          assert {:ok, run} = Pipeline.execute(context, run_id, fixtures.opts)
          assert run.status == "completed"
        end)

      # The notifier raised on the first event; the pipeline must have kept
      # calling it for the rest of them rather than giving up on the channel.
      assert_received {:notified, :import_started, _payload}
      assert_received {:notified, :import_completed, _payload}

      # `GeoGenius.Notifier` promises a raising notifier is logged, not merely
      # tolerated: an event that vanishes with no trace is how a host finds out
      # months later that it never received any.
      assert log =~ "dropped the import_started notification"
      assert log =~ "notifier exploded"
    end

    test "a notifier that exits cannot fail an import either", fixtures do
      context = %{fixtures.context | notifier: GeoGenius.ExitingNotifier}
      {_manifest, _release_id, run_id} = prepare(fixtures)

      log =
        capture_log(fn ->
          assert {:ok, run} = Pipeline.execute(context, run_id, fixtures.opts)
          assert run.status == "completed"
        end)

      assert log =~ "dropped the import_completed notification"
      assert log =~ "exit"
    end

    test "events arrive in order, and phase_advanced names its phase", fixtures do
      {_manifest, release_id, run_id} = prepare(fixtures)

      assert {:ok, _run} = Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      events = for {:notified, event, payload} <- drain(), do: {event, payload}
      names = Enum.map(events, &elem(&1, 0))

      assert List.first(names) == :import_started
      assert List.last(names) == :import_completed
      assert :phase_advanced in names

      assert {:import_started,
              %{run_id: ^run_id, release_id: ^release_id, collection_key: "demo"}} =
               List.first(events)

      phases = for {:phase_advanced, %{phase: phase}} <- events, do: phase

      assert phases == ~w(downloading validating staging normalizing relating indexing verifying)

      assert Enum.any?(events, fn
               {:phase_advanced, %{phase: "staging", metrics: metrics}} ->
                 metrics["required"] == 1

               _other ->
                 false
             end)
    end

    test "a phase that fails emits a stop event marked :error", fixtures do
      attach_import_spans!()
      {_manifest, _release_id, run_id} = prepare_stub(fixtures, rows: [], mode: "default")

      assert {:error, _run} = Pipeline.execute(fixtures.context, run_id, fixtures.opts)

      spans = for {:span, :stop, _measurements, metadata} <- drain(), do: metadata

      # A phase that fails by returning an error returns normally, so it emits
      # `:stop` like any other. Without `:status`, a host counting stop events
      # counts this failed import as seven completed phases -- and empty
      # `:metrics` cannot tell it apart, since `relating` and `indexing`
      # measure nothing even when they succeed.
      assert Enum.map(spans, &{&1.phase, &1.status}) == [
               {"downloading", :ok},
               {"validating", :ok},
               {"staging", :ok},
               {"normalizing", :ok},
               {"relating", :ok},
               {"indexing", :ok},
               {"verifying", :error}
             ]
    end

    test "one telemetry span per phase carries the phase and the phase's metrics",
         fixtures do
      attach_import_spans!()

      {_manifest, release_id, run_id} = prepare(fixtures)
      opts = Keyword.put(fixtures.opts, :publish, true)

      assert {:ok, _run} = Pipeline.execute(fixtures.context, run_id, opts)

      spans = for {:span, :stop, _measurements, metadata} <- drain(), do: metadata

      assert Enum.map(spans, & &1.phase) ==
               ~w(downloading validating staging normalizing relating indexing verifying
                  publishing)

      assert Enum.all?(spans, &(&1.run_id == run_id and &1.prefix == "geo_genius"))
      assert Enum.all?(spans, &(&1.release_id == release_id))

      # `collection_key` is the dimension a host can actually chart against;
      # `run_id` is unique per run and useless as a metrics tag.
      assert Enum.all?(spans, &(&1.collection_key == "demo"))
      assert Enum.all?(spans, &(&1.status == :ok))

      staging = Enum.find(spans, &(&1.phase == "staging"))
      assert staging.metrics == %{"staged" => 3}

      verifying = Enum.find(spans, &(&1.phase == "verifying"))
      assert verifying.metrics["area_count"] == 3
    end
  end

  describe "statement timeouts" do
    test "the long single statements carry a timeout, and :timeout overrides the default",
         fixtures do
      context = %{fixtures.context | repo: RecordingRepo}
      {_manifest, _release_id, run_id} = prepare(fixtures)

      assert {:ok, _run} = Pipeline.execute(context, run_id, fixtures.opts)

      recorded = RecordingRepo.recorded()

      for fragment <- @timed_statements do
        opts = RecordingRepo.options_for(recorded, fragment)
        assert opts != nil, "no query recorded for #{fragment}"
        assert opts[:timeout] == 900_000, "#{fragment} ran without the default timeout"
        assert opts[:checkout_retries] == 0, "#{fragment} permits an ambiguous retry"
      end

      {_manifest, _release_id, second_run} = prepare(fixtures, release: "r2")

      assert {:ok, _run} =
               Pipeline.execute(context, second_run, Keyword.put(fixtures.opts, :timeout, 4_242))

      recorded = RecordingRepo.recorded()

      for fragment <- @timed_statements do
        assert RecordingRepo.options_for(recorded, fragment)[:timeout] == 4_242
      end
    end

    test "artifact and staging mutations disable connection checkout retries", fixtures do
      context = %{fixtures.context | repo: RecordingRepo}
      {_manifest, _release_id, run_id} = prepare(fixtures)

      assert {:ok, _run} = Pipeline.execute(context, run_id, fixtures.opts)

      recorded = RecordingRepo.recorded()

      for fragment <- ~w(record_artifact_observation create_staging drop_staging) do
        opts = RecordingRepo.options_for(recorded, fragment)
        assert opts != nil, "no query recorded for #{fragment}"
        assert opts[:checkout_retries] == 0, "#{fragment} permits an ambiguous retry"
      end
    end

    test "the timeout derives from :stale_after_seconds when :timeout is not given", fixtures do
      context = %{fixtures.context | repo: RecordingRepo}
      {_manifest, _release_id, run_id} = prepare(fixtures)

      opts = Keyword.put(fixtures.opts, :stale_after_seconds, 30)

      # An implementation that kept the hardcoded 900_000 default -- or that
      # read :stale_after_seconds without converting seconds to
      # milliseconds -- would still pass every other case in this describe
      # block; only a value derived correctly from a non-default window
      # distinguishes it.
      assert {:ok, _run} = Pipeline.execute(context, run_id, opts)

      recorded = RecordingRepo.recorded()

      for fragment <- @timed_statements do
        assert RecordingRepo.options_for(recorded, fragment)[:timeout] == 30_000,
               "#{fragment} did not carry a timeout derived from :stale_after_seconds"
      end
    end

    test "the publishing phase carries the same timeout the verifying phase does", fixtures do
      context = %{fixtures.context | repo: RecordingRepo}
      {_manifest, release_id, run_id} = prepare(fixtures)

      # `publish_import` re-runs verification inside itself, so a
      # publishing phase left on DBConnection's fifteen-second default fails
      # every release the verifying phase needed its timeout for.
      opts = Keyword.put(fixtures.opts, :publish, true)

      assert {:ok, _run} = Pipeline.execute(context, run_id, opts)
      assert Catalog.published_release(context, "demo") == release_id

      recorded = RecordingRepo.recorded()
      published = RecordingRepo.options_for(recorded, "publish_import")
      assert published != nil, "no query recorded for publish_import"
      assert published[:timeout] == 900_000, "publish_import ran without the default timeout"
      assert published[:checkout_retries] == 0, "publish_import permits an ambiguous retry"

      {_manifest, _release_id, second_run} = prepare(fixtures, release: "r2")

      assert {:ok, _run} =
               Pipeline.execute(context, second_run, Keyword.put(opts, :timeout, 4_242))

      assert RecordingRepo.options_for(RecordingRepo.recorded(), "publish_import")[:timeout] ==
               4_242
    end

    test "a nil :stale_after_seconds (a runner backend that found nothing to carry) falls back " <>
           "to the default instead of crashing",
         fixtures do
      context = %{fixtures.context | repo: RecordingRepo}
      {_manifest, _release_id, run_id} = prepare(fixtures)

      opts = Keyword.put(fixtures.opts, :stale_after_seconds, nil)

      assert {:ok, _run} = Pipeline.execute(context, run_id, opts)

      recorded = RecordingRepo.recorded()
      assert RecordingRepo.options_for(recorded, "rebuild_relations")[:timeout] == 900_000
    end
  end

  test "both relation writes disable checkout retries and preserve the phase timeout" do
    state = relation_fixture()
    recording = %{state | context: %{state.context | repo: RecordingRepo}}

    assert {:ok, %State{}} = Relate.relate(recording)
    recorded = RecordingRepo.recorded()

    for fragment <- ["rebuild_relations", "put_relation_many"] do
      opts = RecordingRepo.options_for(recorded, fragment)
      assert opts[:timeout] == state.timeout, "#{fragment} lost the phase timeout"
      assert opts[:checkout_retries] == 0, "#{fragment} permits an ambiguous retry"
    end
  end

  # Registers a collection carrying `area_types` under the fixed `demo_auth`
  # authority, stages `payloads` as rows, and normalizes them so every area a
  # relate-phase test needs already exists in the release. Returns the
  # `%State{}` a test drives directly against `GeoGenius.Pipeline.Relate.relate/1`
  # -- no manifest is built, since `relate/1` only reads `state.manifest`
  # through the provider it is handed.
  defp relation_fixture do
    import_fixture(AssertingProvider, [%{key: "city", rank: 30}, %{key: "state", rank: 10}], [
      %{"child" => "LA", "parent" => "CA"}
    ])
  end

  defp import_fixture(provider, area_types, payloads) do
    context = Context.new(repo: TestRepo, prefix: "geo_genius")
    collection = "assert_fixture_#{System.unique_integer([:positive])}"

    on_exit(fn -> ImportFixture.teardown!(collection) end)

    manifest_map = %{
      "collection" => collection,
      "collection_name" => collection,
      "release" => "r1",
      "provider" => "geojson",
      "requires_geometry" => false,
      "authorities" => [%{"key" => "demo_auth", "name" => "Demo Authority"}],
      "area_types" =>
        Enum.map(area_types, fn area_type ->
          %{
            "key" => Map.fetch!(area_type, :key),
            "rank" => Map.fetch!(area_type, :rank),
            "requires_geometry" => Map.get(area_type, :requires_geometry, false)
          }
        end),
      "sources" => [
        %{
          "source_key" => "#{collection}:fixture",
          "provider" => "geojson",
          "license" => "CC0-1.0",
          "release_key" => "r1",
          "artifacts" => [
            %{
              "logical_name" => "fixture.geojson",
              "operator_supplied" => true,
              "format" => "geojson",
              "required" => true,
              "sha256" => sha256("fixture"),
              "bytes" => byte_size("fixture")
            }
          ]
        }
      ],
      "options" => %{
        "area_type" => area_types |> hd() |> Map.fetch!(:key),
        "code_property" => "code"
      }
    }

    {:ok, manifest} = Manifest.from_map(manifest_map)

    candidate =
      ImportFixture.prepare!(context, manifest,
        owner: "asserting-fixture",
        runner_backend: "test",
        stale_after_seconds: 300
      )

    run_id = candidate.run_id
    executor_id = Ecto.UUID.generate()
    assert :claimed = Catalog.claim_import_execution(context, run_id, executor_id)

    on_exit(fn -> Staging.drop(context, run_id, executor_id) end)

    for phase <- ~w(downloading validating staging) do
      Catalog.advance_import(context, run_id, executor_id, phase, %{})
    end

    Staging.create(context, run_id, executor_id)
    rows = Enum.map(payloads, &%Staging.Row{artifact: "fixture", payload: &1, geom: nil})
    Staging.insert(context, run_id, executor_id, rows)
    Catalog.advance_import(context, run_id, executor_id, "normalizing", %{})

    state = %State{
      context: context,
      run: Catalog.import_run(context, run_id),
      executor_id: executor_id,
      opts: [],
      work_dir: System.tmp_dir!(),
      publish?: false,
      batch_size: 500,
      timeout: 30_000,
      manifest: nil,
      providers: [provider],
      artifact_providers: %{"fixture" => provider}
    }

    assert {:ok, state} = Normalize.normalize(state)
    :ok = Catalog.advance_import(context, run_id, executor_id, "relating", %{})
    %{state | run: Catalog.import_run(context, run_id)}
  end

  defp relation_exists?(%State{context: context, run: run}, parent_key, child_key, relation_type) do
    %Postgrex.Result{rows: rows} =
      TestRepo.query!(
        """
        SELECT 1
          FROM "#{context.prefix}".relation
          JOIN "#{context.prefix}".area AS parent ON parent.id = relation.parent_area_id
          JOIN "#{context.prefix}".area AS child ON child.id = relation.child_area_id
         WHERE relation.release_id = $1
           AND parent.area_key = $2
           AND child.area_key = $3
           AND relation.relation_type = $4
        """,
        [Ecto.UUID.dump!(run.release_id), parent_key, child_key, relation_type]
      )

    rows != []
  end

  defp relation_count(%State{context: context, run: run}, parent_key) do
    %Postgrex.Result{rows: [[count]]} =
      TestRepo.query!(
        """
        SELECT count(*)
          FROM "#{context.prefix}".relation
          JOIN "#{context.prefix}".area AS parent ON parent.id = relation.parent_area_id
         WHERE relation.release_id = $1
           AND parent.area_key = $2
        """,
        [Ecto.UUID.dump!(run.release_id), parent_key]
      )

    count
  end

  defp prepare(fixtures, opts \\ []) do
    prepare_manifest(fixtures, geojson_manifest(fixtures, opts))
  end

  defp await_terminal_run(run_id, attempts \\ 50)

  defp await_terminal_run(run_id, attempts) when attempts > 0 do
    case Catalog.import_run(Context.new(repo: TestRepo, prefix: "geo_genius"), run_id) do
      %ImportRun{status: status} = run when status in ["completed", "failed"] ->
        run

      _run ->
        Process.sleep(20)
        await_terminal_run(run_id, attempts - 1)
    end
  end

  defp await_terminal_run(run_id, 0),
    do: Catalog.import_run(Context.new(repo: TestRepo, prefix: "geo_genius"), run_id)

  defp prepare_stub(fixtures, opts) do
    prepare_manifest(fixtures, stub_manifest(fixtures, opts))
  end

  defp prepare_manifest(fixtures, map) do
    {:ok, manifest} = Manifest.from_map(map)

    candidate =
      ImportFixture.prepare!(fixtures.context, manifest,
        owner: "pipeline-test",
        runner_backend: "test",
        stale_after_seconds: 300
      )

    {manifest, candidate.release_id, candidate.run_id}
  end

  # What `GeoGenius.import/1` will do before it calls the pipeline: the
  # collection, its authority and area types, the release opened with its
  # reviewed manifest, and every source release and artifact it composes.

  defp geojson_manifest(fixtures, opts) do
    %{
      "collection" => "demo",
      "collection_name" => "Demo Territories",
      "release" => Keyword.get(opts, :release, "r1"),
      "provider" => "geojson",
      "requires_geometry" => false,
      "source_date" => "2026-01-15",
      "authorities" => [%{"key" => "demo", "name" => "Demo Operations"}],
      "area_types" => [%{"key" => "territory", "rank" => 100}],
      "sources" => [source_map(fixtures, opts)],
      "options" => %{
        "code_property" => "territory_id",
        "name_property" => "territory_name",
        "area_type" => "territory",
        "attribute_properties" => ["short_name", "population"]
      }
    }
  end

  defp stub_manifest(fixtures, opts) do
    fixtures
    |> geojson_manifest(opts)
    |> Map.put("provider", "stub")
    |> Map.update!("sources", fn sources ->
      Enum.map(sources, fn source ->
        source
        |> Map.put("source_key", "demo:territories_stub")
        |> Map.put("provider", "stub")
      end)
    end)
    |> Map.put("area_types", [
      %{"key" => "region", "rank" => 300},
      %{"key" => "district", "rank" => 400}
    ])
    |> Map.put("options", %{
      "mode" => Keyword.get(opts, :mode, "default"),
      "rows" => Keyword.get(opts, :rows, default_rows()),
      "relations" => Keyword.get(opts, :relations, "rebuild")
    })
  end

  defp source_map(fixtures, opts) do
    operator_supplied = Keyword.get(opts, :operator_supplied, false)

    artifact =
      %{
        "logical_name" => "territories.geojson",
        "url" => if(operator_supplied, do: nil, else: @url),
        "operator_supplied" => operator_supplied,
        "format" => "geojson",
        "required" => true,
        "sha256" => sha256(fixtures.body),
        "bytes" => byte_size(fixtures.body)
      }
      |> put_optional("cache_key", Keyword.get(opts, :cache_key))

    %{
      "source_key" => "demo:territories",
      "provider" => "geojson",
      "license" => "CC0-1.0",
      "release_key" => "2026-01",
      "source_date" => "2026-01-15",
      "artifacts" => [artifact | Keyword.get(opts, :extra_artifacts, [])]
    }
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  # An artifact the release can do without: operator-supplied, so nothing can
  # fetch it, and never placed in the cache.
  defp optional_artifact do
    %{
      "logical_name" => "extras.geojson",
      "operator_supplied" => true,
      "format" => "geojson",
      "required" => false,
      "sha256" => sha256("extras"),
      "bytes" => byte_size("extras")
    }
  end

  defp shapefile_archive do
    members = ~w(territories.shp territories.dbf territories.shx territories.prj)
    entries = Enum.map(members, &{String.to_charlist(&1), "stand-in for #{&1}"})
    {:ok, {_name, bytes}} = :zip.create(~c"shapes.zip", entries, [:memory])
    bytes
  end

  defp shapefile_sequence do
    @artifact
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("features")
    |> Enum.map_join("\n", &Jason.encode!/1)
  end

  defp shapefile_manifest(zip) do
    %{
      "collection" => "demo",
      "collection_name" => "Demo Territories",
      "release" => "r1",
      "provider" => "shapefile",
      "requires_geometry" => false,
      "authorities" => [%{"key" => "demo", "name" => "Demo Operations"}],
      "area_types" => [%{"key" => "territory", "rank" => 100}],
      "sources" => [
        %{
          "source_key" => "demo:territories",
          "provider" => "shapefile",
          "license" => "CC0-1.0",
          "release_key" => "2026-01",
          "artifacts" => [
            %{
              "logical_name" => "shapes.zip",
              "operator_supplied" => true,
              "format" => "shapefile",
              "required" => true,
              "sha256" => sha256(zip),
              "bytes" => byte_size(zip)
            }
          ]
        }
      ],
      "options" => %{
        "code_property" => "territory_id",
        "name_property" => "territory_name",
        "area_type" => "territory"
      }
    }
  end

  defp default_rows do
    [%{"code" => "north", "name" => "North", "area_type" => "region", "geometry" => square(0, 4)}]
  end

  defp nested_rows do
    [
      %{
        "code" => "north",
        "name" => "North",
        "area_type" => "region",
        "geometry" => square(0, 4)
      },
      %{
        "code" => "inner",
        "name" => "Inner",
        "area_type" => "district",
        "geometry" => square(1, 2)
      }
    ]
  end

  defp square(origin, size) do
    far = origin + size

    %{
      "type" => "Polygon",
      "coordinates" => [
        [
          [origin, origin],
          [far, origin],
          [far, far],
          [origin, far],
          [origin, origin]
        ]
      ]
    }
  end

  defp seed_cache!(fixtures, %Manifest{} = manifest, body) do
    [source] = manifest.sources
    [artifact] = source.artifacts

    key =
      Enum.join(
        [manifest.collection, source.source_key, source.release_key, artifact.logical_name],
        "/"
      )

    seed_key!(fixtures, key, body)
  end

  defp seed_key!(fixtures, key, body) do
    path = FileSystem.path(key, cache_dir: fixtures.cache_dir)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  defp observation do
    %Postgrex.Result{rows: [[sha, bytes, validated_at]]} =
      TestRepo.query!(
        """
        SELECT observed_sha256, observed_bytes, validated_at
          FROM geo_genius.run_artifacts
         WHERE observed_sha256 IS NOT NULL
         ORDER BY validated_at DESC
         LIMIT 1
        """,
        []
      )

    assert validated_at != nil
    {sha, bytes}
  end

  defp attach_import_spans! do
    test_pid = self()

    :telemetry.attach_many(
      "geo-genius-pipeline-test",
      [[:geo_genius, :import, :start], [:geo_genius, :import, :stop]],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:span, List.last(event), measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("geo-genius-pipeline-test") end)
  end

  # Runs a whole GeoJSON release whose features each carry a cluster code
  # beside their own, under a manifest declaring the `cluster` type and the
  # `implied_areas` entry that reads it. Returns the release id the completed
  # import wrote into.
  defp import_rows_with_implied_areas(fixtures, rows) do
    body = implied_areas_document(rows)
    opts = Keyword.put(fixtures.opts, :bodies, %{@url => body})

    {_manifest, release_id, run_id} =
      prepare_manifest(fixtures, implied_areas_manifest(fixtures, body))

    assert {:ok, %ImportRun{status: "completed"}} =
             Pipeline.execute(fixtures.context, run_id, opts)

    release_id
  end

  # Each row becomes one boundary-free feature: an implied area carries no
  # geometry either way, so geometry would only obscure what the release proves.
  defp two_format_geojson do
    Jason.encode!(%{
      "type" => "FeatureCollection",
      "features" => [
        %{
          "type" => "Feature",
          "properties" => %{"code" => "A", "name" => "Alpha"},
          "geometry" => %{
            "type" => "Polygon",
            "coordinates" => [[[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0], [0.0, 0.0]]]
          }
        }
      ]
    })
  end

  # `options` must satisfy both providers at once: the CSV provider requires
  # `code_column` and the GeoJSON provider `code_property`, and manifest
  # validation now checks every provider a release names.
  defp two_format_manifest(geojson_body) do
    %{
      "collection" => "demo",
      "collection_name" => "Demo Two Formats",
      "release" => "two_format",
      "provider" => "geojson",
      "requires_geometry" => false,
      "source_date" => "2026-01-15",
      "authorities" => [%{"key" => "demo", "name" => "Demo Operations"}],
      "area_types" => [%{"key" => "place", "rank" => 100}],
      "sources" => [
        two_format_source("demo:tabular", "csv", "places.csv", "csv", @csv_url, @two_format_csv),
        two_format_source(
          "demo:spatial",
          "geojson",
          "places.geojson",
          "geojson",
          @url,
          geojson_body
        )
      ],
      "options" => %{
        "area_type" => "place",
        "code_column" => "code",
        "name_column" => "name",
        "code_property" => "code",
        "name_property" => "name"
      }
    }
  end

  defp two_format_source(source_key, provider, logical_name, format, url, body) do
    %{
      "source_key" => source_key,
      "provider" => provider,
      "license" => "CC0-1.0",
      "release_key" => "2026-01",
      "source_date" => "2026-01-15",
      "artifacts" => [
        %{
          "logical_name" => logical_name,
          "url" => url,
          "operator_supplied" => false,
          "format" => format,
          "required" => true,
          "sha256" => sha256(body),
          "bytes" => byte_size(body)
        }
      ]
    }
  end

  defp implied_areas_document(rows) do
    Jason.encode!(%{
      "type" => "FeatureCollection",
      "features" => Enum.map(rows, &%{"type" => "Feature", "properties" => &1, "geometry" => nil})
    })
  end

  defp implied_areas_manifest(fixtures, body) do
    fixtures
    |> geojson_manifest([])
    |> Map.put("authorities", [%{"key" => "auth", "name" => "Demo Operations"}])
    |> Map.put("area_types", [
      %{"key" => "place", "rank" => 100},
      %{"key" => "cluster", "rank" => 50}
    ])
    |> Map.put("options", %{
      "area_type" => "place",
      "code_property" => "code",
      "name_property" => "name",
      "implied_areas" => [
        %{
          "area_type" => "cluster",
          "code_property" => "CLUSTER",
          "names" => %{"1" => "Cluster One"}
        }
      ]
    })
    |> update_in(["sources", Access.at(0), "artifacts", Access.at(0)], fn artifact ->
      Map.merge(artifact, %{"sha256" => sha256(body), "bytes" => byte_size(body)})
    end)
  end

  # Runs a whole stub release whose two rows nest spatially and share one
  # cluster code, so the rebuild and the assertion both write into it. The
  # rebuild pairs areas by type rank, so the nesting needs two types.
  defp import_nested_rows_with_implied_cluster(fixtures) do
    map =
      fixtures
      |> stub_manifest(rows: clustered_nested_rows())
      |> Map.put("area_types", [
        %{"key" => "cluster", "rank" => 100},
        %{"key" => "outer", "rank" => 200},
        %{"key" => "inner", "rank" => 300}
      ])
      |> update_in(["options"], &Map.put(&1, "implied_areas", implied_cluster_entries()))

    {_manifest, release_id, run_id} = prepare_manifest(fixtures, map)

    assert {:ok, %ImportRun{status: "completed"}} =
             Pipeline.execute(fixtures.context, run_id, fixtures.opts)

    release_id
  end

  defp implied_cluster_entries do
    [%{"area_type" => "cluster", "code_field" => "CLUSTER", "names" => %{"1" => "Cluster One"}}]
  end

  defp clustered_nested_rows do
    [
      %{
        "code" => "OUTER",
        "name" => "Outer",
        "area_type" => "outer",
        "CLUSTER" => "1",
        "geometry" => square(0, 4)
      },
      %{
        "code" => "INNER",
        "name" => "Inner",
        "area_type" => "inner",
        "CLUSTER" => "1",
        "geometry" => square(1, 2)
      }
    ]
  end

  defp measured_relation(release_id, parent_key, child_key) do
    [release_id: release_id, parent_area_keys: [parent_key], child_area_keys: [child_key]]
    |> Published.relations()
    |> TestRepo.one()
  end

  defp published_relations(release_id) do
    [release_id: release_id]
    |> Published.relations()
    |> TestRepo.all()
    |> Enum.map(&{&1.parent_area_key, &1.child_area_key, &1.relation_type})
  end

  # Every area key in a release, sorted. `:release_id` swaps `Published` onto the
  # release-scoped base rather than the published views, so this reads a release
  # that was never published -- a failed import included. Sorted explicitly: an
  # assertion comparing whole lists must not depend on the order Postgres happens
  # to return.
  defp release_area_keys(release_id) do
    [release_id: release_id]
    |> Published.areas()
    |> TestRepo.all()
    |> Enum.map(& &1.area_key)
    |> Enum.sort()
  end

  defp drop_staging!(run_id) do
    TestRepo.query!("DROP TABLE IF EXISTS geo_genius.\"#{Staging.table_name(run_id)}\"", [])
  end

  defp staging_table(run_id) do
    %Postgrex.Result{rows: [[table]]} =
      TestRepo.query!("SELECT to_regclass($1)::text", [
        "geo_genius." <> Staging.table_name(run_id)
      ])

    table
  end

  defp sha256(body), do: Base.encode16(:crypto.hash(:sha256, body), case: :lower)

  defp drain do
    receive do
      message -> [message | drain()]
    after
      0 -> []
    end
  end
end
