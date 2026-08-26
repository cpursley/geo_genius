# Reading the catalog

`GeoGenius` wraps the SQL functions described in [`sql_api.md`](sql_api.md) in typed
Elixir functions: ten reads that return `[%GeoGenius.AreaMatch{}]` (or, for
`release_at/2`, a bare release id), plus `GeoGenius.Query` for the one case a
struct-returning call cannot serve, joining catalog areas against a host's own tables in
a single round trip. This guide covers both.

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
| `:limit`            | Row cap on `areas_near/4` and `search_areas/2`                 | `50`              |
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
`release_areas` view a host joins against. GeoGenius ships no index on it, because no shipped
function filters it - every read carries it through as a projection. A host that filters on it,
with `attributes @> '{"lsad": "county"}'` or a jsonpath, should add its own GIN index:

```sql
CREATE INDEX my_app_release_area_attributes_idx
  ON geo_genius.release_area USING gin (data jsonb_path_ops);
```

The column is named `data` on the table and surfaces as `attributes` on the view and the
struct. Index it at the prefix the host installed GeoGenius at.

`coverage_of_input` and `coverage_of_area` are percentages, `0` to `100` - a polygon
argument wholly inside a matched area reads `coverage_of_input: 100.0`. They are not the
same scale as `relation.parent_coverage` and `relation.child_coverage`, reached through
`published_area_relations` or the traversal reads, which are `0`-to-`1` ratios and never
appear on `%AreaMatch{}`. Reading `coverage_of_area` as a fraction, or `parent_coverage`
as a percentage, is silently wrong rather than out of range - both are valid floats on
the wrong scale.

## `GeoGenius.Query`

`GeoGenius`'s struct-returning reads answer one question per call. `GeoGenius.Query`
returns `Ecto.Query.t()` instead, so a host can join catalog areas against its own tables
and aggregate in a single round trip - counting host records per area, for example,
rather than issuing one catalog read per record.

It covers four of the ten reads: `children_of/2`, `ancestors_of/2`, `areas_by_code/3`,
and `search_areas/2`, each selecting `area_key`, `area_type`, `name`, `centroid`, and
`attributes` (plus `score` on `search_areas/2`). The option keys match the struct-returning
API's for the same read.

Joining catalog areas from `children_of/2` against a host's own record table, counting
records per area including areas with none:

```elixir
import Ecto.Query
alias GeoGenius.Query

from(area in subquery(Query.children_of("us:state:pa", types: ["city"])),
  left_join: record in MyApp.Record,
  on: record.area_key == area.area_key,
  group_by: area.area_key,
  order_by: area.area_key,
  select: {area.area_key, count(record.id)}
)
|> MyApp.Repo.all()
```

The subquery runs GeoGenius's SQL function, the outer query is ordinary Ecto over the
host's own schema, and the whole thing is one round trip to Postgres.

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
