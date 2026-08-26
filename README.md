# GeoGenius

[![Hex.pm](https://img.shields.io/hexpm/v/geo_genius.svg)](https://hex.pm/packages/geo_genius)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/geo_genius)
[![License](https://img.shields.io/hexpm/l/geo_genius.svg)](https://github.com/agoodway/geo_genius/blob/main/LICENSE)

> A versioned catalog of named geographic areas for Elixir and PostgreSQL/PostGIS.

GeoGenius owns the geographic reference domain: collections of named areas (states,
counties, ZIP codes, school districts, or any other hierarchy you define), versioned
releases of that data, atomic publication and rollback, and the read-side primitives —
spatial containment, proximity, code lookup, name search, and hierarchy traversal — for
resolving one against the catalog. It also ingests that data: a reviewed manifest, an
artifact cache, format providers, and a resumable import pipeline that ends in a
verification gate. Your application owns when an import runs, any projection it builds on
top of the catalog, and presentation.

GeoGenius is not a geocoder. It resolves points, polygons, codes, and names against areas
it already knows about; it does not parse or normalize free-form street addresses.

## What It Does

- Catalog identity: collections, authorities, ranked area types, and areas addressed by a
  stable `area_key`, with names, external codes, retirement, and successor tracking.
- Versioned releases: sources, source releases, checksummed artifacts, and a verification
  gate a release must pass before it can publish.
- Optional geometry: an area joins a release through a `release_area` membership row;
  attaching a `boundary` is optional, and a collection can require it with
  `requires_geometry`.
- Relations derived from geometry (`rebuild_relations`) or asserted from source data
  (`put_relation`), traversed identically either way.
- Atomic publication and rollback through a single pointer swap, with a durable,
  sequenced publication event log.
- Spatial and non-spatial resolution: containment, overlap-with-coverage, proximity, code
  lookup, ranked name search, hierarchy traversal, and a `resolve` cascade over one input.
- A durable import run state machine with heartbeat leases and stale-run reclaim.
- Ingestion: manifests describing a release, an artifact cache with checksum verification,
  GeoJSON/CSV/shapefile providers, pluggable cache, downloader, command, notifier, and
  runner adapters, and mix tasks for importing, publishing, and rolling back.

## Why GeoGenius?

- **Prefix-installed, host-owned schema** — every object installs into whatever
  PostgreSQL schema the host names; the package's own SQL never hard-codes a schema, so
  one database can host more than one GeoGenius-backed catalog.
- **Geometry is optional, not assumed** — a reference hierarchy with no polygons at all
  (postal codes imported with no boundary data, for instance) is a first-class citizen,
  not a degenerate case. Boundaries attach when a source provides them.
- **Publish is one row, not a rebuild** — a release is verified once, then publication is
  a single-row pointer swap inside a transaction-level advisory lock. Readers never see a
  half-published state.
- **No invented notification protocol** — publication events land in a durable, sequenced
  table instead of a library-chosen `pg_notify` channel; see
  [Reacting to publication](guides/installation.md#reacting-to-publication) for why, and
  the host-owned trigger recipe if a live signal is wanted.
- **Postgres is the source of truth** — the schema installs through
  [EctoEvolver](https://github.com/agoodway/ecto_evolver) raw SQL migrations, wrapped in
  a host-owned, version-pinned Ecto migration the host commits and runs itself.

## Architecture

GeoGenius owns exactly one PostgreSQL schema, at whatever prefix the host selects, through
EctoEvolver raw SQL migrations. Every table, view, function, and type reference in the
shipped SQL is a `$SCHEMA$` placeholder substituted with the configured prefix at migration
time — the package never hard-codes a schema name, and the same SQL installs identically at
any prefix.

Current tables:

- `collection`, `authority`, `area_type`, `area`, `area_name`, `area_code`
- `source`, `source_release`, `artifact`, `release`, `release_source`
- `publication`, `publication_event`
- `boundary`, `boundary_part`, `relation`, `release_area` (partitioned by release)
- `import_run`, `import_run_lease`

Current views: `release_areas`, `published_areas`, `published_area_codes`,
`published_area_names`, `published_area_relations`, `published_boundaries`,
`import_run_status`, `release_artifacts`.

Every catalog operation is a SQL function or view, and the Elixir API is a layer over
them rather than a second implementation. `GeoGenius` exposes the read functions
(`areas_for_point/3` and its siblings), the ingestion API (`import/1`, `status/2`,
`await/3`, `publish/2`, `rollback/2`, `published_release/2`), and `GeoGenius.verify/2`
for a startup prerequisite check; `GeoGenius.Query` wraps the views for hosts composing
their own Ecto queries; the mix tasks drive the same calls from a deploy. A host that
prefers raw SQL can still call every function and view below through its own Repo.

## Prerequisites

- Elixir 1.17+
- PostgreSQL with the `postgis` and `pg_trgm` extensions, and an Ecto Repo (Ecto SQL +
  Postgrex)

## Installation

Add `geo_genius` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:geo_genius, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Setup

Configure the host repo and PostgreSQL prefix:

```elixir
# config/config.exs
config :my_app, ecto_repos: [MyApp.Repo]
config :geo_genius, repo: MyApp.Repo, prefix: "geo_genius"
```

`:prefix` belongs in `config/config.exs` and must never move to `config/runtime.exs`:
`GeoGenius.Query` reads it at compile time, and Elixir refuses to boot when a runtime value
differs from what that read recorded, including when the runtime value is the identical
default string. `:repo` may live wherever the host prefers. See
[`guides/installation.md`](guides/installation.md).

PostGIS and `pg_trgm` must already exist in the target database before migrating — install
them yourself, as a privileged role, or generate the setup migration with
`--with-extensions` to have it issue the `CREATE EXTENSION` statements for you (only works
if the role running the migration has that privilege):

```bash
mix geo_genius.setup --repo MyApp.Repo --prefix geo_genius
mix ecto.migrate
mix geo_genius.check_schema --repo MyApp.Repo --prefix geo_genius
```

`geo_genius.setup` delegates to the host's own `ecto.gen.migration`. It generates a
host-owned Ecto migration wrapper pinned to the installed schema version and never runs a
migration itself. Commit the wrapper so a later package upgrade cannot silently change an
already-deployed migration. Later upgrades use
`mix geo_genius.gen.migration --from N --to N+1`. See
[`guides/installation.md`](guides/installation.md) for prefixes, the pinned wrapper,
upgrades, the destructive down migration, and uninstalling.

> **Startup verification.** Place `{GeoGenius.Preflight, repo: MyApp.Repo, prefix: "geo_genius"}`
> in the supervision tree right after the Repo to fail host startup, with a clear message,
> when the required extensions or the expected schema version are missing — rather than
> deferring that failure to the first query that touches GeoGenius.

## Usage

Every operation is a SQL function or view. `GeoGenius` calls them for a host that wants
typed results, `GeoGenius.Query` returns composable Ecto queries over the views, and a
host that prefers raw SQL calls the same functions through its own Repo.

### Importing a collection

Write a manifest naming the collection, the release, the provider that parses it, and
every file it is built from, at `<manifest_dir>/<collection>/<release>.json`:

```json
{
  "collection": "us_counties",
  "collection_name": "US Counties",
  "release": "2026",
  "provider": "geojson",
  "requires_geometry": true,
  "authority": { "key": "census", "name": "US Census Bureau" },
  "area_types": [{ "key": "county", "rank": 200 }],
  "sources": [
    {
      "source_key": "census:counties",
      "provider": "geojson",
      "license": "public-domain",
      "release_key": "2026",
      "artifacts": [
        {
          "logical_name": "counties.geojson",
          "url": "https://example.test/counties.geojson",
          "operator_supplied": false,
          "format": "geojson",
          "required": true,
          "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
          "bytes": 4096
        }
      ]
    }
  ],
  "options": { "code_property": "GEOID", "name_property": "NAME", "area_type": "county" }
}
```

Then import it, watch it, and publish it:

```bash
mix geo_genius.import --collection us_counties --release 2026
mix geo_genius.status --collection us_counties
mix geo_genius.publish --collection us_counties --release 2026
```

An import produces a verified candidate; publishing is a separate act, so nothing hosts
read changes until you make that call. See
[`guides/ingestion.md`](guides/ingestion.md) for the manifest in full, the provider
contract, the adapters, and the runner backends.

### Load and publish a catalog

A metadata-only collection needs no boundary data:

```elixir
{:ok, _} =
  MyApp.Repo.query(
    "SELECT geo_genius.upsert_collection($1, $2, $3, $4)",
    ["us_counties", "US Counties", "County reference hierarchy", false]
  )

{:ok, _} =
  MyApp.Repo.query("SELECT geo_genius.upsert_authority($1, $2, $3)",
    ["us_counties", "census", "US Census Bureau"])

{:ok, _} =
  MyApp.Repo.query("SELECT geo_genius.upsert_area_type($1, $2, $3)",
    ["us_counties", "county", 1])

{:ok, _} =
  MyApp.Repo.query("SELECT geo_genius.upsert_area($1, $2, $3, $4)",
    ["us_counties", "census", "county", "48201"])

{:ok, _} =
  MyApp.Repo.query("SELECT geo_genius.put_area_code($1, $2, $3)",
    ["census:county:48201", "fips", "48201"])

{:ok, %{rows: [[release_id]]}} =
  MyApp.Repo.query(
    "SELECT geo_genius.open_release($1, $2, $3, $4)",
    ["us_counties", "2026-01", %{}, nil]
  )

# A source records who the data came from and under what license; source and license
# are required. A source_release is one checksummed pull from that source. A release
# must declare every source_release it draws from by calling attach_source_release
# before it can publish - verify_release fails a release with none declared, and
# put_boundary rejects a source_release_id the release has not declared here.
{:ok, _} =
  MyApp.Repo.query(
    "SELECT geo_genius.upsert_source($1, $2, $3, $4)",
    ["us_counties", "census_tiger", "US Census Bureau", "public-domain"]
  )

{:ok, %{rows: [[source_release_id]]}} =
  MyApp.Repo.query(
    "SELECT geo_genius.upsert_source_release($1, $2, $3, $4, $5)",
    ["us_counties", "census_tiger", "2026-01", nil, %{}]
  )

{:ok, _} =
  MyApp.Repo.query(
    "SELECT geo_genius.attach_source_release($1, $2)",
    [release_id, source_release_id]
  )

{:ok, _} =
  MyApp.Repo.query(
    "SELECT geo_genius.put_area_in_release($1, $2, NULL, $3)",
    [release_id, "census:county:48201", %{}]
  )

{:ok, %{rows: [[verification]]}} =
  MyApp.Repo.query("SELECT geo_genius.verify_release($1)", [release_id])
# %{"ok" => true, "failures" => [], "area_count" => 1, "boundary_count" => 0}

{:ok, _} = MyApp.Repo.query("SELECT geo_genius.publish_release($1)", [release_id])
```

A published release is immutable: once `publish_release` sets its status to `completed`,
`put_area_in_release`, `put_boundary`, `put_relation`, and `rebuild_relations` all refuse to
write to it. To change what hosts see, build a new release (a new `release_key` in the same
collection) and publish that one; see [`guides/sql_api.md`](guides/sql_api.md) for the exact
error raised and [`guides/installation.md`](guides/installation.md) for the release retention
that follows.

Attaching a real centroid or boundary binds a `Geo` struct directly as the query
parameter, not WKT/EWKT text: GeoGenius requires the host Repo to be configured with a
Postgrex types module that registers `Geo.PostGIS.Extension` before it will even boot
(`GeoGenius.Preflight` fails startup, with a remedy, otherwise), and that same codec
covers every `Repo.query/2` call, not only reads. See
[`guides/reading.md`](guides/reading.md#configuring-the-repo-to-decode-geometry) for the
Repo configuration and [`guides/installation.md`](guides/installation.md) for where it
sits alongside the extension requirements.

```elixir
{:ok, _} =
  MyApp.Repo.query(
    "SELECT geo_genius.put_area_in_release($1, $2, $3, $4)",
    [
      release_id,
      "census:county:48201",
      %Geo.Point{coordinates: {-97.75, 30.5}, srid: 4326},
      %{}
    ]
  )
```

### Read through resolution

Once published, hosts read through the `published_*` views (they resolve through the
publication pointer, so no view takes a release argument) or through the resolution
functions:

```elixir
{:ok, %{rows: rows}} =
  MyApp.Repo.query(
    "SELECT area_key, match_method FROM geo_genius.resolve($1)",
    [%{code_type: "fips", code_value: "48201"}]
  )
# [["census:county:48201", "code"]]
```

`resolve/6` tries containment, code, name, and proximity strategies in order against one
JSON input and returns the first strategy's matches; see
[`guides/sql_api.md`](guides/sql_api.md) for what each input key selects.

## Reading the catalog

`GeoGenius`'s Elixir read layer wraps the SQL reads above in typed structs, so a host
resolves an area without hand-building SQL or mapping `Postgrex.Result` rows itself:

```elixir
GeoGenius.areas_for_point(-97.75, 30.5)
# [%GeoGenius.AreaMatch{area_key: "census:county:48201", match_method: "containment", ...}]

GeoGenius.areas_by_code("fips", "48201")
# [%GeoGenius.AreaMatch{area_key: "census:county:48201", match_method: "code", ...}]
```

Both calls resolve `:repo` and `:prefix` from `config :geo_genius, repo: ..., prefix:
...` unless a call overrides them. See [`guides/reading.md`](guides/reading.md) for every
read, the shared option keys, what `%GeoGenius.AreaMatch{}` carries, and
`GeoGenius.Query` for composing a catalog read with a host's own tables in one round
trip.

Loading data has an Elixir API of its own: `GeoGenius.import/1` runs a manifest through
the ingestion pipeline, and `GeoGenius.publish/2` and `GeoGenius.rollback/2` move the
publication pointer. See [`guides/ingestion.md`](guides/ingestion.md). Calling the SQL
write functions below directly remains supported for a host loading data some other way.

## Public API

Every operation is a SQL function or view called through the host's own Repo. A
representative set, grouped by what they do — the complete reference, every function
and its full parameter list, lives in [`guides/sql_api.md`](guides/sql_api.md):

```sql
-- Resolution
SELECT * FROM geo_genius.areas_for_point(lon, lat);
SELECT * FROM geo_genius.areas_by_code(code_type, code_value);
SELECT * FROM geo_genius.search_areas(query);
SELECT * FROM geo_genius.resolve(input);

-- Traversal
SELECT * FROM geo_genius.children_of(parent_area_key);
SELECT * FROM geo_genius.ancestors_of(child_area_key);

-- Write
SELECT geo_genius.upsert_collection(key, name, description, requires_geometry);
SELECT geo_genius.upsert_area(collection_key, authority_key, area_type_key, code);
SELECT geo_genius.put_area_in_release(release_id, area_key, centroid, data);
SELECT geo_genius.put_boundary(release_id, area_key, source_release_id, geom);

-- Lifecycle
SELECT geo_genius.verify_release(release_id);
SELECT geo_genius.publish_release(release_id);
SELECT geo_genius.rollback_publication(collection_key);

-- Import
SELECT geo_genius.begin_or_resume_import(release_id, owner, runner_backend);
SELECT geo_genius.advance_import(run_id, next_status, metrics_patch);
```

Reads that only need the currently published release, with no resolution logic, join the
`published_*` views instead — they resolve through the publication pointer, so no view
takes a release argument:

| View                                               | Contains                                                                                  |
|----------------------------------------------------|-------------------------------------------------------------------------------------------|
| `release_areas`                                    | Every `release_area` membership row, release-scoped, published or not                     |
| `published_areas`                                  | `release_areas` narrowed to the currently published release; includes retired areas       |
| `published_area_codes` / `published_area_names`    | Codes and names for published areas                                                       |
| `published_area_relations`                         | Relations among published areas                                                           |
| `published_boundaries`                             | Boundary geometry for published areas                                                     |

See [`guides/installation.md`](guides/installation.md) for what `NULL` measurement columns
on a `relation` row mean, why `max_depth` costs what it costs on a densely mutually-related
graph, why `published_areas` does not hide retired areas, and how to react to a publication
without polling.

## Mix Tasks

| Task                             | Description                                                                  |
|----------------------------------|------------------------------------------------------------------------------|
| `mix geo_genius.setup`           | Generate the initial pinned host migration                                   |
| `mix geo_genius.gen.migration`   | Generate one adjacent version-upgrade wrapper                                |
| `mix geo_genius.check_schema`    | Verify the installed schema version (CI/deploy gate)                         |
| `mix geo_genius.uninstall`       | Print the `DROP SCHEMA` statement for a prefix; pass `--yes` to execute it   |
| `mix geo_genius.import`          | Register a release from its manifest and enqueue its import                  |
| `mix geo_genius.publish`         | Publish a verified release                                                   |
| `mix geo_genius.rollback`        | Roll a collection back to its previous release; pass `--yes` to execute it   |
| `mix geo_genius.status`          | Report import runs and what a collection currently publishes                 |
| `mix geo_genius.sweep_staging`   | Drop leaked per-run staging tables; pass `--yes` to execute it               |

## Guides

- [`guides/installation.md`](guides/installation.md) — prefixes, the pinned wrapper,
  upgrades, the destructive down migration, uninstalling, retired areas, measured versus
  asserted relations, traversal depth on dense graphs, and reacting to publication
- [`guides/sql_api.md`](guides/sql_api.md) — every SQL function, grouped and with its
  full parameter list
- [`guides/reading.md`](guides/reading.md) - the Elixir read layer: every read, shared
  options, what `%AreaMatch{}` carries, and `GeoGenius.Query`
- [`guides/ingestion.md`](guides/ingestion.md) — the manifest, providers, adapters,
  runners, the import phases, publication, and the operational mix tasks
- [CHANGELOG](CHANGELOG.md) — releases
- [`docs/design/geo-genius-design.md`](docs/design/geo-genius-design.md) — the design
  spec the three plans were built from

## Testing

```bash
mix test
mix check   # format check, compile --warnings-as-errors, credo --strict, doctor, test
```

Integration tests run real install and uninstall cycles against Postgres, at the default
prefix, at a custom one, and at a prefix that requires quoting. They are excluded from the
default run:

```bash
mix test --include integration
```

The migration wrapper the Mix tasks generate is covered by the default run, which needs no
database.

The SQL layer itself is covered by a pgTAP suite, run against the same database:

```bash
./test/pgtap/run.sh
```

Quality gates used by this repo:

```bash
mix quality   # compile --warnings-as-errors, deps.unlock --unused, format check, sobelow, ex_dna, doctor, credo --strict
```

## License

MIT
