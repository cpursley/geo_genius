defmodule GeoGenius.ExecutionGuardian do
  @moduledoc false

  use GenServer

  require Logger

  alias GeoGenius.Catalog
  alias GeoGenius.Context

  @spec start(Context.t(), Ecto.UUID.t(), Ecto.UUID.t(), pid()) ::
          {:ok, pid()} | {:error, term()}
  def start(%Context{} = context, run_id, executor_id, owner) when is_pid(owner) do
    child = {__MODULE__, {context, run_id, executor_id, owner}}
    DynamicSupervisor.start_child(GeoGenius.ExecutionGuardianSupervisor, child)
  end

  @spec disarm(pid()) :: :ok
  def disarm(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, {:noproc, _call} -> :ok
  end

  def child_spec(args) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary
    }
  end

  @doc false
  @spec start_link({Context.t(), Ecto.UUID.t(), Ecto.UUID.t(), pid()}) :: GenServer.on_start()
  def start_link({%Context{} = context, run_id, executor_id, owner}) when is_pid(owner) do
    GenServer.start_link(__MODULE__, {context, run_id, executor_id, owner})
  end

  @impl true
  def init({context, run_id, executor_id, owner}) do
    monitor_ref = Process.monitor(owner)

    {:ok,
     %{
       context: context,
       run_id: run_id,
       executor_id: executor_id,
       owner: owner,
       monitor_ref: monitor_ref
     }}
  end

  @impl true
  def handle_info(
        {:DOWN, monitor_ref, :process, owner, reason},
        %{monitor_ref: monitor_ref, owner: owner} = state
      ) do
    record_termination(state, reason)

    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp record_termination(state, reason) do
    Catalog.fail_import(state.context, state.run_id, state.executor_id, %{
      "phase" => "execution",
      "reason" => "executor process terminated before recording an outcome",
      "exception" => ":exit",
      "exit_reason" => inspect(reason)
    })
  rescue
    exception -> log_recording_failure(state.run_id, Exception.message(exception))
  catch
    kind, caught_reason ->
      log_recording_failure(state.run_id, "#{kind} #{inspect(caught_reason)}")
  end

  defp log_recording_failure(run_id, reason) do
    Logger.warning(
      "GeoGenius could not record the terminated executor for import run #{run_id}: #{reason}"
    )

    :ok
  end
end
