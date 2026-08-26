defmodule GeoGenius.Commands.System do
  @moduledoc """
  Runs external executables via `System.cmd/3`.

  `available?/2` reports whether the executable can be found on the search
  path; its options are ignored, since nothing about a search-path probe
  depends on them. `run/3` always merges stdout and stderr into one stream -- a caller
  cannot opt out by passing `stderr_to_stdout: false`, because the behaviour
  promises one interleaved output and a host that wants the streams kept
  apart supplies its own `GeoGenius.Command` instead.

  `run/3` never raises. `System.cmd/3` raises `ErlangError` when the
  executable cannot be found or cannot be executed at all -- the process
  never starts, so there is no `{output, status}` pair to report. This
  rescues that and reports the shell's own conventions for the two cases
  that matter to a pipeline: 127 for "command not found" (`:enoent`) and 126
  for "found but not executable" (`:eacces`). A working directory that does
  not exist is checked before `System.cmd/3` runs at all, because the OS
  failure that would otherwise produce is a bare non-zero status with no
  output naming what went missing.
  """

  @behaviour GeoGenius.Command

  @command_not_found 127
  @not_executable 126
  @cd_missing 127
  @passthrough_opts [:cd, :env, :stderr_to_stdout]

  @impl GeoGenius.Command
  @spec available?(String.t(), keyword()) :: boolean()
  def available?(executable, _opts), do: System.find_executable(executable) != nil

  @impl GeoGenius.Command
  @spec run(String.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, {integer(), String.t()}}
  def run(executable, args, opts) do
    cmd_opts =
      opts
      |> Keyword.take(@passthrough_opts)
      |> Keyword.put(:stderr_to_stdout, true)

    case verify_cd(cmd_opts) do
      :ok -> exec(executable, args, cmd_opts)
      error -> error
    end
  rescue
    error in ErlangError ->
      {:error, errno_result(executable, error)}
  end

  defp exec(executable, args, cmd_opts) do
    case System.cmd(executable, args, cmd_opts) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {status, output}}
    end
  end

  defp verify_cd(cmd_opts) do
    case Keyword.fetch(cmd_opts, :cd) do
      {:ok, dir} -> verify_dir(dir)
      :error -> :ok
    end
  end

  defp verify_dir(dir) do
    if File.dir?(dir) do
      :ok
    else
      {:error,
       {@cd_missing,
        "GeoGenius could not run a command: working directory #{inspect(dir)} does not exist"}}
    end
  end

  defp errno_result(executable, %ErlangError{original: :enoent}) do
    {@command_not_found,
     "GeoGenius could not run #{inspect(executable)}: not found on the search path"}
  end

  defp errno_result(executable, %ErlangError{original: :eacces}) do
    {@not_executable, "GeoGenius could not run #{inspect(executable)}: permission denied"}
  end

  defp errno_result(executable, error) do
    {@command_not_found,
     "GeoGenius could not run #{inspect(executable)}: #{Exception.message(error)}"}
  end
end
