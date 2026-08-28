# Reading the catalog

`GeoGenius` wraps the SQL functions described in [`sql_api.md`](sql_api.md) in typed
Elixir functions: ten reads that return `[%GeoGenius.AreaMatch{}]` (or, for
`release_at/2`, a bare release id). Two composable query APIs sit alongside them:
`GeoGenius.Published`, read-only Ecto schemas over the `published_*` views, which is
where joins, aggregates and set-keyed reads belong; and `GeoGenius.Query`, the same
`SETOF` functions shaped as a query, for the traversal and search a view has no form for.
This guide covers all three.

Everything here reads a published catalog. Getting data into one is the other half, and
it has its own guide: [`ingestion.md`](ingestion.md) covers manifests, providers, the
import pipeline, and publication. A host that would rather load the catalog by hand calls
the SQL write functions in [`sql_api.md`](sql_api.md) directly, the way the README's Usage
section does.

## Configuring the Repo to decode geometry

Every read that touches geometry - a centroid on every match, a polygon argument to
`areas_for_geometry/2` - crosses the wire as a `Geo` struct, not WKT/EWKT text. That only
works if the host's Repo is configured with a Postgrex types module that registers
`Geo.PostGIS.Extension`. `GeoGenius.Preflight` checks this at startup and fails host
boot, with a remedy, when it is missing - a host never discovers this by way of a first
query failing later.

GeoGenius ships `GeoGenius.PostgresTypes` for a host with no types module of its own:

```elixir
# config/config.exs
config :my_app, MyApp.Repo, types: GeoGenius.PostgresTypes
```

A host that already defines its own types module adds `Geo.PostGIS.Extension` to it
instead and points the Repo at that module:

```elixir
Postgrex.Types.define(
  MyApp.PostgrexTypes,
  [Geo.PostGIS.Extension] ++ Ecto.Adapters.Postgres.extensions()
)
```

`GeoGenius.PostgresTypes` passes no `:json` option, so Postgrex resolves the JSON library
from `config :postgrex, :json_library` (Jason by default). GeoGenius depends on Jason and
decodes its own manifest files with it, but it never passes that choice to Postgrex: `codes`
and `attributes` are the host's data, so a host on Elixir 1.18 or later that configured the
built-in `JSON` keeps it. Those two columns are jsonb and appear in every read's projection,
so `GeoGenius.Preflight` probes a jsonb decode as well as a geometry one; a Repo that cannot
do either fails at boot rather than on its first read.

Without one or the other, `GeoGenius.Preflight` raises `GeoGenius.PreflightError` naming
the Repo and the missing capability, rather than letting the host boot into a Repo that
will disconnect the first time a read decodes a `geography` column.

## The shared option keys

Every read takes `opts` last. These keys repeat across the reads that accept them, with
the same meaning and the same default everywhere:

| Option              | Meaning                                                        | Default           |
|---------------------|----------------------------------------------------------------|-------------------|
| `:collections`      | Restrict to these collection keys                              | no filter         |
| `:types`            | Restrict to these area type keys                               | no filter         |
| `:release_id`       | Read a specific release instead of the currently published one | published release |
| `:include_retired`  | Include retired areas                                          | `false`           |
| `:limit`            | Row cap on `areas_near/4` and `search_areas/2`; `nil` for none | `50`              |
| `:classifications`  | Restrict traversal to these `relation_type` values             | no filter         |
| `:max_depth`        | Depth on `children_of/2` and `ancestors_of/2`                  | `1`               |
| `:parent_area_key`  | Scope `areas_by_code/3` to one area's descendants              | no scope          |
| `:parent_max_depth` | How far `:parent_area_key` reaches                             | `1`               |
| `:strategies`       | Restrict or reorder `resolve/2`'s cascade                      | all, in order     |
| `:collection`       | Required by `release_at/2`; which collection to look up        | none, required    |

Two more keys are accepted everywhere but are not catalog options: `:repo` and `:prefix`
override the Repo and schema `GeoGenius.Context.new/1` would otherwise resolve from
`config :geo_genius, repo: ..., prefix: ...`. A `:release_id` accepts either shape a
caller can hold one in: the hyphenated string every read projects and `release_at/2`
returns, or the sixteen raw bytes Postgrex binds a `uuid` parameter to.

## The reads

### `areas_for_point/3`

Areas whose boundary covers a point. Longitude first.

```elixir
GeoGenius.areas_for_point(-97.75, 30.5)
```

### `areas_for_geometry/2`

Areas overlapping a polygon, with the measured overlap of each. Takes a `%Geo.Polygon{}`
or `%Geo.MultiPolygon{}` bound directly, no WKT round trip:

```elixir
polygon = %Geo.Polygon{
  coordinates: [[{-97.9, 30.4}, {-97.6, 30.4}, {-97.6, 30.6}, {-97.9, 30.6}, {-97.9, 30.4}]],
  srid: 4326
}

GeoGenius.areas_for_geometry(polygon)
```

### `areas_near/4`

Areas within a radius of a point, nearest first. Accepts `:limit`.

```elixir
GeoGenius.areas_near(-97.75, 30.5, 50_000.0, limit: 5)
```

### `areas_by_code/3`

Areas carrying an external code. Always returns a list: a code is unique only within a
parent, so more than one area can legitimately carry the same code outside any scope.
`:parent_area_key` and `:parent_max_depth` narrow the lookup to one area's descendants.

```elixir
GeoGenius.areas_by_code("fips", "48201")

GeoGenius.areas_by_code("fips", "48201", parent_area_key: "census:state:48")
```

### `search_areas/2`

Areas ranked by trigram name similarity. Accepts `:limit`.

```elixir
GeoGenius.search_areas("travis", limit: 10)
```

### `resolve/2`

Cascades containment, code, name, and proximity in order against one JSON-shaped input,
returning the first strategy that matched. `:strategies` constrains or reorders which are
attempted.

The input carries whatever the caller holds: `lon` and `lat` together, `code_type` and
`code_value` together, `name`, and `radius_m` for the proximity strategy. `parent_area_key`
is not a signal of its own; it scopes the code and name strategies to one area's
descendants, and containment and proximity ignore it because a coordinate already
identifies a place.

```elixir
GeoGenius.resolve(%{"code_type" => "fips", "code_value" => "48201"})

GeoGenius.resolve(%{
  "code_type" => "slug",
  "code_value" => "washington",
  "parent_area_key" => "census:state:42"
})
```

### `children_of/2`

Areas below this one. Defaults to direct children only; raise `:max_depth` for a deeper
descent (see [Traversal depth on dense graphs](installation.md#traversal-depth-on-dense-graphs)
before raising it on a densely mutually-related collection).

```elixir
GeoGenius.children_of("census:state:48", types: ["county"])
```

### `ancestors_of/2`

Areas that contain this one. Same options and depth behavior as `children_of/2`.

```elixir
GeoGenius.ancestors_of("census:county:48201")
```

### `related_areas/2`

Areas related to this one, one level out, in either direction. Accepts
`:classifications` to filter by `relation_type`.

```elixir
GeoGenius.related_areas("census:county:48201", classifications: ["overlaps"])
```

## Resolving many seeds in one call

`children_of/2`, `ancestors_of/2`, `related_areas/2`, and `areas_by_code/3` each answer for
one seed, so answering for a list costs one round trip per element. Each has a plural
sibling taking a list where the singular takes a string:

| Plural read                                | Seeds are   | Singular it answers for |
|--------------------------------------------|-------------|-------------------------|
| `children_of_many/2`                       | area keys   | `children_of/2`         |
| `ancestors_of_many/2`                      | area keys   | `ancestors_of/2`        |
| `related_areas_many/2`                     | area keys   | `related_areas/2`       |
| `areas_by_code_many/3`                     | code values | `areas_by_code/3`       |

Each takes the same options as the singular beside it and returns
`%GeoGenius.SeededMatch{}` rather than `%GeoGenius.AreaMatch{}`: a result mixes rows from
every seed, so each row carries the seed that produced it in `:seed_key` and the ordinary
`%AreaMatch{}` in `:match`.

```elixir
GeoGenius.children_of_many(county_keys, types: ["city"])
|> Enum.group_by(& &1.seed_key, & &1.match)
```

The plural result for `[a, b]` is exactly the singular results for `a` and then for `b`,
concatenated in the order the seeds were given. A seed that matched nothing contributes no
rows rather than one row of nils, so a caller needing every seed represented supplies its
own default. An empty list returns `[]` in one call; `nil` is an error, the way a `nil`
singular seed is, and so is a `nil` element inside the list -- a silently skipped element
would lose one seed out of thousands without a trace.

What this saves is round trips, not per-seed work: the SQL still runs the singular read
once per seed. Measured against 1,000 seeds over a 4,000-area release on a loopback
connection, 1,000 `children_of/2` calls took 445ms and one `children_of_many/2` call took
52ms; inside the database, with no round trips in either, the same work took 51ms and 37ms.
Essentially all of the difference is the protocol, which is also why the gap widens on a
database that is not on localhost.

Neither shape lets the planner push a predicate into the read -- these are `SETOF` plpgsql
functions. A caller joining catalog areas against its own tables, or aggregating over them,
wants [`GeoGenius.Query`](#geogeniusquery) instead of either.

### `release_at/2`

The release a collection had published as of a moment, or `nil` if it had published
nothing yet. Requires `:collection`. Reads take a `:release_id`, not a timestamp, so this
is how a caller holding a timestamp gets one:

```elixir
release_id = GeoGenius.release_at(~U[2026-01-15 00:00:00Z], collection: "us_counties")
GeoGenius.areas_for_point(-97.75, 30.5, release_id: release_id)
```

The hyphenated string `release_at/2` returns is exactly what every other read's
`:release_id` option expects back.

## What `%GeoGenius.AreaMatch{}` carries

Every read returns the same struct. Which fields beyond the identity ones carry a value
depends on how the row was found:

| Field                                                           | Populated by                                                  |
|-----------------------------------------------------------------|---------------------------------------------------------------|
| `collection_key`, `release_id`, `area_key`                      | every read                                                    |
| `authority`, `area_type`, `type_rank`, `name`                   | every read                                                    |
| `codes`, `centroid`, `attributes`, `match_method`               | every read                                                    |
| `distance_m`                                                    | `areas_near/4` only                                           |
| `intersection_area_m2`, `coverage_of_input`, `coverage_of_area` | `areas_for_geometry/2` only                                   |
| `score`                                                         | `search_areas/2`, and `resolve/2` when the name strategy wins |

`codes` maps each code type to a JSON array of the values an area holds under that type:
`%{"postal" => ["30309", "30310"]}`. An area can legitimately carry more than one value
of one type, so reading `codes["postal"]` always yields a list, even when it holds one
element.

`attributes` is the release's own jsonb column, projected by every read and by the
`release_areas` view a host joins against. GeoGenius ships no index on it, and the keys
inside it are the vendor's, not the library's - see
[Indexing your own attribute keys](sql_api.md#indexing-your-own-attribute-keys) for the two
index shapes that serve it, which one serves which predicate, and what the library
guarantees about reaching partitions created by later imports.

`coverage_of_input` and `coverage_of_area` are percentages, `0` to `100` - a polygon
argument wholly inside a matched area reads `coverage_of_input: 100.0`. They are not the
same scale as `relation.parent_coverage` and `relation.child_coverage`, reached through
`published_area_relations` or the traversal reads, which are `0`-to-`1` ratios and never
appear on `%AreaMatch{}`. Reading `coverage_of_area` as a fraction, or `parent_coverage`
as a percentage, is silently wrong rather than out of range - both are valid floats on
the wrong scale.

## `GeoGenius.Published`

Read-only Ecto schemas over the catalog's read views, plus composable query functions that
return `Ecto.Query.t()`. This is the read path for joins, aggregates, set-keyed reads, and
anything that needs a column the `SETOF` functions do not project.

Two things separate it from `GeoGenius.Query`. A plpgsql `SETOF` function is an optimizer
barrier -- PostgreSQL cannot push a predicate, a join qualifier, or a `LIMIT` inside one,
so the whole set materialises before the host's own `WHERE` runs -- and the four
function-backed queries select five of `area_match`'s sixteen columns. A view is an
ordinary relation the planner optimises, and these schemas carry every column the view
has, `release_id` included.

Each schema reads one of a pair of views: a `published_*` view by default, and its
release-scoped base when a `:release_id` is given. A pair projects identical columns in
identical order, so one schema reads either source.

| Schema                            | Default view               | With `:release_id`   |
|-----------------------------------|----------------------------|----------------------|
| `GeoGenius.Published.Area`        | `published_areas`          | `release_areas`      |
| `GeoGenius.Published.AreaCode`    | `published_area_codes`     | `release_area_codes` |
| `GeoGenius.Published.AreaName`    | `published_area_names`     | `release_area_names` |
| `GeoGenius.Published.AreaRelation`| `published_area_relations` | `release_relations`  |

`areas/1`, `children_of/2`, `ancestors_of/2`, `areas_by_code/3`, `codes/1`, `names/1` and
`relations/1` each return a query selecting whole structs, and each names its sources with
an Ecto binding -- `:area`, `:relation`, `:code`, `:name` -- so composing further never
means counting positions.

Counting host records per city of a state, including cities with none:

```elixir
import Ecto.Query
alias GeoGenius.Published

from([area: area] in Published.children_of("us:state:pa", types: ["city"]),
  left_join: record in MyApp.Record,
  on: record.area_key == area.area_key,
  group_by: area.area_key,
  order_by: area.area_key,
  select: {area.area_key, count(record.id)}
)
|> MyApp.Repo.all()
```

The library's own design has a host keep vendor columns in a projection table keyed
`(release_id, area_key)`. Joining one needs `release_id` on both sides, which no
function-backed read projects:

```elixir
from([area: area] in Published.areas(collections: ["us_counties"]),
  join: projection in MyApp.CountyProjection,
  on: projection.area_key == area.area_key and projection.release_id == area.release_id,
  select: {area.name, projection.median_price}
)
```

Where the function-backed API takes one `area_key`, these take a list, so resolving the
parents of three thousand areas is one query rather than three thousand. A single binary
is accepted as a one-element set. `children_of/2` and `ancestors_of/2` return one row per
relation edge, so an area reachable from two of the parents given appears twice; the
`:relation` binding says which parent each row came from:

```elixir
Published.ancestors_of(area_keys, types: ["state"])
|> select([area: area, relation: relation], {relation.child_area_key, area.area_key})
|> MyApp.Repo.all()
```

With no `:release_id` these read the currently published release of every collection,
through the publication pointer each `published_*` view carries. Giving `:release_id`
swaps every source in the query onto its release-scoped base and reads that release
whether or not its collection publishes it -- what a host verifying a release, or filling
a projection ahead of go-live, needs:

```elixir
Published.areas(release_id: staged_release_id, types: ["city"]) |> MyApp.Repo.all()
```

The swap is all-or-nothing across the sources in one query, and every join between two
release-carrying sources equates their `release_id` as well as the key it joins on. Both
together are what keep a read on one release: joining an edge to an area on `area_key`
alone, or reading one source from a base and another from a published view, would pair a
row of one release with a row of another.

Retired areas are excluded unless `include_retired: true`, on the published and
unpublished paths alike, matching every `SETOF` read.

`codes/1`, `names/1` and `relations/1` cannot honour that and do not take the option:
their views carry no `retired_at`, because retirement is a property of an area rather than
of a code, a name, or an edge between two areas. So all three return rows for retired
areas as well -- moving from `children_of/2` to `relations/1` to reach an edge's
measurement columns silently widens the result. Join `areas/1` back on `area_key` and
`release_id` to narrow it:

```elixir
from([relation: relation] in Published.relations(parent_area_keys: keys),
  join: area in subquery(Published.areas()),
  on: area.area_key == relation.child_area_key and area.release_id == relation.release_id,
  select: {relation.child_area_key, relation.parent_coverage}
)
```

What has no view-backed form, and stays with `GeoGenius` or `GeoGenius.Query`: spatial
resolution, `resolve/2`, trigram name search, and a walk deeper than one relation hop.

`GeoGenius.Published`'s schema prefix is fixed at compile time for the same reason
`GeoGenius.Query`'s is, described below. Read it back with `GeoGenius.Published.prefix/0`
when building SQL of your own against the same catalog.

## `GeoGenius.Query`

`GeoGenius`'s struct-returning reads answer one question per call. `GeoGenius.Query`
returns `Ecto.Query.t()` instead, so a host can compose one further before running it.

It covers four of the ten reads: `children_of/2`, `ancestors_of/2`, `areas_by_code/3`,
and `search_areas/2`, each selecting `area_key`, `area_type`, `name`, `centroid`, and
`attributes` (plus `score` on `search_areas/2`). The option keys match the struct-returning
API's for the same read.

These read through the `SETOF` functions, so a join or an aggregate over one pays the
optimizer barrier and cannot see `release_id` or the other ten columns the select drops.
Use `GeoGenius.Published` above for that. What these serve is the traversal and search a
view has no form for: `:max_depth` walks and `search_areas/2`'s trigram ranking. An
unpublished release is served either way -- `GeoGenius.Published`'s `:release_id` reaches
one too.

```elixir
import Ecto.Query
alias GeoGenius.Query

Query.children_of("us:state:pa", types: ["city"], max_depth: 3)
|> MyApp.Repo.all()
```

`GeoGenius.Query`'s schema prefix is fixed at compile time, not per call, and that is a
hard limitation rather than an oversight: Ecto's `fragment/1` requires its SQL to be a
literal, so the prefix is read once via `Application.compile_env/3` when `GeoGenius.Query`
compiles. Set `:prefix` in `config/config.exs` and never in `config/runtime.exs`: a
`:prefix` that first appears at runtime differs from what the compile-time read recorded
even when the value is the identical default string, and Elixir refuses to boot. Passing
`:prefix` in `opts` raises `ArgumentError` naming the struct API as the alternative, rather
than being silently ignored or reading the wrong schema:

```elixir
Query.children_of("us:state:pa", prefix: "other_geo")
# ** (ArgumentError) GeoGenius.Query does not support a per-call :prefix option ...
```

A host serving more than one catalog from one VM, and needing a runtime `:prefix` per
call, uses `GeoGenius`'s struct-returning functions instead - they resolve `:prefix`
through `GeoGenius.Context` on every call, not at compile time.

## Telemetry

Every `GeoGenius` read emits one `:telemetry` span. `GeoGenius.Query`'s four functions
emit none and cannot: they return a query for the host to run on its own Repo, so
GeoGenius never sees the call. A host that wants those instrumented attaches to Ecto's own
`[:my_app, :repo, :query]` events.

- `[:geo_genius, :read, :start]` with `%{system_time: integer()}`
- `[:geo_genius, :read, :stop]` with `%{duration: integer()}`
- `[:geo_genius, :read, :exception]` with `%{duration: integer()}`

Metadata carries `:function` (the SQL function called, for example `"areas_for_point"`)
and `:prefix` (the schema it ran in). The `:stop` event also carries `:result_count`, so
a host can tell a read that matched nothing from a read that matched thousands without
instrumenting its own callers.
