defmodule GeoGenius.PreflightGeometryTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  # The probes deliberately kill a connection, and the disconnect report that
  # follows is expected output rather than a symptom.
  @moduletag capture_log: true

  alias GeoGenius.TestRepo

  defmodule PlainRepo do
    use Ecto.Repo, otp_app: :geo_genius, adapter: Ecto.Adapters.Postgres
  end

  setup do
    config = Keyword.delete(TestRepo.config(), :types)
    {:ok, pid} = PlainRepo.start_link(config ++ [pool_size: 1])

    # Supervisor.stop/1 expects the Repo supervisor to exit with reason
    # :normal, but Ecto's pool child can still be mid-connect right after
    # start_link returns and exits with :shutdown instead, which
    # Supervisor.stop treats as a stop failure. Monitor-and-exit tolerates
    # either reason.
    on_exit(fn ->
      if Process.alive?(pid) do
        ref = Process.monitor(pid)
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        after
          5_000 -> :ok
        end
      end
    end)

    :ok
  end

  test "a Repo that can decode geometry passes" do
    assert :ok = GeoGenius.verify(TestRepo)
  end

  test "a Repo with no PostGIS types module is rejected with a remedy" do
    assert {:error, reasons} = GeoGenius.verify(PlainRepo)

    assert Enum.any?(reasons, &(&1 =~ "cannot decode PostGIS geometry")),
           "expected a geometry-decoding reason, got: #{inspect(reasons)}"

    assert Enum.any?(reasons, &(&1 =~ "Geo.PostGIS.Extension")),
           "the remedy must name the extension to register"
  end
end
