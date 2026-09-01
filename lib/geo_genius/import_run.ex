defmodule GeoGenius.ImportRun do
  @moduledoc """
  One import run, as the `import_run_status` view reports it.

  A run's state lives in PostgreSQL, never in process memory, so this struct is
  a snapshot rather than a handle. `GeoGenius.status/2` returns a fresh one on
  every call and `GeoGenius.await/3` polls for a newer one.

  `progress` is the lease's rolling progress object, updated by heartbeats
  during a phase. `stage_metrics` is the run's accumulated per-phase metrics,
  updated at each phase boundary. A terminal run has no lease, so its
  `progress` reads as an empty map and its `heartbeat_at` falls back to the
  run's own column.
  """

  @terminal ~w(completed failed)

  @enforce_keys [:run_id]
  defstruct [
    :run_id,
    :release_id,
    :collection_key,
    :release_key,
    :attempt,
    :status,
    :owner,
    :runner_backend,
    :started_at,
    :heartbeat_at,
    :completed_at,
    :error,
    :stage_metrics,
    :progress,
    :executor_id,
    :execution_started_at,
    :manifest
  ]

  @type t :: %__MODULE__{
          run_id: Ecto.UUID.t(),
          release_id: Ecto.UUID.t() | nil,
          collection_key: String.t() | nil,
          release_key: String.t() | nil,
          attempt: integer() | nil,
          status: String.t() | nil,
          owner: String.t() | nil,
          runner_backend: String.t() | nil,
          started_at: DateTime.t() | nil,
          heartbeat_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          error: map() | nil,
          stage_metrics: map() | nil,
          progress: map() | nil,
          executor_id: Ecto.UUID.t() | nil,
          execution_started_at: DateTime.t() | nil,
          manifest: map() | nil
        }

  @fields %{
    "run_id" => :run_id,
    "release_id" => :release_id,
    "collection_key" => :collection_key,
    "release_key" => :release_key,
    "attempt" => :attempt,
    "status" => :status,
    "owner" => :owner,
    "runner_backend" => :runner_backend,
    "started_at" => :started_at,
    "heartbeat_at" => :heartbeat_at,
    "completed_at" => :completed_at,
    "error" => :error,
    "stage_metrics" => :stage_metrics,
    "progress" => :progress,
    "executor_id" => :executor_id,
    "execution_started_at" => :execution_started_at,
    "manifest" => :manifest
  }

  @doc """
  Maps a query result into structs.

  Mapping is by column name. The view projects four text columns in a row, so a
  positional mapping would transpose two of them silently the first time the
  view's column order changed.
  """
  @spec from_result(Postgrex.Result.t()) :: [t()]
  def from_result(%Postgrex.Result{} = result) do
    GeoGenius.ResultMapper.to_structs(result, @fields, __MODULE__)
  end

  @doc "Whether the run has reached a terminal state and will not advance again."
  @spec finished?(t()) :: boolean()
  def finished?(%__MODULE__{status: status}), do: status in @terminal

  @doc "Whether the run finished successfully."
  @spec succeeded?(t()) :: boolean()
  def succeeded?(%__MODULE__{status: status}), do: status == "completed"
end
