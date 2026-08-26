defmodule GeoGenius.Commands.SystemTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Commands.System, as: Command

  test "reports an executable that exists" do
    assert Command.available?("sh", [])
  end

  test "reports an executable that does not exist" do
    refute Command.available?("no_such_executable_anywhere_geo_genius", [])
  end

  test "runs a command and returns its output" do
    assert {:ok, output} = Command.run("sh", ["-c", "echo hello"], [])
    assert String.trim(output) == "hello"
  end

  test "a non-zero exit is an error carrying the status and the output" do
    assert {:error, {status, output}} = Command.run("sh", ["-c", "echo oops >&2; exit 3"], [])
    assert status == 3
    assert output =~ "oops"
  end

  test "captures stderr alongside stdout" do
    assert {:ok, output} = Command.run("sh", ["-c", "echo out; echo err >&2"], [])
    assert output =~ "out"
    assert output =~ "err"
  end

  test "forces stderr_to_stdout regardless of a caller override" do
    assert {:ok, output} =
             Command.run("sh", ["-c", "echo out; echo err >&2"], stderr_to_stdout: false)

    assert output =~ "out"
    assert output =~ "err"
  end

  test "runs in the requested directory" do
    dir = Path.join(System.tmp_dir!(), "gg_cmd_#{System.unique_integer([:positive])}")
    canary = Path.join(dir, "canary.txt")
    stray = Path.join(File.cwd!(), "canary.txt")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      File.rm(stray)
    end)

    assert {:ok, _output} = Command.run("sh", ["-c", "echo marker > canary.txt"], cd: dir)
    assert File.exists?(canary)
    refute File.exists?(stray)
  end

  test "passes environment variables through to the command" do
    assert {:ok, output} =
             Command.run("sh", ["-c", "echo $GEO_GENIUS_PROBE"],
               env: [{"GEO_GENIUS_PROBE", "canary-value"}]
             )

    assert String.trim(output) == "canary-value"
  end

  test "a missing executable is an error carrying status 127, not a raise" do
    assert {:error, {status, output}} =
             Command.run("no_such_executable_anywhere_geo_genius", [], [])

    assert status == 127
    assert output =~ "no_such_executable_anywhere_geo_genius"
  end

  test "a non-executable file is an error carrying status 126" do
    path = Path.join(System.tmp_dir!(), "gg_cmd_noexec_#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\necho hi\n")
    File.chmod!(path, 0o644)
    on_exit(fn -> File.rm(path) end)

    assert {:error, {status, output}} = Command.run(path, [], [])
    assert status == 126
    assert output =~ path
  end

  test "a missing working directory is an error naming it, not a bare status" do
    dir = Path.join(System.tmp_dir!(), "gg_cmd_missing_#{System.unique_integer([:positive])}")
    refute File.exists?(dir)

    assert {:error, {status, output}} = Command.run("sh", ["-c", "echo hi"], cd: dir)
    assert is_integer(status)
    assert output =~ dir
  end
end
