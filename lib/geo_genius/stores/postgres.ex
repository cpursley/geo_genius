defmodule GeoGenius.Stores.Postgres do
  @moduledoc """
  The shipped store. Every read is one call to a SQL function in the installed
  schema, with every optional argument bound explicitly.
  """

  @behaviour GeoGenius.Store

  alias GeoGenius.{AreaMatch, Context, QueryError}

  # One projection serves every read. `AreaMatch` enforces `:area_key` and maps
  # by column name, so a read that projected a subset would fail on its first
  # row rather than return a partial struct.
  #
  # `release_id` is cast to text because these reads go through `Repo.query/2`,
  # which does no Ecto type loading: the column would otherwise arrive as the
  # raw sixteen bytes Postgrex decodes a uuid into, while `AreaMatch` declares
  # `Ecto.UUID.t()` and `release_at/3` returns the hyphenated string. A caller
  # feeds one read's release id into the next read's `:release_id`, so the two
  # have to be the same shape.
  #
  # The measurement columns are declared numeric so the composite type can hold
  # a ratio or an area, but every one of them is computed in double precision
  # inside PostGIS. Projecting them back spares callers Decimal arithmetic. Every
  # cast is aliased to its own column name so the mapping still finds it.
  @projection """
  collection_key, release_id::text AS release_id, area_key, authority, area_type, type_rank, name,
  codes, centroid, attributes, match_method,
  distance_m::double precision AS distance_m,
  intersection_area_m2::double precision AS intersection_area_m2,
  coverage_of_input::double precision AS coverage_of_input,
  coverage_of_area::double precision AS coverage_of_area,
  score::double precision AS score
  """

  @impl GeoGenius.Store
  def areas_for_point(%Context{} = context, lon, lat, opts) do
    call(context, "areas_for_point", "$1, $2, $3, $4, $5, $6", [
      numeric!(lon, "areas_for_point", "lon"),
      numeric!(lat, "areas_for_point", "lat"),
      opts[:collections],
      opts[:types],
      release_id(opts),
      include_retired(opts)
    ])
  end

  @impl GeoGenius.Store
  def areas_for_geometry(%Context{} = context, geometry, opts) do
    call(context, "areas_for_geometry", "$1, $2, $3, $4, $5", [
      geometry,
      opts[:collections],
      opts[:types],
      release_id(opts),
      include_retired(opts)
    ])
  end

  @impl GeoGenius.Store
  def areas_near(%Context{} = context, lon, lat, radius_m, opts) do
    call(context, "areas_near", "$1, $2, $3, $4, $5, $6, $7, $8", [
      numeric!(lon, "areas_near", "lon"),
      numeric!(lat, "areas_near", "lat"),
      numeric!(radius_m, "areas_near", "radius_m"),
      opts[:collections],
      opts[:types],
      Keyword.get(opts, :limit, 50),
      release_id(opts),
      include_retired(opts)
    ])
  end

  @impl GeoGenius.Store
  def areas_by_code(%Context{} = context, code_type, code_value, opts) do
    call(context, "areas_by_code", "$1, $2, $3, $4, $5, $6, $7, $8", [
      code_type,
      code_value,
      opts[:collections],
      opts[:types],
      release_id(opts),
      include_retired(opts),
      opts[:parent_area_key],
      Keyword.get(opts, :parent_max_depth, 1)
    ])
  end

  @impl GeoGenius.Store
  def search_areas(%Context{} = context, query, opts) do
    call(context, "search_areas", "$1, $2, $3, $4, $5, $6", [
      query,
      opts[:collections],
      opts[:types],
      Keyword.get(opts, :limit, 50),
      release_id(opts),
      include_retired(opts)
    ])
  end

  @impl GeoGenius.Store
  def resolve(%Context{} = context, input, opts) when is_map(input) do
    call(context, "resolve", "$1, $2, $3, $4, $5, $6", [
      input,
      opts[:collections],
      opts[:types],
      opts[:strategies],
      release_id(opts),
      include_retired(opts)
    ])
  end

  @impl GeoGenius.Store
  def children_of(%Context{} = context, area_key, opts) do
    call(context, "children_of", "$1, $2, $3, $4, $5, $6", [
      area_key,
      opts[:types],
      opts[:classifications],
      Keyword.get(opts, :max_depth, 1),
      release_id(opts),
      include_retired(opts)
    ])
  end

  @impl GeoGenius.Store
  def ancestors_of(%Context{} = context, area_key, opts) do
    call(context, "ancestors_of", "$1, $2, $3, $4, $5, $6", [
      area_key,
      opts[:types],
      opts[:classifications],
      Keyword.get(opts, :max_depth, 1),
      release_id(opts),
      include_retired(opts)
    ])
  end

  @impl GeoGenius.Store
  def related_areas(%Context{} = context, area_key, opts) do
    call(context, "related_areas", "$1, $2, $3, $4", [
      area_key,
      opts[:classifications],
      release_id(opts),
      include_retired(opts)
    ])
  end

  @impl GeoGenius.Store
  def release_at(%Context{} = context, %DateTime{} = as_of, opts) do
    collection =
      case Keyword.fetch(opts, :collection) do
        {:ok, collection} ->
          collection

        :error ->
          raise ArgumentError,
                "GeoGenius read release_at requires the :collection option naming which " <>
                  "collection to look up, as in " <>
                  ~S|GeoGenius.release_at(as_of, collection: "us_counties")|
      end

    call_scalar(context, "release_at", "$1, $2", [collection, as_of])
  end

  # Coordinates and radii bind as double precision. An integer is the ordinary
  # way to write a whole-degree coordinate, and a host reading lat/lon from a
  # numeric column holds a `%Decimal{}`, so both convert. Anything else names
  # the read and the argument it arrived as, which a bare multiplication by 1.0
  # cannot: `ArithmeticError` names neither GeoGenius nor the value.
  defp numeric!(value, _function, _argument) when is_float(value), do: value
  defp numeric!(value, _function, _argument) when is_integer(value), do: value * 1.0
  defp numeric!(%Decimal{} = value, _function, _argument), do: Decimal.to_float(value)

  defp numeric!(value, function, argument) do
    raise ArgumentError,
          "GeoGenius read #{function} requires #{argument} to be a number -- a float, an " <>
            "integer, or a Decimal -- got: #{inspect(value)}"
  end

  defp include_retired(opts), do: Keyword.get(opts, :include_retired, false)

  # `:release_id` is accepted in either shape a caller can hold one: the
  # hyphenated string every read projects and `release_at/3` returns, or the
  # sixteen bytes Postgrex binds. Postgrex takes only the latter.
  defp release_id(opts), do: opts |> Keyword.get(:release_id) |> dump_uuid()

  @doc """
  Normalises a release id into the sixteen raw bytes Postgrex binds to a
  `uuid` parameter. Accepts either that already-dumped binary or the
  hyphenated string every read projects and `release_at/3` returns, so a
  caller can feed one read's release id into the next read's `:release_id`
  regardless of which layer produced it. `GeoGenius.Query` binds `:release_id`
  through this same function rather than reimplementing the shape check.
  """
  @spec dump_uuid(String.t() | binary() | nil) :: binary() | nil
  def dump_uuid(nil), do: nil
  def dump_uuid(<<_::128>> = release_id), do: release_id
  def dump_uuid(release_id) when is_binary(release_id), do: Ecto.UUID.dump!(release_id)

  # `GeoGenius.Context.new/1` validates the prefix, so a context built through
  # it carries an identifier already proven safe to interpolate. A `%Context{}`
  # assembled as a struct literal skips that validation, and this interpolation
  # trusts whatever such a context carries. Everything a caller supplies as
  # data travels as a bound parameter regardless.
  defp call(%Context{repo: repo, prefix: prefix}, function, placeholders, params) do
    GeoGenius.Telemetry.span(function, %{prefix: prefix}, fn ->
      sql = "SELECT #{@projection} FROM \"#{prefix}\".#{function}(#{placeholders})"

      case run(repo, sql, params) do
        {:ok, result} -> AreaMatch.from_result(result)
        {:error, reason} -> raise QueryError, function: function, reason: reason
      end
    end)
  end

  # release_at returns a uuid rather than SETOF area_match, so it cannot share
  # the projection. Casting to text keeps the value a plain string on the way
  # out, which is what a caller passes back as :release_id.
  defp call_scalar(%Context{repo: repo, prefix: prefix}, function, placeholders, params) do
    GeoGenius.Telemetry.span(function, %{prefix: prefix}, fn ->
      sql =
        "SELECT #{function}::text FROM \"#{prefix}\".#{function}(#{placeholders}) AS #{function}"

      case run(repo, sql, params) do
        {:ok, %Postgrex.Result{rows: [[value]]}} -> value
        {:ok, %Postgrex.Result{rows: []}} -> nil
        {:error, reason} -> raise QueryError, function: function, reason: reason
      end
    end)
  end

  # A read reports through `QueryError` whichever way the driver reports
  # trouble. A statement the database rejects comes back as an error tuple, but
  # a parameter the driver cannot encode -- a bare string where `:types` wants a
  # list, say -- raises before the statement is ever sent. Both carry the
  # original as the exception's `:reason`.
  defp run(repo, sql, params) do
    repo.query(sql, params)
  rescue
    error -> {:error, error}
  end
end
