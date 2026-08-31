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
collection), `assert_seed_keys` (the guard every plural read calls to reject a null seed
array or a null element inside one), `assert_write_arrays` and `assert_resolved` (the two
guards every [set write](#set-writes) calls, to reject arrays that disagree in length or
carry a null where the column is required, and to refuse a key that resolves to nothing),
`area_lock_key` and `lock_areas` (the single definition of the lock one area serializes on,
and the loop that takes a batch's locks in one order -- see
[One lock order for the whole write path](#one-lock-order-for-the-whole-write-path)),
and `area_codes_json` (the helper every function returning `area_match` calls to build the
`codes` field; see below).

Every function is `SECURITY INVOKER` with a pinned `search_path`; read functions are
`STABLE PARALLEL SAFE` and write functions are `VOLATILE`. Five carry no parallel marking:
`release_at`, `staging_table_name`, and the three internal guards
`assert_extensions`, `assert_release_mutable`, and `assert_area_in_collection`. Every function returning rows
(all of Resolution and Traversal below) returns `SETOF area_match`, except the four
[set-keyed reads](#set-keyed-reads), which return `SETOF seeded_area_match`; Lifecycle and
Import functions return a scalar (`uuid`, `jsonb`, `integer`) or `void`.

Across Resolution and Traversal, four parameters repeat with the same meaning and the
same defaults everywhere they appear: `collections` and `types` (`text[] DEFAULT NULL`,
no filter), `target_release_id` (`uuid DEFAULT NULL`, meaning the collection's currently
published release), and `include_retired` (`boolean DEFAULT false`, active areas only).
`max_depth` (on `children_of`/`ancestors_of`) defaults to `1`; `result_limit` (on
`areas_near`/`search_areas`) defaults to `50`, and an explicit `NULL` returns every
row instead -- which is how a caller that narrows the result afterwards asks for the
whole ranked set rather than naming a number that stands in for one.

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

## Set-keyed reads

Four reads above answer for exactly one seed, so answering for a list of seeds costs one
call per element. Each has a plural sibling taking an array where the singular takes a
scalar:

| Function                                                                                                                                            | Answers                                              |
|-------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------|
| `children_of_many(parent_area_keys, types, classifications, max_depth, target_release_id, include_retired)`                                          | Areas each of these areas contains                   |
| `ancestors_of_many(child_area_keys, types, classifications, max_depth, target_release_id, include_retired)`                                          | Areas that contain each of these areas               |
| `related_areas_many(target_area_keys, classifications, target_release_id, include_retired)`                                                          | Areas related to each of these, one level, either direction |
| `areas_by_code_many(target_code_type, target_code_values, collections, types, target_release_id, include_retired, parent_area_key, parent_max_depth)` | Areas carrying each of these code values             |

Every parameter after the seed array keeps the singular's meaning and default.

They return `SETOF seeded_area_match`, which is `seed_key text` followed by `area_match`'s
sixteen columns in `area_match`'s order. A plural result mixes rows from every seed, so the
seed has to travel with each row; a composite type cannot be declared as "`area_match` plus
one column", and nesting `area_match` inside a result column would force every client to
decode a nested composite, so the columns are repeated and
`test/pgtap/schema/test_install.sql` pins the two lists against each other. The column is
`seed_key` rather than `seed_area_key` because three of the four are seeded by an area key
and `areas_by_code_many` is seeded by a code value.

Semantics, all four:

- The result for `ARRAY[a, b]` is the singular result for `a` followed by the singular
  result for `b`, in the array's order -- not the seeds' sort order.
- A seed that matched nothing contributes no rows, rather than one row of `NULL`s.
- An empty array returns zero rows.
- A `NULL` array raises SQLSTATE `22004`, as a `NULL` singular seed does, and so does a
  `NULL` element inside the array: a skipped element would lose one seed out of thousands
  with no error to show for it.

Each delegates to the singular read once per seed rather than reimplementing it, the way
`resolve` delegates to each strategy. What that removes is the round trip, not the per-seed
lookup. Measured over a 4,000-area release with 1,000 seeds: 1,000 `children_of` calls from
a client on loopback took 445ms against 52ms for one `children_of_many` call, while the same
work run entirely inside the database took 51ms against 37ms. A caller that needs to join or
aggregate against catalog areas wants `GeoGenius.Query`'s composable, view-backed path
instead: these are `SETOF` plpgsql functions and the planner cannot push a predicate into
either shape.

## Write

Load catalog identity, then release membership and geometry.

| Function                                                                                                     | Answers                                                                                            |
|--------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------|
| `upsert_collection(key, name, description, requires_geometry)`                                               | Create or update a collection                                                                      |
| `upsert_authority(collection_key, key, name)`                                                                | Create or update a naming authority                                                                |
| `upsert_area_type(collection_key, key, rank)`                                                                | Create or update a ranked area type                                                                |
| `upsert_area(collection_key, authority_key, area_type_key, code)`                                            | Create or update an area's identity                                                                |
| `upsert_area_many(collection_key, authority_keys, area_type_keys, codes)`                                    | Create or update a batch of areas, returning their ids in the caller's order                       |
| `put_area_name(target_area_key, name, kind, locale)`                                                         | Attach a name (official, alias, mailing, abbreviation)                                             |
| `put_area_name_many(target_area_keys, names, kinds, locales)`                                                | Attach a batch of names, returning their ids in the caller's order                                 |
| `put_area_code(target_area_key, code_type, code_value)`                                                      | Attach an external code                                                                            |
| `put_area_code_many(target_area_keys, code_types, code_values)`                                              | Attach a batch of external codes, returning their ids in the caller's order                        |
| `upsert_source(collection_key, source_key, provider, license)`                                               | Create or update a source: a provider feed within a collection                                     |
| `upsert_source_release(collection_key, source_key, release_key, source_date, metadata)`                      | Create or update a vintage of a source's data                                                       |
| `put_artifact(target_source_release_id, logical_name, url, operator_supplied, format, expected_sha256, expected_bytes, metadata)` | Record an artifact a source release expects to have fetched                          |
| `record_artifact_observation(target_artifact_id, observed_sha256, observed_bytes)`                           | Record what was actually fetched for an artifact, or raise on a mismatch                            |
| `open_release(collection_key, release_key, manifest, source_date)`                                           | Create or reopen a release for writing, and create its partitions                                   |
| `create_release_partitions(target_release_id)`                                                               | Create the per-release partitions writes below require, for a release row created some other way   |
| `attach_source_release(target_release_id, target_source_release_id)`                                         | Declare that a release draws on a source release's data                                             |
| `put_area_in_release(target_release_id, target_area_key, centroid, data)`                                    | Record release membership; geometry optional                                                       |
| `put_area_in_release_many(target_release_id, target_area_keys, centroids, data)`                             | Record a batch of release memberships                                                              |
| `put_boundary(target_release_id, target_area_key, target_source_release_id, input_geom, simplify_tolerance)` | Attach a polygon; also ensures release membership                                                  |
| `put_boundaries(target_release_id, target_area_keys, target_source_release_ids, input_geometries, display_tiers, source_properties)` | Attach a batch of polygons; also ensures release membership                         |
| `put_relation(target_release_id, parent_area_key, child_area_key, relation_type)`                            | Assert an unmeasured relation from source data                                                     |
| `put_relation_many(target_release_id, parent_area_keys, child_area_keys, relation_types)`                    | Assert a batch of unmeasured relations                                                             |
| `rebuild_relations(target_release_id)`                                                                       | Derive measured relations from boundary overlap                                                    |

### Set writes

Six of the writes above come in a plural form taking one array per column, with element
_n_ of every array describing row _n_. The scalar form is the plural form called with
one-element arrays, so there is one implementation of what each write means, and a caller
choosing between them is choosing only how many round trips to spend.

They exist because an import writes in bulk and the round trips dominate. A source that
denormalises a hierarchy describes the same county in every city row of that county, so a
page of staged rows names far fewer distinct areas than it has rows, and one statement per
area per column spends a round trip on every repeat. Measured on the US SimpleMaps import
(150,622 staged rows, 153,917 areas, 466,262 area writes): the normalizing phase costs
2,449 statements and 39.6 s written as sets, against 1,755,328 statements and 994.8 s
written one area at a time.
`put_boundaries` validates and repairs the accepted geometries, replaces each area's
boundary and subdivided parts, and recomputes its centroid from what it stored. The
Elixir `put_boundary/4` API is a one-element plural call when its
`simplify_tolerance` is zero or omitted. A nonzero tolerance retains the original
singular SQL path and its display-geometry simplification behavior. The plural SQL
takes an explicit `display_tier` and `source_properties` per boundary instead.

Before touching a boundary row, both boundary calls acquire the collection's publication
lock and then recheck release mutability. Publication acquires that same lock before it
verifies a release. A writer that waited for publication therefore sees the completed
release and fails, while a publisher that waited for a writer verifies the writer's
committed result instead of an earlier snapshot. The plural call additionally upserts
every accepted `release_area` row in area-id order, so overlapping batches take membership
locks deterministically before either path locks `boundary` or `boundary_part`. Canonical
repaired geometry is materialized once and reused for centroid, boundary, and subdivision
writes.

Four rules govern what a batch means, and all four are things a naive batching would get
wrong:

- **Arrays must agree in length, and may not carry a null where the column is
  required.** `unnest` pads a short array with nulls rather than failing, so a batch
  assembled from two sources of different lengths would write rows the caller never
  described. Mismatched lengths raise `22023`; a null in a required column raises `22004`.
  The optional columns are `put_area_name_many`'s `locales`, and
  `put_area_in_release_many`'s `centroids` and `data`.
- **A key that resolves to nothing raises**, with SQLSTATE `P0002` and a message naming the
  key. The plural forms resolve their keys by joining, and a join alone would drop the
  unknown key's row and report success.
- **Repeats within one batch are deduplicated on the constraint key.** `ON CONFLICT DO
  UPDATE` raises `21000` when one statement presents the same conflict key twice, and a
  batch legitimately repeats areas.
- **Where a write is last-write-wins, the last occurrence in the arrays is the one that
  wins.** That is release membership (`put_area_in_release_many` overwrites `centroid` and
  `data`), boundaries (`put_boundaries` keeps the last row for an `area_key`), and
  relations (`put_relation_many` overwrites `relation_type`), matching what a loop of
  scalar calls in the same order would leave. Names and codes accumulate instead, so
  their deduplication changes nothing but the statement's legality.

### One lock order for the whole write path

A plural write locks many rows per statement where the scalar beside it locks one, so two
of them running at once can only avoid a cycle by agreeing on an order -- and the agreement
has to hold **between** functions, not just inside each one. Two functions that each sorted
their own way would deadlock over any pair of rows they share, which is reachable in
ordinary use: import leases are scoped to a release, so two releases of one collection
normalize at the same time, and the normalizing phase issues an area upsert and a name
write for every page.

Two things enforce it, and each covers the other:

- **`lock_areas`** takes one `pg_advisory_xact_lock` per distinct area a batch is about to
  touch, **ascending by lock key**, before the batch touches any row. The key comes from
  `area_lock_key(collection_id, composed_key)`, the single definition of what an area
  serializes on, so a batch and a scalar `upsert_area` of the same area take the same lock.
  Both `upsert_area_many` and `put_area_name_many` go through it. Because every lock is
  taken before any row is written, two batches sharing an area can never both reach their
  row writes.
- **Every insert walks its own rows in constraint-key order**, and where two functions
  write the same table they use the same key. `upsert_area_many` inserts in `area_key`
  order and `put_area_name_many` pre-locks the `area` rows in `area_key` order, so the two
  agree even for a writer that skips the advisory lock.

`put_area_name_many` pre-locks at all because writing names fires the `area_name` statement
trigger, which updates `area.official_name` for every area the insert touched: holding
those rows first also stops the trigger computing a name from a set another batch has not
finished writing.

One consequence worth knowing: a batch holds one advisory lock per distinct area for the
length of its statement, so the batch size a caller chooses is what bounds its share of the
lock table (`max_locks_per_transaction`).

`put_area_code_many`, `put_area_in_release_many` and `put_relation_many` take no advisory
lock. They write `area_code`, `release_area` and `relation`, and reach `area` only through
their foreign keys, which take `FOR KEY SHARE` -- compatible with the `FOR NO KEY UPDATE`
the two functions above take, so no cycle can form against them. Each still orders its own
insert on its own conflict key, so two batches of the same kind agree.

None of this holds a lock across two calls: every function here is one statement, and a
caller that wraps several of them in one transaction is choosing its own lock ordering.

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
`put_boundary`, `put_boundaries`, and `put_relation` to write to. `create_release_partitions` stays
available directly for a release row created some other way; omitting it before writing
to such a release fails with a `no partition of relation ... found for row` error, not a
silent no-op. Both boundary write forms ensure release membership, so a polygon-first
caller never needs to call both.

A published release is immutable. `put_area_in_release`, `put_boundary`, `put_boundaries`, `put_relation`,
`rebuild_relations`, and `attach_source_release` all call `assert_release_mutable` first
and raise SQLSTATE `55000` when the target release has status `completed` (the status
`publish_release` sets) or has a non-null `retired_at`. `attach_source_release` is in that
list because provenance is part of what a release publishes: `release_artifacts` joins
through `release_source`, so attaching a source release after publication would change
what readers of a published release see. Build a new release and publish it to change what
hosts see; there is no way to edit a published release in place.

Every write that targets an area also calls `assert_area_in_collection`, which raises
SQLSTATE `23503` when the area's `collection_id` does not match the release's. The boundary writes
additionally require that each source release id be one the release has already
declared through `release_source` (see [Declaring provenance](#declaring-provenance)
below); an undeclared source release also raises SQLSTATE `23503`. Both boundary writes reject
a geometry whose coordinates fall outside the SRID 4326 domain (longitude beyond ±180,
latitude beyond ±90) with SQLSTATE `22023`.

### Declaring provenance

The boundary writes' source release ids are not free-form: the release must
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

Both boundary calls also follow each accepted source release through `source_release` to
`source` and independently check its collection. This is intentionally redundant with
`attach_source_release`: `release_source` is directly writable, and its foreign keys cannot
express that the release and source belong to the same collection.

## Lifecycle

Move a release from staged to published, or roll one back.

| Function                                | Answers                                                             |
|-----------------------------------------|---------------------------------------------------------------------|
| `verify_release(target_release_id)`     | Check whether a release is ready to publish; returns a jsonb report |
| `publish_release(target_release_id)`    | Lock, verify, then atomically publish a release; returns the collection's id |
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

Publication and boundary writes serialize on the collection's publication advisory lock.
`publish_release` takes that lock before `verify_release`; each boundary writer takes it
before `assert_release_mutable`. This common order closes both race directions: neither a
write can commit after publication nor a publisher can accept verification performed before
a waiting writer committed.

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
are both safe to call twice, which is what lets a caller drop and recreate the table
without first asking whether the run ever got that far.

`create_staging` keeps whatever rows are already in the table -- it is `CREATE TABLE IF
NOT EXISTS` and nothing more. A caller staging a run that may already have been staged
once calls `drop_staging` first, so the pass starts from an empty table rather than
appending to an interrupted attempt's rows. `GeoGenius.Staging.reset/2` is that pair, and
what `GeoGenius.Pipeline` calls.

`analyze_release` runs against the release's own partitions rather than the whole table,
so a freshly loaded release has statistics before the first read plans against it.
`GeoGenius.Pipeline` calls it as the `"indexing"` phase, between rebuilding relations and
verifying.

## Views

Every view here is an ordinary view a host can `SELECT` from and join against; none takes
an argument. Two of them assemble a join the import side would otherwise repeat at every
call site, and are read through `GeoGenius.Catalog`.

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

### Published read views

The read views come in pairs. Each `release_*` base carries every release, published or
not, and stamps `release_id` on every row. Each `published_*` view is that base joined to
the publication pointer and nothing else, so none of them takes a release argument and a
pointer swap changes what all of them show at once, under MVCC, with no refresh step. The
Resolution and Traversal functions above query the bases, so a non-null
`target_release_id` reaches a release that is not the published one; `GeoGenius.Published`
does the same with its `:release_id` option.

A pair projects identical columns in identical order, so the same query shape works either
side of publication.

| Pair                                                | Columns                                                                                                                                          |
|-----------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------|
| `release_areas` / `published_areas`                 | `collection_key`, `release_id`, `area_id`, `area_key`, `authority`, `area_type`, `type_rank`, `name`, `centroid`, `attributes`, `retired_at`      |
| `release_area_codes` / `published_area_codes`       | `collection_key`, `release_id`, `area_key`, `area_id`, `code_type`, `code_value`                                                                  |
| `release_area_names` / `published_area_names`       | `collection_key`, `release_id`, `area_key`, `area_id`, `name`, `kind`, `locale`                                                                   |
| `release_relations` / `published_area_relations`    | `collection_key`, `release_id`, `parent_area_id`, `parent_area_key`, `child_area_id`, `child_area_key`, `relation_type`, `intersection_area_m2`, `parent_coverage`, `child_coverage` |
| `published_boundaries`                              | `collection_key`, `release_id`, `area_id`, `area_key`, `display_tier`, `geom`, `display_geom`, `valid_from`, `valid_to`, `source_properties`      |

`published_areas` does not hide retired areas; `retired_at` is projected so a caller
decides. It is the only view that projects it at all, because retirement is a property of
an area rather than of a code, a name, or an edge between two areas. A caller filtering
retired areas out of codes, names, or relations joins the matching areas view on
`area_id` and `release_id` and filters there.

Codes and names hang off the area rather than off a release, and an area belongs to as
many releases as carry it, so `release_area_codes` and `release_area_names` yield one row
per release carrying the area. `release_id` is what tells those rows apart, and it is the
second half of any join back to an areas view; joining on `area_id` alone would pair a
code of one release with an area of another.
`parent_coverage` and `child_coverage` on `published_area_relations` are ratios from 0 to
1, not the 0-to-100 percentages `area_match` reports.

### Choosing a read API

Three ways to read the same catalog, and the choice is not a matter of taste:

| Path                                            | Reads through                          | Use it for                                                                                       |
|-------------------------------------------------|----------------------------------------|---------------------------------------------------------------------------------------------------|
| `GeoGenius`'s struct-returning functions        | the `SETOF` functions, one call each   | one area, one answer, `%GeoGenius.AreaMatch{}` back; a per-call `:prefix`; telemetry spans          |
| `GeoGenius.Query`                               | the same `SETOF` functions, as a query | `:max_depth` walks, trigram `search_areas`                                                          |
| `GeoGenius.Published`                           | the read views, as Ecto schemas        | joins, aggregates, set-keyed reads, and anything needing `release_id` or any other dropped column |

A plpgsql `SETOF` function is an optimizer barrier: PostgreSQL cannot push a predicate, a
join qualifier, or a `LIMIT` inside one, so the whole set materialises before the caller's
own `WHERE` runs. Both function-backed paths pay that, and both project five of
`area_match`'s sixteen columns. Counting host rows per area through
`GeoGenius.Query.children_of/2` and through `GeoGenius.Published.children_of/2` returns
the same rows, but only the second plans as an ordinary join, and only the second can join
a host projection table keyed `(release_id, area_key)` -- `release_id` never reaches the
function-backed result at all.

`GeoGenius.Published` exposes every column of `published_areas`,
`published_area_codes`, `published_area_names` and `published_area_relations` as a
read-only Ecto schema, takes `[String.t()]` where the function-backed API takes one
`String.t()`, and names every source with an Ecto binding (`:area`, `:relation`, `:code`,
`:name`) so a caller composes further without counting positions. Its `:release_id`
option swaps every source in the query onto the matching `release_*` base, so an
unpublished release reads through it too. It has no view-backed equivalent for spatial
resolution, name search, or a multi-hop walk; those stay with the functions above. See
[`reading.md`](reading.md#geogeniuspublished) for worked examples.

## Indexing your own attribute keys

`release_area.data` -- `attributes` on the `release_areas` and `published_areas` views and
on `%GeoGenius.AreaMatch{}` -- holds whatever a provider put there. GeoGenius ships three
indexes on `release_area`: the `(release_id, area_id)` primary key, `(area_id, release_id)`
for the reads that arrive from an area with no release predicate, and a gist on `centroid`.
It ships none on `data`, and that is deliberate rather than an oversight:
`test/pgtap/catalog/test_partition_index_propagation.sql` asserts the shipped index set so
one cannot be added by accident.

No installed function issues a containment, key-existence, or jsonpath predicate against
`data`, and none orders by a value extracted from it -- every read carries the column
through as a projection. An index here would be write cost on every import with no read to
pay for it. The keys are also vendor-defined: a library that stays country- and
vendor-agnostic cannot know which of them a host ranks or filters on.

A host that does filter or rank on one adds its own, on the **partitioned parent**:

```sql
-- Containment and key existence: attributes @> '{"lsad": "county"}', jsonpath.
CREATE INDEX my_app_release_area_attributes_idx
  ON geo_genius.release_area USING gin (data jsonb_path_ops);

-- Ranking on one extracted scalar: ORDER BY (data->>'population')::numeric DESC NULLS LAST.
CREATE INDEX my_app_release_area_population_idx
  ON geo_genius.release_area (((data->>'population')::numeric) DESC NULLS LAST);
```

The two are not interchangeable. GIN serves containment and key existence and cannot serve
an ordered read at all: over a 31,000-row partition, a top-50 ranking query with only the
GIN index in place still read all 31,000 rows through a sequential scan and a top-N sort
(567 buffers, 5.2ms), and dropped to an index scan of 52 buffers and 0.2ms once the btree
expression index existed. In the other direction the selective containment count went from
1,134 buffers and 5.0ms to 14 buffers and 0.1ms once the GIN index existed, which the
btree cannot do.

**The btree's ordering has to match the query's.** A default (ascending, nulls last) btree
does not serve `ORDER BY expr DESC NULLS LAST` when any row is missing the key -- measured
at 371 buffers and 5.1ms with a plain index against 51 buffers and 0.09ms with a
`DESC NULLS LAST` one. Declare the index the way the `ORDER BY` reads.

Neither index is free on the write side: over a 31,000-row bulk insert the GIN index cost
roughly 20% more time, and it occupied 1.8MB against an 11MB partition. Add one because a
query needs it, not in case one might.

### Reaching partitions from later imports

`release_area` is partitioned by `release_id`, and `create_release_partitions` builds each
release's partition with `CREATE TABLE ... PARTITION OF`. PostgreSQL propagates an index on
a partitioned parent to every partition created under it afterwards, so **a host indexes
`release_area` once, on the parent, and every future release inherits it** -- including a
partition dropped by `retire_releases` and rebuilt by a later import.
`test/pgtap/catalog/test_partition_index_propagation.sql` pins this end to end against
`create_release_partitions` itself, for both index shapes above.

Index the parent, never an individual partition: a per-partition index covers exactly one
release and the next import's partition would have none.

`CREATE INDEX CONCURRENTLY` is rejected on a partitioned table (`cannot create index on
partitioned table "release_area" concurrently`), so the plain form above takes an
`AccessExclusiveLock` while it builds every existing partition. On a catalog small enough
that this is a moment, that is the whole procedure. On a large one, build it in the
supported three steps -- and note that a partition created between step one and step three
picks the index up automatically, so an import running alongside does not defeat it:

```sql
CREATE INDEX my_app_release_area_population_idx
  ON ONLY geo_genius.release_area (((data->>'population')::numeric) DESC NULLS LAST);

-- Per existing partition, one at a time:
CREATE INDEX CONCURRENTLY release_area_<suffix>_population_idx
  ON geo_genius.release_area_<suffix> (((data->>'population')::numeric) DESC NULLS LAST);
ALTER INDEX my_app_release_area_population_idx
  ATTACH PARTITION release_area_<suffix>_population_idx;
```

The parent index reads as invalid in `pg_index` until every existing partition has an index
attached, and becomes valid on the last `ATTACH`.

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
| `put_area_in_release`, `put_boundary`, `put_boundaries` (via `assert_area_in_collection`) | `area % belongs to collection %, but release % belongs to collection %` |
| `attach_source_release`                           | `source release % belongs to collection %, but release % belongs to collection %` |
| `put_boundary`, `put_boundaries`                  | `source release % is not declared by release %`                  |

Two families depart from `23503`, and a caller matching on SQLSTATE has to expect them.

`rebuild_relations` raises `22023` for `release % does not exist`, where every sibling
carrying that same message raises `23503`. It is the one outlier in the catalogue.

An unresolved key raises PL/pgSQL's own `P0002` (`no_data_found`), from one of two places.
A lookup written as `SELECT ... INTO STRICT` raises the bare message `query returned no
rows`, naming neither the function nor the value that was not found. A plural write
resolves its keys by joining instead, and reports an unresolved one through
`assert_resolved`, which raises the same SQLSTATE with the same wording and appends the key
-- `query returned no rows for area key acme:city:portland`. The five scalar writes
delegate to their plural forms, so they carry the named message too. Every site, and what
makes it fire:

| Function                                          | Missing row that raises `P0002`                     | Message |
|---------------------------------------------------|------------------------------------------------------|---------|
| `upsert_area`, `upsert_area_many`                 | an unknown `authority_key` or `area_type_key`         | named   |
| `upsert_area`, `upsert_area_many`                 | an unknown `collection_key`                           | bare    |
| `put_area_name`, `put_area_code`, `put_area_in_release`, and their plural forms | an unknown `target_area_key` | named |
| `put_relation`, `put_relation_many`               | an unknown `parent_area_key` or `child_area_key`      | named   |
| `put_boundary`                                    | an unknown `target_area_key`                          | bare    |
| `put_boundaries`                                  | an unknown `target_area_key`                          | named   |
| `assert_release_mutable`                          | an unknown `target_release_id`, which is how `put_boundary`, `put_boundaries`, `put_area_in_release`, `put_relation`, and `rebuild_relations` report one | bare |
| `assert_area_in_collection`                       | a release or area row deleted between the caller's lookup and this guard | bare |

`verify_release` and `publish_release` each hold one `INTO STRICT` lookup as well, but
both check the release exists first and raise `23503`, so neither reaches `P0002` for a
release id that names nothing.

A provider emitting an unknown `authority_key` is the reachable ingestion path into this
family, and it is one of the sites that names the key.

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
publication. The `published_*` views above are the read-side contract most hosts join
directly rather than calling a resolution function; `GeoGenius.Published` is the Elixir
surface over them.
