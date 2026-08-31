defmodule GeoGenius.CatalogTest do
  use ExUnit.Case, async: false

  alias GeoGenius.AppEnv
  alias GeoGenius.{Catalog, Context, GraphFixture, TestRepo}
  alias GeoGenius.ImportRun

  setup do
    GraphFixture.teardown!()
    on_exit(&GraphFixture.teardown!/0)

    # `GeoGenius.areas_for_point/3` builds its own context from application
    # environment rather than accepting one, so the boundary test that reads
    # a match back through it needs `:repo` configured for the duration.
    AppEnv.put(:repo, TestRepo)

    {:ok, context: Context.new(repo: TestRepo, prefix: "geo_genius")}
  end

  defp open_demo(context) do
    Catalog.upsert_collection(context, %{key: "demo", name: "Demo", description: nil})

    Catalog.open_release(context, "demo", %{
      release_key: "r1",
      manifest: %{"release" => "r1"},
      source_date: ~D[2026-01-15]
    })
  end

  test "opens a release and returns a hyphenated uuid string", %{context: context} do
    release_id = open_demo(context)

    assert is_binary(release_id)
    assert {:ok, _} = Ecto.UUID.cast(release_id)
    assert String.contains?(release_id, "-")
  end

  test "reopening an unpublished release returns the same id", %{context: context} do
    first = open_demo(context)
    second = open_demo(context)

    assert first == second
  end

  test "records a source, a vintage, and an artifact", %{context: context} do
    release_id = open_demo(context)

    Catalog.upsert_source(context, "demo", %{
      source_key: "demo:src",
      provider: "geojson",
      license: "CC0"
    })

    # `provider` and `license` are adjacent same-typed text arguments to
    # upsert_source. Nothing else in this test reads `source.provider` or
    # `source.license` back, so a wrapper that transposed those two lines
    # would still pass everything else here.
    %Postgrex.Result{rows: [[stored_provider, stored_license]]} =
      TestRepo.query!(
        "SELECT provider, license FROM geo_genius.source WHERE source_key = $1",
        ["demo:src"]
      )

    assert stored_provider == "geojson"
    assert stored_license == "CC0"

    source_release_id =
      Catalog.upsert_source_release(context, "demo", %{
        source_key: "demo:src",
        release_key: "v1",
        source_date: ~D[2026-01-15],
        metadata: %{"attribution" => "Demo"}
      })

    # `:source_date` and `:metadata` are written here but asserted nowhere
    # else: a wrapper that dropped either (for example a literal `%{}` in
    # place of `Map.get(attrs, :metadata, %{})`) would still pass the rest of
    # this test.
    %Postgrex.Result{rows: [[stored_source_date, stored_metadata]]} =
      TestRepo.query!(
        """
        SELECT source_date, metadata FROM geo_genius.source_release
        WHERE source_id = (SELECT id FROM geo_genius.source WHERE source_key = $1)
          AND release_key = $2
        """,
        ["demo:src", "v1"]
      )

    assert stored_source_date == ~D[2026-01-15]
    assert stored_metadata == %{"attribution" => "Demo"}

    artifact_id =
      Catalog.put_artifact(context, source_release_id, %{
        logical_name: "areas.geojson",
        url: "https://example.test/areas.geojson",
        operator_supplied: false,
        format: "geojson",
        expected_sha256: String.duplicate("a", 64),
        expected_bytes: 1024,
        metadata: %{"required" => true}
      })

    assert {:ok, _} = Ecto.UUID.cast(artifact_id)

    assert :ok =
             Catalog.record_artifact_observation(context, artifact_id, %{
               observed_sha256: String.duplicate("a", 64),
               observed_bytes: 1024
             })

    # A wrapper that transposes two same-typed arguments (for example
    # `logical_name` and `format`, both text) would still satisfy the
    # assertions above, since `record_artifact_observation` only checks the
    # sha256/byte pair. Reading the artifact back through the release closes
    # that gap by checking every field landed where it belongs.
    Catalog.attach_source_release(context, release_id, source_release_id)

    assert [artifact] = Catalog.release_artifacts(context, release_id)
    assert artifact["artifact_id"] == artifact_id
    assert artifact["source_release_id"] == source_release_id
    assert artifact["logical_name"] == "areas.geojson"
    assert artifact["url"] == "https://example.test/areas.geojson"
    assert artifact["operator_supplied"] == false
    assert artifact["format"] == "geojson"
    assert artifact["expected_sha256"] == String.duplicate("a", 64)
    assert artifact["expected_bytes"] == 1024
    assert artifact["observed_sha256"] == String.duplicate("a", 64)
    assert artifact["observed_bytes"] == 1024
    assert artifact["metadata"] == %{"required" => true}
  end

  test "a contradicting observation raises CatalogError carrying the driver error",
       %{context: context} do
    open_demo(context)

    Catalog.upsert_source(context, "demo", %{source_key: "s", provider: "geojson", license: "CC0"})

    source_release_id =
      Catalog.upsert_source_release(context, "demo", %{
        source_key: "s",
        release_key: "v1",
        source_date: nil,
        metadata: %{}
      })

    artifact_id =
      Catalog.put_artifact(context, source_release_id, %{
        logical_name: "a.geojson",
        url: "https://example.test/a",
        operator_supplied: false,
        format: "geojson",
        expected_sha256: String.duplicate("a", 64),
        expected_bytes: 10,
        metadata: %{}
      })

    error =
      assert_raise GeoGenius.CatalogError, fn ->
        Catalog.record_artifact_observation(context, artifact_id, %{
          observed_sha256: String.duplicate("b", 64),
          observed_bytes: 11
        })
      end

    assert error.function == "record_artifact_observation"
    assert %Postgrex.Error{postgres: %{code: :check_violation}} = error.reason
  end

  test "claims a run and reads it back through the status view", %{context: context} do
    release_id = open_demo(context)

    run_id =
      Catalog.begin_or_resume_import(context, release_id, %{
        owner: "worker-1",
        runner_backend: "test",
        stale_after_seconds: 300
      })

    assert %ImportRun{} = run = Catalog.import_run(context, run_id)
    assert run.run_id == run_id
    assert run.release_id == release_id
    assert run.collection_key == "demo"
    assert run.release_key == "r1"
    assert run.status == "pending"
    assert run.owner == "worker-1"
    assert run.runner_backend == "test"
    assert run.attempt == 1
    assert run.progress == %{}
  end

  test "import_run returns nil for a run that does not exist", %{context: context} do
    assert Catalog.import_run(context, Ecto.UUID.generate()) == nil
  end

  test "import_runs lists a collection's runs, most recently started first",
       %{context: context} do
    release_id = open_demo(context)

    first_run_id =
      Catalog.begin_or_resume_import(context, release_id, %{
        owner: "worker-1",
        runner_backend: "test",
        stale_after_seconds: 300
      })

    assert :ok = Catalog.fail_import(context, first_run_id, %{"reason" => "boom"})

    second_run_id =
      Catalog.begin_or_resume_import(context, release_id, %{
        owner: "worker-2",
        runner_backend: "test",
        stale_after_seconds: 300
      })

    assert [%ImportRun{run_id: ^second_run_id}, %ImportRun{run_id: ^first_run_id}] =
             Catalog.import_runs(context, "demo")
  end

  test "advances a run and accumulates stage metrics", %{context: context} do
    release_id = open_demo(context)

    run_id =
      Catalog.begin_or_resume_import(context, release_id, %{
        owner: "worker-1",
        runner_backend: "test",
        stale_after_seconds: 300
      })

    assert :ok = Catalog.advance_import(context, run_id, "downloading", %{"files" => 1})
    assert :ok = Catalog.advance_import(context, run_id, "staging", %{"rows" => 5})

    run = Catalog.import_run(context, run_id)
    assert run.status == "staging"
    assert run.stage_metrics == %{"files" => 1, "rows" => 5}
  end

  test "heartbeat merges into the lease progress", %{context: context} do
    release_id = open_demo(context)

    run_id =
      Catalog.begin_or_resume_import(context, release_id, %{
        owner: "worker-1",
        runner_backend: "test",
        stale_after_seconds: 300
      })

    # The second patch is not a superset of the first (it omits "stage"), so
    # the merge only reads as a merge if the result keeps "stage" from the
    # first patch alongside "rows" from the second. A patch pair where the
    # second is a superset of the first cannot tell a merge from an outright
    # overwrite -- both produce the same result.
    assert :ok =
             Catalog.heartbeat_import(context, run_id, %{"rows" => 100, "stage" => "download"})

    assert :ok = Catalog.heartbeat_import(context, run_id, %{"rows" => 200})

    assert Catalog.import_run(context, run_id).progress == %{"rows" => 200, "stage" => "download"}
  end

  test "fails a run and stores the error", %{context: context} do
    release_id = open_demo(context)

    run_id =
      Catalog.begin_or_resume_import(context, release_id, %{
        owner: "worker-1",
        runner_backend: "test",
        stale_after_seconds: 300
      })

    assert :ok = Catalog.fail_import(context, run_id, %{"reason" => "boom"})

    run = Catalog.import_run(context, run_id)
    assert run.status == "failed"
    assert run.error == %{"reason" => "boom"}
    assert ImportRun.finished?(run)
    refute ImportRun.succeeded?(run)
  end

  test "verify_release reports failures as a value rather than raising",
       %{context: context} do
    release_id = open_demo(context)

    assert %{"ok" => false, "failures" => failures} = Catalog.verify_release(context, release_id)
    assert "release contains no areas" in failures
  end

  test "verify_release requires boundaries only for area types marked as requiring geometry",
       %{context: context} do
    release_id = open_demo(context)
    Catalog.upsert_authority(context, "demo", %{key: "a", name: "A"})

    Catalog.upsert_area_type(context, "demo", %{
      key: "bounded_zone",
      rank: 10,
      requires_geometry: true
    })

    Catalog.upsert_area_type(context, "demo", %{
      key: "metadata_record",
      rank: 20,
      requires_geometry: false
    })

    Catalog.upsert_area_many(context, "demo", [
      %{authority_key: "a", area_type_key: "bounded_zone", code: "alpha"},
      %{authority_key: "a", area_type_key: "metadata_record", code: "detail"}
    ])

    Catalog.put_area_in_release_many(context, release_id, [
      %{area_key: "a:bounded_zone:alpha", centroid: nil, attributes: %{}},
      %{area_key: "a:metadata_record:detail", centroid: nil, attributes: %{}}
    ])

    Catalog.upsert_source(context, "demo", %{source_key: "s", provider: "geojson", license: "CC0"})

    source_release_id =
      Catalog.upsert_source_release(context, "demo", %{
        source_key: "s",
        release_key: "v1",
        source_date: nil,
        metadata: %{}
      })

    Catalog.attach_source_release(context, release_id, source_release_id)

    assert %{"ok" => false, "failures" => ["1 areas lack a boundary"]} =
             Catalog.verify_release(context, release_id)

    Catalog.put_boundary(context, release_id, "a:bounded_zone:alpha", %{
      source_release_id: source_release_id,
      geometry: square(0.0, 1.0)
    })

    assert %{"ok" => true, "boundary_count" => 1} = Catalog.verify_release(context, release_id)
  end

  test "legacy uncast SQL upsert_area_type calls resolve to the false wrapper",
       %{context: context} do
    open_demo(context)

    %{rows: [[_area_type_id]]} =
      TestRepo.query!(
        "SELECT geo_genius.upsert_area_type('demo', 'legacy_type', 90)::text",
        []
      )

    assert query_rows(context, """
           SELECT requires_geometry
             FROM geo_genius.area_type
            WHERE key = 'legacy_type'
           """) == [[false]]
  end

  test "the explicit geometry-aware area type SQL function has no default argument" do
    %{rows: [[arguments]]} =
      TestRepo.query!(
        """
        SELECT pg_get_function_arguments(p.oid)
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'geo_genius'
           AND p.proname = 'upsert_area_type'
           AND pg_get_function_identity_arguments(p.oid) =
               'collection_key text, key text, rank integer, requires_geometry boolean'
        """,
        []
      )

    assert arguments == "collection_key text, key text, rank integer, requires_geometry boolean"
  end

  test "creates and drops a staging table, returning its name", %{context: context} do
    release_id = open_demo(context)

    run_id =
      Catalog.begin_or_resume_import(context, release_id, %{
        owner: "worker-1",
        runner_backend: "test",
        stale_after_seconds: 300
      })

    table = Catalog.create_staging(context, run_id)
    assert table == "staging_" <> String.replace(run_id, "-", "")

    assert :ok = Catalog.drop_staging(context, run_id)
  end

  test "published_release is nil before publication and the release id after",
       %{context: context} do
    assert Catalog.published_release(context, "demo") == nil

    release_id = open_demo(context)

    # `open_release/3`'s `:source_date` is written but never read back
    # anywhere else: a wrapper that dropped it (bound `NULL` regardless of
    # what was passed) would still pass every other Catalog test.
    %Postgrex.Result{rows: [[stored_source_date]]} =
      TestRepo.query!("SELECT source_date FROM geo_genius.release WHERE id = $1", [
        Ecto.UUID.dump!(release_id)
      ])

    assert stored_source_date == ~D[2026-01-15]

    Catalog.upsert_authority(context, "demo", %{key: "a", name: "A"})
    Catalog.upsert_area_type(context, "demo", %{key: "t", rank: 10})
    Catalog.upsert_area(context, "demo", %{authority_key: "a", area_type_key: "t", code: "c"})
    Catalog.put_area_name(context, "a:t:c", %{name: "Area", kind: "official", locale: nil})

    Catalog.upsert_source(context, "demo", %{source_key: "s", provider: "geojson", license: "CC0"})

    source_release_id =
      Catalog.upsert_source_release(context, "demo", %{
        source_key: "s",
        release_key: "v1",
        source_date: nil,
        metadata: %{}
      })

    Catalog.attach_source_release(context, release_id, source_release_id)

    Catalog.put_area_in_release(context, release_id, "a:t:c", %{
      centroid: %Geo.Point{coordinates: {0.0, 0.0}, srid: 4326},
      attributes: %{"population" => 10}
    })

    # `put_area_in_release/4`'s `:attributes` is likewise written but never
    # read back anywhere else: a wrapper that dropped it (bound `{}`
    # regardless of what was passed) would still pass every other Catalog
    # test.
    %Postgrex.Result{rows: [[stored_attributes]]} =
      TestRepo.query!(
        """
        SELECT data FROM geo_genius.release_area
        WHERE release_id = $1
          AND area_id = (SELECT id FROM geo_genius.area WHERE area_key = 'a:t:c')
        """,
        [Ecto.UUID.dump!(release_id)]
      )

    assert stored_attributes == %{"population" => 10}

    assert Catalog.publish_release(context, release_id)
    assert Catalog.published_release(context, "demo") == release_id
  end

  test "a boundary binds a Geo struct and a centroid binds a geography point",
       %{context: context} do
    release_id = open_demo(context)
    Catalog.upsert_authority(context, "demo", %{key: "a", name: "A"})
    Catalog.upsert_area_type(context, "demo", %{key: "t", rank: 10})
    Catalog.upsert_area(context, "demo", %{authority_key: "a", area_type_key: "t", code: "c"})
    Catalog.put_area_name(context, "a:t:c", %{name: "Area", kind: "official", locale: nil})

    Catalog.upsert_source(context, "demo", %{source_key: "s", provider: "geojson", license: "CC0"})

    source_release_id =
      Catalog.upsert_source_release(context, "demo", %{
        source_key: "s",
        release_key: "v1",
        source_date: nil,
        metadata: %{}
      })

    Catalog.attach_source_release(context, release_id, source_release_id)

    Catalog.put_area_in_release(context, release_id, "a:t:c", %{
      centroid: %Geo.Point{coordinates: {0.5, 0.5}, srid: 4326},
      attributes: %{}
    })

    assert :ok =
             Catalog.put_boundary(context, release_id, "a:t:c", %{
               source_release_id: source_release_id,
               geometry: %Geo.Polygon{
                 coordinates: [[{0.0, 0.0}, {1.0, 0.0}, {1.0, 1.0}, {0.0, 1.0}, {0.0, 0.0}]],
                 srid: 4326
               },
               simplify_tolerance: 0.0
             })

    assert [match] = GeoGenius.areas_for_point(0.5, 0.5, release_id: release_id)
    assert match.area_key == "a:t:c"
  end

  test "rebuild_relations measures one relation from two overlapping boundaries",
       %{context: context} do
    release_id = open_demo(context)
    Catalog.upsert_authority(context, "demo", %{key: "a", name: "A"})
    Catalog.upsert_area_type(context, "demo", %{key: "outer", rank: 10})
    Catalog.upsert_area_type(context, "demo", %{key: "inner", rank: 20})
    Catalog.upsert_area(context, "demo", %{authority_key: "a", area_type_key: "outer", code: "A"})
    Catalog.upsert_area(context, "demo", %{authority_key: "a", area_type_key: "inner", code: "B"})
    Catalog.put_area_name(context, "a:outer:A", %{name: "Outer", kind: "official", locale: nil})
    Catalog.put_area_name(context, "a:inner:B", %{name: "Inner", kind: "official", locale: nil})

    Catalog.upsert_source(context, "demo", %{source_key: "s", provider: "geojson", license: "CC0"})

    source_release_id =
      Catalog.upsert_source_release(context, "demo", %{
        source_key: "s",
        release_key: "v1",
        source_date: nil,
        metadata: %{}
      })

    Catalog.attach_source_release(context, release_id, source_release_id)

    Catalog.put_area_in_release(context, release_id, "a:outer:A", %{
      centroid: %Geo.Point{coordinates: {0.25, 0.25}, srid: 4326},
      attributes: %{}
    })

    Catalog.put_area_in_release(context, release_id, "a:inner:B", %{
      centroid: %Geo.Point{coordinates: {0.1, 0.1}, srid: 4326},
      attributes: %{}
    })

    outer_square = %Geo.Polygon{
      coordinates: [[{0.0, 0.0}, {1.0, 0.0}, {1.0, 1.0}, {0.0, 1.0}, {0.0, 0.0}]],
      srid: 4326
    }

    inner_square = %Geo.Polygon{
      coordinates: [[{0.0, 0.0}, {0.5, 0.0}, {0.5, 0.5}, {0.0, 0.5}, {0.0, 0.0}]],
      srid: 4326
    }

    Catalog.put_boundary(context, release_id, "a:outer:A", %{
      source_release_id: source_release_id,
      geometry: outer_square,
      simplify_tolerance: 0.0
    })

    Catalog.put_boundary(context, release_id, "a:inner:B", %{
      source_release_id: source_release_id,
      geometry: inner_square,
      simplify_tolerance: 0.0
    })

    assert Catalog.rebuild_relations(context, release_id) == 1
  end

  test "put_relation asserts a relation between two areas in a release",
       %{context: context} do
    release_id = open_demo(context)
    Catalog.upsert_authority(context, "demo", %{key: "a", name: "A"})
    Catalog.upsert_area_type(context, "demo", %{key: "t", rank: 10})

    Catalog.upsert_area(context, "demo", %{authority_key: "a", area_type_key: "t", code: "parent"})

    Catalog.upsert_area(context, "demo", %{authority_key: "a", area_type_key: "t", code: "child"})
    Catalog.put_area_name(context, "a:t:parent", %{name: "Parent", kind: "official", locale: nil})
    Catalog.put_area_name(context, "a:t:child", %{name: "Child", kind: "official", locale: nil})

    Catalog.put_area_in_release(context, release_id, "a:t:parent", %{
      centroid: %Geo.Point{coordinates: {0.0, 0.0}, srid: 4326},
      attributes: %{}
    })

    Catalog.put_area_in_release(context, release_id, "a:t:child", %{
      centroid: %Geo.Point{coordinates: {0.1, 0.1}, srid: 4326},
      attributes: %{}
    })

    assert :ok =
             Catalog.put_relation(context, release_id, %{
               parent_area_key: "a:t:parent",
               child_area_key: "a:t:child",
               relation_type: "contains"
             })

    %Postgrex.Result{rows: rows} =
      TestRepo.query!(
        """
        SELECT relation_type FROM geo_genius.relation
        WHERE parent_area_id = (SELECT id FROM geo_genius.area WHERE area_key = 'a:t:parent')
          AND child_area_id = (SELECT id FROM geo_genius.area WHERE area_key = 'a:t:child')
        """,
        []
      )

    assert rows == [["contains"]]
  end

  test "put_area_code sets an external code on an area", %{context: context} do
    release_id = open_demo(context)
    Catalog.upsert_authority(context, "demo", %{key: "a", name: "A"})
    Catalog.upsert_area_type(context, "demo", %{key: "t", rank: 10})
    Catalog.upsert_area(context, "demo", %{authority_key: "a", area_type_key: "t", code: "c"})
    Catalog.put_area_name(context, "a:t:c", %{name: "Area", kind: "official", locale: nil})

    Catalog.put_area_in_release(context, release_id, "a:t:c", %{
      centroid: %Geo.Point{coordinates: {0.0, 0.0}, srid: 4326},
      attributes: %{}
    })

    code_id = Catalog.put_area_code(context, "a:t:c", %{code_type: "fips", code_value: "12345"})

    assert {:ok, _} = Ecto.UUID.cast(code_id)

    # A wrapper that transposed `code_type` and `code_value` would still
    # return a valid uuid above and store `code_type = "12345"`,
    # `code_value = "fips"`. Looking the area up by the code it was given
    # proves the values landed in the right columns.
    assert [match] =
             GeoGenius.areas_by_code("fips", "12345",
               release_id: release_id,
               repo: TestRepo,
               prefix: "geo_genius"
             )

    assert match.area_key == "a:t:c"
  end

  test "rollback_publication returns nil for a collection the catalog does not carry",
       %{context: context} do
    assert Catalog.rollback_publication(context, "no_such_collection") == nil
  end

  test "rollback_publication raises when a published collection has no previous release",
       %{context: context} do
    release_id = open_demo(context)
    Catalog.upsert_authority(context, "demo", %{key: "a", name: "A"})
    Catalog.upsert_area_type(context, "demo", %{key: "t", rank: 10})
    Catalog.upsert_area(context, "demo", %{authority_key: "a", area_type_key: "t", code: "c"})
    Catalog.put_area_name(context, "a:t:c", %{name: "Area", kind: "official", locale: nil})

    Catalog.upsert_source(context, "demo", %{source_key: "s", provider: "geojson", license: "CC0"})

    source_release_id =
      Catalog.upsert_source_release(context, "demo", %{
        source_key: "s",
        release_key: "v1",
        source_date: nil,
        metadata: %{}
      })

    Catalog.attach_source_release(context, release_id, source_release_id)

    Catalog.put_area_in_release(context, release_id, "a:t:c", %{
      centroid: %Geo.Point{coordinates: {0.0, 0.0}, srid: 4326},
      attributes: %{}
    })

    Catalog.publish_release(context, release_id)

    error =
      assert_raise GeoGenius.CatalogError, fn ->
        Catalog.rollback_publication(context, "demo")
      end

    assert error.function == "rollback_publication"
    assert %Postgrex.Error{postgres: %{code: :check_violation}} = error.reason
  end

  test "analyze_release runs against a release's partitions without raising",
       %{context: context} do
    release_id = open_demo(context)

    assert :ok = Catalog.analyze_release(context, release_id)
  end

  test "retire_releases returns 0 for a collection with a single release",
       %{context: context} do
    open_demo(context)

    assert Catalog.retire_releases(context, "demo", 1) == 0
  end

  test "release_manifest returns the exact manifest a release was opened with, and nil for an unknown release",
       %{context: context} do
    release_id = open_demo(context)

    assert Catalog.release_manifest(context, release_id) == %{"release" => "r1"}
    assert Catalog.release_manifest(context, Ecto.UUID.generate()) == nil
  end

  test "release_artifacts returns one entry per attached artifact, and [] with no attached sources",
       %{context: context} do
    release_id = open_demo(context)

    assert Catalog.release_artifacts(context, release_id) == []

    Catalog.upsert_source(context, "demo", %{source_key: "s", provider: "geojson", license: "CC0"})

    source_release_id =
      Catalog.upsert_source_release(context, "demo", %{
        source_key: "s",
        release_key: "v1",
        source_date: nil,
        metadata: %{}
      })

    Catalog.put_artifact(context, source_release_id, %{
      logical_name: "areas.geojson",
      url: "https://example.test/areas.geojson",
      operator_supplied: false,
      format: "geojson",
      expected_sha256: String.duplicate("a", 64),
      expected_bytes: 1024,
      metadata: %{}
    })

    Catalog.attach_source_release(context, release_id, source_release_id)

    assert [artifact] = Catalog.release_artifacts(context, release_id)
    assert artifact["logical_name"] == "areas.geojson"
    assert artifact["source_release_id"] == source_release_id
  end

  describe "set writes" do
    test "upsert_area_many returns hyphenated ids in the caller's order",
         %{context: context} do
      open_demo(context)
      Catalog.upsert_authority(context, "demo", %{key: "a", name: "A"})
      Catalog.upsert_area_type(context, "demo", %{key: "t", rank: 10})
      Catalog.upsert_area_type(context, "demo", %{key: "u", rank: 20})

      ids =
        Catalog.upsert_area_many(context, "demo", [
          %{authority_key: "a", area_type_key: "t", code: "one"},
          %{authority_key: "a", area_type_key: "u", code: "two"},
          %{authority_key: "a", area_type_key: "t", code: "one"}
        ])

      assert [first, second, first] = ids
      assert first != second
      assert Enum.all?(ids, &String.contains?(&1, "-"))
      assert Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1)))

      # The three attrs are adjacent same-typed strings, so a wrapper that
      # transposed :area_type_key and :code would still return two distinct
      # ids. The composed area_key is what says which went where.
      assert stored_area_keys(context, "demo") == ["a:t:one", "a:u:two"]
    end

    test "the plural writes cost no round trip at all for an empty batch",
         %{context: context} do
      recording = %{context | repo: GeoGenius.RecordingRepo}

      assert Catalog.upsert_area_many(recording, "demo", []) == []
      assert Catalog.put_area_name_many(recording, []) == []
      assert Catalog.put_area_code_many(recording, []) == []
      assert Catalog.put_area_in_release_many(recording, Ecto.UUID.generate(), []) == :ok
      assert Catalog.put_relation_many(recording, Ecto.UUID.generate(), []) == :ok
      assert Catalog.put_boundaries(recording, Ecto.UUID.generate(), []) == :ok

      refute_received {:query, _sql, _params, _opts}
    end

    test "an empty batch still refuses a release id that is not a uuid",
         %{context: context} do
      assert_raise ArgumentError, fn ->
        Catalog.put_area_in_release_many(context, "not-a-uuid", [])
      end

      assert_raise ArgumentError, fn ->
        Catalog.put_relation_many(context, "not-a-uuid", [])
      end

      assert_raise ArgumentError, fn ->
        Catalog.put_boundaries(context, "not-a-uuid", [])
      end
    end

    test "a boundary batch is one typed query with ordered arrays and defaults",
         %{context: context} do
      {release_id, source_release_id} = boundary_fixture(context, ~w(one two))
      recording = %{context | repo: GeoGenius.RecordingRepo}
      first = square(0.0, 1.0)
      second = square(2.0, 3.0)

      assert :ok =
               Catalog.put_boundaries(recording, release_id, [
                 %{
                   area_key: "a:t:one",
                   source_release_id: source_release_id,
                   geometry: first,
                   display_tier: 3,
                   source_properties: %{"vintage" => "2026"}
                 },
                 %{
                   area_key: "a:t:two",
                   source_release_id: source_release_id,
                   geometry: second
                 }
               ])

      assert_received {:query, sql,
                       [dumped_release, area_keys, source_ids, geometries, tiers, properties],
                       _opts}

      assert sql =~
               ~s|"geo_genius".put_boundaries($1::uuid, $2::text[], $3::uuid[], $4::geometry[], $5::integer[], $6::jsonb[])|

      assert dumped_release == Ecto.UUID.dump!(release_id)
      assert area_keys == ["a:t:one", "a:t:two"]

      assert source_ids == [
               Ecto.UUID.dump!(source_release_id),
               Ecto.UUID.dump!(source_release_id)
             ]

      assert geometries == [first, second]
      assert tiers == [3, 0]
      assert properties == [%{"vintage" => "2026"}, %{}]
      refute_received {:query, _sql, _params, _opts}
    end

    test "a boundary batch keeps the last geometry for a repeated area",
         %{context: context} do
      {release_id, source_release_id} = boundary_fixture(context, ["one"])

      assert :ok =
               Catalog.put_boundaries(context, release_id, [
                 %{
                   area_key: "a:t:one",
                   source_release_id: source_release_id,
                   geometry: square(0.0, 1.0),
                   source_properties: %{"ordinal" => 1}
                 },
                 %{
                   area_key: "a:t:one",
                   source_release_id: source_release_id,
                   geometry: square(2.0, 3.0),
                   display_tier: 2,
                   source_properties: %{"ordinal" => 2}
                 }
               ])

      assert query_rows(context, """
             SELECT display_tier, source_properties, ST_AsText(geom)
               FROM geo_genius.boundary
             """) == [[2, %{"ordinal" => 2}, "POLYGON((2 2,3 2,3 3,2 3,2 2))"]]
    end

    test "put_boundary remains a one-element compatibility wrapper",
         %{context: context} do
      {release_id, source_release_id} = boundary_fixture(context, ["one"])
      recording = %{context | repo: GeoGenius.RecordingRepo}
      geometry = square(0.0, 1.0)

      assert :ok =
               Catalog.put_boundary(recording, release_id, "a:t:one", %{
                 source_release_id: source_release_id,
                 geometry: geometry,
                 source_properties: %{"origin" => "scalar"}
               })

      assert_received {:query, sql,
                       [
                         _release_id,
                         ["a:t:one"],
                         [_source_id],
                         [^geometry],
                         [0],
                         [%{"origin" => "scalar"}]
                       ], _opts}

      assert sql =~ "put_boundaries"
      refute_received {:query, _sql, _params, _opts}
    end

    test "put_boundary preserves a nonzero simplify tolerance on the singular SQL path",
         %{context: context} do
      {release_id, source_release_id} = boundary_fixture(context, ["one"])
      recording = %{context | repo: GeoGenius.RecordingRepo}
      geometry = square(0.0, 1.0)

      assert :ok =
               Catalog.put_boundary(recording, release_id, "a:t:one", %{
                 source_release_id: source_release_id,
                 geometry: geometry,
                 simplify_tolerance: 0.25
               })

      assert_received {:query, sql, [dumped_release, "a:t:one", dumped_source, ^geometry, 0.25],
                       _opts}

      assert sql =~ ~s|"geo_genius".put_boundary($1, $2, $3, $4, $5)|
      assert dumped_release == Ecto.UUID.dump!(release_id)
      assert dumped_source == Ecto.UUID.dump!(source_release_id)
      refute_received {:query, _sql, _params, _opts}
    end

    test "missing required boundary keys raise before the query", %{context: context} do
      recording = %{context | repo: GeoGenius.RecordingRepo}
      release_id = Ecto.UUID.generate()
      source_release_id = Ecto.UUID.generate()

      for boundary <- [
            %{source_release_id: source_release_id, geometry: square(0.0, 1.0)},
            %{area_key: "a:t:one", geometry: square(0.0, 1.0)},
            %{area_key: "a:t:one", source_release_id: source_release_id}
          ] do
        assert_raise KeyError, fn -> Catalog.put_boundaries(recording, release_id, [boundary]) end
      end

      refute_received {:query, _sql, _params, _opts}
    end

    test "names and codes land in the columns their keys name", %{context: context} do
      open_demo(context)
      Catalog.upsert_authority(context, "demo", %{key: "a", name: "A"})
      Catalog.upsert_area_type(context, "demo", %{key: "t", rank: 10})

      Catalog.upsert_area_many(context, "demo", [
        %{authority_key: "a", area_type_key: "t", code: "c"}
      ])

      # Every value here is distinguishable from every other, so a wrapper
      # that transposed :name with :kind, or :code_type with :code_value,
      # fails rather than writing a legal-looking row.
      Catalog.put_area_name_many(context, [
        %{area_key: "a:t:c", name: "Ville", kind: "alias", locale: "fr"},
        %{area_key: "a:t:c", name: "Town", kind: "official", locale: nil}
      ])

      Catalog.put_area_code_many(context, [
        %{area_key: "a:t:c", code_type: "fips", code_value: "01001"}
      ])

      assert query_rows(context, """
             SELECT name, kind, locale FROM geo_genius.area_name
              WHERE area_id = (SELECT id FROM geo_genius.area WHERE area_key = 'a:t:c')
              ORDER BY name
             """) == [["Town", "official", nil], ["Ville", "alias", "fr"]]

      assert query_rows(context, """
             SELECT code_type, code_value FROM geo_genius.area_code
              WHERE area_id = (SELECT id FROM geo_genius.area WHERE area_key = 'a:t:c')
             """) == [["fips", "01001"]]
    end

    test "a membership batch binds a geography array carrying a nil element",
         %{context: context} do
      release_id = open_demo(context)
      Catalog.upsert_authority(context, "demo", %{key: "a", name: "A"})
      Catalog.upsert_area_type(context, "demo", %{key: "t", rank: 10})

      Catalog.upsert_area_many(context, "demo", [
        %{authority_key: "a", area_type_key: "t", code: "placed"},
        %{authority_key: "a", area_type_key: "t", code: "unplaced"}
      ])

      assert :ok =
               Catalog.put_area_in_release_many(context, release_id, [
                 %{
                   area_key: "a:t:placed",
                   centroid: %Geo.Point{coordinates: {0.5, 1.5}, srid: 4326},
                   attributes: %{"population" => 10}
                 },
                 %{area_key: "a:t:unplaced", centroid: nil, attributes: %{}}
               ])

      assert query_rows(context, """
             SELECT area.area_key, ST_AsText(membership.centroid::geometry), membership.data
               FROM geo_genius.release_area membership
               JOIN geo_genius.area ON area.id = membership.area_id
              ORDER BY area.area_key
             """) == [
               ["a:t:placed", "POINT(0.5 1.5)", %{"population" => 10}],
               ["a:t:unplaced", nil, %{}]
             ]
    end

    test "a relation batch keeps parent and child on the sides it was given",
         %{context: context} do
      release_id = open_demo(context)
      Catalog.upsert_authority(context, "demo", %{key: "a", name: "A"})
      Catalog.upsert_area_type(context, "demo", %{key: "t", rank: 10})

      Catalog.upsert_area_many(context, "demo", [
        %{authority_key: "a", area_type_key: "t", code: "over"},
        %{authority_key: "a", area_type_key: "t", code: "under"}
      ])

      Catalog.put_area_in_release_many(context, release_id, [
        %{area_key: "a:t:over", centroid: nil, attributes: %{}},
        %{area_key: "a:t:under", centroid: nil, attributes: %{}}
      ])

      assert :ok =
               Catalog.put_relation_many(context, release_id, [
                 %{
                   parent_area_key: "a:t:over",
                   child_area_key: "a:t:under",
                   relation_type: "mostly_contains"
                 }
               ])

      assert query_rows(context, """
             SELECT parent.area_key, child.area_key, edge.relation_type
               FROM geo_genius.relation edge
               JOIN geo_genius.area parent ON parent.id = edge.parent_area_id
               JOIN geo_genius.area child ON child.id = edge.child_area_id
             """) == [["a:t:over", "a:t:under", "mostly_contains"]]
    end

    test "an area key nothing carries raises rather than shortening the batch",
         %{context: context} do
      open_demo(context)
      Catalog.upsert_authority(context, "demo", %{key: "a", name: "A"})
      Catalog.upsert_area_type(context, "demo", %{key: "t", rank: 10})

      Catalog.upsert_area_many(context, "demo", [
        %{authority_key: "a", area_type_key: "t", code: "c"}
      ])

      assert_raise GeoGenius.CatalogError, fn ->
        Catalog.put_area_name_many(context, [
          %{area_key: "a:t:c", name: "Town", kind: "official", locale: nil},
          %{area_key: "a:t:absent", name: "Nowhere", kind: "official", locale: nil}
        ])
      end
    end
  end

  defp stored_area_keys(context, collection_key) do
    context
    |> query_rows("""
    SELECT area.area_key FROM geo_genius.area
      JOIN geo_genius.collection ON collection.id = area.collection_id
     WHERE collection.key = '#{collection_key}'
     ORDER BY area.area_key
    """)
    |> Enum.map(fn [area_key] -> area_key end)
  end

  defp query_rows(%Context{repo: repo}, sql) do
    %Postgrex.Result{rows: rows} = repo.query!(sql, [])
    rows
  end

  defp boundary_fixture(context, codes) do
    release_id = open_demo(context)
    Catalog.upsert_authority(context, "demo", %{key: "a", name: "A"})
    Catalog.upsert_area_type(context, "demo", %{key: "t", rank: 10})

    Catalog.upsert_area_many(
      context,
      "demo",
      Enum.map(codes, &%{authority_key: "a", area_type_key: "t", code: &1})
    )

    Catalog.upsert_source(context, "demo", %{source_key: "s", provider: "geojson", license: "CC0"})

    source_release_id =
      Catalog.upsert_source_release(context, "demo", %{
        source_key: "s",
        release_key: "v1",
        source_date: nil,
        metadata: %{}
      })

    Catalog.attach_source_release(context, release_id, source_release_id)
    {release_id, source_release_id}
  end

  defp square(low, high) do
    %Geo.Polygon{
      coordinates: [[{low, low}, {high, low}, {high, high}, {low, high}, {low, low}]],
      srid: 4326
    }
  end
end
