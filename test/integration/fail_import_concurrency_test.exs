defmodule GeoGenius.FailImportConcurrencyTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Ecto.Adapters.SQL
  alias GeoGenius.TestRepo

  test "publication wins cleanly over a failure report already waiting on the run row" do
    candidate = publishable_candidate!()
    blocker = raw_connection!()
    publisher = raw_connection!()
    reporter = raw_connection!()
    publisher_backend_pid = backend_pid(publisher)
    reporter_backend_pid = backend_pid(reporter)

    Postgrex.query!(blocker, "BEGIN", [])

    Postgrex.query!(
      blocker,
      "SELECT 1 FROM geo_genius.import_run WHERE id = $1 FOR UPDATE",
      [candidate.run_id]
    )

    publish =
      Task.async(fn ->
        Postgrex.query(
          publisher,
          "SELECT geo_genius.publish_import($1, $2)",
          [candidate.run_id, candidate.executor_id],
          timeout: 30_000
        )
      end)

    assert await_lock_wait(TestRepo, publisher_backend_pid)

    fail =
      Task.async(fn ->
        Postgrex.query(
          reporter,
          "SELECT geo_genius.fail_import($1, $2, $3)",
          [candidate.run_id, candidate.executor_id, %{"reason" => "late failure"}],
          timeout: 30_000
        )
      end)

    refute Task.yield(fail, 100)
    assert await_lock_wait(TestRepo, reporter_backend_pid)
    Postgrex.query!(blocker, "COMMIT", [])

    assert {:ok, %Postgrex.Result{}} = Task.await(publish, 30_000)

    assert {:error, %Postgrex.Error{postgres: %{code: :object_not_in_prerequisite_state}}} =
             Task.await(fail, 30_000)

    assert %{rows: [["completed", nil]]} =
             TestRepo.query!(
               "SELECT status, error FROM geo_genius.import_run WHERE id = $1",
               [candidate.run_id]
             )
  end

  test "simultaneous failure reports preserve the first committed evidence" do
    candidate = publishable_candidate!()
    blocker = raw_connection!()
    first_reporter = raw_connection!()
    second_reporter = raw_connection!()
    first_backend_pid = backend_pid(first_reporter)
    second_backend_pid = backend_pid(second_reporter)

    Postgrex.query!(blocker, "BEGIN", [])

    Postgrex.query!(
      blocker,
      "SELECT 1 FROM geo_genius.import_run WHERE id = $1 FOR UPDATE",
      [candidate.run_id]
    )

    first =
      Task.async(fn ->
        Postgrex.query(
          first_reporter,
          "SELECT geo_genius.fail_import($1, $2, $3)",
          [candidate.run_id, candidate.executor_id, %{"reason" => "first evidence"}],
          timeout: 30_000
        )
      end)

    refute Task.yield(first, 100)
    assert await_lock_wait(TestRepo, first_backend_pid)

    second =
      Task.async(fn ->
        Postgrex.query(
          second_reporter,
          "SELECT geo_genius.fail_import($1, $2, $3)",
          [candidate.run_id, candidate.executor_id, %{"reason" => "second evidence"}],
          timeout: 30_000
        )
      end)

    assert await_lock_wait(TestRepo, second_backend_pid)
    Postgrex.query!(blocker, "COMMIT", [])

    assert {:ok, %Postgrex.Result{}} = Task.await(first, 30_000)
    assert {:ok, %Postgrex.Result{}} = Task.await(second, 30_000)

    assert %{rows: [["failed", %{"reason" => "first evidence"}]]} =
             TestRepo.query!(
               "SELECT status, error FROM geo_genius.import_run WHERE id = $1",
               [candidate.run_id]
             )
  end

  test "an executor that does not own the active lease cannot fail the run" do
    candidate = publishable_candidate!()

    assert {:error, %Postgrex.Error{postgres: %{code: :object_not_in_prerequisite_state}}} =
             TestRepo.query(
               "SELECT geo_genius.fail_import($1, $2, $3)",
               [candidate.run_id, uuid!(), %{"reason" => "foreign executor"}]
             )

    assert %{rows: [["publishing", nil, true]]} =
             TestRepo.query!(
               """
               SELECT import_run.status,
                      import_run.error,
                      import_run_lease.executor_id = $2
                 FROM geo_genius.import_run
                 JOIN geo_genius.import_run_lease
                   ON import_run_lease.run_id = import_run.id
                WHERE import_run.id = $1
               """,
               [candidate.run_id, candidate.executor_id]
             )
  end

  defp publishable_candidate! do
    suffix = System.unique_integer([:positive])
    collection_key = "fail_race_#{suffix}"
    collection_id = uuid!()
    authority_id = uuid!()
    area_type_id = uuid!()
    area_id = uuid!()
    source_id = uuid!()
    source_release_id = uuid!()
    release_id = uuid!()
    run_id = uuid!()
    executor_id = uuid!()

    TestRepo.transaction(fn ->
      TestRepo.query!(
        "INSERT INTO geo_genius.collection (id, key) VALUES ($1, $2)",
        [collection_id, collection_key]
      )

      TestRepo.query!(
        "INSERT INTO geo_genius.authority (id, collection_id, key) VALUES ($1, $2, 'authority')",
        [authority_id, collection_id]
      )

      TestRepo.query!(
        "INSERT INTO geo_genius.area_type (id, collection_id, key) VALUES ($1, $2, 'area')",
        [area_type_id, collection_id]
      )

      TestRepo.query!(
        """
        INSERT INTO geo_genius.release
          (id, collection_id, release_key, status, manifest)
        VALUES ($1, $2, 'v1', 'publishing', '{}'::jsonb)
        """,
        [release_id, collection_id]
      )

      TestRepo.query!("SELECT geo_genius.create_release_partitions($1)", [release_id])

      TestRepo.query!(
        """
        INSERT INTO geo_genius.release_collection_policy
          (release_id, name, requires_geometry)
        VALUES ($1, 'Failure race fixture', false)
        """,
        [release_id]
      )

      TestRepo.query!(
        "INSERT INTO geo_genius.release_authority (release_id, authority_id, name) VALUES ($1, $2, 'Authority')",
        [release_id, authority_id]
      )

      TestRepo.query!(
        """
        INSERT INTO geo_genius.release_area_type
          (release_id, area_type_id, rank, requires_geometry)
        VALUES ($1, $2, 10, false)
        """,
        [release_id, area_type_id]
      )

      TestRepo.query!(
        """
        INSERT INTO geo_genius.source (id, collection_id, source_key, provider, license)
        VALUES ($1, $2, 'source', 'fixture', 'test')
        """,
        [source_id, collection_id]
      )

      TestRepo.query!(
        "INSERT INTO geo_genius.source_release (id, source_id, release_key) VALUES ($1, $2, 'v1')",
        [source_release_id, source_id]
      )

      TestRepo.query!(
        "INSERT INTO geo_genius.release_source (release_id, source_release_id) VALUES ($1, $2)",
        [release_id, source_release_id]
      )

      TestRepo.query!(
        """
        INSERT INTO geo_genius.area
          (id, collection_id, authority_id, area_type_id, code, area_key)
        VALUES ($1, $2, $3, $4, 'A', $5)
        """,
        [area_id, collection_id, authority_id, area_type_id, "#{collection_key}:authority:area:A"]
      )

      TestRepo.query!(
        """
        INSERT INTO geo_genius.release_area
          (release_id, area_id, official_name, data)
        VALUES ($1, $2, 'Area A', '{}'::jsonb)
        """,
        [release_id, area_id]
      )

      TestRepo.query!(
        """
        INSERT INTO geo_genius.import_run
          (id, release_id, status, owner, runner_backend, manifest)
        VALUES ($1, $2, 'publishing', 'failure-race', 'test', '{}'::jsonb)
        """,
        [run_id, release_id]
      )

      TestRepo.query!(
        """
        INSERT INTO geo_genius.import_run_lease
          (run_id, release_id, executor_id, execution_started_at)
        VALUES ($1, $2, $3, clock_timestamp())
        """,
        [run_id, release_id, executor_id]
      )
    end)

    on_exit(fn ->
      TestRepo.query!("DELETE FROM geo_genius.import_run_lease WHERE release_id = $1", [
        release_id
      ])

      TestRepo.query!("SELECT geo_genius.drop_release_partitions($1)", [release_id])

      TestRepo.query!("DELETE FROM geo_genius.publication WHERE collection_id = $1", [
        collection_id
      ])

      TestRepo.query!("DELETE FROM geo_genius.release WHERE id = $1", [release_id])

      TestRepo.query!("DELETE FROM geo_genius.source_release WHERE id = $1", [
        source_release_id
      ])

      TestRepo.query!("DELETE FROM geo_genius.collection WHERE id = $1", [collection_id])
    end)

    %{run_id: run_id, executor_id: executor_id}
  end

  defp raw_connection! do
    config = TestRepo.config()

    {:ok, connection} =
      Postgrex.start_link(
        hostname: config[:hostname],
        port: config[:port],
        username: config[:username],
        password: config[:password],
        database: config[:database],
        types: config[:types]
      )

    on_exit(fn ->
      if Process.alive?(connection) do
        Process.exit(connection, :shutdown)
      end
    end)

    connection
  end

  defp backend_pid(connection) do
    %{rows: [[pid]]} = Postgrex.query!(connection, "SELECT pg_backend_pid()", [])
    pid
  end

  defp await_lock_wait(observer, backend_pid, attempts \\ 200) do
    %{rows: [[waiting]]} =
      SQL.query!(
        observer,
        "SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = $1",
        [backend_pid]
      )

    cond do
      waiting -> true
      attempts == 0 -> false
      true -> Process.sleep(25) && await_lock_wait(observer, backend_pid, attempts - 1)
    end
  end

  defp uuid!, do: Ecto.UUID.generate() |> Ecto.UUID.dump!()
end
