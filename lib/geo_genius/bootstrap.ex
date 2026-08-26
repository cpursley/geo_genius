defmodule GeoGenius.Bootstrap do
  @moduledoc """
  Optional supervised child that idempotently enqueues a configured desired
  release at host boot.

  GeoGenius does not add this to its own supervision tree -- starting a host
  application must never download or import anything on its own. A host that
  wants a release enqueued automatically places this child in its OWN
  supervision tree, the same way `GeoGenius.Preflight` is left for a host to
  place rather than shipped in `GeoGenius.Application`'s tree:

      children = [
        MyApp.Repo,
        {GeoGenius.Preflight, repo: MyApp.Repo},
        {GeoGenius.Bootstrap, repo: MyApp.Repo},
        MyAppWeb.Endpoint
      ]

  and configures the desired release:

      config :geo_genius, :bootstrap,
        enabled: true,
        collection: "us_counties",
        release: "2026",
        publish: true

  **Disabled by default.** `:enabled` defaults to `false`, so a host that
  configures nothing under `:bootstrap` -- or configures it without flipping
  `enabled: true` -- gets a no-op child every time. `:enabled` and `:publish`
  are both compared against the literal value `true`, so a truthy-but-not-`true`
  value (`enabled: "true"`, `publish: 1`) is treated as `false` rather than
  coerced -- the safe direction for `:enabled`, and the same rule applied
  consistently to `:publish`.

  `:enabled`, `:collection`, `:release`, and `:publish` may each be passed to
  `start_link/1` directly, and an explicit value there wins over
  `config :geo_genius, :bootstrap` for that key, even when the explicit value
  is `false` or `nil` and the configured one is not. Every other option is
  forwarded to `GeoGenius.import/1` as given -- `:repo`, `:prefix`, `:runner`,
  `:manifest_paths`, and so on -- so this child needs no configuration keys of
  its own beyond the four above.

  Modelled on `GeoGenius.Preflight`: `start_link/1` returns `:ignore`, so
  nothing lingers in the supervision tree once the release has been enqueued
  (or the child has decided there is nothing to enqueue). Unlike `Preflight`,
  it never raises -- and that protection covers `start_link/1`'s entire body,
  not just the call into `GeoGenius.import/1`. `import/1` returns
  `{:error, exception}` for a manifest that cannot be resolved or a catalog
  write that cannot complete, but it can also raise outside that pair -- a
  bad runner, a missing `:collection`, a `Context.new/1` that cannot resolve
  a Repo -- and resolving `:enabled` itself can raise on a malformed
  `config :geo_genius, :bootstrap` (the wrong shape entirely, not just a
  missing key). None of those may stop a host from booting: the host can
  still read whatever release is already published. Every path -- the
  error-tuple branch and anything raised, from `:enabled` resolution through
  `GeoGenius.import/1` -- is logged at `:error`, and the child still returns
  `:ignore` either way.
  """

  require Logger

  @doc "Builds the child spec for placing this bootstrap in a supervision tree."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      # start_link/1 always returns :ignore, so no supervisor ever restarts
      # this child regardless of :restart -- :transient would behave the
      # same way here. :temporary is still the honest declaration: this is a
      # one-shot child with no ongoing work, not a worker a supervisor should
      # expect to keep running.
      restart: :temporary
    }
  end

  @doc """
  Enqueues the configured desired release, once, and returns `:ignore`.

  When `:enabled` (opts, falling back to `config :geo_genius, :bootstrap`) is
  not `true`, returns `:ignore` immediately without reading `:collection`,
  `:release`, `:publish`, or calling `GeoGenius.import/1` at all.
  """
  @spec start_link(keyword()) :: :ignore
  def start_link(opts) do
    if enabled?(opts) do
      enqueue(opts)
    end

    :ignore
  rescue
    # Covers the whole body, not just the GeoGenius.import/1 call inside
    # enqueue/1: enabled?/1 runs for every host, configured or not, and a
    # malformed `config :geo_genius, :bootstrap` (wrong shape entirely, not
    # just a missing key) must not stop a host from booting any more than a
    # missing :collection does.
    exception ->
      log_failure(exception)
      :ignore
  end

  defp enabled?(opts), do: resolved(opts, :enabled) == true

  # Called only for its side effect (an enqueue attempt, or a logged
  # failure); start_link/1 discards whatever this returns. Raises from here
  # propagate to start_link/1's own rescue rather than being caught locally.
  defp enqueue(opts) do
    import_opts =
      opts
      |> Keyword.drop([:enabled, :collection, :release, :publish])
      |> Keyword.merge(target(opts))

    case GeoGenius.import(import_opts) do
      {:ok, _run_id} -> :ok
      {:error, reason} -> log_failure(reason)
    end
  end

  defp target(opts) do
    [publish: resolved(opts, :publish) == true]
    |> put_if_present(:collection, resolved(opts, :collection))
    |> put_if_present(:release, resolved(opts, :release))
  end

  defp put_if_present(keyword, _key, nil), do: keyword
  defp put_if_present(keyword, key, value), do: Keyword.put(keyword, key, value)

  # `Keyword.fetch/2` rather than `Keyword.get/2` (or `||`) so an option
  # explicitly given in `opts` -- including `false` or `nil` -- wins over
  # application environment. `false || Application.get_env(...)` would fall
  # through to configuration on exactly the call a host makes to explicitly
  # turn this off, which is the one call this precedence exists to honor.
  defp resolved(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Keyword.get(bootstrap_config(), key)
    end
  end

  defp bootstrap_config, do: Application.get_env(:geo_genius, :bootstrap, [])

  defp log_failure(reason) do
    message = if is_exception(reason), do: Exception.message(reason), else: inspect(reason)
    Logger.error("GeoGenius.Bootstrap could not enqueue the configured release: " <> message)
  end
end
