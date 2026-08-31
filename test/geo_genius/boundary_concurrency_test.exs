defmodule GeoGenius.BoundaryConcurrencyTest do
  use ExUnit.Case, async: false

  alias GeoGenius.{Catalog, Context, ImportFixture, TestRepo}

  @moduletag :integration
  @moduletag timeout: 60_000

  setup do
    unique = System.unique_integer([:positive])
    collection = "boundary_concurrency_#{unique}"
    authority = "boundary_auth_#{unique}"
    context = Context.new(repo: TestRepo, prefix: "geo_genius")

    on_exit(fn -> ImportFixture.teardown!(collection) end)

    Catalog.upsert_collection(context, %{
      key: collection,
      name: collection,
      requires_geometry: true
    })

    Catalog.upsert_authority(context, collection, %{key: authority, name: "Authority"})
    Catalog.upsert_area_type(context, collection, %{key: "zone", rank: 10})

    for code <- ~w(a b) do
      Catalog.upsert_area(context, collection, %{
        authority_key: authority,
        area_type_key: "zone",
        code: code
      })

      Catalog.put_area_name(context, "#{authority}:zone:#{code}", %{
        name: String.upcase(code),
        kind: "official"
      })
    end

    release_id =
      Catalog.open_release(context, collection, %{
        release_key: "r1",
        manifest: %{"collection" => collection}
      })

    Catalog.upsert_source(context, collection, %{
      source_key: "source",
      provider: "test",
      license: "test"
    })

    source_release_id =
      Catalog.upsert_source_release(context, collection, %{
        source_key: "source",
        release_key: "v1"
      })

    Catalog.attach_source_release(context, release_id, source_release_id)

    for {code, offset} <- [{"a", 0.0}, {"b", 2.0}] do
      Catalog.put_boundary(context, release_id, "#{authority}:zone:#{code}", %{
        source_release_id: source_release_id,
        geometry: square(offset)
      })
    end

    %{rows: area_key_rows} =
      TestRepo.query!(
        "SELECT area_key FROM geo_genius.area WHERE area_key = ANY($1) ORDER BY id",
        [["#{authority}:zone:a", "#{authority}:zone:b"]]
      )

    {:ok,
     collection: collection,
     authority: authority,
     area_keys: List.flatten(area_key_rows),
     release_id: release_id,
     source_release_id: source_release_id}
  end

  test "plural and singular boundary writes serialize before touching boundary rows", fixture do
    [first_area_key, second_area_key] = fixture.area_keys
    blocker = raw_connection!()
    plural_worker = raw_connection!()
    singular_worker = raw_connection!()
    observer = raw_connection!()
    plural_pid = backend_pid(plural_worker)
    singular_pid = backend_pid(singular_worker)
    lock_sql = publication_lock_sql(fixture.collection)

    Postgrex.query!(blocker, "BEGIN", [])

    Postgrex.query!(
      blocker,
      """
      SELECT 1 FROM geo_genius.release_area membership
       JOIN geo_genius.area ON area.id = membership.area_id
      WHERE membership.release_id = $1 AND area.area_key = $2
      FOR UPDATE OF membership
      """,
      [dump(fixture.release_id), first_area_key]
    )

    plural =
      Task.async(fn ->
        Postgrex.query(plural_worker, plural_sql(), [
          dump(fixture.release_id),
          Enum.reverse(fixture.area_keys),
          [dump(fixture.source_release_id), dump(fixture.source_release_id)],
          [square(4.0), square(6.0)],
          [2, 2],
          [%{"writer" => "plural"}, %{"writer" => "plural"}]
        ])
      end)

    assert await_lock_wait(observer, plural_pid), "plural write did not wait on the held area"

    singular =
      Task.async(fn ->
        Postgrex.query(singular_worker, singular_sql(), [
          dump(fixture.release_id),
          second_area_key,
          dump(fixture.source_release_id),
          square(8.0),
          0.0
        ])
      end)

    assert await_advisory_wait(observer, singular_pid, lock_sql),
           "singular write did not wait behind the plural writer"

    Postgrex.query!(blocker, "COMMIT", [])
    assert {:ok, _result} = Task.await(plural, 10_000)
    assert {:ok, _result} = Task.await(singular, 10_000)

    assert %{rows: [[2, 1, 0, 0]]} =
             TestRepo.query!(
               """
               SELECT
                 (SELECT count(*)::int FROM geo_genius.boundary
                   WHERE release_id = $1),
                 (SELECT max(tier_count)::int FROM (
                    SELECT count(*) AS tier_count FROM geo_genius.boundary
                     WHERE release_id = $1 GROUP BY area_id
                  ) tiers),
                 (SELECT count(*)::int
                    FROM geo_genius.boundary boundary
                    JOIN geo_genius.boundary_part part
                      ON part.release_id = boundary.release_id
                     AND part.area_id = boundary.area_id
                   WHERE boundary.release_id = $1
                     AND NOT ST_CoveredBy(part.geom, boundary.geom)),
                 (SELECT display_tier FROM geo_genius.boundary boundary
                    JOIN geo_genius.area ON area.id = boundary.area_id
                   WHERE boundary.release_id = $1 AND area.area_key = $2)
               """,
               [dump(fixture.release_id), second_area_key]
             )
  end

  test "publication wins its lifecycle lock and a waiting boundary write rechecks mutability",
       fixture do
    publisher = raw_connection!()
    writer = raw_connection!()
    observer = raw_connection!()
    writer_pid = backend_pid(writer)
    lock_sql = publication_lock_sql(fixture.collection)

    Postgrex.query!(publisher, "BEGIN", [])
    Postgrex.query!(publisher, "SELECT pg_advisory_xact_lock(#{lock_sql})", [])

    writing =
      Task.async(fn ->
        Postgrex.query(writer, plural_sql(), [
          dump(fixture.release_id),
          ["#{fixture.authority}:zone:a"],
          [dump(fixture.source_release_id)],
          [square(10.0)],
          [0],
          [%{}]
        ])
      end)

    assert await_advisory_wait(observer, writer_pid, lock_sql),
           "boundary write did not wait on the collection publication lock"

    Postgrex.query!(publisher, "SELECT geo_genius.publish_release($1)", [
      dump(fixture.release_id)
    ])

    Postgrex.query!(publisher, "COMMIT", [])

    assert {:error, %Postgrex.Error{postgres: %{code: :object_not_in_prerequisite_state}}} =
             Task.await(writing, 10_000)

    assert Catalog.published_release(
             Context.new(repo: TestRepo, prefix: "geo_genius"),
             fixture.collection
           ) == fixture.release_id
  end

  test "a publisher waiting on a plural writer verifies only after the writer commits",
       fixture do
    writer = raw_connection!()
    publisher = raw_connection!()
    observer = raw_connection!()
    publisher_pid = backend_pid(publisher)
    lock_sql = publication_lock_sql(fixture.collection)

    Postgrex.query!(writer, "BEGIN", [])

    Postgrex.query!(writer, plural_sql(), [
      dump(fixture.release_id),
      ["#{fixture.authority}:zone:a"],
      [dump(fixture.source_release_id)],
      [square(12.0)],
      [2],
      [%{}]
    ])

    publishing =
      Task.async(fn ->
        Postgrex.query(publisher, "SELECT geo_genius.publish_release($1)", [
          dump(fixture.release_id)
        ])
      end)

    assert await_advisory_wait(observer, publisher_pid, lock_sql),
           "publisher did not wait on the plural writer's publication lock"

    Postgrex.query!(writer, "COMMIT", [])

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Task.await(publishing, 10_000)

    assert Catalog.published_release(
             Context.new(repo: TestRepo, prefix: "geo_genius"),
             fixture.collection
           ) == nil
  end

  test "a nonzero-tolerance singular write waits for publication and rechecks mutability",
       fixture do
    publisher = raw_connection!()
    writer = raw_connection!()
    observer = raw_connection!()
    writer_pid = backend_pid(writer)
    lock_sql = publication_lock_sql(fixture.collection)

    Postgrex.query!(publisher, "BEGIN", [])
    Postgrex.query!(publisher, "SELECT pg_advisory_xact_lock(#{lock_sql})", [])

    writing =
      Task.async(fn ->
        Postgrex.query(writer, singular_sql(), [
          dump(fixture.release_id),
          "#{fixture.authority}:zone:a",
          dump(fixture.source_release_id),
          square(14.0),
          0.25
        ])
      end)

    assert await_advisory_wait(observer, writer_pid, lock_sql),
           "singular boundary write did not wait on the collection publication lock"

    Postgrex.query!(publisher, "SELECT geo_genius.publish_release($1)", [
      dump(fixture.release_id)
    ])

    Postgrex.query!(publisher, "COMMIT", [])

    assert {:error, %Postgrex.Error{postgres: %{code: :object_not_in_prerequisite_state}}} =
             Task.await(writing, 10_000)
  end

  defp plural_sql do
    """
    SELECT geo_genius.put_boundaries(
      $1::uuid, $2::text[], $3::uuid[], $4::geometry[], $5::integer[], $6::jsonb[])
    """
  end

  defp singular_sql do
    "SELECT geo_genius.put_boundary($1::uuid, $2::text, $3::uuid, $4::geometry, $5::float8)"
  end

  defp publication_lock_sql(collection) do
    %{rows: [[collection_id]]} =
      TestRepo.query!("SELECT id::text FROM geo_genius.collection WHERE key = $1", [collection])

    "geo_genius.publication_lock_key('#{collection_id}'::uuid)"
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
        reference = Process.monitor(connection)
        Process.exit(connection, :shutdown)

        receive do
          {:DOWN, ^reference, :process, _pid, _reason} -> :ok
        after
          5_000 -> :ok
        end
      end
    end)

    connection
  end

  defp backend_pid(connection) do
    %{rows: [[pid]]} = Postgrex.query!(connection, "SELECT pg_backend_pid()", [])
    pid
  end

  defp await_lock_wait(observer, backend_pid, attempts \\ 100) do
    %{rows: [[waiting]]} =
      Postgrex.query!(
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

  defp await_advisory_wait(observer, backend_pid, key_sql, attempts \\ 100) do
    %{rows: [[waiting]]} =
      Postgrex.query!(
        observer,
        """
        SELECT count(*) > 0 FROM pg_locks
         WHERE pid = $1 AND locktype = 'advisory' AND NOT granted
           AND classid = ((((#{key_sql}) >> 32) & 4294967295))::oid
           AND objid = (((#{key_sql}) & 4294967295))::oid
        """,
        [backend_pid]
      )

    cond do
      waiting ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(25) && await_advisory_wait(observer, backend_pid, key_sql, attempts - 1)
    end
  end

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)

  defp square(offset) do
    %Geo.Polygon{
      coordinates: [
        [
          {offset, offset},
          {offset + 1.0, offset},
          {offset + 1.0, offset + 1.0},
          {offset, offset + 1.0},
          {offset, offset}
        ]
      ],
      srid: 4326
    }
  end
end
