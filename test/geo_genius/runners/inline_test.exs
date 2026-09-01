defmodule GeoGenius.Runners.InlineTest do
  use ExUnit.Case, async: false

  alias GeoGenius.AppEnv
  alias GeoGenius.Catalog
  alias GeoGenius.Context
  alias GeoGenius.GraphFixture
  alias GeoGenius.ImportFixture
  alias GeoGenius.RecordingRepo
  alias GeoGenius.Runners

  setup do
    GraphFixture.teardown!()
    on_exit(&GraphFixture.teardown!/0)

    unique = System.unique_integer([:positive])
    cache_dir = Path.join(System.tmp_dir!(), "geo_genius_inline_cache_#{unique}")
    AppEnv.put(:cache_dir, cache_dir)
    on_exit(fn -> File.rm_rf(cache_dir) end)

    {:ok, context: Context.new(repo: GeoGenius.TestRepo, prefix: "geo_genius")}
  end

  test "name/0 and available?/0" do
    assert Runners.Inline.name() == "inline"
    assert Runners.Inline.available?()
  end

  test "runs the pipeline synchronously", %{context: context} do
    {_collection, _release_id, run_id} = ImportFixture.claim_run!(context)

    assert :ok = Runners.Inline.enqueue(context, run_id, %{publish: false})

    # No polling, no sleep: if this is not already completed, the pipeline
    # did not run inside enqueue/3 -- it was handed off somewhere else.
    assert Catalog.import_run(context, run_id).status == "completed"
  end

  test "publish: true reaches the pipeline rather than being silently dropped",
       %{context: context} do
    {collection, release_id, run_id} = ImportFixture.claim_run!(context)

    assert :ok = Runners.Inline.enqueue(context, run_id, %{publish: true})

    # A backend that ignored `args` (or always forwarded `publish: false`)
    # would leave the release unpublished here just as it would for the
    # default case below -- only forwarding the true value publishes it.
    assert Catalog.published_release(context, collection) == release_id
  end

  test "publish defaults to false when args carries none", %{context: context} do
    {collection, _release_id, run_id} = ImportFixture.claim_run!(context)

    assert :ok = Runners.Inline.enqueue(context, run_id, %{})

    assert Catalog.published_release(context, collection) == nil
  end

  test "publish: true is honored from a string-keyed args map too", %{context: context} do
    {collection, release_id, run_id} = ImportFixture.claim_run!(context)

    # A durable backend that round-trips `args` through its own JSON decoder
    # hands back `%{"publish" => true}`, not `%{publish: true}`. Runner.publish?/1
    # is what makes that not silently mean "never publish".
    assert :ok = Runners.Inline.enqueue(context, run_id, %{"publish" => true})

    assert Catalog.published_release(context, collection) == release_id
  end

  test "an unknown run id comes back as an error naming the run, not :ok", %{context: context} do
    run_id = Ecto.UUID.generate()

    assert {:error, {:not_enqueued, reason}} =
             Runners.Inline.enqueue(context, run_id, %{publish: false})

    assert reason =~ run_id
    assert reason =~ "does not exist"
  end

  test "a genuinely failing import still returns :ok, since the pipeline recorded it",
       %{context: context} do
    {_collection, _release_id, run_id} = ImportFixture.claim_run!(context, corrupt_artifact: true)

    # An implementation that maps a recorded business failure to
    # `{:error, run}` instead of `:ok` would pass every other test in this
    # file -- nothing else drives a run through `enqueue/3` that actually
    # fails. This is the one assertion that would catch it.
    assert :ok = Runners.Inline.enqueue(context, run_id, %{publish: false})

    run = Catalog.import_run(context, run_id)
    assert run.status == "failed"
    assert run.error != nil
  end

  test "a post-claim failure that cannot be recorded has unknown enqueue outcome",
       %{context: context} do
    {_collection, _release_id, run_id} =
      ImportFixture.claim_run!(context, corrupt_artifact: true)

    RecordingRepo.fail_on("fail_import")
    recording_context = %{context | repo: RecordingRepo}

    assert {:error, {:outcome_unknown, reason}} =
             Runners.Inline.enqueue(recording_context, run_id, %{publish: false})

    assert reason =~ "artifact"
  end

  test "duplicate delivery is successful without claiming completion", %{context: context} do
    {collection, _release_id, run_id} = ImportFixture.claim_run!(context)
    first_executor = Ecto.UUID.generate()

    assert Catalog.claim_import_execution(context, run_id, first_executor) == :claimed
    assert :ok = Runners.Inline.enqueue(context, run_id, %{publish: true})

    assert %GeoGenius.ImportRun{
             status: "pending",
             executor_id: ^first_executor,
             completed_at: nil
           } = Catalog.import_run(context, run_id)

    assert Catalog.published_release(context, collection) == nil
  end

  test "forwards :stale_after_seconds from args into Pipeline.execute/3's derived timeout",
       %{context: context} do
    {_collection, _release_id, run_id} = ImportFixture.claim_run!(context)
    recording_context = %{context | repo: RecordingRepo}

    # An implementation that built opts without :stale_after_seconds -- or
    # dropped it silently -- would still return :ok and complete the run
    # under Pipeline's 900_000ms default; only a derived, non-default
    # timeout on the actual SQL distinguishes it.
    assert :ok = Runners.Inline.enqueue(recording_context, run_id, %{stale_after_seconds: 30})

    recorded = RecordingRepo.recorded()

    assert RecordingRepo.options_for(recorded, "rebuild_relations")[:timeout] == 30_000
  end
end
