# Changelog

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
  provider, the ranked area types, every source with its license and attribution, and
  every artifact with its URL or operator-supplied cache key, expected SHA-256, expected
  byte count, archive members, and whether it is required. `GeoGenius.Manifest` validates
  every field and names the one that was wrong; `to_map/1` round-trips, so the manifest
  stored on the release row rebuilds without touching the filesystem. Manifests are
  searched for under `config :geo_genius, :manifest_paths`, with the package's own
  directory last so a host-shipped correction wins.
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
