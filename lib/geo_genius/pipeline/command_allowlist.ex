defmodule GeoGenius.Pipeline.CommandAllowlist do
  @moduledoc """
  The `GeoGenius.Command` the import pipeline hands a provider: the configured
  command adapter, narrowed to the one executable a shipped provider needs.

  A provider is given a command adapter by design -- `GeoGenius.Providers.Shapefile`
  converts its archive with `ogr2ogr` -- but `c:GeoGenius.Command.run/3` takes an
  arbitrary executable with arbitrary arguments, and both `ogr2ogr -f PostgreSQL
  PG:...` and `psql` write to the very database the catalog lives in. Narrowing
  the adapter the pipeline passes means a provider that reaches for something
  else is refused by name rather than obeyed.

  **This is a guardrail, not a sandbox.** It bounds what a provider does by
  accident or by copying an example; it cannot bound what a provider does
  deliberately. Nothing stops provider code from calling
  `GeoGenius.Commands.System` directly, resolving the configured adapter
  itself out of application environment, or reading the adapter this
  wraps out of `opts[:command_target]` -- which is there because a caller must
  be able to substitute an adapter per call, including in tests. Elixir has no
  module-level enforcement to offer here, so, exactly as with the rest of
  `GeoGenius.Provider`'s contract, a provider that only parses is a discipline
  the pipeline and the tests hold providers to rather than a guarantee this
  module can make.

  `run/3` refuses anything but `ogr2ogr` with an error naming the rejected
  executable, using the shell's own 126 ("found, not executable") so a provider
  formats it the same way it formats any other failed command. `available?/2`
  answers `false` for a refused executable rather than reporting what is on the
  search path, so a provider that probes before running gets the same answer
  either way.

  The adapter this wraps comes from `opts[:command_target]`, falling back to
  the configured adapter. Configuring *this* module as the host's command
  adapter would make that fallback resolve to itself and recurse forever, with
  no error and no output -- an import that simply hangs -- so it raises
  instead. The options it forwards have `:command` and `:command_target`
  removed, so a host's own adapter never receives this module's private
  vocabulary.
  """

  @behaviour GeoGenius.Command

  alias GeoGenius.Config

  @allowed_executables ~w(ogr2ogr)
  @refused_status 126
  @pipeline_opts [:command, :command_target]

  @impl GeoGenius.Command
  @doc "Whether an allowed executable is on the search path; `false` for a refused one."
  @spec available?(String.t(), keyword()) :: boolean()
  def available?(executable, opts) do
    executable in @allowed_executables and
      target(opts).available?(executable, delegated_opts(opts))
  end

  @impl GeoGenius.Command
  @doc "Runs an allowed executable through the wrapped adapter, refusing every other one."
  @spec run(String.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, {integer(), String.t()}}
  def run(executable, args, opts) do
    if executable in @allowed_executables do
      target(opts).run(executable, args, delegated_opts(opts))
    else
      {:error, {@refused_status, refusal(executable)}}
    end
  end

  defp refusal(executable) do
    "GeoGenius refuses to run #{inspect(executable)} for a provider: the import pipeline " <>
      "allows only #{Enum.join(@allowed_executables, ", ")}"
  end

  defp delegated_opts(opts), do: Keyword.drop(opts, @pipeline_opts)

  defp target(opts) do
    case Keyword.get_lazy(opts, :command_target, fn -> Config.adapter(:command, []) end) do
      __MODULE__ -> raise ArgumentError, self_reference()
      module -> module
    end
  end

  defp self_reference do
    "#{inspect(__MODULE__)} wraps a GeoGenius.Command adapter and cannot wrap itself: " <>
      "delegating to itself would recurse until the import hangs with no error. Configure " <>
      "`config :geo_genius, :command, ...` with a real adapter, such as " <>
      "#{inspect(GeoGenius.Commands.System)}; the import pipeline applies this wrapper itself."
  end
end
