defmodule GeoGenius.RecordingNotifier do
  @moduledoc false
  @behaviour GeoGenius.Notifier

  @impl GeoGenius.Notifier
  def notify(event, payload, opts) do
    if pid = opts[:test_pid], do: send(pid, {:notified, event, payload})
    :ok
  end
end

defmodule GeoGenius.RaisingNotifier do
  @moduledoc false
  @behaviour GeoGenius.Notifier

  # Reports the event before raising, so a test can tell "the pipeline stopped
  # notifying after the first raise" from "the pipeline carried on".
  @impl GeoGenius.Notifier
  def notify(event, payload, opts) do
    if pid = opts[:test_pid], do: send(pid, {:notified, event, payload})
    raise "notifier exploded delivering #{event}"
  end
end

defmodule GeoGenius.ExitingNotifier do
  @moduledoc false
  @behaviour GeoGenius.Notifier

  # An adapter that exits rather than raises: a `GenServer.call` into a
  # notifier process that is not running does exactly this.
  @impl GeoGenius.Notifier
  def notify(event, payload, opts) do
    if pid = opts[:test_pid], do: send(pid, {:notified, event, payload})
    exit({:notifier_gone, event})
  end
end

defmodule GeoGenius.ArmingNotifier do
  @moduledoc false
  @behaviour GeoGenius.Notifier

  # Runs `opts[:arm]` when the event it was told to watch for arrives. The
  # pipeline notifies from its own process, so this is how a test arms a
  # failure at one exact seam in a run rather than from the outside.
  #
  # Reach for it only when the seam is unreachable from outside the run. It
  # is a general lever for running arbitrary code mid-import, and a test that
  # uses it to stand in for a condition it could have set up beforehand ends
  # up asserting against a run nobody would ever have.
  @impl GeoGenius.Notifier
  def notify(event, payload, opts) do
    if pid = opts[:test_pid], do: send(pid, {:notified, event, payload})
    if event == opts[:arm_on], do: opts[:arm].()
    :ok
  end
end
