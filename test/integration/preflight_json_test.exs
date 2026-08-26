defmodule GeoGenius.PreflightJsonTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  # The probes deliberately kill a connection, and the disconnect report that
  # follows is expected output rather than a symptom.
  @moduletag capture_log: true

  alias GeoGenius.TestRepo

  defmodule NoJsonRepo do
    @moduledoc false
    use Ecto.Repo, otp_app: :geo_genius, adapter: Ecto.Adapters.Postgres
  end

  setup do
    config = Keyword.put(TestRepo.config(), :types, GeoGenius.NoJsonTypes)
    {:ok, pid} = NoJsonRepo.start_link(config ++ [pool_size: 1])

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

  test "a Repo whose types module has no usable JSON library is rejected with a remedy" do
    assert {:error, reasons} = GeoGenius.verify(NoJsonRepo)

    assert Enum.any?(reasons, &(&1 =~ "cannot decode jsonb")),
           "expected a jsonb-decoding reason, got: #{inspect(reasons)}"

    assert Enum.any?(reasons, &(&1 =~ "json_library")),
           "the remedy must name the Postgrex setting that chooses a JSON library"
  end

  # The geometry probe decodes geography, never jsonb, so it passes on exactly
  # the Repo that dies on the first real read. That is why jsonb needs a probe
  # of its own rather than riding along on the geometry one.
  test "the geometry probe alone does not catch it" do
    assert {:error, reasons} = GeoGenius.verify(NoJsonRepo)

    refute Enum.any?(reasons, &(&1 =~ "cannot decode PostGIS geometry")),
           "geography decodes fine here: #{inspect(reasons)}"
  end

  test "a Repo with a working JSON library passes" do
    assert :ok = GeoGenius.verify(TestRepo)
  end
end
