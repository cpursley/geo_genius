defmodule GeoGenius.Pipeline.CommandAllowlistTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Pipeline.CommandAllowlist
  alias GeoGenius.RecordingCommand

  defp opts, do: [command_target: RecordingCommand, test_pid: self(), cd: "/tmp"]

  test "runs an allowed executable through the wrapped adapter, arguments intact" do
    assert {:ok, "ran"} =
             CommandAllowlist.run("ogr2ogr", ["-f", "GeoJSON", "out.json", "in.shp"], opts())

    assert_received {:command_ran, "ogr2ogr", args, _opts}
    assert args == ["-f", "GeoJSON", "out.json", "in.shp"]
  end

  test "refuses every other executable by name, without consulting the adapter" do
    assert {:error, {126, reason}} = CommandAllowlist.run("psql", ["-c", "SELECT 1"], opts())

    assert reason =~ "psql"
    assert reason =~ "ogr2ogr"

    # An allowlist that delegated first and complained afterwards would already
    # have run the command it exists to prevent.
    refute_received {:command_ran, "psql", _args, _opts}
  end

  test "available? answers false for a refused executable and delegates for an allowed one" do
    refute CommandAllowlist.available?("psql", opts())
    refute_received {:command_probe, "psql", _opts}

    assert CommandAllowlist.available?("ogr2ogr", opts())
    assert_received {:command_probe, "ogr2ogr", _opts}
  end

  test "does not forward its own option vocabulary to the adapter it wraps" do
    assert {:ok, "ran"} = CommandAllowlist.run("ogr2ogr", [], opts())

    assert_received {:command_ran, "ogr2ogr", _args, forwarded}

    # A host's adapter gets its own options and nothing about how the pipeline
    # resolved it -- but it does keep everything the caller passed.
    refute Keyword.has_key?(forwarded, :command)
    refute Keyword.has_key?(forwarded, :command_target)
    assert forwarded[:cd] == "/tmp"
  end

  test "refuses to wrap itself rather than recursing until the import hangs" do
    for call <- [
          fn -> CommandAllowlist.run("ogr2ogr", [], command_target: CommandAllowlist) end,
          fn -> CommandAllowlist.available?("ogr2ogr", command_target: CommandAllowlist) end
        ] do
      error = assert_raise ArgumentError, call

      assert Exception.message(error) =~ "cannot wrap itself"
      assert Exception.message(error) =~ "GeoGenius.Commands.System"
    end
  end
end
