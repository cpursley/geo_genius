# GeoGenius Design

> Status: historical design notes. The current schema is installed and the public
> contract lives in `README.md`, `guides/sql_api.md`, `guides/ingestion.md`,
> and the shipped schema SQL. Do not treat this document as an
> operator manual: several Import/Provider/Storage sketches here predate the
> executor-fenced SQL (for example `heartbeat_import/2` is now
> `heartbeat_import/3`).
>
> Scope: a standalone Elixir and PostgreSQL/PostGIS library, distributed on Hex, installable into
> any Ecto-backed application. No HTTP layer, no UI, no frontend.

## Goal

GeoGenius is a versioned catalog of named geographic areas and the primitives that resolve
locations into them.

A host application installs the package, publishes one or more area collections, and queries them:
which areas contain this point, which areas overlap this shape, which areas are near it, which area
does this postal code or place name identify, and what is the hierarchy above or below a given area.

The library owns the catalog and its resolution primitives. It never learns about the host's
records, tenants, roles, HTTP layer, or presentation.

## Decisions

1. PostgreSQL with PostGIS is an unconditional requirement. There is no metadata-only install
   variant.
2. The library ships catalog primitives only. Projections that join a host's records to areas are
   host-owned and hand-written.
3. The database is the API. Claims, transitions, composition, verification, publication, rollback,
   retention, measurement, and resolution are named SQL functions shipped as versioned migrations.
   Elixir is a thin shell.
4. Hosts bind to the catalog by joining published read views. There is exactly one binding model.
   Denormalization, where a host wants it, is a host-owned materialized view over the same join.
5. The publishable unit is a **collection**, not a country. A national boundary vintage and an
   operator's own territory set move through identical machinery.
6. Area types are rows, not an enumerated type. Hierarchy is derived from measured relations, not
   from a fixed depth.
7. Overlapping areas are normal. The model never assumes areas tile a plane or that a point
   resolves to exactly one area of a type.
7a. Geometry is optional per area. An area participates in a release through its `release_area`
    membership row; a boundary is an optional attachment. A reference hierarchy carrying only
    names, codes, centroids, and asserted relations is a first-class catalog. A collection
    declaring `requires_geometry` restores the strict check for sources that must be polygonal.
8. Time is a query dimension. Every read function defaults to the collection's published release
   and accepts an explicit `target_release_id`. A moment in time is resolved to a release id by
   `release_at(collection_key, as_of)`, which reads the durable publication event log, rather than
   by an `as_of` parameter repeated on every signature: one resolution step, then an ordinary
   pinned-release read.
9. The catalog is tenant-free. Collections are the isolation unit.
10. Schema migrations are raw SQL managed by EctoEvolver, installed under a host-selected prefix
    through a host-owned, version-pinned Ecto migration.
11. Execution is adapter-based. A supervised task is the safe zero-configuration default; durable
    PgFlow execution is explicit because its finite job deadline is host policy for bounded work.
12. GDAL is not a package requirement. Only providers that read shapefiles need it.
13. Automatic bootstrap and artifact download are disabled by default. Starting a host application
    never downloads or imports geographic data.
14. Geometry crosses the Elixir boundary as a `Geo` struct, never as WKT or EWKT text, so
    `geo_postgis` is a required dependency rather than an optional one. Text geometry would put
    parsing and formatting on both sides of every read and make the host's own PostGIS queries
    speak a different dialect than the catalog's.

## Context

Three existing applications each hand-rolled a different subset of this problem, and none of the
three implementations is reusable by the other two:

| Concern | Implementation A | Implementation B | Implementation C |
|---|---|---|---|
| Geometry | PostGIS polygons, versioned vendor releases | PostGIS points from vendor CSVs | No PostGIS; text columns only |
| Identity | Stable composite keys, release-versioned | UUID foreign keys on host rows | Text name equality |
| Resolution | Point in polygon | Postal, then name, then nearest point | String comparison |
| Extras | Overlap measurement, publication, rollback | Ranked name search, radius, batch matching | Hierarchy rollups, cached counts |

Between them they establish the required capability set: containment, overlap with coverage
measurement, radius, ranked name and alias search, code lookup, hierarchy traversal, versioned
publication with rollback, and per-area attributes usable for ranking.

The design generalizes that union. It does not encode any concept from the applications that
motivated it.

## Domain Model

| Entity | Purpose |
|---|---|
| `collection` | The publishable unit. Owns its area types. Published and rolled back as a whole. |
| `release` | A version of a collection. Immutable from the moment it is published: the write API refuses to modify a completed or retired release, so a change to what hosts see is always a new release. |
| `source` | A provider and dataset. |
| `source_release` | A provider's semantic vintage. |
| `artifact` | One file belonging to a source release: URL or operator-supplied key, expected bytes, SHA-256, license, required or optional. |
| `release_source` | Which source releases compose a release. |
| `authority` | The body that defines an area set and its codes, such as a statistical agency or an operator's own namespace. Registered per collection; a collection may draw on more than one. |
| `area_type` | Rows scoped to a collection: code, label-neutral identity, and a `rank` used for ordering. |
| `area` | Stable logical identity within a collection. Survives geometry change. Retired areas remain addressable and may declare a successor. |
| `area_name` | Official names, aliases, mailing names, abbreviations, with kind and locale. |
| `area_code` | Additional codes such as postal codes, GEOIDs, and administrative codes. |
| `release_area` | An area's participation in a release, carrying its centroid and per-release JSONB attributes: population, density, timezone, risk tier, provider fields. Membership lives here, not on `boundary`. |
| `boundary` | Canonical geometry plus simplified display geometry per zoom tier, per area, per release. |
| `boundary_part` | Subdivided canonical geometry used by resolution queries. |
| `relation` | A measured relation between two areas in a release: classification and ratio. |
| `publication` | One row per collection pointing at the active release, retaining the previous release for rollback. |
| `import_run` | The durable state machine: claim, lease, phase, heartbeat, metrics, terminal status, runner backend. |
| `publication_event` | Durable record of a publication or rollback, for host-side cache invalidation. |

### Area keys

An area key is `<authority>:<type>:<code>`.

```text
census:state:13
census:county:13121
census:zcta:30309
acme:territory:west
```

The authority segment implies jurisdiction, so no country segment is carried. A territory that
spans several countries has no ambiguous country field to fill in.

Database relationships use internal identifiers. URLs, saved filters, and host columns use the
portable area key, so a saved reference survives a database rebuild or a move to another host.

`type_rank` orders types within a collection. A query spanning several collections orders by
collection first, then by rank, because ranks from unrelated collections are not comparable.

### Relations

Relations are measured, not asserted. Each carries a classification and a ratio:

```text
contains | mostly_contains | overlaps
```

A parent-child hierarchy is one traversal over relations. Many-to-many relations, such as a place
crossing county lines or a postal area overlapping several municipalities, are the normal case
rather than an exception.

Relations are release-scoped and may reference an area in another collection. Cross-collection
relation storage is not built in the first version; `areas_for_geometry` computes such an
association on demand.

## Storage and PostGIS Practices

Canonical geometry is `geometry(Geometry, 4326)` with a check constraint restricting it to
polygonal types. Typing the column generically keeps a later widening to corridors or linear
features a migration rather than a redesign. Geodesic measurement casts to `geography` at call
time; both representations are never stored.

Two practices carry the design at scale:

- **Subdivision.** Large multipolygons make index scans return very large candidate geometries.
  `boundary_part` stores `ST_Subdivide(geom, 256)` pieces keyed back to their area. Resolution
  queries scan the subdivided table, then confirm against canonical geometry. This is the single
  largest improvement for containment and intersection queries on national datasets.
- **Partitioning.** `boundary`, `boundary_part`, `relation`, and `area_attribute` are partitioned by
  list on `release_id`. Retention becomes `DETACH` and `DROP PARTITION`, which is instant and leaves
  no bloat, instead of a mass delete followed by vacuum.

Indexing and statistics:

- GiST on canonical geometry and on subdivided parts.
- GIN with `jsonb_path_ops` on attributes.
- GIN trigram on names.
- Unique B-tree on area identity per release.
- B-tree on codes by type and value.
- Raised statistics targets on geometry columns, with `ANALYZE` after load.
- Indexes are created after bulk load, never before.

Validity and display:

- `ST_IsValid` on ingest. `ST_MakeValid` repair is recorded as provenance, never applied silently.
- Display geometry is `ST_SimplifyPreserveTopology` followed by `ST_QuantizeCoordinates`, stored per
  zoom tier.
- Classification always uses canonical geometry. Simplified geometry is only for rendering.

Loading:

- `UNLOGGED` staging tables, `COPY` in, validate, then insert into logged partitioned tables.
- Rows and files stream. A national dataset is never held in application memory.

Function hardening:

- All functions are `SECURITY INVOKER` with a pinned `SET search_path`.
- Read functions are `STABLE`; write functions are `VOLATILE`.
- Advisory locks are transaction-level only. No session-level lock is held across a download or a
  long import stage.
- Any dynamic staging identifier is validated against a package-owned pattern and quoted.

## SQL API Surface

### Published read views

Reads go through the publication pointer, so swapping a release changes every host's results
atomically under MVCC. No materialized view refresh window exists. Materialized views are added only
where measurement proves one necessary.

| View | Contents |
|---|---|
| `published_areas` | area_key, collection, authority, area_type, type_rank, name, centroid, attributes |
| `published_area_codes` | area_key, code_type, code_value |
| `published_area_names` | area_key, name, kind, locale |
| `published_area_relations` | left area, right area, classification, ratio |
| `published_boundaries` | canonical geometry, display geometry per tier |

Only `published_boundaries` requires PostGIS at query time. A host whose records carry no
coordinates joins codes and names instead, using the same catalog and the same identity.

### Result shape

Every query function returns one composite type, so host code and generated types stay uniform:

```text
area_match(
  collection_key, release_id,
  area_key, authority, area_type, type_rank,
  name, codes, centroid, attributes,
  match_method,
  distance_m,
  intersection_area_m2, coverage_of_input, coverage_of_area,
  score
)
```

Measurement columns are null where they do not apply. A containment match carries no coverage; a
proximity match carries no intersection area; only a search carries a score.

### Functions

| Function | Behavior |
|---|---|
| `areas_for_point(lon, lat, ...)` | Boundary-inclusive `ST_Covers` |
| `areas_for_geometry(geom, ...)` | `ST_Intersects`, then geodesic intersection area. Zero-area edge contact is excluded. Returns coverage of the input and coverage of the area. |
| `areas_near(lon, lat, radius_m, ...)` | `ST_DWithin` on geography, ordered by distance |
| `areas_by_code(code_type, code_value, ...)` | Geometry-free lookup |
| `search_areas(query, ...)` | Name and alias search, ranked, attribute-weightable |
| `children_of(area_key, ...)` | Relation traversal downward |
| `ancestors_of(area_key, ...)` | Relation traversal upward |
| `related_areas(area_key, classifications, ...)` | Arbitrary measured relations |
| `resolve(input, ...)` | The cascade below |

Optional named parameters shared across all of them: `collections`, `types`,
`target_release_id`, `result_limit`, `include_retired`. A caller holding a timestamp rather than
a release id gets one from `release_at(collection_key, as_of)` first.

No function reads session state, a role, or a tenant identifier. A host passes what it needs
explicitly.

### The resolution cascade

`resolve/2` tries strategies in order of the authority of the signal, stamping `match_method` and a
confidence on the result:

1. **containment**: if the input carries coordinates, point in polygon wins.
2. **code**: exact postal, administrative, or provider code match, scoped by a parent area. A code
   is unique only within a parent, so a slug or a local identifier needs the parent to tell twenty
   candidates apart.
3. **name**: normalized name or alias, scoped by a parent area.
4. **proximity**: nearest area within a bounded radius.

Containment precedes code deliberately. Postal geographies are approximations of delivery networks
rather than authoritative boundaries, so a real coordinate is the stronger signal. A host that needs
a different order passes a `strategies` list to reorder or restrict the cascade.

### Publication signalling

Publishing or rolling back writes a durable `publication_event` row carrying a monotonic
`sequence` suitable for cursor-based polling. That row is the entire contract, and the library reads
no host table.

The library emits no `pg_notify`. A fixed, library-chosen channel name is integration policy rather
than a catalog primitive, and `NOTIFY` is session-scoped and lossy: it reaches only sessions holding
a `LISTEN` at that instant, and is dead entirely under a connection pooler in transaction mode. A
host could not distinguish "no publication happened" from "the notification was lost", which is a
worse contract than shipping no signal at all.

A host wanting low-latency wakeups adds its own `AFTER INSERT` trigger on `publication_event`. That
is strictly better: the host chooses the channel name, the payload, and the delivery mechanism, and
because the trigger runs in the inserting transaction it keeps commit-then-deliver ordering. The
durable row remains the source of truth; any notification is only a hint that polling is worthwhile.

Note that sequence values are assigned before commit, so a reader polling by cursor may briefly see
a gap that later fills. Poll with a small lag, or treat the highest contiguous value as the
watermark.

## Import and Publication

Phases:

```text
pending -> downloading -> validating -> staging -> normalizing ->
relating -> indexing -> verifying -> publishing -> completed | failed
```

`import_run` in PostgreSQL is authoritative. No process memory holds import state.

| Function | Role |
|---|---|
| `prepare_import(manifest, claim)` | Reuse the exact current candidate or create its first immutable attempt |
| `retry_failed(run_id, manifest, claim)` | Create an explicitly corrected attempt after a durable failure |
| `claim_import_execution(run_id, executor_id)` | Atomically select the sole executor for a pending attempt |
| `heartbeat_import(run_id, progress)` | Renew liveness and record progress for the owning attempt |
| `advance_import(run_id, executor_id, phase, metrics)` | Advance exactly one nonterminal phase and record progress |
| `fail_import(run_id, executor_id, error)` | Terminal, inspectable, retryable |
| `verify_release(release_id)` | Invariants before publication |
| `complete_import(run_id, executor_id, metrics)` | Verify and complete an import without publishing |
| `publish_import(run_id, executor_id)` | Verify, complete the import, release its lease, publish, and emit the event atomically |
| `publish_release(release_id)` | Publish a release that has no import history, for deliberate catalog administration |
| `rollback_publication(collection)` | Revert to the retained previous release |
| `retire_releases(collection, keep)` | Drop partitions, mark the release retired, keep its row |
| `release_at(collection, as_of)` | The release a collection had published at a moment |

Candidate identity and retry are explicit. Calling `prepare_import` again for the same exact
candidate returns its existing attempt; it does not overwrite the manifest, source declarations,
artifact evidence, or failure. Once that attempt has failed, ordinary preparation returns a
structured refusal for both identical and changed manifests. A retry starts only through
`retry_failed`, receives a new attempt number, and retains the failed attempt as immutable evidence.

Execution is also explicit. A pending attempt must win `claim_import_execution` before doing any
work, and there is no executor takeover. Every import-owned write is fenced by the current run, so
a duplicate, failed, or superseded worker cannot continue mutating the candidate release.
An independently supervised execution guardian monitors the process that performs that claim.
If the process dies while the Repo remains reachable, the guardian records failure with the exact
executor identity. It cannot cover whole-node loss or dependency shutdown after the host Repo has
already stopped; those remain operator-visible abandoned attempts, never automatic takeovers.

Verification invariants include: required area types present, area counts within configured
thresholds, all geometry valid, no orphan relations, every member area belonging to the release's
own collection, unique identity per release, and every declared code resolvable.

Retention reclaims a release's bulk data by dropping its partitions and marking the release
retired. The release row itself is kept, because `publication_event` and `import_run` reference it:
deleting it would cascade both away, tearing holes in the monotonic event sequence hosts poll and
erasing import history the catalog keeps indefinitely.

Publication is fail-safe. A failed candidate leaves the current release, its boundaries, and every
host join untouched. An imported release becomes visible only when `publish_import` completes the
run, removes its lease, swaps the publication pointer, and records the event in one transaction,
after every required selected artifact has a validated observation and all source, relation,
index, and catalog validations complete. Phase changes follow the fixed sequence and cannot skip
ahead or create a terminal state; `fail_import`, `complete_import`, and `publish_import` own the
terminal transitions. The completion-only path performs the same validation without changing the
publication pointer.

Retention keeps the active release and one previous complete release. Source and import history are
kept indefinitely; they are small.

## Elixir Shell

Elixir performs only what PostgreSQL cannot:

- manifest decoding and validation;
- streaming HTTP download;
- checksum and byte verification;
- artifact cache management, including operator-supplied licensed files;
- external command invocation;
- long-stage supervision and heartbeats;
- issuing narrow calls into the SQL API;
- mapping result rows to structs;
- telemetry.

It does not reimplement locking, transitions, verification, publication, retention, measurement, or
resolution.

### Adapters

Each adapter is a behaviour with a name-to-module registry and a `configured/0` reading application
environment. Optional dependencies are reached through `Code.ensure_loaded?/1` and
`function_exported?/3` so the library compiles without them.

| Behaviour | Default | Alternatives |
|---|---|---|
| `GeoGenius.Runner` | `Runners.Task` | `Runners.PgFlow`, `Runners.Inline`, host adapters |
| `GeoGenius.Store` | `Stores.Postgres` | host repo seam |
| `GeoGenius.Cache` | `Caches.FileSystem` | object storage |
| `GeoGenius.Downloader` | `Downloaders.Req` | any HTTP client |
| `GeoGenius.Command` | `Commands.System` | test stub |
| `GeoGenius.Notifier` | `Notifiers.Noop` | host event delivery |
| `GeoGenius.Provider` | none | `Providers.Census`, `Providers.GeoJSON`, `Providers.CSV` |

The runner backend name is persisted on `import_run.runner_backend`, so a later status query or
cancellation routes to the correct backend even if configuration changed since the run started.

### Provider behaviour

The provider is the generality hinge. Six callbacks describe any source:

| Callback | Responsibility |
|---|---|
| `area_types/0` | Types and ranks contributed to the collection |
| `manifest_schema/0` | Shape of a reviewed release manifest |
| `artifacts/1` | Files a release requires or optionally uses |
| `stage/2` | Load one artifact into staging |
| `normalize/1` | Staging rows into canonical areas, names, codes, attributes, geometry |
| `relations/1` | Which relations to measure for this collection |

A national boundary vintage and a single uploaded GeoJSON of delivery zones implement the same six
callbacks. Because only shapefile-reading providers invoke GDAL, a host that publishes GeoJSON or
CSV collections never installs it.

### Manifests

A reviewed manifest names a provider, dataset, semantic vintage, exact artifact URL or
operator-supplied cache key, expected archive members, expected bytes, SHA-256, license and
attribution, and which artifacts are required.

Shipping a manifest is how a new release becomes available. Nothing discovers or follows a mutable
"latest" URL. Licensed artifacts are operator-supplied into the cache or fetched from an approved
internal mirror.

### Public API

```elixir
GeoGenius.import(collection: "acme_territories", release: "2026-q1")
GeoGenius.status(run_id)
GeoGenius.await(run_id, timeout)
GeoGenius.publish(release_id)
GeoGenius.rollback(collection)
GeoGenius.published_release(collection)

GeoGenius.resolve(input, opts)
GeoGenius.areas_for_point(lon, lat, opts)
GeoGenius.areas_for_geometry(geom, opts)
GeoGenius.areas_near(lon, lat, radius_m, opts)
GeoGenius.search_areas(query, opts)
GeoGenius.children_of(area_key, opts)
GeoGenius.ancestors_of(area_key, opts)
```

Reads return `%GeoGenius.AreaMatch{}`.

`GeoGenius.Context` carries repo, prefix, and adapter overrides. The application environment
describes exactly one host; a VM serving multiple hosts passes an explicit context to every call.

Geometry is a `Geo` struct on both sides of a read: `centroid` arrives as a `%Geo.Point{}`, and
`areas_for_geometry` takes a `%Geo.Polygon{}` or `%Geo.MultiPolygon{}` and binds it directly. That
requires the host's Repo to run on a Postgrex types module registering `Geo.PostGIS.Extension`.
`GeoGenius.PostgresTypes` is that module for a host with none of its own; a host that already
defines one adds the extension to it instead. The types module chooses no JSON library, leaving
`config :postgrex, :json_library` to the host, because `codes` and `attributes` cross as decoded
maps through whichever library the host already runs.

### Composable queries

The struct-returning API answers one question per call, which is the wrong shape for the one
question a host asks about its own data: how many of my records fall in each of these areas.
Answering that through `children_of/2` means one catalog read plus one query per area returned.

`GeoGenius.Query` returns an `Ecto.Query.t()` over the same SQL function instead, so the catalog
read becomes a subquery inside the host's own query and the join, the grouping, and the aggregate
all happen in one round trip:

```elixir
from(area in subquery(GeoGenius.Query.children_of("us:state:pa", types: ["city"])),
  left_join: record in MyApp.Record, on: record.area_key == area.area_key,
  group_by: area.area_key,
  select: {area.area_key, count(record.id)})
```

It covers `children_of`, `ancestors_of`, `areas_by_code`, and `search_areas`, the reads a host
joins against. The join is on `area_key`, the same stable identifier the binding model uses
everywhere else, so nothing about the host's side of the join changes.

The schema prefix is the one thing it cannot take per call. Ecto requires a fragment's SQL to be a
literal, so the prefix is read at compile time and a per-call `:prefix` raises rather than
silently reading the wrong schema. A host serving several catalogs from one VM uses the
struct-returning API, which resolves the prefix through `GeoGenius.Context` on every call.

### Startup preflight

A misconfigured database must fail loudly at boot, not on the first query. `GeoGenius.verify!/2`
checks, against an explicit repo and prefix:

1. every required PostgreSQL extension is installed, not merely available, and sits on the search
   path the catalog's functions pin;
2. the Repo decodes PostGIS geometry, which every match's centroid and every geometry argument
   depends on;
3. the Repo decodes jsonb, which `codes` and `attributes` depend on in every projection;
4. the prefix schema exists and carries the version-tracking view;
5. the installed schema version equals the version the loaded code expects.

Each failure raises with the specific remedy: which extension to create, which types module to
register, which JSON library to configure, which migration to run, or which version mismatch was
found. The last check is the one that catches code deployed ahead of its migration, a failure that
otherwise surfaces later as an undefined-function or missing-column error far from its cause.

The two decode checks are separate because geography and jsonb are decoded by different Postgrex
extensions: a Repo can decode one and not the other, and a Repo that cannot decode jsonb passes a
geometry-only probe and then loses its connection on the first real read.

`GeoGenius.Preflight` wraps the same check as a supervisor child. The host places it in its own
supervision tree immediately after its Repo, because dependency applications boot before the host
application and `:geo_genius` cannot see a Repo that has not started yet. The library's application
callback therefore starts only process infrastructure that needs no host Repo at boot: the
execution-guardian supervisor and, unless the host configured its own, a `Task.Supervisor` for the
default asynchronous runner. `GeoGenius.Preflight` deliberately does not belong to that package
tree.

The child returns `:ignore` on success, so nothing lingers in the tree, and raises on failure, which
aborts host startup. A host that prefers to decide for itself calls `GeoGenius.verify/2`, the
non-raising variant returning `:ok | {:error, [reason]}`, from a release task or a health endpoint.

Preflight duplicates the migration-time extension check on purpose: the SQL check guards the moment
the schema is created, when no schema yet exists to hold an Elixir-callable function, and the Elixir
check guards every boot thereafter.

`GeoGenius.Bootstrap` is an optional supervised child that idempotently enqueues the configured
desired release. It is disabled by default, so starting a host application never downloads or
imports anything.

## Install and Versioning

```elixir
defmodule GeoGenius.Migration do
  use EctoEvolver,
    otp_app: :geo_genius,
    default_prefix: "geo_genius",
    tracking_object: {:view, "geo_genius_version"},
    versions: [GeoGenius.Migrations.V01]
end
```

Version SQL lives at `priv/geo_genius/sql/versions/vNN/vNN_up.sql` and `vNN_down.sql`, using
`$SCHEMA$` for the prefix and `--SPLIT--` between statements. Package SQL never hard-codes a schema
name.

The host owns migration timing:

```elixir
defmodule MyApp.Repo.Migrations.InstallGeoGenius do
  use Ecto.Migration

  def up, do: GeoGenius.Migration.up(prefix: "geo_genius")
  def down, do: GeoGenius.Migration.down(prefix: "geo_genius")
end
```

| Task | Role |
|---|---|
| `mix geo_genius.setup --repo MyApp.Repo --prefix geo_genius` | Generate the pinned host wrapper. Never runs a migration. |
| `mix geo_genius.gen.migration --from N --to N+1` | Generate one adjacent upgrade wrapper |
| `mix geo_genius.check_schema` | Verify the installed version. A CI and deploy gate. |
| `mix geo_genius.uninstall` | Explicit, confirmed teardown |
| `mix geo_genius.import` | Start an import |
| `mix geo_genius.publish` | Publish a verified release |
| `mix geo_genius.rollback` | Revert a collection to its previous release |
| `mix geo_genius.status` | Inspect runs and publications |

Igniter hosts run `mix igniter.install geo_genius`.

**Extensions are host-owned.** PostGIS and `pg_trgm` are required. The install verifies their
presence and raises an instructive error rather than issuing `CREATE EXTENSION`, which assumes
privileges a library should not. `mix geo_genius.setup --with-extensions` emits the create
statements into the host's own wrapper for hosts that do hold those privileges.

**Staging placement.** Staging objects live inside the selected schema under package-owned,
strictly validated names, are `UNLOGGED`, and are created and dropped per run. No second schema is
required, so the single-placeholder behavior of the migration tool is never a constraint.

**Down-migration policy.** `down` is a true reversal: it drops objects and data. This is acceptable
because catalog content is derived. Every release is reproducible from a reviewed, checksummed
manifest. The policy is documented plainly rather than softened with a partial-teardown mode.

### Repository layout

```text
lib/geo_genius.ex
lib/geo_genius/{config,context,migration,error,telemetry}.ex
lib/geo_genius/migrations/v01.ex
lib/geo_genius/{runners,stores,caches,downloaders,commands,notifiers,providers}/
lib/mix/tasks/geo_genius.*.ex
priv/geo_genius/sql/versions/v01/{v01_up.sql,v01_down.sql}
priv/geo_genius/manifests/
test/
test/pgtap/
```

The pgTAP suite is a shipped artifact of the library, because the SQL is the API.

Implementation note: `mix new geo_genius` run inside the repository root creates a nested
`geo_genius/` directory. Its contents move up one level so the package root is the repository root.

## Testing

**pgTAP is the primary specification.** Tests are transactional, use tiny synthetic geometries, and
never download anything. Required coverage:

- stable identity across releases; retired areas and successors remain addressable;
- only published releases are visible;
- a failed candidate never replaces the active release;
- publication swap atomicity and rollback to the retained previous release;
- retention by partition drop;
- two concurrent claims yield exactly one winner;
- phase transitions, terminal states, single-executor claims, and explicit handling of a stale run;
- verification invariants fail closed;
- SRID enforcement and longitude/latitude ordering;
- boundary-inclusive containment;
- zero-area edge contact excluded from overlap;
- coverage ratios denominated against the correct operand;
- relation classification and ratios;
- cascade ordering, method stamping, and strategy overrides;
- radius, distance ordering, and search ranking;
- as-of and explicit-release queries;
- collection isolation, including that a failed import in one collection cannot affect another;
- presence of required indexes and constraints, function volatility, `SECURITY INVOKER`, and pinned
  `search_path`.

**Elixir tests** cover manifest validation, cache hit and miss, partial-download cleanup, checksum
mismatch, stubbed command invocation, every runner adapter, provider callbacks against tiny
fixtures, and result mapping. HTTP is stubbed throughout.

**Install integration tests** are excluded from the default run and compile disposable host
projects to prove: clean install at the default prefix, clean install at a non-default prefix,
incremental upgrade across every supported version, rollback, `check_schema` gating, and a working
install with neither PgFlow nor Oban present.

## Adoption

Each adoption is a separate change with its own spec and plan. Ordering is deliberate: the first two
hosts have no prior versioned catalog, so they exert the strongest pressure toward a host-neutral
API. The largest and most spatially sophisticated host adopts last, once the API has survived two
foreign hosts.

The library is expected to change during the first two adoptions. Until the third host begins, the
package is pre-1.0 and its API, schema version, and SQL contracts may break in response to what real
adoption exposes. Each host adoption runs on a branch named `geo-genius` cut from that repository's
main branch. The third adoption does not begin without explicit approval.

1. **First host.** Replace a hand-rolled reference-data module set with the library: install, publish
   a collection, add a thin host facade, and add a host-owned projection over the host's own point
   geometry. Host records that are themselves polygons route through `areas_for_geometry`. A contract
   test locks host-visible behavior before and after. A separate, later change drops the legacy
   tables behind a data-completeness guard that refuses the drop if any legacy row is unrepresented.
2. **Second host.** Add PostGIS. Replace a reference table and its materialized views with the
   library. Because this host's records carry no coordinates, it joins `published_area_codes` and
   `published_area_names`, and derives hierarchy rollups from `published_area_relations`. Host-side
   caching stays host-side.
3. **Third host.** Fresh branch off current main. Existing exploratory branches and stashes are
   preserved untouched for historical reference and are read without being applied. Retained from
   that prior work: metadata, development fixtures, the host's own wrapper functions rewired onto
   library primitives, and the entire frontend layer. Removed: the in-repository catalog modules, the
   large database adapter, and the catalog migrations, replaced by the library install wrapper plus
   host-projection migrations.

Version pinning discipline: every host runs `mix geo_genius.check_schema` in CI and at deploy.

## Out of Scope

- Any HTTP layer, controller, LiveView, GraphQL contract, or UI.
- Any frontend package, map component, drawing tool, or filter grammar.
- Tenancy, actors, roles, or authorization.
- Host record projections, counts, or option lists.
- Display labels for area types.
- Stored cross-collection crosswalk relations.
- Measured relations between areas of equal `type_rank`. Relation building compares a
  lower-ranked area against higher-ranked ones within a collection, so two overlapping
  areas of the same type produce no stored relation. Pairwise measurement within a type
  is quadratic and does not survive census-tract scale. Such an overlap is still
  discoverable on demand through `areas_for_geometry`.
- Geocoding of free-form addresses.
- Runtime dependence on any external boundary or geocoding service.
- Automatic discovery of mutable vendor release URLs.
- Non-polygonal area geometry in the first version.
- Raster data and three-dimensional geometry.
- Database engines other than PostgreSQL.

## Acceptance

The design is delivered when:

- a clean install succeeds at the default prefix and at a non-default prefix;
- an incremental upgrade succeeds from every supported version, and rollback is tested and
  documented;
- no host application table, role, tenant concept, or job framework appears anywhere in the package;
- the database state machine and publication behavior are exercised directly by pgTAP;
- Elixir contract tests run against the installed SQL API rather than against mocks of it;
- two concurrent import requests preserve exactly one active claim;
- a failed candidate release never replaces the current publication;
- a host can use the library with no Phoenix, no PgFlow, and no GDAL;
- a collection of operator-supplied polygons and a national vendor vintage are published through
  identical code paths;
- a host whose records carry no coordinates can resolve and filter through codes and names alone.

## References

- EctoEvolver: versioned raw-SQL migrations for libraries, `$SCHEMA$` substitution, `--SPLIT--`
  statement boundaries, tracking objects.
- BlogEngine: host-owned pinned migration wrapper, context-carried configuration, host behaviours,
  conflict-safe generated scaffolds, `check_schema` gate.
- DripDrop: adapter behaviour with a name-to-module registry, optional dependencies resolved at
  runtime, backend name persisted on the row so later operations route correctly.
- PostGIS: `ST_Subdivide` for large-polygon indexing, `ST_Covers` for boundary-inclusive
  containment, `ST_DWithin` on geography for radius, `ST_SimplifyPreserveTopology` for display
  geometry, declarative partitioning for versioned retention.
