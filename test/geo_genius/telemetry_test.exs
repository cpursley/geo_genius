defmodule GeoGenius.TelemetryTest do
  use ExUnit.Case, async: false

  alias GeoGenius.Telemetry

  setup do
    events = [
      [:geo_genius, :read, :start],
      [:geo_genius, :read, :stop],
      [:geo_genius, :read, :exception],
      [:geo_genius, :import, :start],
      [:geo_genius, :import, :stop],
      [:geo_genius, :import, :exception]
    ]

    test_pid = self()

    :telemetry.attach_many(
      "geo-genius-telemetry-test",
      events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("geo-genius-telemetry-test") end)
    :ok
  end

  test "emits start and stop around a read, counting results" do
    assert [1, 2, 3] ==
             Telemetry.span("areas_for_point", %{prefix: "geo_genius"}, fn -> [1, 2, 3] end)

    assert_received {:event, [:geo_genius, :read, :start], _, %{function: "areas_for_point"}}
    assert_received {:event, [:geo_genius, :read, :stop], measurements, metadata}
    assert is_integer(measurements.duration)
    assert metadata.result_count == 3
    assert metadata.prefix == "geo_genius"
  end

  test "emits an exception event and re-raises" do
    assert_raise RuntimeError, fn ->
      Telemetry.span("search_areas", %{prefix: "geo_genius"}, fn -> raise "boom" end)
    end

    assert_received {:event, [:geo_genius, :read, :exception], _, %{function: "search_areas"}}
  end

  test "an import phase spans on its own event, carrying its metrics and outcome" do
    metadata = %{
      run_id: "run-1",
      release_id: "rel-1",
      collection_key: "demo",
      prefix: "geo_genius"
    }

    assert :staged ==
             Telemetry.import_span("staging", metadata, fn ->
               {:staged, %{"staged" => 3}, :ok}
             end)

    assert_received {:event, [:geo_genius, :import, :start], _, %{phase: "staging"}}
    assert_received {:event, [:geo_genius, :import, :stop], measurements, stop_metadata}
    assert is_integer(measurements.duration)

    # The stop event has to carry both: `:metrics` says what the phase
    # produced, `:status` says whether it produced it at all, and a phase that
    # measures nothing on success is indistinguishable from a failed one
    # without the second.
    assert stop_metadata.metrics == %{"staged" => 3}
    assert stop_metadata.status == :ok
    assert stop_metadata.collection_key == "demo"
    assert stop_metadata.run_id == "run-1"
  end

  test "an import phase that returns an error stops with :status :error" do
    assert {:error, "no"} ==
             Telemetry.import_span("verifying", %{prefix: "geo_genius"}, fn ->
               {{:error, "no"}, %{}, :error}
             end)

    assert_received {:event, [:geo_genius, :import, :stop], _, %{status: :error, metrics: %{}}}
  end

  test "an import phase that raises emits an exception event and re-raises" do
    assert_raise RuntimeError, fn ->
      Telemetry.import_span("staging", %{prefix: "geo_genius"}, fn -> raise "boom" end)
    end

    assert_received {:event, [:geo_genius, :import, :exception], _, %{phase: "staging"}}
  end

  test "release_at's scalar shape counts a found value as 1 and nil as 0" do
    assert "abc" == Telemetry.span("release_at", %{prefix: "geo_genius"}, fn -> "abc" end)

    assert_received {:event, [:geo_genius, :read, :stop], _,
                     %{result_count: 1, function: "release_at"}}

    assert nil == Telemetry.span("release_at", %{prefix: "geo_genius"}, fn -> nil end)

    assert_received {:event, [:geo_genius, :read, :stop], _,
                     %{result_count: 0, function: "release_at"}}
  end
end
