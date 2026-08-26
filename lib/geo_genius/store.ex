defmodule GeoGenius.Store do
  @moduledoc """
  The contract every catalog read goes through.

  A store issues one call to a shipped SQL function per read and maps the rows.
  It adds no filtering, ordering, or limiting of its own: those belong to the
  SQL API, where they are already specified and tested.
  """

  alias GeoGenius.{AreaMatch, Context}

  @typedoc """
  A coordinate or a radius in metres.

  These bind as `double precision`, and a host holds one in whatever shape it
  read: a float, an integer for a whole-degree coordinate, or the `%Decimal{}`
  Ecto loads from a `numeric` column. All three are accepted.
  """
  @type numeric :: number() | Decimal.t()

  @callback areas_for_point(Context.t(), numeric(), numeric(), keyword()) :: [AreaMatch.t()]
  @callback areas_for_geometry(Context.t(), Geo.geometry(), keyword()) :: [AreaMatch.t()]
  @callback areas_near(Context.t(), numeric(), numeric(), numeric(), keyword()) ::
              [AreaMatch.t()]
  @callback areas_by_code(Context.t(), String.t(), String.t(), keyword()) :: [AreaMatch.t()]
  @callback search_areas(Context.t(), String.t(), keyword()) :: [AreaMatch.t()]
  @callback resolve(Context.t(), map(), keyword()) :: [AreaMatch.t()]
  @callback children_of(Context.t(), String.t(), keyword()) :: [AreaMatch.t()]
  @callback ancestors_of(Context.t(), String.t(), keyword()) :: [AreaMatch.t()]
  @callback related_areas(Context.t(), String.t(), keyword()) :: [AreaMatch.t()]
  @callback release_at(Context.t(), DateTime.t(), keyword()) :: Ecto.UUID.t() | nil

  @backend_modules %{"postgres" => GeoGenius.Stores.Postgres}

  @doc "Resolves a backend name to its module."
  @spec module_for_backend(String.t()) :: {:ok, module()} | {:error, :unknown_backend}
  def module_for_backend(backend) when is_binary(backend) do
    case Map.fetch(@backend_modules, backend) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_backend}
    end
  end

  @doc "The store this host configured, or the shipped default."
  @spec configured(keyword()) :: module()
  def configured(opts \\ []), do: GeoGenius.Config.store(opts)
end
