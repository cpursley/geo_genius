defmodule GeoGenius.RecordingCommand do
  @moduledoc false
  @behaviour GeoGenius.Command

  # Runs nothing. It reports what it was asked to do, so a test can assert both
  # what reached the wrapped adapter and what never did.

  @impl GeoGenius.Command
  def available?(executable, opts) do
    report(opts, {:command_probe, executable, opts})
    true
  end

  @impl GeoGenius.Command
  def run(executable, args, opts) do
    report(opts, {:command_ran, executable, args, opts})
    {:ok, "ran"}
  end

  defp report(opts, message) do
    if pid = opts[:test_pid], do: send(pid, message)
    :ok
  end
end
