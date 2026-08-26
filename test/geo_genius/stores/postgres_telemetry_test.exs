defmodule GeoGenius.Stores.PostgresTelemetryTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias GeoGenius.{Context, QueryError, Stores.Postgres, TestRepo}

  setup do
    TestRepo.query!("SELECT geo_genius_test.demo_fixture()", [])

    events = [
      [:geo_genius, :read, :start],
      [:geo_genius, :read, :stop],
      [:geo_genius, :read, :exception]
    ]

    test_pid = self()

    :telemetry.attach_many(
      "geo-genius-postgres-telemetry-test",
      events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach("geo-genius-postgres-telemetry-test")
      TestRepo.query!("SELECT geo_genius_test.demo_teardown()", [])
    end)

    {:ok, context: Context.new(repo: TestRepo, prefix: "geo_genius")}
  end

  test "a row-returning read reports its function, prefix, and row count", %{context: context} do
    assert [_, _] = Postgres.areas_for_point(context, 0.25, 0.25, [])

    assert_received {:event, [:geo_genius, :read, :start], start_measurements,
                     %{function: "areas_for_point", prefix: "geo_genius"}}

    assert is_integer(start_measurements.system_time)

    assert_received {:event, [:geo_genius, :read, :stop], stop_measurements,
                     %{function: "areas_for_point", prefix: "geo_genius", result_count: 2}}

    assert is_integer(stop_measurements.duration)
  end

  test "release_at reports result_count 1 for a found release and 0 for none", %{
    context: context
  } do
    assert release_id = Postgres.release_at(context, DateTime.utc_now(), collection: "demo")
    assert is_binary(release_id)

    assert_received {:event, [:geo_genius, :read, :stop], _,
                     %{function: "release_at", prefix: "geo_genius", result_count: 1}}

    assert nil ==
             Postgres.release_at(context, ~U[1970-01-01 00:00:00Z], collection: "demo")

    assert_received {:event, [:geo_genius, :read, :stop], _,
                     %{function: "release_at", prefix: "geo_genius", result_count: 0}}
  end

  test "result_count discriminates a two-row read from a scalar one-row read", %{
    context: context
  } do
    assert [_, _] = Postgres.areas_for_point(context, 0.25, 0.25, [])
    assert_received {:event, [:geo_genius, :read, :stop], _, %{result_count: two}}

    assert Postgres.release_at(context, DateTime.utc_now(), collection: "demo")
    assert_received {:event, [:geo_genius, :read, :stop], _, %{result_count: one}}

    assert two == 2
    assert one == 1
    refute two == one
  end

  test "a read that raises still emits an exception event and still surfaces a QueryError", %{
    context: context
  } do
    error =
      assert_raise QueryError, fn ->
        Postgres.areas_for_point(context, 0.25, 0.25, types: "outer")
      end

    assert error.function == "areas_for_point"

    assert_received {:event, [:geo_genius, :read, :exception], exception_measurements,
                     %{function: "areas_for_point", prefix: "geo_genius", reason: reason}}

    assert is_integer(exception_measurements.duration)
    assert %QueryError{function: "areas_for_point"} = reason

    refute_received {:event, [:geo_genius, :read, :stop], _, _}
  end
end
