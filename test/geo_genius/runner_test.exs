defmodule GeoGenius.RunnerTest do
  # `Runners.PgFlow` is our own module and always compiles -- its top-level
  # `defmodule` has no dependency on `:pgflow` being present, only its
  # nested `Job` submodule does. `:pgflow` itself is not a dependency of
  # this library at all (see `GeoGenius.Runners.PgFlow`'s moduledoc for why),
  # so `Runners.PgFlow.available?/0` is genuinely false here -- the actual
  # experience of every host of this library, not a simulation -- and the
  # availability chain falls through to `Runners.Task` or `Runners.Inline`.
  use ExUnit.Case, async: false

  alias GeoGenius.AppEnv
  alias GeoGenius.{Context, Runner, Runners}

  defmodule Custom do
    @moduledoc false
    @behaviour GeoGenius.Runner

    @impl GeoGenius.Runner
    def name, do: "custom"

    @impl GeoGenius.Runner
    def available?, do: true

    @impl GeoGenius.Runner
    def enqueue(_context, _run_id, _args), do: :ok
  end

  defmodule NotARunner do
    @moduledoc false
  end

  setup do
    AppEnv.restore_on_exit(:runner)
    AppEnv.restore_on_exit(:task_supervisor)
  end

  test "an explicit option wins over everything" do
    Application.put_env(:geo_genius, :runner, Runners.Inline)
    assert Runner.configured(runner: Custom) == Custom
  end

  test "application environment wins over the availability chain" do
    Application.put_env(:geo_genius, :runner, Custom)
    assert Runner.configured([]) == Custom
  end

  test "falls back to an available backend and always terminates" do
    assert Runner.configured([]) in [
             Runners.PgFlow,
             Runners.Task,
             Runners.Inline
           ]
  end

  test "configured/1 resolves to Runners.Task with no configuration at all" do
    # The central behaviour this wave exists to fix: before it, a host that
    # configured nothing fell through to Runners.Inline and blocked the
    # calling process for the length of every import. The membership check
    # above passes for any of the three backends, including Inline, so it
    # cannot catch a regression back to that default; only pinning the exact
    # module can. A first_available/1 gated on whether :task_supervisor
    # happens to be set, rather than resolving the name and probing it live
    # with GenServer.whereis/1, would pass the membership check by
    # coincidence while failing this one.
    assert Runner.configured([]) == Runners.Task
  end

  test "the availability chain prefers Task over Inline once a supervisor is running" do
    name = Module.concat(__MODULE__, "Sup#{System.unique_integer([:positive])}")
    start_supervised!({Elixir.Task.Supervisor, name: name})
    Application.put_env(:geo_genius, :task_supervisor, name)

    # A `first_available/1` collapsed to a constant returning `Runners.Inline`
    # -- or one that never actually checks `available?/0` -- would pass every
    # membership assertion above while getting the order wrong. This is the
    # one assertion that pins the order: with Task genuinely available and
    # ahead of Inline in the chain, it must be what `configured/1` picks.
    assert Runner.configured([]) == Runners.Task
  end

  test "Runners.PgFlow loads but is unavailable with :pgflow not installed" do
    # `configured/1`'s chain guards every backend with `Code.ensure_loaded?/1`
    # before calling `available?/0` on it -- true for `Runners.PgFlow` on
    # this build (it is our own module, unconditionally compiled), so the
    # chain does reach in and call it. The assertion that matters is not
    # that the module fails to load; it is that a genuinely unavailable
    # backend still answers `available?/0` on its own terms instead of the
    # chain assuming unavailability from non-existence.
    assert Code.ensure_loaded?(Runners.PgFlow)
    refute Runners.PgFlow.available?()
  end

  test "an explicit :task_supervisor override takes precedence, even dead" do
    context = Context.new(repo: GeoGenius.TestRepo)
    run_id = Ecto.UUID.generate()

    Application.put_env(:geo_genius, :task_supervisor, GeoGenius.NoSuchSupervisor)

    # A resolver that fell back to GeoGenius.TaskSupervisor whenever the
    # configured name was not running -- instead of reporting the configured
    # name's own gap -- would report this available (the library's own
    # supervisor really is running) and would enqueue work under a
    # supervisor the host never asked for. Configured but not running names
    # the gap instead.
    refute Runners.Task.available?()
    assert {:error, not_running} = Runners.Task.enqueue(context, run_id, %{})
    assert not_running =~ "GeoGenius.NoSuchSupervisor"
  end

  test "configured/1 still selects Runners.Task when :task_supervisor is configured but dead" do
    # Ruling EB: a host that set :task_supervisor has committed to this
    # backend, and enqueue/3 already turns a dead supervisor into a named
    # error rather than an exit -- so the chain selects Runners.Task here
    # regardless of Runners.Task.available?/0, which is (correctly) false
    # for this exact case. The alternative -- falling through to
    # Runners.Inline -- is silent and strictly worse: it blocks the caller
    # for the length of an import instead of surfacing the typo.
    Application.put_env(:geo_genius, :task_supervisor, GeoGenius.NoSuchSupervisor)

    refute Runners.Task.available?()
    assert Runner.configured([]) == Runners.Task
  end

  test "Runners.Inline is always available" do
    assert Runners.Inline.available?()
  end

  test "every backend name resolves back to its module" do
    for module <- [Runners.Inline, Runners.Task, Runners.PgFlow] do
      assert Runner.module_for_backend(module.name()) == {:ok, module}
    end

    assert Runner.module_for_backend("nope") == {:error, :unknown_backend}
  end

  test "backend names are distinct" do
    names = Enum.map([Runners.Inline, Runners.Task, Runners.PgFlow], & &1.name())
    assert names == Enum.uniq(names)
  end

  describe "publish?/1" do
    test "reads an atom-keyed :publish" do
      assert Runner.publish?(%{publish: true})
      refute Runner.publish?(%{publish: false})
    end

    test "reads a string-keyed \"publish\", the shape a durable backend hands back after its own JSON decode" do
      assert Runner.publish?(%{"publish" => true})
      refute Runner.publish?(%{"publish" => false})
    end

    test "defaults to false when neither key is present, or the value is not a boolean" do
      refute Runner.publish?(%{})
      refute Runner.publish?(%{publish: "true"})
      refute Runner.publish?(%{"publish" => "true"})
    end
  end

  describe "stale_after_seconds/1" do
    test "reads an atom-keyed :stale_after_seconds" do
      assert Runner.stale_after_seconds(%{stale_after_seconds: 120}) == 120
    end

    test "reads a string-keyed \"stale_after_seconds\", the shape a durable backend hands back after its own JSON decode" do
      assert Runner.stale_after_seconds(%{"stale_after_seconds" => 120}) == 120
    end

    test "defaults to nil when the key is absent, non-positive, or not an integer" do
      assert Runner.stale_after_seconds(%{}) == nil
      assert Runner.stale_after_seconds(%{stale_after_seconds: nil}) == nil
      assert Runner.stale_after_seconds(%{stale_after_seconds: 0}) == nil
      assert Runner.stale_after_seconds(%{stale_after_seconds: -1}) == nil
      assert Runner.stale_after_seconds(%{stale_after_seconds: "120"}) == nil
      assert Runner.stale_after_seconds(%{"stale_after_seconds" => "120"}) == nil
    end
  end

  describe "configured/1 validates an explicit runner" do
    test "raises naming the module when it does not load" do
      error =
        assert_raise ArgumentError, fn ->
          Runner.configured(runner: GeoGenius.RunnerTest.NoSuchModuleAtAll)
        end

      assert error.message =~ "GeoGenius.RunnerTest.NoSuchModuleAtAll"
      assert error.message =~ "does not load"
    end

    test "raises naming every missing callback when the module does not implement the behaviour" do
      error = assert_raise ArgumentError, fn -> Runner.configured(runner: NotARunner) end

      assert error.message =~ inspect(NotARunner)
      assert error.message =~ "name/0"
      assert error.message =~ "available?/0"
      assert error.message =~ "enqueue/3"
    end

    test "a module implementing every callback passes through unchanged" do
      assert Runner.configured(runner: Custom) == Custom
    end

    test "config :geo_genius, :runner is validated the same way as the opt" do
      Application.put_env(:geo_genius, :runner, NotARunner)
      assert_raise ArgumentError, ~r/enqueue\/3/, fn -> Runner.configured([]) end
    end
  end
end
