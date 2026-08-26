defmodule GeoGenius.Context do
  @moduledoc "Runtime dependencies for one GeoGenius operation."

  alias GeoGenius.Config
  alias GeoGenius.Runner

  @adapters ~w(cache downloader command notifier runner)a

  @enforce_keys [:repo, :prefix, :store]
  defstruct [:repo, :prefix, :store, :cache, :downloader, :command, :notifier, :runner]

  @type t :: %__MODULE__{
          repo: module(),
          prefix: String.t(),
          store: module(),
          cache: module() | nil,
          downloader: module() | nil,
          command: module() | nil,
          notifier: module() | nil,
          runner: module() | nil
        }

  @doc """
  Builds a context from explicit options over package configuration.

  The application environment describes exactly one host. A VM serving several
  hosts passes `:repo` and `:prefix` on every call instead.

  `:runner` carries only what `opts` explicitly gave -- never `nil` coalesced
  against `config :geo_genius, :runner` here, and never validated here. Both
  of those happen once, in `Runner.configured/1`, the only place they need to
  live: `adapter/2` routes every `:runner` lookup through it below, whether
  this context ends up carrying an explicit module or `nil`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      repo: Config.repo!(opts),
      prefix: Config.prefix(opts),
      store: Config.store(opts),
      cache: Config.adapter(:cache, opts),
      downloader: Config.adapter(:downloader, opts),
      command: Config.adapter(:command, opts),
      notifier: Config.adapter(:notifier, opts),
      runner: Keyword.get(opts, :runner)
    }
  end

  @doc """
  The module serving one adapter role for this operation.

  A context built through `new/1` carries its adapters. A context assembled as
  a struct literal carries nil, and falls back to the same resolution `new/1`
  used, so a caller that built one by hand still gets a working adapter rather
  than a `nil` module and an `UndefinedFunctionError` several phases in.

  `:runner` always routes through `Runner.configured/1`, even when this
  context already carries an explicit module for it: that is the only place
  an explicit runner is validated -- checked for `Code.ensure_loaded?/1` and
  every `GeoGenius.Runner` callback -- and a lookup that returned early on a
  non-nil field would skip that check on the one path a host actually calls,
  `Context.new(runner: SomeModule) |> Context.adapter(:runner)`. The other
  adapters have no such validation step, so they keep the cheap early return:
  a context already carrying one never spends a second lookup on it.
  """
  @spec adapter(t(), atom()) :: module()
  def adapter(%__MODULE__{} = context, :runner) do
    Runner.configured(runner: context.runner)
  end

  def adapter(%__MODULE__{} = context, name) when name in @adapters do
    Map.fetch!(context, name) || Config.adapter(name, [])
  end
end
