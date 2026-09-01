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
artifact cache, format providers, and an explicitly retryable import pipeline that ends in a
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
- A durable import run state machine with heartbeat leases, explicit failed-attempt retry,
  and one executor per attempt.
- Ingestion: manifests describing a release, an artifact cache with checksum verification,
  GeoJSON/CSV/shapefile/SimpleMaps providers, pluggable cache, downloader, command,
  notifier, and runner adapters, and mix tasks for importing, publishing, and rolling
  back.

## Why GeoGenius?

- **Prefix-installed, host-owned schema** — every object installs into whatever
  PostgreSQL schema the host names; the package's own SQL never hard-codes a schema, so
  one database can host more than one GeoGenius-backed catalog.
- **Geometry is optional, not assumed** — a reference hierarchy with no polygons at all
  (postal codes imported with no boundary data, for instance) is a first-class citizen,
  not a degenerate case. Boundaries attach when a source provides them.
- **Publish is one row, not a rebuild** — readers flip on one `publication` row under a
  transaction advisory lock. `complete_import` finishes a verified candidate without that
  flip. `publish_import` completes the publishing attempt, drops the lease, re-verifies, and
  swaps the pointer in one transaction. Readers never see a half-published state.
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
- `import_run`, `import_run_lease`, `import_run_artifact`

Current views: `release_areas`, `release_area_codes`, `release_area_names`,
`release_relations`, `published_areas`, `published_area_codes`,
`published_area_names`, `published_area_relations`, `published_boundaries`,
`import_run_status`, `release_artifacts`, `run_artifacts`.

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
  Postgrex `>= 0.20.0 and < 0.23.0`)
- GDAL's `ogr2ogr` binary when using the shapefile provider; GeoJSON and CSV ingestion do
  not require it

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
SQL-first rendering, the pre-production return-and-reinstall policy, the destructive down
migration, and uninstalling. GeoGenius never installs or changes a host schema automatically.

> **Startup verification.** Place `{GeoGenius.Preflight, repo: MyApp.Repo, prefix: "geo_genius"}`
> in the supervision tree right after the Repo to fail host startup, with a clear message,
> when the required extensions, schema version, or content-addressed schema contract do not
> match — rather than deferring that failure to the first query that touches GeoGenius. An older
> pre-production install must be returned and reinstalled from the current package; see
> [`guides/installation.md`](guides/installation.md#returning-a-pre-production-install).

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
  "authorities": [{ "key": "census", "name": "US Census Bureau" }],
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

### Drive an import through SQL

`prepare_import` registers the exact manifest and claims one attempt. Every ingestion mutation
then takes that `run_id`, not the release id; the run fence prevents a failed or superseded
attempt from changing the candidate. The high-level `GeoGenius.import/1` pipeline performs this
sequence for you. A direct loader uses the same lifecycle:

```elixir
manifest_map = GeoGenius.Manifest.to_map(manifest)

{:ok, %{rows: [["enqueue", "registered", release_id, run_id, 1]]}} =
  MyApp.Repo.query(
    "SELECT * FROM geo_genius.prepare_import($1, $2)",
    [manifest_map, %{owner: "catalog-loader", runner_backend: "direct"}]
  )

executor_id = Ecto.UUID.generate()

{:ok, %{rows: [["claimed"]]}} =
  MyApp.Repo.query(
    "SELECT geo_genius.claim_import_execution($1, $2)",
    [run_id, executor_id]
  )

{:ok, _} =
  MyApp.Repo.query(
    "SELECT geo_genius.advance_import($1, $2, 'downloading', '{}'::jsonb)",
    [run_id, executor_id]
  )

{:ok, %{rows: [[artifact_id]]}} =
  MyApp.Repo.query(
    "SELECT artifact_id FROM geo_genius.run_artifacts WHERE run_id = $1",
    [run_id]
  )

[source] = manifest.sources
[artifact] = source.artifacts

{:ok, _} =
  MyApp.Repo.query(
    "SELECT geo_genius.record_artifact_observation($1, $2, $3, $4, $5)",
    [run_id, executor_id, artifact_id, artifact.sha256, artifact.bytes]
  )

{:ok, _} =
  MyApp.Repo.query(
    "SELECT geo_genius.advance_import($1, $2, 'validating', '{}'::jsonb)",
    [run_id, executor_id]
  )

{:ok, _} =
  MyApp.Repo.query(
    "SELECT geo_genius.advance_import($1, $2, 'staging', '{}'::jsonb)",
    [run_id, executor_id]
  )

{:ok, _} =
  MyApp.Repo.query(
    "SELECT geo_genius.advance_import($1, $2, 'normalizing', '{}'::jsonb)",
    [run_id, executor_id]
  )

{:ok, _} =
  MyApp.Repo.query(
    "SELECT geo_genius.upsert_area_many($1, $2, $3, $4, $5)",
    [run_id, executor_id, ["census"], ["county"], ["48201"]]
  )

{:ok, _} =
  MyApp.Repo.query(
    "SELECT geo_genius.put_area_in_release($1, $2, $3, NULL, $4)",
    [run_id, executor_id, "census:county:48201", %{}]
  )

{:ok, _} =
  MyApp.Repo.query(
    "SELECT geo_genius.put_area_code($1, $2, $3, $4, $5)",
    [run_id, executor_id, "census:county:48201", "fips", "48201"]
  )

{:ok, _} =
  MyApp.Repo.query(
    "SELECT geo_genius.advance_import($1, $2, 'relating', '{}'::jsonb)",
    [run_id, executor_id]
  )

{:ok, _} =
  MyApp.Repo.query(
    "SELECT geo_genius.advance_import($1, $2, 'indexing', '{}'::jsonb)",
    [run_id, executor_id]
  )

{:ok, _} =
  MyApp.Repo.query(
    "SELECT geo_genius.advance_import($1, $2, 'verifying', '{}'::jsonb)",
    [run_id, executor_id]
  )

{:ok, %{rows: [[verification]]}} =
  MyApp.Repo.query("SELECT geo_genius.verify_import($1, $2)", [run_id, executor_id])
# %{"ok" => true, "failures" => [], "area_count" => 1, "boundary_count" => 0}

{:ok, _} =
  MyApp.Repo.query(
    "SELECT geo_genius.advance_import($1, $2, 'publishing', '{}'::jsonb)",
    [run_id, executor_id]
  )

{:ok, _} = MyApp.Repo.query("SELECT geo_genius.publish_import($1, $2)", [run_id, executor_id])
```

Only the executor whose claim returned `claimed` runs the attempt. Another delivery receives
`occupied` and must not take over. An independently supervised guardian records failure when that
executor process dies while the Repo remains reachable. Whole-node loss, or shutdown after the Repo
has already stopped, cannot be recorded by a local guardian; a stale heartbeat is then diagnostic.
Fail the abandoned attempt with its latched `executor_id` from `import_run_status`, then call
`retry_failed` to create a new run with its own immutable manifest, artifact observations, and
failure evidence. A new executor cannot fail a live lease, and `import/1` will not replace it. `publish_import` removes the lease,
marks the run completed, verifies the release, and swaps publication in one transaction.
Calling `GeoGenius.import/1` again after a durable failure returns
`%GeoGenius.CandidateError{reason: :failed}` for an identical manifest (or
`:manifest_changed` for a different one); ordinary import never creates the replacement attempt.

`publish_release(release_id)` remains an operator API for a release with no active lease and no
incomplete latest import. It is not the ingestion completion path. A published release is
immutable; changing what readers see means importing a new release key and publishing that
candidate.

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
    "SELECT geo_genius.put_area_in_release($1, $2, $3, $4, $5)",
    [
      run_id,
      executor_id,
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
read, the shared option keys, what `%GeoGenius.AreaMatch{}` carries, the plural reads
that resolve a whole list in one call, and `GeoGenius.Query` for composing a catalog read
with a host's own tables in one round trip.

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

-- Set-keyed reads: one call per list, not one call per element
SELECT * FROM geo_genius.children_of_many(parent_area_keys);
SELECT * FROM geo_genius.areas_by_code_many(code_type, code_values);

-- Write
SELECT geo_genius.upsert_collection(key, name, description, requires_geometry);
SELECT geo_genius.upsert_area(collection_key, authority_key, area_type_key, code);
SELECT geo_genius.put_area_in_release(run_id, executor_id, area_key, centroid, data);
SELECT geo_genius.put_boundary(run_id, executor_id, area_key, source_release_id, geom);

-- Set writes: one call per batch, not one call per row. Each scalar write above
-- is its plural form called with one-element arrays.
SELECT geo_genius.upsert_area_many(run_id, executor_id, authority_keys, area_type_keys, codes);
SELECT geo_genius.put_area_in_release_many(run_id, executor_id, area_keys, centroids, data);
SELECT geo_genius.put_boundaries(
  run_id, executor_id, area_keys, source_release_ids, geometries, display_tiers, source_properties
);

-- Lifecycle
SELECT geo_genius.verify_release(release_id);
SELECT geo_genius.publish_release(release_id);
SELECT geo_genius.rollback_publication(collection_key);

-- Import
SELECT * FROM geo_genius.prepare_import(manifest, claim);
SELECT * FROM geo_genius.retry_failed(failed_run_id, manifest, claim);
SELECT geo_genius.claim_import_execution(run_id, executor_id);
SELECT geo_genius.advance_import(run_id, executor_id, next_status, metrics_patch);
SELECT geo_genius.verify_import(run_id, executor_id);
SELECT geo_genius.complete_import(run_id, executor_id, metrics_patch);
SELECT geo_genius.publish_import(run_id, executor_id);
```

Reads that need no resolution logic join the read views instead. They come in pairs: a
`release_*` base carrying every release, and a `published_*` view that is the base joined
to the publication pointer, so a pointer swap changes what all of them show at once:

| View                                                  | Contains                                                                            |
|-------------------------------------------------------|--------------------------------------------------------------------------------------|
| `release_areas`                                       | Every `release_area` membership row, published or not                               |
| `release_area_codes` / `release_area_names`           | Codes and names, one row per release carrying the area                              |
| `release_relations`                                   | Every relation edge, published or not                                               |
| `published_areas`                                     | `release_areas` narrowed to the currently published release; includes retired areas |
| `published_area_codes` / `published_area_names`       | Codes and names for published areas                                                 |
| `published_area_relations`                            | Relations among published areas                                                     |
| `published_boundaries`                                | Boundary geometry for published areas                                               |

`GeoGenius.Published` is the Elixir surface over those views: read-only Ecto schemas
carrying every column, plus composable query functions (`areas/1`, `children_of/2`,
`ancestors_of/2`, `areas_by_code/3`, `codes/1`, `names/1`, `relations/1`) that return an
`Ecto.Query` a host joins and aggregates against its own tables. Use it for joins,
aggregates, set-keyed reads, and anything keyed on `release_id`; use `GeoGenius` and
`GeoGenius.Query` for spatial resolution, name search, and multi-level traversal. Its
`:release_id` option reads a release whether or not its collection publishes it, by
swapping every source in the query onto the `release_*` base views.

See [`guides/installation.md`](guides/installation.md) for what `NULL` measurement columns
on a `relation` row mean, why `max_depth` costs what it costs on a densely mutually-related
graph, why `published_areas` does not hide retired areas, and how to react to a publication
without polling.

## Mix Tasks

| Task                             | Description                                                                  |
|----------------------------------|------------------------------------------------------------------------------|
| `mix geo_genius.setup`           | Generate the initial pinned host migration                                   |
| `mix geo_genius.gen.migration`   | Generate one adjacent version-upgrade wrapper                                |
| `mix geo_genius.migration_sql`   | Render a pinned SQL transition for a host-owned migration                    |
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
- [`guides/projections.md`](guides/projections.md) — keeping a source's own columns in a
  host-owned table keyed `(release_id, area_key)`, and resolving the artifacts to fill it
  from
- [CHANGELOG](CHANGELOG.md) — releases
- [`docs/design/geo-genius-design.md`](docs/design/geo-genius-design.md) — the design spec:
  what the catalog stores, why a release is immutable once published, and what the
  library deliberately leaves to its host

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
