# Changelog

## Unreleased

### Reading

- **`:limit` accepts `nil` to mean no cap** on `GeoGenius.areas_near/4`,
  `GeoGenius.search_areas/2` and `GeoGenius.Query.search_areas/2`, and `result_limit`
  accepts an explicit `NULL` on the `areas_near` and `search_areas` SQL functions.
  Both defaulted a `nil` to 50, so a caller that narrows the result afterwards -- by a
  scope the catalog does not model -- had to name a number large enough to stand in for
  the whole set. Omitting the option, or the argument, still means 50.
  **Reinstall the schema.**
- **Four set-keyed reads: `children_of_many/2`, `ancestors_of_many/2`,
  `related_areas_many/2`, and `areas_by_code_many/3`,** each taking a list where the
  singular beside it takes a string, and each backed by a SQL function of the same name.
  Resolving a list previously cost one round trip per element; a page issuing one call per
  city paid several thousand. The plural result for `[a, b]` is the singular results for
  `a` and then `b`, concatenated in the array's order; a seed that matched nothing
  contributes no rows; an empty list returns nothing in one call; a `nil` list, or a `nil`
  element inside one, raises. Measured over a 4,000-area release with 1,000 seeds on
  loopback: 445ms for 1,000 singular calls against 52ms for one plural call.
- **`%GeoGenius.SeededMatch{}`** pairs the seed a row came from with the ordinary
  `%GeoGenius.AreaMatch{}`, which is unchanged. The plural reads return it because one
  result mixes rows from many seeds.
  `Enum.group_by(result, & &1.seed_key, & &1.match)` regroups them onto the caller's list.
- **`GeoGenius.Store` gains four callbacks** -- `children_of_many/3`, `ancestors_of_many/3`,
  `related_areas_many/3`, and `areas_by_code_many/4`. **An out-of-tree store must implement
  them to keep compiling.**
- **`seeded_area_match`** is installed beside `area_match`: `seed_key text` followed by
  `area_match`'s sixteen columns in order.
- **Three release-scoped base views** -- `release_area_codes`, `release_area_names` and
  `release_relations` -- join `release_areas`, and the four `published_*` views are now
  each nothing but their base joined to the publication pointer. A pair projects identical
  columns in identical order, so one read shape works either side of publication.
  **`published_area_codes` and `published_area_names` gain a `release_id` column**: their
  bases carry every release, so `release_id` is what tells apart the rows of an area that
  several releases carry, and it is the second half of any join back to an areas view.
  **Reinstall the schema.** `release_id` is inserted at ordinal 2 of both views, matching
  where `published_areas` has carried it since the catalog was first installed, so the
  four columns after it shift down by one rather than the new column being appended.
  A host reading these views by name -- which every read in this library does -- is
  unaffected. A host doing positional `SELECT *`, `INSERT ... SELECT *`, or reading result
  columns by index sees those four move. Until the schema is reinstalled,
  `GeoGenius.Published.AreaCode` and `GeoGenius.Published.AreaName` select a column the
  installed views do not have, and every read through them fails with
  `undefined_column`.
- **No index is shipped on `release_area.data`,** now as a tested decision rather than an
  omission. No installed function filters or orders by it, GIN cannot serve the ordered
  read a host actually wants there, and the keys are vendor-defined. `guides/sql_api.md`
  documents both index shapes a host can add, which predicate each serves, and the
  guarantee that an index on the partitioned parent reaches every partition a later import
  creates -- pinned against `create_release_partitions` in pgTAP.

- **`GeoGenius.Published`, a view-backed queryable.** Read-only Ecto schemas over
  `published_areas`, `published_area_codes`, `published_area_names` and
  `published_area_relations`, plus composable query functions -- `areas/1`,
  `children_of/2`, `ancestors_of/2`, `areas_by_code/3`, `codes/1`, `names/1`,
  `relations/1` -- each returning an `Ecto.Query` selecting whole structs. Two things it
  fixes for a host that joins or aggregates against the catalog: a plpgsql `SETOF`
  function is an optimizer barrier, so the whole set materialises before the host's own
  `WHERE` runs, and `GeoGenius.Query`'s selects project five of `area_match`'s sixteen
  columns. Every column of every view is exposed here, `release_id` included, so a host
  projection table keyed `(release_id, area_key)` is joinable at last. Set-keyed: where
  the function-backed API takes one `area_key`, these take a list. Sources carry Ecto
  bindings (`:area`, `:relation`, `:code`, `:name`) for composing further. Its
  `:release_id` option reads a release whether or not its collection publishes it, by
  swapping every source in the query onto the matching release-scoped base view.
- **`GeoGenius.Query` is not the join API.** Its moduledoc said it was. It stays correct
  and unchanged for what a view has no form for: `:max_depth` walks and trigram
  `search_areas/2`. An unpublished release is served either way.

### Projections

- **`GeoGenius.ReleaseArtifacts`** answers what files a release was built from and where
  each one is on this machine. `list/2` returns every artifact of a release, `fetch/3`
  one by logical name, and `path/3` a local file. Resolution goes through
  `GeoGenius.Cache` for both downloaded and operator-supplied artifacts, so a licensed
  file placed by hand -- which carries a `cache_key` and no `url` -- resolves the same
  way a download does. `:release_id` reads a release other than the published one, which
  is how a host fills a projection before the release goes live.
- **`GeoGenius.ArtifactError`** carries `:reason` -- `:no_published_release`,
  `:unknown_artifact`, `:invalid_cache_key`, or `:not_cached` -- and, for `:not_cached`,
  the cache key and the path the artifact was expected at, so an operator reading the
  message knows where to put the file.
- **`GeoGenius.Pipeline.Artifacts`** derives its cache keys through
  `GeoGenius.ReleaseArtifacts.cache_key/1`, so a release is addressed the same way by the
  import that wrote it and the host that reads it afterwards.
- **`guides/projections.md`** documents the pattern: a host-owned table keyed
  `(release_id, area_key)` holding a source's own columns, why it is keyed that way, how
  to repopulate it for a new release, and how to prune rows for retired ones.

### Provider contract

- **`asserted_relations/2` is a required callback.** A provider returns the relation edges
  one staged row states outright, as `{parent_area_key, child_area_key, relation_type}`
  tuples, for the hierarchy no overlap test can derive: a county FIPS on every city row, an
  admin parent code on every place, or a source with no geometry at all. It composes with
  `relations/1` rather than replacing it, and both land in the same release. **An
  out-of-tree provider must add one line to keep compiling:**

  ```elixir
  @impl GeoGenius.Provider
  defdelegate asserted_relations(manifest, row), to: GeoGenius.Provider, as: :no_asserted_relations
  ```

- **`normalize/2` may return a list of areas.** A source that denormalises a hierarchy into
  every row -- a city row carrying its county and its state -- describes several areas, and
  returning them together is cheaper and truer than staging the same row once per level.
  Areas repeated across rows converge on `area_key`. Returning a single `{:ok, area}` is
  unchanged.
- **`GeoGenius.Provider.Area.key/1` is public.** It composes an area's catalog key --
  `authority_key`, `area_type_key` and `code` joined by `:` -- which is the same
  composition PostgreSQL stores in `area.area_key` and the string form both ends of an
  asserted edge take. A provider asserting edges composes keys through it rather than
  re-deriving the format.
- **`GeoGenius.Manifest` enforces `:authorities`.** The field was already required and
  non-empty at load; it is now in `@enforce_keys` too, so a `%GeoGenius.Manifest{}` built
  in Elixir cannot default it to `nil` and reach registration as a `Protocol.UndefinedError`
  instead of an error naming the field.
- **The `relating` phase writes asserted edges** as well as rebuilding measured relations,
  streaming staged rows in pages and heartbeating the run's lease between them. It measures
  `asserted_relations` beside `relations`.

### Ingestion

- **Five set writes: `upsert_area_many`, `put_area_name_many`, `put_area_code_many`,
  `put_area_in_release_many`, and `put_relation_many`,** each taking one array per column
  and pairing them by position, with `GeoGenius.Catalog` wrappers of the same names taking
  a list of maps. Each scalar write is now that plural form called with one-element
  arrays, so there is one implementation of what a write means. `put_boundary` has no
  plural form: it validates and repairs a geometry, replaces the area's boundary and its
  subdivided parts, and recomputes the centroid, and the dataset that motivated this work
  carries no boundaries at all.
- **The normalizing and relating phases write a page as a set.** Normalizing collects a
  page of staged rows, then issues one statement for its areas, one for its names, one for
  its codes and one for its memberships; relating issues one for a page's asserted edges.
  Measured on the US SimpleMaps import (150,622 staged rows, 153,917 areas, 466,262 area
  writes, 330,297 asserted edges), against the same data on the same machine:

  | Phase       | Before             | After           |
  |-------------|--------------------|-----------------|
  | normalizing | 994.8 s, 1,755,328 statements | 39.6 s, 2,449 statements |
  | relating    | 162.7 s, 331,751 statements   | 20.4 s, 1,254 statements |
  | whole run   | 1183.5 s           | 85.5 s          |

  The catalog the two runs left is identical, row for row.
- **A batch that fails leaves none of itself written.** A page is collected before any of
  it is written, so a provider returning an illegal name kind, or a staged row naming an
  artifact the run did not stage, fails the phase with nothing of that page written rather
  than with the areas ahead of the failure already in the catalog. Earlier pages stay
  committed, which is what keeps the phase resumable.
- **An unresolved key now names itself.** The plural writes resolve keys by joining, and
  report an unresolved one through the new `assert_resolved` guard, which raises the same
  `P0002` that `SELECT ... INTO STRICT` raised but appends the key: `query returned no rows
  for authority key acme`. Because the scalar writes delegate, they carry the named message
  too. `put_boundary` and `assert_release_mutable` still raise the bare message.
- **`assert_write_arrays` refuses a malformed batch.** Arrays that disagree in length raise
  `22023`, and a null element in a column that requires one raises `22004`. `unnest` pads a
  short array with nulls rather than failing, so without this a batch assembled from two
  sources of different lengths would write rows the caller never described. The columns
  that accept a null element are `put_area_name_many`'s `locales` and
  `put_area_in_release_many`'s `centroids` and `data`.
- **One lock order for the whole write path**, through two new helpers: `area_lock_key`,
  the single definition of what an area serializes on, and `lock_areas`, which takes a
  batch's locks ascending by that key before the batch touches any row. Both
  `upsert_area_many` and `put_area_name_many` go through it, and both walk their `area`
  rows in `area_key` order, so the two agree at both levels. A plural write locks many rows
  per statement where a scalar locks one, and import leases are scoped to a release, so two
  releases of one collection normalize at once and the normalizing phase issues an area
  upsert and a name write for every page: two functions each sorting their own way
  deadlock over any pair of areas they share. `put_area_code_many`,
  `put_area_in_release_many` and `put_relation_many` take no advisory lock -- they reach
  `area` only through foreign keys, which take `FOR KEY SHARE` and cannot conflict with the
  `FOR NO KEY UPDATE` the other two take -- and each orders its own insert on its own
  conflict key. A batch holds one advisory lock per distinct area for the length of its
  statement, so the batch size a caller chooses bounds its share of
  `max_locks_per_transaction`.
- **Repeats inside one batch are deduplicated on the constraint key**, since `ON CONFLICT
  DO UPDATE` raises `21000` when one statement presents the same conflict key twice and a
  denormalised source repeats the same county in every city row. Where a write is
  last-write-wins -- release membership and relations -- the last occurrence in the arrays
  wins, matching what a loop of scalar calls in that order would have left.

- **`GeoGenius.await/3`'s default timeout is now 1,800,000ms (thirty minutes), up from
  300,000ms (five minutes) -- this changes default behaviour for existing callers.** The
  previous default did not cover the library's own flagship workload: a full US SimpleMaps
  import measured at ~17 minutes (1015 seconds), so any caller awaiting one with no explicit
  `timeout` failed on the default alone. The set writes above have since brought that same
  import under two minutes, but the default stays where it is: a boundary-carrying
  collection still writes one `put_boundary` per area, which is the shape the thirty
  minutes are for. Resolution order is now the `timeout` argument, then
  `config :geo_genius, :await_timeout`, then the 1,800,000ms library default, via the new
  `await_timeout/1` resolver in the library's internal config module -- the same
  per-call-opts-then-app-env-then-default pattern `manifest_paths/1` and the adapter
  resolvers already use. `:infinity` remains valid at every level. A caller that already
  passes an explicit `timeout` is unaffected.
- **`mix geo_genius.import --await` participates in that resolution.** The task carried a
  `300_000` default of its own and passed it to `await/3` as an explicit argument, which
  wins the order above, so `config :geo_genius, :await_timeout` could not reach the
  library's own CLI and it still gave up after five minutes. `--timeout` now parses to nil
  when absent, and the value the task reports on a timeout is the one the wait used.
- **A staging pass empties the run's table before it writes to it.** `create_staging` is
  `CREATE UNLOGGED TABLE IF NOT EXISTS`, and nothing truncated, so an attempt that died
  where `GeoGenius.Pipeline`'s cleanup could not run -- a killed VM, a lost machine --
  left its rows staged under the same run id and the next attempt appended to them. A
  measured import reported 150,622 staged rows into a table holding 301,244. Doubling the
  work is the mild half; the other half is that the stale rows are normalized too, so a
  row deleted from the source between attempts is resurrected into the release. The new
  `GeoGenius.Staging.reset/2` drops and recreates the table, and the staging phase calls
  it in place of `create/2`. No SQL changed: `create_staging` still keeps what it finds,
  and a host driving staging through the SQL API calls `drop_staging` before it.
- **Every `authorities` and `area_types` entry is validated field by field.** An entry
  naming no `key`, an authority naming no `name`, or an area type whose `rank` is not a
  positive integer is refused by `GeoGenius.Manifest.load/3` and `from_map/2` with a
  message naming both the field and the list it came from. Such an entry passed
  validation and failed several phases later as a `GeoGenius.CatalogError` wrapping a
  NOT NULL violation or a failed cast inside `upsert_authority`/`upsert_area_type`.
  **A manifest carrying one now fails at load rather than partway through an import.**

### SimpleMaps provider

- **`GeoGenius.Providers.SimpleMaps` (`"simplemaps"`)** parses the SimpleMaps US cities and
  US ZIP codes datasets into states, counties, cities and ZIPs, ranked 10/20/30/40. Both
  files denormalise the hierarchy into every row, so counties and states are read out of
  columns rather than off rows of their own, and the whole hierarchy is asserted from the
  FIPS columns -- the data carries centroids and no boundaries, so `relations/1` is `:none`.
  It requires no manifest `options`; the artifact's `logical_name`, `uscities` or `uszips`,
  selects the parser.
- **Three authorities.** Cities key under `simplemaps`, counties and most states under
  `census`, and ZIPs under `usps`. Six state codes key under `usps` as well: `AA`, `AE` and
  `AP` are USPS military-mail constructs and `FM`, `PW` and `MH` are the Freely Associated
  States, and the Census assigns none of the six an ANSI code. A host looking a state up by
  code queries both `ansi_state` and `usps_state`, or misses those six.
- **A county hangs under the state its own FIPS names.** A five-digit county FIPS begins
  with the two-digit FIPS of the state that assigns it, and that prefix -- not the row's
  `state_id` column -- is what `asserted_relations/2` reads a county's state parent from.
  The two disagree wherever a mailing address crosses a state line: ZIP `20041` carries
  `state_id` DC and `county_fips` 51107, which is Loudoun County, Virginia, and 150 of the
  source's 3,233 counties are named on rows of more than one state. A row whose county
  lies in another state also yields that state as an area of its own, since
  `put_relation` requires both ends of an edge to be members of the release. A county
  whose prefix names no state `GeoGenius.Providers.SimpleMaps.Fips` carries gets no state
  parent at all rather than a false one.
- **`GeoGenius.Providers.SimpleMaps.Fips`** states the state FIPS to postal code table the
  above reads: the fifty states, DC, and the five inhabited territories the Census assigns
  a state-level FIPS to. Neither source file carries the pair and no single row can
  establish it, so it is stated in the provider, where the rest of this vendor's US
  knowledge already lives.
- **Row-scoped county validation.** A row whose `county_fips`, `county_fips_all`,
  county-name or `county_weights` columns contradict each other fails the release, naming
  the column and the row. Cross-file agreement is deliberately not checked: it cannot be
  seen from a single row. A `uscities` row naming no county fails; a `uszips` row naming
  none hangs its ZIP off its state directly.
- **A shipped manifest**, `us_simplemaps`, declaring the collection, the three authorities,
  the four ranked area types and both artifacts as operator-supplied cache keys. The files
  are licensed downloads, so an operator places their copies in the cache and replaces each
  artifact's `sha256` and `bytes` with those of the copy they licensed.

## v0.1.0

Initial release: a versioned catalog of named geographic areas, installed into a
host-selected PostgreSQL schema through [EctoEvolver](https://github.com/agoodway/ecto_evolver).

- **Catalog identity** — collections, authorities, area types (ranked), and areas with a
  stable, human-readable `area_key`. Areas carry names (official, alias, mailing,
  abbreviation), external codes, and an optional `retired_at` with a `successor_id`.
- **Releases and membership** — versioned releases with sources, source releases, and
  checksummed artifacts. `put_area_in_release`/`put_boundary` record `release_area`
  membership rows; geometry is an optional attachment to that membership, not a
  condition of it. A collection can set `requires_geometry` to restore the strict
  boundary check for release verification.
- **Boundaries and relations** — partitioned `boundary`/`boundary_part` tables (subdivided
  index geometry for spatial joins), plus `relation` rows that are either measured from
  geometry (`rebuild_relations`, populating `intersection_area_m2`/`parent_coverage`/
  `child_coverage`) or asserted from source data (`put_relation`, leaving those columns
  `NULL`). Both traverse identically.
- **Publication lifecycle** — `verify_release`, `publish_release`, `rollback_publication`,
  and `retire_releases`, guarded by transaction-level advisory locks and a constraint
  trigger that only allows a completed release to be published. Every publish or
  rollback appends a row to the durable `publication_event` table.
- **Reads** — `published_*` views that resolve through the publication pointer, so a
  release swap changes every view's results atomically under MVCC with no refresh step.
  `published_areas` exposes retired areas (with `retired_at`) rather than hiding them.
- **Resolution** — `areas_for_point`, `areas_for_geometry`, `areas_near`, `areas_by_code`
  (scoped to a parent area's descendants via `parent_area_key`/`parent_max_depth`), and
  `search_areas` (trigram-ranked name search), plus `children_of`, `ancestors_of`, and
  `related_areas` for hierarchy traversal. The `resolve` cascade tries containment, code,
  name, and proximity in order against a single JSON input and returns the first
  strategy's matches, with `parent_area_key` scoping the code and name strategies.
- **Import runs** — a durable `import_run` state machine (`begin_or_resume_import`,
  `heartbeat_import`, `advance_import`, `fail_import`) with a heartbeat lease and stale
  reclaim, so a crashed or replaced worker can resume rather than double-run an import.
  `completed` is terminal on both write paths: neither advancing nor failing can move a
  run out of it, so a late error cannot overwrite the outcome of a run that published.
- **Host integration** — `GeoGenius.Preflight` for a startup-time prerequisite check
  (extensions, geometry and jsonb decoding, and schema version), and `mix geo_genius.setup`,
  `mix geo_genius.gen.migration`, `mix geo_genius.check_schema`, and
  `mix geo_genius.uninstall` for install, upgrade, verification, and (opt-in,
  `--yes`-gated) teardown.
- **Elixir read layer** — `GeoGenius` wraps all ten reads in `%GeoGenius.AreaMatch{}`
  structs, and `GeoGenius.Query` composes a catalog read into a host's own Ecto query for
  a single-round-trip join. Requires `geo_postgis`: geometry crosses the boundary as
  `Geo` structs (`centroid` as `%Geo.Point{}`, `areas_for_geometry`'s argument as
  `%Geo.Polygon{}`/`%Geo.MultiPolygon{}`), never as WKT/EWKT text, and the host Repo must
  be configured with a Postgrex types module registering `Geo.PostGIS.Extension`.
- **Manifests** — a reviewed JSON document per release, describing the collection, the
  provider, the authorities its areas are keyed under, the ranked area types, every source
  with its license and attribution, and every artifact with its URL or operator-supplied
  cache key, expected SHA-256, expected byte count, archive members, and whether it is
  required. `GeoGenius.Manifest` validates every field and names the one that was wrong;
  `to_map/1` round-trips, so the manifest stored on the release row rebuilds without
  touching the filesystem. Manifests are searched for under
  `config :geo_genius, :manifest_paths`, with the package's own
  directory last so a host-shipped correction wins. `authorities` is a required, non-empty
  list, because a collection may draw on more than one — a US release keyed partly by the
  Census, partly by the USPS, and partly by a vendor's own identifiers names all three —
  and every authority its areas are keyed under is registered when the release is opened.
- **Artifact acquisition** — a cache checked before any download, so a rerun costs
  nothing and an operator-supplied file is the same lookup as a fetched one. Cache hits
  are hashed on every run, and `record_artifact_observation` in PostgreSQL is the only
  place an expectation meets an observation.
- **Providers** — `GeoGenius.Provider` (`area_types/0`, `required_options/0`,
  `artifacts/1`, `stage/5`, `normalize/2`, `relations/1`) with three implementations:
  `Providers.GeoJSON`, `Providers.CSV`, and `Providers.Shapefile`, the last converting its
  archive through `ogr2ogr`. A host registers its own under
  `config :geo_genius, :providers`.
- **Adapters** — `GeoGenius.Cache` (`Caches.FileSystem`), `GeoGenius.Downloader`
  (`Downloaders.Req`, requiring the optional `req` dependency), `GeoGenius.Command`
  (`Commands.System`, narrowed to `ogr2ogr` by `Pipeline.CommandAllowlist` before a
  provider sees it), and `GeoGenius.Notifier` (`Notifiers.Noop`), each resolved from
  options, then application environment, then the shipped default. A notifier cannot fail
  an import.
- **The import pipeline** — `GeoGenius.Pipeline` walks a claimed run through downloading,
  validating, staging, normalizing, relating, indexing, and verifying, advancing the
  durable run row at each boundary and heartbeating its lease from inside long phases. It
  opens no transaction, drops its staging table on success and failure alike, and records
  every failure durably before returning it.
- **Runner backends** — `GeoGenius.Runner` with `Runners.Task` (the zero-configuration
  default, running each import under a supervised `Task.Supervisor`), `Runners.Inline`
  (the calling process), and `Runners.PgFlow` (available only to a host that has installed
  `pgflow` itself). The backend a run was claimed under is recorded on
  `import_run.runner_backend` and resolves back to a module through
  `GeoGenius.Runner.module_for_backend/1`. Nothing in the library reads it back: run
  cancellation, the feature that would have, is not shipped, and the column stands as the
  durable record of which backend claimed a run.
- **Elixir ingestion API** — `GeoGenius.import/1`, `status/2`, `await/3`, `publish/2`,
  `rollback/2`, and `published_release/2`. Registration is idempotent end to end, and
  importing never publishes unless asked.
- **Operational mix tasks** — `mix geo_genius.import`, `mix geo_genius.publish`,
  `mix geo_genius.rollback`, `mix geo_genius.status`, and `mix geo_genius.sweep_staging`.
  The two that change what hosts see, and the one that drops tables, do nothing without
  `--yes`.
- **Boot-time enqueue** — `GeoGenius.Bootstrap`, an optional child a host places in its
  own supervision tree, disabled unless `config :geo_genius, :bootstrap` sets
  `enabled: true`.
- **New SQL** — `upsert_source`, `upsert_source_release`, `put_artifact`,
  `record_artifact_observation`, `open_release`, `attach_source_release`,
  `staging_table_name`, `create_staging`, `drop_staging`, `analyze_release`, and
  `published_release`, plus the `import_run_status` and `release_artifacts` views.

### Registration

- **`GeoGenius.Registration.register/2`** writes the catalog rows a manifest describes --
  the collection, its authorities and area types, the release, and every source, source
  release and artifact -- and returns the release id. This is steps 2 through 6 of
  `GeoGenius.import/1`, lifted out so a host or a test that claims an import run directly
  registers through the same function the public entry point does, rather than
  reimplementing it. Registration remains idempotent end to end.

### Deliberate deviations from the specification

1. **`GeoGenius.Providers.Shapefile` ships in place of `Providers.Census`.** Nothing in
   it is Census-specific: it unpacks an archive, converts it with `ogr2ogr`, and parses
   the result. A Census collection is a manifest, not a module, and naming the provider
   after one publisher would have implied a second module was needed for the next one.
2. **`GeoGenius.Runners.Inline` ships in place of `Runners.Test`.** It is not a test
   double. It is the backend a host with no PgFlow and no `Task.Supervisor` actually runs
   imports under, and a name saying otherwise would have steered hosts away from the only
   backend available to them.
3. **`Runners.Oban` is not shipped; `Runners.PgFlow` is the only durable backend.** The
   `GeoGenius.Runner` behaviour is the extension point for exactly this case: a host that
   wants an Oban-backed runner implements `name/0`, `available?/0`, and `enqueue/3`
   itself, which is the reason the behaviour exists rather than a fixed backend list.
4. **The library declares a `mod:` application callback**, where the specification says it
   starts no supervision tree of its own. The tree holds at most one child, a
   `Task.Supervisor` registered as `GeoGenius.TaskSupervisor`, and starts nothing at all
   when `config :geo_genius, :task_supervisor` is already set at boot. Without it,
   `Runners.Task` required a host to both configure a supervisor and start it, and
   configuring only the first selected the Task backend and then failed to enqueue; the
   practical default was therefore `Runners.Inline`, which blocks the caller for the
   length of an import. A `Task.Supervisor` carries none of the boot-order risk that rule
   exists to avoid: it needs nothing to start and does no work until a host calls
   `GeoGenius.import/1`. Its *shutdown* is the caveat. `:geo_genius` stops after its host,
   so the library's own supervisor is stopped only once the host's Repo has already gone,
   and an import still running then keeps running against a Repo that is no longer there.
   A host that cares about shutdown ordering sets `config :geo_genius, :task_supervisor`
   to a supervisor it places after its own Repo, which this library cannot arrange from
   the outside. `GeoGenius.Preflight` deliberately does not join this tree.
5. **The provider callback arities are `stage/5`, `normalize/2`, and `relations/1`**,
   where the specification writes `stage/2` and `normalize/1`. A provider needs the
   manifest on every call, and `stage` needs an emit function to hand batches to and an
   adapter list to shell out through. The six callbacks and their responsibilities are
   otherwise unchanged. This is the deviation that matters most to a reader, because
   every host writing its own provider implements these exact signatures.
6. **`Runners.Task` resolves its supervisor from two tiers, not three**, and
   `Runners.Task.available?/1` does not exist. The specification's per-call `opts` tier is
   gone: resolution reads `config :geo_genius, :task_supervisor` and falls back to
   `GeoGenius.TaskSupervisor`, and the behaviour callback is `available?/0`. A per-call
   supervisor would have let one import run under a supervisor a later import knew nothing
   about, while the durable backend it competes with, `Runners.PgFlow`, has no per-call
   equivalent to offer. The visible consequence is in `GeoGenius.Runner.configured/1`:
   `Runners.Task` is selected whenever the config key names anything at all, live or not,
   so a typo'd or not-yet-started supervisor surfaces as a named `enqueue/3` error instead
   of falling through to `Runners.Inline` and blocking the caller for a whole import.
