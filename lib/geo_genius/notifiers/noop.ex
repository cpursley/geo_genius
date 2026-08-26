defmodule GeoGenius.Notifiers.Noop do
  @moduledoc """
  The shipped notifier for a host that has not configured one of its own.

  Accepts every event `GeoGenius.Notifier.events/0` names and does nothing
  with any of them.
  """

  @behaviour GeoGenius.Notifier

  @impl GeoGenius.Notifier
  @spec notify(atom(), map(), keyword()) :: :ok
  def notify(_event, _payload, _opts), do: :ok
end
