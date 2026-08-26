defmodule GeoGenius.ApplicationTest do
  # `children/0` is the pure computation `start/2` hands to
  # `Supervisor.start_link/2`, extracted so the configured-vs-unconfigured
  # decision is provable without touching any running process -- the first
  # two tests below. That is not the same claim as "start/2 actually uses
  # children/0": an implementation where start/2 ignores it and hard-codes
  # its own child list passes both of those and every other test in this
  # suite. The third test below calls start/2 itself, which means briefly
  # stopping the real, already-running :geo_genius application to free the
  # GeoGenius.Supervisor name start/2 registers under. Checked before doing
  # that: no other test file in this suite calls GeoGenius.import/1 (or
  # anything else that resolves a runner) without pinning `runner:`
  # explicitly, except test/geo_genius/public_ingestion_test.exs, which is
  # itself async: false and therefore cannot run concurrently with this
  # file -- so nothing else in the suite can observe GeoGenius.TaskSupervisor
  # missing during the brief window this test controls. The `after` block
  # looks up whatever is currently registered as GeoGenius.Supervisor rather
  # than tracking a specific pid, so restoration works even when an
  # assertion fails partway through and leaves one of the two ad-hoc
  # supervisors below still running under that name.
  use ExUnit.Case, async: false

  alias GeoGenius.AppEnv

  setup do
    AppEnv.restore_on_exit(:task_supervisor)
  end

  test "starts GeoGenius.TaskSupervisor when nothing is configured" do
    assert GeoGenius.Application.children() == [{Task.Supervisor, name: GeoGenius.TaskSupervisor}]
  end

  test "starts no child when a host has already configured :task_supervisor" do
    # A host that names its own supervisor has committed to starting and
    # placing it itself -- an unconfigured second one sitting idle in this
    # tree would be a process the host neither asked for nor can remove
    # short of disabling the runner outright.
    Application.put_env(:geo_genius, :task_supervisor, GeoGenius.ApplicationTest.SomeSupervisor)

    assert GeoGenius.Application.children() == []
  end

  test "start/2 itself honors the opt-out, not just children/0" do
    :ok = Application.stop(:geo_genius)

    try do
      {:ok, unconfigured_pid} = GeoGenius.Application.start(:normal, [])
      assert length(Supervisor.which_children(unconfigured_pid)) == 1
      assert GenServer.whereis(GeoGenius.TaskSupervisor)
      :ok = Supervisor.stop(unconfigured_pid)

      Application.put_env(:geo_genius, :task_supervisor, GeoGenius.ApplicationTest.BootSupervisor)
      {:ok, configured_pid} = GeoGenius.Application.start(:normal, [])
      assert Supervisor.which_children(configured_pid) == []
      refute GenServer.whereis(GeoGenius.TaskSupervisor)
      :ok = Supervisor.stop(configured_pid)
    after
      case Process.whereis(GeoGenius.Supervisor) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end

      Application.delete_env(:geo_genius, :task_supervisor)
      {:ok, _} = Application.ensure_all_started(:geo_genius)
    end
  end
end
