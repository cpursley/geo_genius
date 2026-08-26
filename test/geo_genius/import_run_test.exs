defmodule GeoGenius.ImportRunTest do
  use ExUnit.Case, async: true

  alias GeoGenius.ImportRun

  test "maps a result by column name, not by position" do
    result = %Postgrex.Result{
      columns: [
        "status",
        "run_id",
        "release_id",
        "collection_key",
        "release_key",
        "attempt",
        "owner",
        "runner_backend",
        "started_at",
        "heartbeat_at",
        "completed_at",
        "error",
        "stage_metrics",
        "progress"
      ],
      rows: [
        [
          "staging",
          "11111111-1111-1111-1111-111111111111",
          "22222222-2222-2222-2222-222222222222",
          "demo",
          "r1",
          2,
          "worker-1",
          "test",
          ~U[2026-08-25 00:00:00Z],
          ~U[2026-08-25 00:01:00Z],
          nil,
          nil,
          %{"staged" => 10},
          %{"rows" => 10}
        ]
      ],
      num_rows: 1,
      command: :select,
      connection_id: nil,
      messages: []
    }

    assert [run] = ImportRun.from_result(result)
    assert run.status == "staging"
    assert run.run_id == "11111111-1111-1111-1111-111111111111"
    assert run.release_id == "22222222-2222-2222-2222-222222222222"
    assert run.collection_key == "demo"
    assert run.release_key == "r1"
    assert run.attempt == 2
    assert run.owner == "worker-1"
    assert run.runner_backend == "test"
    assert run.completed_at == nil
    assert run.stage_metrics == %{"staged" => 10}
    assert run.progress == %{"rows" => 10}
  end

  test "reports whether a run has reached a terminal state" do
    assert ImportRun.finished?(%ImportRun{run_id: "x", status: "completed"})
    assert ImportRun.finished?(%ImportRun{run_id: "x", status: "failed"})
    refute ImportRun.finished?(%ImportRun{run_id: "x", status: "staging"})
    refute ImportRun.finished?(%ImportRun{run_id: "x", status: "pending"})
  end

  test "reports success only for a completed run" do
    assert ImportRun.succeeded?(%ImportRun{run_id: "x", status: "completed"})
    refute ImportRun.succeeded?(%ImportRun{run_id: "x", status: "failed"})
    refute ImportRun.succeeded?(%ImportRun{run_id: "x", status: "publishing"})
  end
end
