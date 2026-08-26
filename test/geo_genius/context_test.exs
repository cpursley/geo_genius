defmodule GeoGenius.ContextTest do
  # Two tests here mutate the global `:geo_genius, :cache` application
  # environment key. Running async alongside another test that reads or sets
  # the same key would be the same latent flake a prior task hit with
  # `:geo_genius, :providers`.
  use ExUnit.Case, async: false

  alias GeoGenius.AppEnv
  alias GeoGenius.Context

  defmodule OtherStore do
    @moduledoc false
  end

  test "builds from explicit options" do
    context = Context.new(repo: GeoGenius.TestRepo, prefix: "custom_geo", store: OtherStore)

    assert context.repo == GeoGenius.TestRepo
    assert context.prefix == "custom_geo"
    assert context.store == OtherStore
  end

  test "defaults the store to the shipped Postgres store" do
    assert Context.new(repo: GeoGenius.TestRepo).store == GeoGenius.Stores.Postgres
  end

  test "validates the prefix rather than trusting it" do
    assert_raise ArgumentError, fn -> Context.new(repo: GeoGenius.TestRepo, prefix: "public") end

    assert_raise ArgumentError, fn ->
      Context.new(repo: GeoGenius.TestRepo, prefix: "Bad Name")
    end
  end

  defmodule StubCache do
    @moduledoc false
    @behaviour GeoGenius.Cache

    @impl GeoGenius.Cache
    def fetch(_key, _opts), do: :miss

    @impl GeoGenius.Cache
    def put(_key, path, _opts), do: {:ok, path}

    @impl GeoGenius.Cache
    def path(key, _opts), do: key

    @impl GeoGenius.Cache
    def delete(_key, _opts), do: :ok
  end

  defmodule OtherStubCache do
    @moduledoc false
    @behaviour GeoGenius.Cache

    @impl GeoGenius.Cache
    def fetch(_key, _opts), do: :miss

    @impl GeoGenius.Cache
    def put(_key, path, _opts), do: {:ok, path}

    @impl GeoGenius.Cache
    def path(key, _opts), do: key

    @impl GeoGenius.Cache
    def delete(_key, _opts), do: :ok
  end

  test "new/1 takes an adapter from options over application environment" do
    AppEnv.put(:cache, OtherStubCache)

    context = Context.new(repo: GeoGenius.TestRepo, cache: StubCache)

    assert Context.adapter(context, :cache) == StubCache
  end

  test "new/1 takes an adapter from application environment over the default" do
    AppEnv.put(:cache, StubCache)

    assert Context.adapter(Context.new(repo: GeoGenius.TestRepo), :cache) == StubCache
  end

  test "new/1 falls back to the shipped default" do
    assert Context.adapter(Context.new(repo: GeoGenius.TestRepo), :cache) ==
             GeoGenius.Caches.FileSystem

    assert Context.adapter(Context.new(repo: GeoGenius.TestRepo), :downloader) ==
             GeoGenius.Downloaders.Req

    assert Context.adapter(Context.new(repo: GeoGenius.TestRepo), :command) ==
             GeoGenius.Commands.System

    assert Context.adapter(Context.new(repo: GeoGenius.TestRepo), :notifier) ==
             GeoGenius.Notifiers.Noop
  end

  test "a context assembled as a struct literal still resolves adapters" do
    context = %Context{
      repo: GeoGenius.TestRepo,
      prefix: "geo_genius",
      store: GeoGenius.Stores.Postgres
    }

    assert context.cache == nil
    assert Context.adapter(context, :cache) == GeoGenius.Caches.FileSystem

    # `:runner` has no shipped default in `Config.adapter/2`, so this is the
    # one adapter whose lookup runs a different function -- `adapter/2`'s
    # dedicated `:runner` clause always calls `Runner.configured/1`, never
    # `Config.adapter/2` -- a distinction a deleted-and-forgotten clause
    # would leave silently unexercised while every other test in this file
    # stays green.
    assert context.runner == nil
    runner = Context.adapter(context, :runner)
    assert runner in [GeoGenius.Runners.PgFlow, GeoGenius.Runners.Task, GeoGenius.Runners.Inline]
  end

  test "runner defaults to an available backend when none is configured" do
    context = Context.new(repo: GeoGenius.TestRepo)
    runner = Context.adapter(context, :runner)

    assert runner in [GeoGenius.Runners.PgFlow, GeoGenius.Runners.Task, GeoGenius.Runners.Inline]
    assert Code.ensure_loaded?(runner)
    assert runner.available?()
  end

  defmodule Custom do
    @moduledoc false
    @behaviour GeoGenius.Runner

    @impl GeoGenius.Runner
    def name, do: "context-custom"

    @impl GeoGenius.Runner
    def available?, do: true

    @impl GeoGenius.Runner
    def enqueue(_context, _run_id, _args), do: :ok
  end

  test "new/1 carries a :runner passed in options, unvalidated, before anything resolves it" do
    context = Context.new(repo: GeoGenius.TestRepo, runner: Custom)

    assert context.runner == Custom
  end

  test "an explicit, valid :runner reaches Context.adapter/2 through new/1 unchanged" do
    assert Context.adapter(Context.new(repo: GeoGenius.TestRepo, runner: Custom), :runner) ==
             Custom
  end

  test "an explicit :runner that does not implement the behaviour raises through adapter/2" do
    # `Context.new(runner: SomeModule) |> Context.adapter(:runner)` is the
    # path a host actually calls. `adapter/2` used to return a non-nil
    # `:runner` field straight from `Map.fetch!/2` without ever reaching
    # `Runner.configured/1`'s validation -- StubCache implements
    # `GeoGenius.Cache`, not `GeoGenius.Runner`, and dispatching `enqueue/3`
    # on it several phases into a run raised `UndefinedFunctionError` rather
    # than this, at the one point that could have named the problem.
    context = Context.new(repo: GeoGenius.TestRepo, runner: StubCache)

    error = assert_raise ArgumentError, fn -> Context.adapter(context, :runner) end

    assert error.message =~ inspect(StubCache)
    assert error.message =~ "name/0"
    assert error.message =~ "available?/0"
    assert error.message =~ "enqueue/3"
  end
end
