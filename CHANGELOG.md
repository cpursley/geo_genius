# Changelog

## Unreleased

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
