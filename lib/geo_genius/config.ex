defmodule GeoGenius.Config do
  @moduledoc false

  # The `:geo_genius` application environment describes exactly one host: one
  # repo and one prefix. A VM serving several hosts passes both explicitly on
  # every call rather than relying on this fallback.

  @prefix ~r/\A[a-z_][a-z0-9_]*\z/

  # Uninstalling drops the prefix schema. These are schemas GeoGenius must
  # never be allowed to own, because dropping one would take the host's own
  # objects -- or the catalog itself -- with it.
  @reserved_prefixes ~w(public information_schema pg_catalog pg_toast pg_temp)

  @adapter_defaults %{
    cache: GeoGenius.Caches.FileSystem,
    downloader: GeoGenius.Downloaders.Req,
    command: GeoGenius.Commands.System,
    notifier: GeoGenius.Notifiers.Noop
  }

  # Providers this package ships. A host registering its own module under one
  # of these names in `config :geo_genius, :providers` takes precedence, since
  # `providers/0` merges this map first and the host's second.
  @shipped_providers %{
    "geojson" => GeoGenius.Providers.GeoJSON,
    "csv" => GeoGenius.Providers.CSV,
    "shapefile" => GeoGenius.Providers.Shapefile,
    "simplemaps" => GeoGenius.Providers.SimpleMaps
  }

  @spec repo!(keyword()) :: module()
  @doc "Resolves the Repo from `opts[:repo]`, falling back to application environment."
  def repo!(opts) do
    Keyword.get_lazy(opts, :repo, fn -> Application.fetch_env!(:geo_genius, :repo) end)
  end

  @spec prefix(keyword()) :: String.t()
  @doc "Resolves and validates the prefix from `opts[:prefix]`, falling back to application environment."
  def prefix(opts) do
    opts
    |> Keyword.get(:prefix, Application.get_env(:geo_genius, :prefix, "geo_genius"))
    |> validate_prefix!()
  end

  @spec validate_prefix!(term()) :: String.t()
  @doc "Validates that a value is a safe PostgreSQL schema identifier, raising otherwise."
  def validate_prefix!(prefix) when not is_binary(prefix) do
    raise ArgumentError, "PostgreSQL prefix must be a string"
  end

  def validate_prefix!(prefix) when byte_size(prefix) > 63 do
    raise ArgumentError, "PostgreSQL prefix must be at most 63 bytes"
  end

  def validate_prefix!(prefix) when prefix in @reserved_prefixes do
    raise ArgumentError,
          "PostgreSQL prefix #{inspect(prefix)} is reserved; GeoGenius must own its schema " <>
            "because uninstalling drops it"
  end

  def validate_prefix!("pg_" <> _ = prefix) do
    raise ArgumentError,
          "PostgreSQL prefix #{inspect(prefix)} is reserved; the pg_ namespace belongs to PostgreSQL"
  end

  def validate_prefix!(prefix) do
    if Regex.match?(@prefix, prefix) do
      prefix
    else
      raise ArgumentError, "invalid PostgreSQL prefix"
    end
  end

  @spec store(keyword()) :: module()
  @doc "Resolves the Store module from options, falling back to application environment."
  def store(opts) do
    Keyword.get_lazy(opts, :store, fn ->
      Application.get_env(:geo_genius, :store, GeoGenius.Stores.Postgres)
    end)
  end

  @spec adapter(atom(), keyword()) :: module()
  @doc """
  Resolves one adapter module from options, then application environment, then
  the shipped default.

  `:runner` is resolved by `GeoGenius.Runner.configured/1` instead, because its
  default depends on which optional durable-execution package is loaded.
  """
  def adapter(name, opts) when is_map_key(@adapter_defaults, name) do
    Keyword.get_lazy(opts, name, fn ->
      Application.get_env(:geo_genius, name, Map.fetch!(@adapter_defaults, name))
    end)
  end

  @doc """
  Resolves a provider name to its module.

  A host registers providers with
  `config :geo_genius, :providers, %{"acme" => MyApp.AcmeProvider}`.

  The module a name resolves to must load. A name pointing at a module that
  does not is a configuration error rather than a provider carrying no
  requirements, and reading it as the latter makes manifest validation accept
  every options block written for that provider.
  """
  @spec provider!(String.t()) :: module()
  def provider!(name) when is_binary(name) do
    case Map.fetch(providers(), name) do
      {:ok, module} ->
        loaded_provider!(name, module)

      :error ->
        raise ArgumentError,
              "GeoGenius provider #{inspect(name)} is not a known provider; " <>
                registered_providers()
    end
  end

  defp loaded_provider!(name, module) do
    if Code.ensure_loaded?(module) do
      module
    else
      raise ArgumentError,
            "GeoGenius provider #{inspect(name)} is registered as #{inspect(module)}, which " <>
              "does not load. Check the module name in config :geo_genius, :providers, and " <>
              "that the module is compiled into this build."
    end
  end

  # providers/0 always contains at least the shipped providers, so this never
  # sees an empty list.
  defp registered_providers do
    names = providers() |> Map.keys() |> Enum.sort()
    "known providers are " <> Enum.join(names, ", ")
  end

  @doc """
  Every provider name this application can resolve.

  Shipped providers are merged ahead of the host's registrations, so a host
  that registers its own module under a shipped name -- `"geojson"`, say --
  takes precedence over the one this package carries.
  """
  @spec providers() :: %{optional(String.t()) => module()}
  def providers do
    Map.merge(@shipped_providers, Application.get_env(:geo_genius, :providers, %{}))
  end

  @doc """
  Directories searched for manifests, in order.

  The package's own `priv/geo_genius/manifests` is searched last, so a host
  shipping a corrected manifest under the same name takes precedence over one
  the package carries.
  """
  @spec manifest_paths(keyword()) :: [Path.t()]
  def manifest_paths(opts \\ []) do
    configured =
      Keyword.get_lazy(opts, :manifest_paths, fn ->
        Application.get_env(:geo_genius, :manifest_paths, [])
      end)

    List.wrap(configured) ++ [Application.app_dir(:geo_genius, "priv/geo_genius/manifests")]
  end
end
