defmodule GeoGenius.NotifierTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Notifiers.Noop

  defmodule Recording do
    @moduledoc false
    @behaviour GeoGenius.Notifier

    @impl GeoGenius.Notifier
    def notify(event, payload, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:notified, event, payload})
      :ok
    end
  end

  test "the shipped notifier accepts every event and does nothing" do
    for event <- GeoGenius.Notifier.events() do
      assert Noop.notify(event, %{}, []) == :ok
    end
  end

  test "events/0 lists exactly the six events the pipeline emits" do
    assert Enum.sort(GeoGenius.Notifier.events()) ==
             Enum.sort([
               :import_started,
               :phase_advanced,
               :import_completed,
               :import_failed,
               :release_published,
               :release_rolled_back
             ])
  end

  test "a host notifier receives the event and the payload" do
    assert Recording.notify(:import_started, %{run_id: "r"}, test_pid: self()) == :ok
    assert_receive {:notified, :import_started, %{run_id: "r"}}
  end
end
