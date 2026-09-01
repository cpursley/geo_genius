defmodule GeoGenius.Runners.Inline do
  @moduledoc """
  Runs an import in the calling process.

  This is the honest default for a host with a small catalog and no job
  framework installed: `enqueue/3` does not return until
  `GeoGenius.Pipeline.execute/3` has finished, so by the time it does, the
  run's outcome is already durable in PostgreSQL.

  Ships in place of the plan's `Runners.Test`, because this is not a
  test-only module -- it is the backend a host without PgFlow or a
  `Task.Supervisor` actually runs imports under.
  """

  @behaviour GeoGenius.Runner

  alias GeoGenius.Pipeline
  alias GeoGenius.Runner

  @impl GeoGenius.Runner
  @doc "Returns `\"inline\"`."
  @spec name() :: String.t()
  def name, do: "inline"

  @impl GeoGenius.Runner
  @doc "Always `true`: running in the calling process needs no configuration."
  @spec available?() :: boolean()
  def available?, do: true

  @impl GeoGenius.Runner
  @doc """
  Runs the import synchronously and returns once it has finished.

  Returns `:ok` for both an import that completed and one that ran and
  recorded a failure -- either outcome is durably in the catalog, and a
  caller reads it back from there rather than from this return value.
  Returns `{:error, {:not_enqueued, reason}}` only when the pipeline reports
  `:not_started`. A missing durable outcome after executor claim returns
  `{:error, {:outcome_unknown, reason}}`, because the import may have mutated
  its candidate even though its final state could not be confirmed.
  """
  @spec enqueue(GeoGenius.Context.t(), Ecto.UUID.t(), Runner.args()) ::
          :ok | {:error, Runner.enqueue_error()}
  def enqueue(context, run_id, args) do
    case Pipeline.execute(context, run_id, Runner.pipeline_opts(args)) do
      {:ok, _run} ->
        :ok

      {:noop, _run} ->
        :ok

      {:error, {:unrecorded, :not_started, reason}} ->
        {:error, {:not_enqueued, reason}}

      {:error, {:unrecorded, :outcome_unknown, reason}} ->
        {:error, {:outcome_unknown, reason}}

      {:error, %GeoGenius.ImportRun{}} ->
        :ok
    end
  end
end
