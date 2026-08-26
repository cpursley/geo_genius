defmodule GeoGenius.StagingTest do
  use ExUnit.Case, async: false

  alias GeoGenius.{Catalog, Context, GraphFixture, Staging, StagingError}

  setup do
    GraphFixture.teardown!()
    on_exit(&GraphFixture.teardown!/0)

    context = Context.new(repo: GeoGenius.TestRepo, prefix: "geo_genius")
    Catalog.upsert_collection(context, %{key: "demo", name: "Demo", description: nil})

    release_id =
      Catalog.open_release(context, "demo", %{
        release_key: "r1",
        manifest: %{},
        source_date: nil
      })

    run_id =
      Catalog.begin_or_resume_import(context, release_id, %{
        owner: "worker-1",
        runner_backend: "test",
        stale_after_seconds: 300
      })

    on_exit(fn -> Staging.drop(context, run_id) end)

    {:ok, context: context, run_id: run_id}
  end

  test "the Elixir table-name derivation matches the SQL one",
       %{context: context, run_id: run_id} do
    assert Staging.create(context, run_id) == Staging.table_name(run_id)
  end

  test "table_name refuses anything that is not a uuid" do
    for bad <- [
          "nope",
          "",
          "; DROP TABLE x",
          "staging_x",
          # 32 valid hex characters plus a trailing payload: an unanchored
          # `[0-9a-f]{32}` would match the leading substring and let this
          # through to interpolate straight into a query.
          "0123456789abcdef0123456789abcdef\"; DROP TABLE boundary; --"
        ] do
      assert_raise ArgumentError, fn -> Staging.table_name(bad) end
    end
  end

  test "inserts a batch and reads it back", %{context: context, run_id: run_id} do
    Staging.create(context, run_id)

    rows = [
      %Staging.Row{
        artifact: "a.geojson",
        payload: %{"id" => "1", "name" => "One"},
        geom: %Geo.Point{coordinates: {1.0, 2.0}, srid: 4326}
      },
      %Staging.Row{
        artifact: "a.geojson",
        payload: %{"id" => "2", "name" => "Two"},
        geom: nil
      }
    ]

    assert Staging.insert(context, run_id, rows) == 2
    assert Staging.count(context, run_id) == 2

    read = context |> Staging.stream(run_id) |> Enum.to_list()

    assert length(read) == 2
    assert Enum.map(read, & &1.payload["id"]) == ["1", "2"]
    assert Enum.map(read, & &1.artifact) == ["a.geojson", "a.geojson"]
  end

  test "the payload arrives as a decoded object, not a JSON string",
       %{context: context, run_id: run_id} do
    Staging.create(context, run_id)

    Staging.insert(context, run_id, [
      %Staging.Row{artifact: "a", payload: %{"nested" => %{"k" => [1, 2]}}, geom: nil}
    ])

    assert [row] = context |> Staging.stream(run_id) |> Enum.to_list()
    assert row.payload == %{"nested" => %{"k" => [1, 2]}}
    refute is_binary(row.payload)
  end

  test "geometry round-trips as a Geo struct and nil stays nil",
       %{context: context, run_id: run_id} do
    Staging.create(context, run_id)

    polygon = %Geo.Polygon{
      coordinates: [[{0.0, 0.0}, {1.0, 0.0}, {1.0, 1.0}, {0.0, 1.0}, {0.0, 0.0}]],
      srid: 4326
    }

    Staging.insert(context, run_id, [
      %Staging.Row{artifact: "a", payload: %{"n" => 1}, geom: polygon},
      %Staging.Row{artifact: "a", payload: %{"n" => 2}, geom: nil}
    ])

    assert [first, second] = context |> Staging.stream(run_id) |> Enum.to_list()
    assert %Geo.Polygon{srid: 4326} = first.geom
    assert first.geom.coordinates == polygon.coordinates
    assert second.geom == nil
  end

  test "streams across more rows than one batch holds", %{context: context, run_id: run_id} do
    Staging.create(context, run_id)

    rows =
      for n <- 1..2500 do
        %Staging.Row{artifact: "a", payload: %{"n" => n}, geom: nil}
      end

    rows |> Enum.chunk_every(500) |> Enum.each(&Staging.insert(context, run_id, &1))

    assert Staging.count(context, run_id) == 2500

    read = context |> Staging.stream(run_id, batch_size: 100) |> Enum.to_list()

    assert length(read) == 2500
    assert Enum.map(read, & &1.payload["n"]) == Enum.to_list(1..2500)
  end

  test "streams in pages rather than one unbounded query", %{context: context, run_id: run_id} do
    Staging.create(context, run_id)

    rows =
      for n <- 1..2500 do
        %Staging.Row{artifact: "a", payload: %{"n" => n}, geom: nil}
      end

    rows |> Enum.chunk_every(500) |> Enum.each(&Staging.insert(context, run_id, &1))

    test_pid = self()
    handler_id = "staging-round-trip-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:geo_genius, :test_repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if String.contains?(query, "ORDER BY id") do
          send(test_pid, :page_query)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    read = context |> Staging.stream(run_id, batch_size: 100) |> Enum.to_list()

    assert length(read) == 2500

    # A page of exactly 2500/100 rows never comes back short, so one more
    # query -- the page that comes back empty -- is what tells the stream to
    # halt. A `stream/3` that issues a single unbounded `SELECT` and ignores
    # `:batch_size` would return the same 2500 rows in the same order through
    # exactly one query here, passing every other assertion in this file
    # while failing only this one.
    assert count_received(:page_query) == div(2500, 100) + 1
  end

  test "an empty batch inserts nothing and does not fail",
       %{context: context, run_id: run_id} do
    Staging.create(context, run_id)

    assert Staging.insert(context, run_id, []) == 0
    assert Staging.count(context, run_id) == 0
  end

  test "an empty batch still validates run_id rather than short-circuiting", %{context: context} do
    assert_raise ArgumentError, fn -> Staging.insert(context, "not-a-uuid", []) end
  end

  test "drop removes the table and is idempotent", %{context: context, run_id: run_id} do
    Staging.create(context, run_id)

    Staging.insert(context, run_id, [
      %Staging.Row{artifact: "a", payload: %{"n" => 1}, geom: nil}
    ])

    assert Staging.count(context, run_id) == 1

    assert :ok = Staging.drop(context, run_id)
    assert_raise StagingError, fn -> Staging.count(context, run_id) end

    assert :ok = Staging.drop(context, run_id)
  end

  test "a value the driver cannot encode surfaces as a StagingError, not a bare driver error",
       %{context: context, run_id: run_id} do
    Staging.create(context, run_id)

    error =
      assert_raise StagingError, fn ->
        Staging.insert(context, run_id, [
          %Staging.Row{artifact: "a", payload: %{"n" => 1}, geom: %{"type" => "Point"}}
        ])
      end

    assert error.operation == "insert"
  end

  test "stream refuses a non-positive batch_size", %{context: context, run_id: run_id} do
    Staging.create(context, run_id)

    assert_raise ArgumentError, fn -> Staging.stream(context, run_id, batch_size: 0) end
    assert_raise ArgumentError, fn -> Staging.stream(context, run_id, batch_size: -1) end
  end

  defp count_received(tag, acc \\ 0) do
    receive do
      ^tag -> count_received(tag, acc + 1)
    after
      0 -> acc
    end
  end
end
