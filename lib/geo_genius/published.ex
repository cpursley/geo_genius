defmodule GeoGenius.Published do
  @moduledoc """
  Composable Ecto queries over the catalog's read views.

  `GeoGenius.Query` builds queries over the catalog's `SETOF` plpgsql
  functions. PostgreSQL cannot push a predicate, a join qualifier, or a `LIMIT`
  inside one, so the whole set materialises before a host's own `WHERE` runs,
  and the four functions project five of `area_match`'s sixteen columns. This
  module reads the views those functions read, as ordinary Ecto schemas: the
  planner gets a relation it can optimise, and the caller gets every column the
  view carries, `release_id` among them.

  Reach for this module for joins, aggregates, set-keyed reads, and anything
  keyed on `release_id` -- a host projection table keyed
  `(release_id, area_key)` is joinable only from here. Reach for `GeoGenius`
  and `GeoGenius.Query` for spatial resolution, name search, and multi-level
  traversal; those have no view-backed equivalent. `guides/sql_api.md` lays the
  two side by side.

  ## Composing

  Every function returns an `Ecto.Query` selecting whole schema structs, not a
  list, and every source carries a named binding: `:area` for
  `GeoGenius.Published.Area`, `:relation` for
  `GeoGenius.Published.AreaRelation`, `:code` for
  `GeoGenius.Published.AreaCode`, `:name` for `GeoGenius.Published.AreaName`.
  Counting host records per child area, the case `GeoGenius.Query` serves
  worst:

      from([area: area] in GeoGenius.Published.children_of("us:state:pa", types: ["city"]),
        left_join: record in MyApp.Record,
        on: record.area_key == area.area_key and record.release_id == area.release_id,
        group_by: area.area_key,
        select: {area.area_key, count(record.id)})

  ## Set-keyed by default

  Where the function-backed API takes one `area_key`, these take a list, so
  resolving the parents of three thousand areas is one query rather than three
  thousand. A single binary is accepted as a one-element set. `children_of/2`
  and `ancestors_of/2` return one row per relation edge, so an area reachable
  from two of the parents given appears twice; the `:relation` binding says
  which parent each row came from, and `Ecto.Query.distinct/3` collapses them
  when the edge does not matter.

  ## Release and retirement scoping

  Each `published_*` view is a release-scoped base view joined to the
  publication pointer, so with no `:release_id` these queries read the
  currently published release of every collection. Giving `:release_id` swaps
  every source in the query onto its base -- `release_areas`,
  `release_relations`, `release_area_codes`, `release_area_names` -- and reads
  that release whether or not its collection publishes it, which is what a host
  verifying a release or filling a projection ahead of go-live needs. The bases
  project exactly the columns their published counterparts do, so nothing else
  about a query changes.

  The swap is all-or-nothing across the sources in one query, and every join
  between two release-carrying sources equates their `release_id` as well as
  the key it joins on. Both together are what keep a read on one release:
  reading areas from a base and relations from a published view, or joining
  them on `area_key` alone, would pair an edge of one release with an area of
  another.

  Retired areas are excluded unless `include_retired: true` is given, matching
  every `SETOF` read function, on the published and unpublished paths alike.
  `codes/1`, `names/1` and `relations/1` cannot honour it and do not take it:
  their views carry no `retired_at`, because retirement is a property of an
  area rather than of a code, a name, or an edge between two areas. So all
  three return rows for retired areas too. Moving from `children_of/2` to
  `relations/1` to reach an edge's measurement columns therefore widens the
  result; join back through `areas/1` on `area_key` and `release_id` to narrow
  it again.

  ## The compile-time prefix

  `@schema_prefix` is read at compile time through `Application.compile_env/3`
  and validated exactly as `GeoGenius.Query` validates its own. `:prefix`
  therefore belongs in `config/config.exs` and must never be set in
  `config/runtime.exs`; `GeoGenius.Query`'s moduledoc explains what breaks if
  it is, and how to recompile after changing it. There is no per-call
  `:prefix`, for the same reason there is none there: a host serving several
  catalogs from one VM uses the struct-returning API in `GeoGenius`, which
  resolves `:prefix` through `GeoGenius.Context` on every call.
  """

  import Ecto.Query

  alias GeoGenius.Published.{Area, AreaCode, AreaName, AreaRelation, Prefix}

  # The release-scoped base each schema reads when a `:release_id` is given.
  # Every base projects exactly the columns of the `published_*` view its
  # schema declares, in the same order, so one schema reads either source. A
  # bare source string carries no prefix, so every join naming one passes
  # `:prefix` explicitly rather than inheriting `@schema_prefix`.
  @release_sources %{
    Area => "release_areas",
    AreaCode => "release_area_codes",
    AreaName => "release_area_names",
    AreaRelation => "release_relations"
  }

  @doc """
  The schema prefix these schemas read, as validated at compile time.

  A host building SQL of its own against the same catalog reads it from here
  rather than assuming the default.
  """
  @spec prefix() :: String.t()
  def prefix, do: Prefix.get()

  @doc """
  The areas of a release, as a query.

  Accepts `:collections`, `:types`, `:area_keys`, `:release_id` and
  `:include_retired`. Each list-valued option keeps the rows matching any of
  its members and is skipped entirely when absent. `:release_id` accepts either
  the hyphenated string every read projects or the sixteen raw bytes Postgrex
  binds, and reads that release whether or not it is published.
  """
  @spec areas(keyword()) :: Ecto.Query.t()
  def areas(opts \\ []) do
    from(area in source(Area, opts), as: :area)
    |> scope_release(:area, opts)
    |> scope_retired(opts)
    |> filter_in(:area, :collection_key, opts[:collections])
    |> filter_in(:area, :area_type, opts[:types])
    |> filter_in(:area, :area_key, opts[:area_keys])
  end

  @doc """
  Areas one relation hop below any of these parents, as a query.

  Takes every option `areas/1` takes, plus `:classifications` to keep only
  edges of given relation types. A walk deeper than one hop is
  `GeoGenius.Query.children_of/2`'s `:max_depth`; a recursive walk has no
  view-backed form here.
  """
  @spec children_of([String.t()] | String.t(), keyword()) :: Ecto.Query.t()
  def children_of(parent_area_keys, opts \\ [])
      when is_binary(parent_area_keys) or is_list(parent_area_keys) do
    relation_hop(parent_area_keys, :child_area_key, :parent_area_key, opts)
  end

  @doc """
  Areas one relation hop above any of these children, as a query.

  Same options as `children_of/2`.
  """
  @spec ancestors_of([String.t()] | String.t(), keyword()) :: Ecto.Query.t()
  def ancestors_of(child_area_keys, opts \\ [])
      when is_binary(child_area_keys) or is_list(child_area_keys) do
    relation_hop(child_area_keys, :parent_area_key, :child_area_key, opts)
  end

  @doc """
  Areas carrying any of these values under one code type, as a query.

  Takes every option `areas/1` takes. The matched code is available through the
  `:code` binding, which is what tells apart the areas a set of values matched.
  A code is unique only within a parent, so scope a slug lookup by composing
  this with `children_of/2`'s parent set rather than trusting a bare value.
  """
  @spec areas_by_code(String.t(), [String.t()] | String.t(), keyword()) :: Ecto.Query.t()
  def areas_by_code(code_type, code_values, opts \\ [])
      when is_binary(code_type) and (is_binary(code_values) or is_list(code_values)) do
    opts
    |> areas()
    |> join(:inner, [area: area], code in ^source(AreaCode, opts),
      on: code.area_id == area.area_id and code.release_id == area.release_id,
      as: :code,
      prefix: ^prefix()
    )
    |> filter_in(:code, :code_type, code_type)
    |> filter_in(:code, :code_value, code_values)
  end

  @doc """
  Codes held by the areas of a release, as a query.

  Accepts `:collections`, `:area_keys`, `:code_types` and `:release_id`. One
  row per code an area of the release holds, where `GeoGenius.AreaMatch`
  carries them collapsed into a JSON object. A code is a fact about the area,
  so an area carried by several releases yields one row per release, each
  stamped with its own `release_id`.
  """
  @spec codes(keyword()) :: Ecto.Query.t()
  def codes(opts \\ []) do
    from(code in source(AreaCode, opts), as: :code)
    |> scope_release(:code, opts)
    |> filter_in(:code, :collection_key, opts[:collections])
    |> filter_in(:code, :area_key, opts[:area_keys])
    |> filter_in(:code, :code_type, opts[:code_types])
  end

  @doc """
  Names held by the areas of a release, as a query.

  Accepts `:collections`, `:area_keys`, `:kinds`, `:locales` and `:release_id`.
  Every name of every kind, where `GeoGenius.Published.Area`'s `name` is the
  single official one a trigger keeps current. Like `codes/1`, a name is a fact
  about the area, so an area carried by several releases yields one row per
  release.
  """
  @spec names(keyword()) :: Ecto.Query.t()
  def names(opts \\ []) do
    from(name in source(AreaName, opts), as: :name)
    |> scope_release(:name, opts)
    |> filter_in(:name, :collection_key, opts[:collections])
    |> filter_in(:name, :area_key, opts[:area_keys])
    |> filter_in(:name, :kind, opts[:kinds])
    |> filter_in(:name, :locale, opts[:locales])
  end

  @doc """
  Relation edges among the areas of a release, as a query.

  Accepts `:collections`, `:parent_area_keys`, `:child_area_keys`,
  `:classifications` and `:release_id`. Use this to read an edge's measurement
  columns, which no `area_match` read projects; use `children_of/2` or
  `ancestors_of/2` to read the areas at the far end of one.

  There is no `:include_retired`, and edges touching a retired area are always
  returned: the relation views carry no `retired_at` to filter on, because
  retirement is a property of an area rather than of an edge between two. A
  caller coming from `children_of/2`, which excludes them by default, narrows
  the result by joining `areas/1` back on `area_key` and `release_id`.
  """
  @spec relations(keyword()) :: Ecto.Query.t()
  def relations(opts \\ []) do
    from(relation in source(AreaRelation, opts), as: :relation)
    |> scope_release(:relation, opts)
    |> filter_in(:relation, :collection_key, opts[:collections])
    |> filter_in(:relation, :parent_area_key, opts[:parent_area_keys])
    |> filter_in(:relation, :child_area_key, opts[:child_area_keys])
    |> filter_in(:relation, :relation_type, opts[:classifications])
  end

  # One hop across the relation view: `area_side` is the end of the edge the
  # resulting areas sit on, `key_side` the end the given keys match. The
  # `release_id` equality is what keeps an edge of one release from reaching an
  # area of another, which matters on every path and not only the published
  # one: `release_areas` and `release_relations` both carry every release.
  defp relation_hop(area_keys, area_side, key_side, opts) do
    opts
    |> areas()
    |> join(:inner, [area: area], relation in ^source(AreaRelation, opts),
      on: field(relation, ^area_side) == area.area_key and relation.release_id == area.release_id,
      as: :relation,
      prefix: ^prefix()
    )
    |> filter_in(:relation, key_side, area_keys)
    |> filter_in(:relation, :relation_type, opts[:classifications])
  end

  defp filter_in(query, _binding, _field, nil), do: query

  defp filter_in(query, binding, field, values) do
    from([{^binding, row}] in query, where: field(row, ^field) in ^List.wrap(values))
  end

  # The source a schema reads. With no `:release_id` every schema stays on its
  # `published_*` view and the publication pointer decides what a read sees.
  # An explicit `:release_id` swaps every schema in the query onto its
  # release-scoped base, so the release reads the same whether or not it is
  # published; swapping some and not others is what would mix releases, so the
  # option routes all of them or none.
  defp source(schema, opts) do
    case Keyword.get(opts, :release_id) do
      nil -> schema
      _release_id -> {Map.fetch!(@release_sources, schema), schema}
    end
  end

  # Narrows to one release. Paired with `source/2`, which has already put the
  # query on a base carrying every release, so the release reached here need
  # not be a published one.
  defp scope_release(query, binding, opts) do
    case Keyword.get(opts, :release_id) do
      nil -> query
      release_id -> from([{^binding, row}] in query, where: row.release_id == ^uuid(release_id))
    end
  end

  defp scope_retired(query, opts) do
    if Keyword.get(opts, :include_retired, false) do
      query
    else
      from([area: area] in query, where: is_nil(area.retired_at))
    end
  end

  # `Ecto.UUID` casts the hyphenated string every read projects. The sixteen
  # raw bytes reach here from a caller passing on a release id that has already
  # been through `GeoGenius.Stores.Postgres.dump_uuid/1`, which the
  # function-backed API accepts in both shapes too.
  defp uuid(<<_::128>> = release_id), do: Ecto.UUID.load!(release_id)
  defp uuid(release_id) when is_binary(release_id), do: release_id
end
