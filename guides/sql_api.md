# SQL API reference

Every GeoGenius operation is a SQL function or view in the installed schema, called
through the host's own Ecto Repo (`MyApp.Repo.query/2` for a write, or `GeoGenius`'s own
read functions for a resolution or traversal read - see [`reading.md`](reading.md) for
the calling convention, including why a geometry/geography argument binds as a `Geo`
struct rather than WKT/EWKT text). This guide lists every function a host calls directly,
grouped by what it does, with its full parameter list.

A handful of implementation-only functions are not listed here because a host never
calls them directly: `assert_extensions` (run once, at install, by the migration itself),
`classify_relation` and `relation_lock_key` (helpers `rebuild_relations` calls
internally), `partition_lock_key` (the key `open_release`,
`create_release_partitions`, and `drop_release_partitions` serialize on; see
[Concurrent partition DDL](#concurrent-partition-ddl) below), `publication_lock_key`
(the key `publish_release`, `rollback_publication`, and `retire_releases` serialize on,
so two callers cannot interleave a swap of one collection's publication pointer), `publication_release_is_publishable` (a constraint trigger function),
`drop_release_partitions` (called by `retire_releases`, not on its own),
`assert_release_mutable` (the guard every write function below calls to reject a write
against a completed or retired release), `assert_area_in_collection` (the guard the
release-membership and geometry writes call to reject an area from a different
collection), and `area_codes_json` (the helper every function returning `area_match`
calls to build the `codes` field; see below).

Every function is `SECURITY INVOKER` with a pinned `search_path`; read functions are
`STABLE PARALLEL SAFE` and write functions are `VOLATILE`. Five carry no parallel marking:
`release_at`, `staging_table_name`, and the three internal guards
`assert_extensions`, `assert_release_mutable`, and `assert_area_in_collection`. Every function returning rows
(all of Resolution and Traversal below) returns `SETOF area_match`; Lifecycle and Import
functions return a scalar (`uuid`, `jsonb`, `integer`) or `void`.

Across Resolution and Traversal, four parameters repeat with the same meaning and the
same defaults everywhere they appear: `collections` and `types` (`text[] DEFAULT NULL`,
no filter), `target_release_id` (`uuid DEFAULT NULL`, meaning the collection's currently
published release), and `include_retired` (`boolean DEFAULT false`, active areas only).
`max_depth` (on `children_of`/`ancestors_of`) defaults to `1`; `result_limit` (on
`areas_near`/`search_areas`) defaults to `50`.

Every `area_match` row's `codes` field is a `jsonb` object mapping each code type to a
JSON array of the values an area holds under that type, for example
`{"postal": ["30309", "30310"]}`, an area with two postal codes keeps both. It is built
by `area_codes_json`, grouping and aggregating every `area_code` row for the area rather
than picking one.

## Time-scoped release lookup

The read functions above take a `target_release_id`, not a timestamp. `release_at`
bridges the two:

| Function                            | Answers                                                             |
|-------------------------------------|---------------------------------------------------------------------|
| `release_at(collection_key, as_of)` | The release a collection had published at a given moment, or `NULL` |

`release_at("us_counties", "2026-01-15T00:00:00Z")` turns "what did we serve on January
15?" into a `target_release_id` argument for any Resolution or Traversal function above.
It returns `NULL` when the collection had published nothing yet as of `as_of`.

## Resolution

Spatial and non-spatial lookups against the currently published release of a collection
(or an explicit `target_release_id`).

| Function                                                                                                                                        | Answers                                                            |
|-------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------|
| `areas_for_point(lon, lat, collections, types, target_release_id, include_retired)`                                                             | Area containing a point                                            |
| `areas_for_geometry(input_geom, collections, types, target_release_id, include_retired)`                                                        | Areas overlapping a polygon, with coverage percentages             |
| `areas_near(lon, lat, radius_m, collections, types, result_limit, target_release_id, include_retired)`                                          | Areas within a radius, ordered by distance (boundary or centroid)  |
| `areas_by_code(target_code_type, target_code_value, collections, types, target_release_id, include_retired, parent_area_key, parent_max_depth)` | Area with a given external code                                    |
| `search_areas(query, collections, types, result_limit, target_release_id, include_retired)`                                                     | Trigram-ranked name search                                         |
| `resolve(input, collections, types, strategies, target_release_id, include_retired)`                                                            | Cascades containment, code, name, proximity against one JSON input |

A code is unique only within a parent, so `areas_by_code`'s `parent_area_key` scopes the
lookup to that area's descendants and `parent_max_depth` controls how far down it
reaches, defaulting to a direct parent relation.

`resolve`'s `input` is a single `jsonb` object: `lon`/`lat` (together) selects
containment then proximity, `code_type`/`code_value` selects code lookup, `name`
(optionally with `parent_area_key` to scope the search to that area's children) selects
name search. `strategies` (`text[] DEFAULT NULL`) restricts or reorders which of
`containment`, `code`, `name`, `proximity` are attempted; the default order is exactly
that sequence, and the first strategy whose required input is present and whose query
returns at least one row wins.

## Traversal

Hierarchy walks over `relation` rows, measured (`rebuild_relations`) or asserted
(`put_relation`) alike — see [Measured versus asserted relations](installation.md#measured-versus-asserted-relations).

| Function                                                                                              | Answers                                                |
|-------------------------------------------------------------------------------------------------------|--------------------------------------------------------|
| `children_of(parent_area_key, types, classifications, max_depth, target_release_id, include_retired)` | Areas this area contains                               |
| `ancestors_of(child_area_key, types, classifications, max_depth, target_release_id, include_retired)` | Areas that contain this area                           |
| `related_areas(target_area_key, classifications, target_release_id, include_retired)`                 | Areas related to this one, one level, either direction |

`classifications` (`text[] DEFAULT NULL`) filters by `relation_type`
(`contains`/`mostly_contains`/`overlaps`). Raising `max_depth` past `1` is cheap on an
ordinary ranked hierarchy and combinatorially more expensive on a densely
mutually-related one — see
[Traversal depth on dense graphs](installation.md#traversal-depth-on-dense-graphs) for
measured numbers before raising it on a collection where many areas relate to many
others of similar rank.

## Write

Load catalog identity, then release membership and geometry.

| Function                                                                                                     | Answers                                                                                            |
|--------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------|
| `upsert_collection(key, name, description, requires_geometry)`                                               | Create or update a collection                                                                      |
| `upsert_authority(collection_key, key, name)`                                                                | Create or update a naming authority                                                                |
| `upsert_area_type(collection_key, key, rank)`                                                                | Create or update a ranked area type                                                                |
| `upsert_area(collection_key, authority_key, area_type_key, code)`                                            | Create or update an area's identity                                                                |
| `put_area_name(target_area_key, name, kind, locale)`                                                         | Attach a name (official, alias, mailing, abbreviation)                                             |
| `put_area_code(target_area_key, code_type, code_value)`                                                      | Attach an external code                                                                            |
| `upsert_source(collection_key, source_key, provider, license)`                                               | Create or update a source: a provider feed within a collection                                     |
| `upsert_source_release(collection_key, source_key, release_key, source_date, metadata)`                      | Create or update a vintage of a source's data                                                       |
| `put_artifact(target_source_release_id, logical_name, url, operator_supplied, format, expected_sha256, expected_bytes, metadata)` | Record an artifact a source release expects to have fetched                          |
| `record_artifact_observation(target_artifact_id, observed_sha256, observed_bytes)`                           | Record what was actually fetched for an artifact, or raise on a mismatch                            |
| `open_release(collection_key, release_key, manifest, source_date)`                                           | Create or reopen a release for writing, and create its partitions                                   |
| `create_release_partitions(target_release_id)`                                                               | Create the per-release partitions writes below require, for a release row created some other way   |
| `attach_source_release(target_release_id, target_source_release_id)`                                         | Declare that a release draws on a source release's data                                             |
| `put_area_in_release(target_release_id, target_area_key, centroid, data)`                                    | Record release membership; geometry optional                                                       |
| `put_boundary(target_release_id, target_area_key, target_source_release_id, input_geom, simplify_tolerance)` | Attach a polygon; also ensures release membership                                                  |
| `put_relation(target_release_id, parent_area_key, child_area_key, relation_type)`                            | Assert an unmeasured relation from source data                                                     |
| `rebuild_relations(target_release_id)`                                                                       | Derive measured relations from boundary overlap                                                    |

### Concurrent partition DDL

`open_release`, `create_release_partitions`, and `drop_release_partitions` all take a
transaction-level advisory lock on `partition_lock_key()` before they touch anything, so
only one of them builds or drops a release's partitions at a time. This costs nothing that
partition DDL was not already going to cost, because creating or dropping a partition
takes an `AccessExclusiveLock` on the parent and those callers were never going to run
concurrently anyway. What it buys is that they no longer deadlock trying: creating a
partition clones the parent's foreign key to `release`, which needs a
`ShareRowExclusiveLock` on `release`, while the caller that just inserted that release row
holds a `RowExclusiveLock` on it, and two callers doing this at once each hold what the
other needs.

`open_release` takes the lock before its own insert, which is what makes it safe. **A
caller that inserts a `release` row itself and then calls `create_release_partitions` does
not get that protection**: its insert took a `RowExclusiveLock` on `release` outside the
lock, so two such callers running at once can still deadlock with SQLSTATE `40P01`. Take
`pg_advisory_xact_lock(partition_lock_key())` before the insert if you build release rows
by hand, or go through `open_release`, which does it for you.

`upsert_area` and `upsert_area_type` serialize on their own identity for a related reason:
`area` and `area_type` each carry two unique constraints, `ON CONFLICT` can name only one
of them as its arbiter, and a concurrent speculative insert that blocks on the other index
surfaces as a bare `23505` instead of taking the `DO UPDATE` path. Two callers upserting
different area type keys at the same rank do not serialize and still get the rank
violation, which is the constraint doing its job.

`area_key` is unique across the whole catalog, not within a collection. It is composed as
`<authority_key>:<area_type_key>:<code>`, so two collections that draw on the same
authority, name their area types alike, and carry the same code compose the same key, and
the second `upsert_area` fails with a bare `23505` on `area_area_key_uq` naming no
remedy. Global uniqueness is the binding model: an `area_key` is meant to identify one
real place no matter which collection reached it first. Give the two collections distinct
authority keys when they are genuinely describing different places.

`boundary`, `boundary_part`, `relation`, and `release_area` are all partitioned by
`release_id`. `open_release` creates a release's partitions as part of opening it, so a
release created through `open_release` is always ready for `put_area_in_release`,
`put_boundary`, and `put_relation` to write to. `create_release_partitions` stays
available directly for a release row created some other way; omitting it before writing
to such a release fails with a `no partition of relation ... found for row` error, not a
silent no-op. `put_boundary` calls `put_area_in_release` internally, so a polygon-first
caller never needs to call both.

A published release is immutable. `put_area_in_release`, `put_boundary`, `put_relation`,
`rebuild_relations`, and `attach_source_release` all call `assert_release_mutable` first
and raise SQLSTATE `55000` when the target release has status `completed` (the status
`publish_release` sets) or has a non-null `retired_at`. `attach_source_release` is in that
list because provenance is part of what a release publishes: `release_artifacts` joins
through `release_source`, so attaching a source release after publication would change
what readers of a published release see. Build a new release and publish it to change what
hosts see; there is no way to edit a published release in place.

Every write that targets an area also calls `assert_area_in_collection`, which raises
SQLSTATE `23503` when the area's `collection_id` does not match the release's. `put_boundary`
additionally requires that `target_source_release_id` be one the release has already
declared through `release_source` (see [Declaring provenance](#declaring-provenance)
below); an undeclared source release also raises SQLSTATE `23503`. `put_boundary` rejects
a geometry whose coordinates fall outside the SRID 4326 domain (longitude beyond ±180,
latitude beyond ±90) with SQLSTATE `22023`.

### Declaring provenance

`put_boundary`'s `target_source_release_id` argument is not free-form: the release must
declare it first by calling `attach_source_release`, which links a `release` to a
`source_release` it draws data from. `attach_source_release` raises SQLSTATE `23503` if
either id does not exist, or if the source release belongs to a different collection than
the release. `verify_release` also fails a release that declares no source releases at
all, so attaching at least one is mandatory before publishing, even for a release with no
boundaries. The `source` and `source_release` rows themselves come from `upsert_source`
and `upsert_source_release`. `put_artifact` records what a source release's manifest
declares: the logical name, format, expected sha256, and expected byte count, all of them
required. `record_artifact_observation` records what the import actually fetched and is
the call that compares the two, raising SQLSTATE `23514` when the observed digest or byte
count differs from the declared one.

## Lifecycle

Move a release from staged to published, or roll one back.

| Function                                | Answers                                                             |
|-----------------------------------------|---------------------------------------------------------------------|
| `verify_release(target_release_id)`     | Check whether a release is ready to publish; returns a jsonb report |
| `publish_release(target_release_id)`    | Verify, then atomically publish a release; returns the collection's id |
| `rollback_publication(collection_key)`  | Swap the publication pointer to the previous release                |
| `published_release(collection_key)`     | The release a collection publishes right now, or `NULL`             |
| `retire_releases(collection_key, keep)` | Drop older completed releases' partitions beyond a retention count  |

`published_release` is the pointer every read resolves through when it is given no
`target_release_id`, exposed as a function so a caller can name the same release across
several calls and know they all read one release rather than racing a publication that
lands between them. It returns `NULL` for a collection that has published nothing and for
a collection key the catalog does not carry, for the same reason `release_at` does: from
the caller's side there is no release to pin either way.

Publishing the release that is already published is a no-op: it appends no
`publication_event` row and leaves `previous_release_id` untouched, so
`rollback_publication` still reaches the last release that was actually swapped away
from, not the release that is currently published.

`retire_releases` drops a retired release's partitions (`boundary`, `boundary_part`,
`relation`, `release_area`) to reclaim storage, and sets `release.retired_at`, but keeps
the `release` row itself - `publication_event` and `import_run` reference it, and
deleting the row would cascade both away, tearing holes in the sequenced event log hosts
poll and erasing import history. Re-running `retire_releases` does not re-retire a
release that already has `retired_at` set, and it never retires the currently published
release.

## Import

A durable state machine for a long-running import, with a heartbeat lease so a crashed
or replaced worker can resume rather than double-run.

| Function                                                                        | Answers                                         |
|---------------------------------------------------------------------------------|-------------------------------------------------|
| `begin_or_resume_import(target_release_id, owner, runner_backend, stale_after)` | Claim or resume a durable import run            |
| `heartbeat_import(target_run_id, progress_patch)`                               | Extend an import run's lease and merge progress |
| `advance_import(target_run_id, next_status, metrics_patch)`                     | Move an import run to its next state            |
| `fail_import(target_run_id, error_detail)`                                      | Mark an import run failed and release its lease; refuses a completed run |

`stale_after` defaults to `interval '15 minutes'` and must be non-negative; a negative
interval raises SQLSTATE `22023` rather than being accepted and making every existing
lease look retroactively stale. `begin_or_resume_import` called again by the same
`owner` for a still-live run returns the existing run id and extends its lease rather
than starting a second attempt; called by a different owner while the lease is live, it
raises; called after the lease has gone stale, it marks the abandoned run failed and
starts a new attempt.

`advance_import` refuses to move a run out of a terminal status: once a run is
`completed` or `failed`, advancing it to any other status raises SQLSTATE `55000`.
Start a new attempt with `begin_or_resume_import` instead of trying to resurrect one.

`fail_import` carries the same guard on the one transition that would lose data:
failing a `completed` run raises SQLSTATE `55000`. Failing a run that already
failed is idempotent, so a caller recording the same failure twice does not
raise. Nothing else is refused -- a run stuck in any working phase can always be
failed, which is what an operator reclaiming one needs.

### Staging and analysis

A provider's parsed rows land in a table of their own, one per run, before anything
reaches the catalog. The table is `UNLOGGED`: its content is rebuilt from a checksummed
artifact after any restart, and skipping WAL is most of the reason staging is a separate
phase at all.

| Function                              | Answers                                                        |
|---------------------------------------|-----------------------------------------------------------------|
| `staging_table_name(target_run_id)`   | The table name a run's staged rows live under                   |
| `create_staging(target_run_id)`       | Create that table if it is not there, returning its name        |
| `drop_staging(target_run_id)`         | Drop it, whether or not the run ever staged anything            |
| `analyze_release(target_release_id)`  | `ANALYZE` the release's own partitions after its rows are in    |

The name is derived from the run's uuid rather than supplied, so it is `[0-9a-f_]+` by
construction and no caller-supplied text ever reaches an identifier. The staged table
carries `artifact`, `payload` (jsonb), and `geom`; `create_staging` and `drop_staging`
are both safe to call twice, which is what lets a resumed run re-stage and a failed run
clean up without first asking whether it got that far.

`analyze_release` runs against the release's own partitions rather than the whole table,
so a freshly loaded release has statistics before the first read plans against it.
`GeoGenius.Pipeline` calls it as the `"indexing"` phase, between rebuilding relations and
verifying.

## Views

Two views assemble a join the import side would otherwise repeat at every call site.
Neither takes an argument; both are ordinary views a host can `SELECT` from, join
against, or read through `GeoGenius.Catalog`.

| View                 | One row per                                                  |
|----------------------|---------------------------------------------------------------|
| `import_run_status`  | Import run, with its collection, release, lease, and metrics |
| `release_artifacts`  | Artifact a release composes, with the source release it came from |

`import_run_status` joins `import_run` to `release` and `collection` and left-joins the
lease, projecting `run_id`, `release_id`, `collection_key`, `release_key`, `attempt`,
`status`, `owner`, `runner_backend`, `started_at`, `heartbeat_at`, `completed_at`,
`error`, `stage_metrics`, and `progress`. A terminal run has no lease row, so
`heartbeat_at` falls back to the run's own column and `progress` reads as `{}` rather
than `NULL`. This is what `GeoGenius.status/2` reads, and what
`%GeoGenius.ImportRun{}`'s fields are named for.

`release_artifacts` joins `release_source` through `source_release` and `source` to
`artifact`, projecting `release_id`, `source_release_id`, `source_key`,
`source_release_key`, `collection_key`, `artifact_id`, `logical_name`, `url`,
`operator_supplied`, `format`, `expected_sha256`, `expected_bytes`, `observed_sha256`,
`observed_bytes`, `validated_at`, and `metadata`. Every join is an inner one, so an
artifact belonging to a source release the release has not declared through
`attach_source_release` does not appear here at all: declaring provenance is what makes
an artifact part of a release.

The `published_*` views are the read side and are listed in the
[README](../README.md#public-api); `release_areas` is their release-scoped base.

## Error contracts

A write that must reference a row reports a missing row in one of three ways, and which
one depends on how the function looks the row up. Most raise SQLSTATE `23503`, whether the
row is absent or present but belonging to a different collection; those two shapes read
differently and mean different things, so they are listed apart. The two exceptions,
`rebuild_relations` and the `SELECT ... INTO STRICT` lookups, follow the `23503` tables.

A row the call names does not exist:

| Function                       | Message                                        |
|--------------------------------|-------------------------------------------------|
| `upsert_authority`             | `collection % does not exist`                   |
| `upsert_area_type`             | `collection % does not exist`                   |
| `upsert_source`                | `collection % does not exist`                   |
| `open_release`                 | `collection % does not exist`                   |
| `retire_releases`              | `collection % does not exist`                   |
| `upsert_source_release`        | `source % does not exist in collection %`       |
| `put_artifact`                 | `source release % does not exist`               |
| `record_artifact_observation`  | `artifact % does not exist`                     |
| `create_release_partitions`    | `release % does not exist`                      |
| `verify_release`               | `release % does not exist`                      |
| `attach_source_release`        | `release % does not exist`, `source release % does not exist` |
| `put_relation`                 | `area % is not a member of release %` (parent, then child) |
| `advance_import`               | `import run % does not exist`                   |
| `fail_import`                  | `import run % does not exist`                   |
| `create_staging`               | `import run % does not exist`                   |
| `heartbeat_import`             | `import run % has no active lease`              |

The row exists but belongs somewhere else:

| Function                                          | Message                                                         |
|---------------------------------------------------|------------------------------------------------------------------|
| `put_area_in_release`, `put_boundary` (via `assert_area_in_collection`) | `area % belongs to collection %, but release % belongs to collection %` |
| `attach_source_release`                           | `source release % belongs to collection %, but release % belongs to collection %` |
| `put_boundary`                                    | `source release % is not declared by release %`                  |

Two families depart from `23503`, and a caller matching on SQLSTATE has to expect them.

`rebuild_relations` raises `22023` for `release % does not exist`, where every sibling
carrying that same message raises `23503`. It is the one outlier in the catalogue.

The lookups written as `SELECT ... INTO STRICT` raise PL/pgSQL's own `P0002`
(`no_data_found`) with the message `query returned no rows`, naming neither the function
nor the value that was not found. Every site, and what makes it fire:

| Function                                          | Missing row that raises `P0002`                     |
|---------------------------------------------------|------------------------------------------------------|
| `upsert_area`                                     | an unknown `collection_key`, `authority_key`, or `area_type_key` |
| `put_area_name`, `put_area_code`                  | an unknown `target_area_key`                         |
| `put_relation`                                    | an unknown `parent_area_key` or `child_area_key`     |
| `put_boundary`, `put_area_in_release`             | an unknown `target_area_key`                         |
| `assert_release_mutable`                          | an unknown `target_release_id`, which is how `put_boundary`, `put_area_in_release`, `put_relation`, and `rebuild_relations` report one |
| `assert_area_in_collection`                       | a release or area row deleted between the caller's lookup and this guard |

`verify_release` and `publish_release` each hold one `INTO STRICT` lookup as well, but
both check the release exists first and raise `23503`, so neither reaches `P0002` for a
release id that names nothing.

A provider emitting an unknown `authority_key` is the reachable ingestion path into this
family: `upsert_area` fails with a bare `P0002` rather than a message naming the key.

Neither `23503` shape is expressible as a foreign key. An area and a release each reference their
own collection independently, and a source release does the same, so nothing in the
schema can say "these two must agree"; the write API says it instead, and
`verify_release` re-checks the membership rule at publication time rather than trusting
the writer.

`23503` is not the only code these functions raise. `55000` is a release that can no
longer be written to or a run that has already reached a terminal status, and `55006` is a
release whose import is already claimed by another owner.

`23514` has four producers, and the two most reachable are not the artifact check:
`publish_release` raises it for a release that fails verification, `rollback_publication`
for a collection with no previous release to roll back to, `record_artifact_observation`
for an artifact whose observed bytes do not match what the manifest expected, and the
publication trigger for a publication row pointed at a release that is not a completed
release of that collection.

`22004` is a required argument left null, asserted for every guarded argument of every
guarded function in `test/pgtap/invariants/test_required_arguments.sql`.
`create_staging` and `drop_staging` are outside that set, because neither guards its own
argument: `create_staging(NULL)` reaches its existence check first and raises `23503`
naming a run that does not exist, and `drop_staging(NULL)` reaches `staging_table_name`,
which raises the `22004` on its behalf.

`22023` is an argument outside its domain. It covers a geometry that is not SRID
4326, not a polygon type, or empty; a `manifest` or a `resolve` input that is not a JSON
object; an unknown relation type; an unknown import phase; a negative `stale_after`; a
`keep` below one; a `max_depth` below one; a longitude or latitude out of range; a
non-positive radius; `lon` supplied without `lat`; and the `rebuild_relations` outlier
above.

See [`installation.md`](installation.md) for prefixes, upgrades, and the four notes on
retired areas, measured versus asserted relations, traversal depth, and reacting to
publication. See the [README](../README.md) for the `published_*` views table — the
read-side contract most hosts join directly rather than calling a resolution function.
