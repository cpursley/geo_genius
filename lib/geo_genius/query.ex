defmodule GeoGenius.Query do
  @moduledoc """
  Composable Ecto queries over the catalog's read functions.

  `GeoGenius`'s struct-returning functions answer one question per call. These
  return queries instead, so a host can join catalog areas against its own
  tables and aggregate in a single round trip. Counting host records per area
  is the case this exists for.

  Joins are on `area_key`. It is the catalog's stable identifier, it survives
  re-import, and it is what a host stores as its own reference.

      from(area in subquery(GeoGenius.Query.children_of("us:state:pa", types: ["city"])),
        left_join: record in MyApp.Record, on: record.area_key == area.area_key,
        group_by: area.area_key,
        select: {area.area_key, count(record.id)})

  Ecto requires a fragment's SQL to be a literal, so the schema prefix is read
  at compile time via `Application.compile_env/3` and validated the same way
  every other path validates a prefix, through the package's internal prefix
  validation. It is emitted as a quoted identifier, because that validation
  accepts reserved words: a host installed at `prefix: "user"` needs
  `"user".children_of(...)`, which is what these fragments build.

  `:prefix` therefore belongs in `config/config.exs`, and must never be set in
  `config/runtime.exs`. `Application.compile_env/3` records the result of its
  read, and "not configured" is one of the results it records; Elixir raises at
  boot when the value present then differs from the recorded one. A `:prefix`
  first assigned in `runtime.exs` differs from a compile-time read that found
  nothing even when the value assigned is the identical default string, so the
  host fails to boot. `:repo` carries no such constraint and may be set
  wherever the host prefers. A changed compile-time `:prefix` takes effect once
  `:geo_genius` is recompiled, with `mix deps.compile geo_genius --force`.

  There is no per-call `:prefix` option here, and there cannot be one: a
  runtime value cannot fill a position `fragment/1` requires to be a literal.
  Passing `:prefix` in `opts` raises `ArgumentError` rather than being
  silently ignored. A host that serves several catalogs from one VM and needs
  a runtime `:prefix` per call must use the struct-returning API in
  `GeoGenius` instead, which resolves `:prefix` through `GeoGenius.Context` on
  every call.
  """

  import Ecto.Query

  alias GeoGenius.{Config, Stores.Postgres}

  @prefix Application.compile_env(:geo_genius, :prefix, "geo_genius") |> Config.validate_prefix!()

  @doc """
  Areas below this one, as a query.

  Accepts `:types`, `:classifications`, `:max_depth`, `:release_id`,
  `:include_retired`. `:release_id` accepts either the hyphenated string
  every read projects or the sixteen raw bytes Postgrex binds.
  """
  @spec children_of(String.t(), keyword()) :: Ecto.Query.t()
  def children_of(area_key, opts \\ []) do
    reject_prefix_option!(opts)

    from(
      area in fragment(
        unquote("\"#{@prefix}\".children_of(?, ?, ?, ?, ?, ?)"),
        ^area_key,
        ^opts[:types],
        ^opts[:classifications],
        ^Keyword.get(opts, :max_depth, 1),
        ^Postgres.dump_uuid(opts[:release_id]),
        ^Keyword.get(opts, :include_retired, false)
      ),
      select: %{
        area_key: area.area_key,
        area_type: area.area_type,
        name: area.name,
        centroid: area.centroid,
        attributes: area.attributes
      }
    )
  end

  @doc "Areas above this one, as a query. Same options as `children_of/2`."
  @spec ancestors_of(String.t(), keyword()) :: Ecto.Query.t()
  def ancestors_of(area_key, opts \\ []) do
    reject_prefix_option!(opts)

    from(
      area in fragment(
        unquote("\"#{@prefix}\".ancestors_of(?, ?, ?, ?, ?, ?)"),
        ^area_key,
        ^opts[:types],
        ^opts[:classifications],
        ^Keyword.get(opts, :max_depth, 1),
        ^Postgres.dump_uuid(opts[:release_id]),
        ^Keyword.get(opts, :include_retired, false)
      ),
      select: %{
        area_key: area.area_key,
        area_type: area.area_type,
        name: area.name,
        centroid: area.centroid,
        attributes: area.attributes
      }
    )
  end

  @doc """
  Areas carrying a code, as a query.

  Accepts `:collections`, `:types`, `:release_id`, `:include_retired`,
  `:parent_area_key`, and `:parent_max_depth`. `:release_id` accepts the same
  two shapes as `children_of/2`.
  """
  @spec areas_by_code(String.t(), String.t(), keyword()) :: Ecto.Query.t()
  def areas_by_code(code_type, code_value, opts \\ []) do
    reject_prefix_option!(opts)

    from(
      area in fragment(
        unquote("\"#{@prefix}\".areas_by_code(?, ?, ?, ?, ?, ?, ?, ?)"),
        ^code_type,
        ^code_value,
        ^opts[:collections],
        ^opts[:types],
        ^Postgres.dump_uuid(opts[:release_id]),
        ^Keyword.get(opts, :include_retired, false),
        ^opts[:parent_area_key],
        ^Keyword.get(opts, :parent_max_depth, 1)
      ),
      select: %{
        area_key: area.area_key,
        area_type: area.area_type,
        name: area.name,
        centroid: area.centroid,
        attributes: area.attributes
      }
    )
  end

  @doc """
  Areas ranked by name similarity, as a query.

  Accepts `:collections`, `:types`, `:limit`, `:release_id`, and
  `:include_retired`. `:release_id` accepts the same two shapes as
  `children_of/2`.
  """
  @spec search_areas(String.t(), keyword()) :: Ecto.Query.t()
  def search_areas(query, opts \\ []) do
    reject_prefix_option!(opts)

    from(
      area in fragment(
        unquote("\"#{@prefix}\".search_areas(?, ?, ?, ?, ?, ?)"),
        ^query,
        ^opts[:collections],
        ^opts[:types],
        ^Keyword.get(opts, :limit, 50),
        ^Postgres.dump_uuid(opts[:release_id]),
        ^Keyword.get(opts, :include_retired, false)
      ),
      select: %{
        area_key: area.area_key,
        area_type: area.area_type,
        name: area.name,
        centroid: area.centroid,
        attributes: area.attributes,
        score: fragment("?::double precision", area.score)
      }
    )
  end

  # `fragment/1` needs a compile-time literal, so `:prefix` cannot be honoured
  # per call the way the struct-returning API honours it. Raising here means a
  # caller who expects a runtime, per-call catalog to be honoured gets a loud
  # error instead of silently reading the compile-time prefix's rows.
  defp reject_prefix_option!(opts) do
    if Keyword.has_key?(opts, :prefix) do
      raise ArgumentError,
            "GeoGenius.Query does not support a per-call :prefix option -- its SQL is fixed " <>
              "to the compile-time :prefix (#{inspect(@prefix)}) because Ecto's fragment/1 " <>
              "requires a literal. Use GeoGenius's struct-returning API for a per-call :prefix."
    end
  end
end
