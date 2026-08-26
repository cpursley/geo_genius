# Installation and host integration

GeoGenius requires Ecto, Ecto SQL, Postgrex, and an already available PostgreSQL Repo with
PostGIS and `pg_trgm`. It does not provision or start a database, and it does not decide
where its own schema lives — that is a host decision, made once, at install time.

## Prefixes are host-selected

Every GeoGenius object — tables, views, functions, the `area_match` composite type — installs
into one PostgreSQL schema, and the host names that schema. There is no default GeoGenius
would prefer over another: `"geo_genius"` is only the fallback value the tasks and the
`:geo_genius` application environment use when nothing more specific is given. A host with an
existing `geo` schema, a host running two GeoGenius-backed products in one database, or a host
that simply prefers a different name passes `--prefix` (mix tasks) or `prefix:` (application
config, SQL calls) and GeoGenius installs and runs there instead. The package's own SQL never
hard-codes a schema name — every reference in the shipped `.sql` files is a placeholder
(`$SCHEMA$`) that EctoEvolver substitutes with the configured prefix before executing, table by
table and function by function, at migration time.

A prefix cannot be `public`, `information_schema`, `pg_catalog`, `pg_toast`, `pg_temp`, or
anything starting with `pg_`: `mix geo_genius.uninstall` drops the whole prefix schema, and
letting GeoGenius own one of those would risk dropping a schema PostgreSQL or the host's own
migrations depend on. Every mix task and the Elixir API validate the prefix against this
list and raise before touching the database.

Configure the Repo and prefix together so the Elixir API, the preflight check, and the mix
tasks all agree on where the schema lives:

```elixir
# config/config.exs
config :my_app, ecto_repos: [MyApp.Repo]
config :geo_genius, repo: MyApp.Repo, prefix: "geo_genius"
```

`:prefix` must be set in `config/config.exs`, and never in `config/runtime.exs`.
`GeoGenius.Query` reads it at compile time through `Application.compile_env/3`, because
Ecto's `fragment/1` requires its SQL to be a literal; Elixir then refuses to boot when the
value present at runtime differs from what the compile-time read recorded, and a `:prefix`
that first appears in `runtime.exs` differs from a compile-time read that found nothing even
when the value is the identical default string. `:repo` carries no such constraint and may
live in `runtime.exs`. A changed compile-time `:prefix` takes effect once `:geo_genius` is
recompiled, with `mix deps.compile geo_genius --force`.

This configuration feeds calls into the `GeoGenius` Elixir API and `GeoGenius.Preflight`. It
does **not** feed the mix tasks: `mix geo_genius.setup`, `mix geo_genius.gen.migration`,
`mix geo_genius.check_schema`, and `mix geo_genius.uninstall` all take `--prefix` explicitly
(defaulting to the literal `"geo_genius"` when omitted) and resolve `--repo` from the host's
`:ecto_repos` when not given. A host running at a non-default prefix passes `--prefix` on every
task invocation; setting it only under `config :geo_genius` will not reach the generators.

## Registering providers

A manifest names the provider that reads its artifacts by a string key, and GeoGenius resolves
that key to a module through application config:

```elixir
# config/config.exs
config :geo_genius, :providers, %{"acme" => MyApp.AcmeProvider}
```

The package ships three provider modules, registered under `"geojson"`, `"csv"`, and
`"shapefile"`. Host registrations merge on top of those, so `config :geo_genius, :providers`
adds keys of the host's own and, under a shipped key, replaces the module that key resolves to.

A provider module may export `required_options/0`, returning the list of `options` keys its
manifests must carry; manifest validation rejects a manifest missing any of them. A provider
that does not export it requires no options. The shipped `"geojson"` provider requires
`"area_type"` and `"code_property"`, `"csv"` requires `"area_type"` and `"code_column"`, and
`"shapefile"` delegates to `"geojson"`.

Resolution fails loudly rather than quietly. An unregistered key names the keys that are
registered, the shipped ones always among them:

```
GeoGenius provider "acme" is not a known provider; known providers are csv, geojson, shapefile
```

and a key registered against a module that does not load is reported as the configuration error
it is, rather than being read as a provider carrying no requirements, which would have made
validation accept every options block written for it:

```
GeoGenius provider "acme" is registered as MyApp.AcmeProvider, which does not load. Check the
module name in config :geo_genius, :providers, and that the module is compiled into this build.
```

## Asynchronous imports need no configuration

`GeoGenius.import/1` picks a runner backend through `GeoGenius.Runner.configured/1`: PgFlow if
installed and running, otherwise a `Task.Supervisor` this package starts on its own, otherwise
`GeoGenius.Runners.Inline`, which runs the import in the calling process and blocks it for the
import's full duration. `:geo_genius` starts at most one process of its own — a `Task.Supervisor`
registered as `GeoGenius.TaskSupervisor` — for exactly this reason: without it, a host that has
not installed PgFlow and has not wired up its own `Task.Supervisor` falls all the way through to
`Runners.Inline`, and a national vintage takes hours to import synchronously in whatever process
called `GeoGenius.import/1`. (It starts *no* process at all when the host has already configured
`:task_supervisor` — see the override below.)

Nothing needs to be configured for this — but the default's shutdown ordering is backwards, and a
host that cares about it should configure the override below rather than live with that.
Applications stop in the reverse of the order they started, and `:geo_genius` starts *before* its
host, so it stops *after* it: on `System.stop/1`, the host's own tree — Repo included — finishes
stopping first, and only then is the library's own supervisor told to stop. An import task still
running at that moment keeps running against a Repo that is already gone for the entire length of
the host's own shutdown, its calls failing repeatedly against a connection that no longer exists.

The fix is the override, placed correctly:

```elixir
config :geo_genius, :task_supervisor, MyApp.TaskSupervisor
```

with `MyApp.TaskSupervisor` started under the host's own supervision tree, listed *after*
`MyApp.Repo` in that tree's children list. Supervisors stop children in the reverse of their start
order, so a later-listed `TaskSupervisor` stops — and every task under it is killed — *before*
`Repo` does, instead of after. This is the only supervision arrangement whose shutdown ordering is
actually correct for a host running import work under this backend, and this library cannot arrange
it from the outside. The configured name takes precedence over the library's own supervisor
whenever it is set, whether or not it is actually running (more on what that means below), and
when it is set, the library skips starting its own supervisor entirely, so a host that placed one
of its own is never left with an idle, unreachable second one sitting in the tree.

Killing a task this way is still not graceful: a `Task` does not trap exits, so it dies the instant
its supervisor tells it to, mid-statement if that is where it happens to be — the standard shutdown
timeout is never actually spent, because there is no cleanup phase to spend it on. Neither
arrangement lets a task write `fail_import/3` or drop its own staging table on the way out: under
the default ordering it keeps running and both calls fail against a Repo that is already gone;
under the override it is killed before it gets the chance to make either call at all. What the
correct ordering buys is narrower than graceful shutdown: the task dies while the Repo can still be
reached rather than while it cannot, so it fails cleanly instead of repeatedly against a connection
that no longer exists. Either way, what actually recovers the run is the same as always: the lease,
reclaimed once `stale_after` elapses. This supervisor is not durability regardless of where it is
placed — a host that needs an import to survive a VM restart, not merely a crashed task, installs
PgFlow.

A host can list the pids of tasks running under either supervisor with `Task.Supervisor.children/1`
— bare pids, not run ids, and, under the override, potentially mixed with any unrelated tasks the
host started under that same supervisor itself. A host that wants to see actual import runs queries
`import_run` (or `GeoGenius.status/2`) instead.

**A configured but never-started `:task_supervisor` is still selected, not silently downgraded.**
`GeoGenius.Runner.configured/1` picks `Runners.Task` whenever `:task_supervisor` names anything at
all, even a name nothing has registered — a typo, or a supervisor the host has not started yet.
The alternative would be worse: falling back to `Runners.Inline` and blocking the caller for the
length of a national import, silently, with no indication the configured supervisor was never
reached. Instead `GeoGenius.import/1` returns `{:error, reason}` naming the configured module, the
same way it would if `:runner` were pinned to `Runners.Task` directly. This only ever surfaces for
a host that set `:task_supervisor` and has not (yet) started it; a host running with no
configuration at all always resolves to the library's own, genuinely running supervisor.

Tests need no different treatment for this default: see
["`Runners.Task` needs no sandbox setup, with two real caveats"](#runners-task-needs-no-sandbox-setup-with-two-real-caveats)
under `Ecto.Adapters.SQL.Sandbox`, below, for why.

## The pinned wrapper, and why it is committed

`mix geo_genius.setup` does not install anything itself. It generates one ordinary,
host-owned Ecto migration file through the host's own `mix ecto.gen.migration`, then rewrites
that file's `up`/`down` bodies to call `GeoGenius.Migration.up/1` and
`GeoGenius.Migration.down/1` pinned to the exact prefix and version requested:

```console
mix geo_genius.setup --repo MyApp.Repo --prefix geo_genius
```

```console
* creating priv/repo/migrations/20260825120000_setup_geo_genius.exs
Generated GeoGenius setup migration: priv/repo/migrations/20260825120000_setup_geo_genius.exs
```

```elixir
defmodule MyApp.Repo.Migrations.SetupGeoGenius do
  use Ecto.Migration

  def up, do: GeoGenius.Migration.up(prefix: "geo_genius", version: 1)

  def down, do: GeoGenius.Migration.down(prefix: "geo_genius", version: 0)
end
```

Commit this file. It is the host's record of exactly which GeoGenius schema version is
installed at exactly which prefix, and it runs through the host's own `mix ecto.migrate` like
any other migration — GeoGenius never runs a migration on the host's behalf. Because the prefix
and version are baked into the file rather than read from configuration at migrate time, a
later change to `config :geo_genius, prefix:` cannot silently redirect an already-applied
migration at a different schema, and a later GeoGenius release cannot silently change what an
already-committed migration does.

Pass `--with-extensions` when the migrating role has the privilege to run `CREATE EXTENSION`,
and the generated wrapper's `up/0` will issue `CREATE EXTENSION IF NOT EXISTS postgis` and
`CREATE EXTENSION IF NOT EXISTS pg_trgm` before installing the schema. Without the flag, PostGIS
and `pg_trgm` must already exist — install them yourself, as a privileged role, before running
`mix ecto.migrate`.

The extensions being installed in the database is not enough on its own: the host's Repo also
has to be able to decode what they produce. GeoGenius reads and writes geometry as `Geo`
structs, not WKT/EWKT text, so the Repo needs a Postgrex types module registering
`Geo.PostGIS.Extension`. `GeoGenius.Preflight` (see the README's Usage section) checks this at
startup, alongside the extensions and schema version, and fails boot with a remedy if it is
missing. GeoGenius ships `GeoGenius.PostgresTypes` for a host with no types module of its own:

```elixir
# config/config.exs
config :my_app, MyApp.Repo, types: GeoGenius.PostgresTypes
```

A host with its own types module adds `Geo.PostGIS.Extension` to it instead of switching to
`GeoGenius.PostgresTypes`:

```elixir
Postgrex.Types.define(
  MyApp.PostgrexTypes,
  [Geo.PostGIS.Extension] ++ Ecto.Adapters.Postgres.extensions(),
  json: Jason
)
```

See [`reading.md`](reading.md#configuring-the-repo-to-decode-geometry) for what fails, and how,
when this is skipped.

```console
mix geo_genius.setup --repo MyApp.Repo --prefix geo_genius
mix ecto.migrate
mix geo_genius.check_schema --repo MyApp.Repo --prefix geo_genius
```

`mix geo_genius.check_schema` is read-only. It starts the selected Repo, compares the installed
schema version (read from a tracking view's comment) against the version the loaded package
code expects, and exits non-zero on a mismatch — usable as a CI or deploy gate. It never
creates, repairs, or migrates anything.

## Testing with `Ecto.Adapters.SQL.Sandbox`

Ecto hosts run their suites with the Repo pooled through `Ecto.Adapters.SQL.Sandbox`, which
wraps each test in a transaction and rolls it back. Four things about GeoGenius are worth knowing
inside that transaction: three change shape and need a decision from the host, and one — the
runner default — turns out to need no setup at all.

### Preflight skips itself, and how to run it anyway

`GeoGenius.Preflight` belongs in `application.ex`, which means the supervisor starts it from a
process that owns no sandbox connection. In the sandbox's `:manual` mode its verification query
would raise `DBConnection.OwnershipError`, `start_link/1` would raise, `Application.start/2`
would fail, and every test in the suite would error before its first `setup` block. So a Repo
configured with the sandbox pool skips the check: `start_link/1` returns `:ignore` without
querying, and nothing else in the child spec changes.

Nothing verifies the test database in exchange, so verify it from `test/test_helper.exs`, where
a connection is available. One line is enough, and it fails the run with the same remedy
Preflight would have printed at boot:

```elixir
# test/test_helper.exs
:ok = GeoGenius.verify!(MyApp.Repo, prefix: "geo_genius")

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, :manual)
```

The order is the whole point. A sandbox pool starts in `:auto` mode, where each query checks a
connection out and back in by itself, so `verify!/2` runs normally there. After
`Sandbox.mode/2` sets `:manual`, the `test_helper` process owns no connection, and the same call
raises `DBConnection.OwnershipError` — the failure this section exists to prevent, moved from
`application.ex` into `test_helper.exs`.

A host that has to verify after `:manual` is set checks a connection out around the call:

```elixir
Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, :manual)

:ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)
:ok = GeoGenius.verify!(MyApp.Repo, prefix: "geo_genius")
:ok = Ecto.Adapters.SQL.Sandbox.checkin(MyApp.Repo)
```

Passing `enabled?: true` in the child spec overrides the skip and runs the check from the
supervisor, which is correct only for a Repo the host has arranged to be checked out there.
`enabled?: false` skips it for any Repo, sandboxed or not.

### Publication and import tests are `async: false`

`publish_release`, `rollback_publication`, `retire_releases`, `rebuild_relations` and
`begin_or_resume_import` each take a `pg_advisory_xact_lock` keyed on the collection or release
they touch. Outside a transaction that lock is released when the statement commits, which is
what the design intends: two publishes of the same collection serialize for the length of one
statement.

Inside the sandbox the statement is part of the test's transaction, so the lock is held until
the test checks its connection back in. Two `async: true` tests publishing the same collection
then block each other for their full duration, and two tests that take the same pair of locks in
opposite orders — one publishing A then B, the other B then A — deadlock, which PostgreSQL
reports as a `40P01` error on whichever it chooses to abort.

Mark every test that publishes, rolls back, retires, rebuilds relations, or begins an import
`async: false`. Tests that only read the catalog are unaffected and stay `async: true`.

```elixir
defmodule MyApp.PublicationTest do
  use MyApp.DataCase, async: false
end
```

Every import test needs this `async: false` for the advisory-lock reason above, independent of
which runner it exercises. A host that also needs
[shared mode for the `$callers` caveat](#runners-task-needs-no-sandbox-setup-with-two-real-caveats)
below needs `async: false` for that too, since shared mode is a Repo-global setting.

### Staging tables do not survive the test

`create_staging` issues `CREATE TABLE`, and PostgreSQL rolls DDL back with the transaction like
any other statement. A staging table created in one test is gone by the next, and
`drop_staging` has nothing to clean up. Build and read the staging table inside the same test
that created it, rather than in a `setup_all` or across tests.

### `Runners.Task` needs no sandbox setup, with two real caveats

`GeoGenius.Runners.Task` runs the import in a process the sandbox's `:manual` mode never checked
a connection out to directly — and that turns out not to matter. `Task.Supervisor.start_child/2`
has seeded the spawned process's `$callers` since Elixir 1.8, and `Ecto.Adapters.SQL.Sandbox` —
built on `DBConnection.Ownership` — walks that list to find an owner: a process whose `$callers`
chain leads back to the sandbox owner (or to a process the owner allowed) inherits the
checked-out connection automatically. A call to `GeoGenius.import/1` from inside an ordinary
sandboxed test, with no `Sandbox.allow/3` and no shared mode, spawns a task that queries
successfully and — provided the test waits for it, the second caveat below — runs the import to
completion, because the task's `$callers` chain leads straight back to the process holding the
checkout. This is documented Ecto behaviour — "Callers lookup" in `DBConnection.Ownership`'s
moduledoc, "Caller Tracking" in `Ecto.Adapters.SQL.Sandbox`'s — not an accident of this library's
own code, and it holds for both the explicit-checkout shape shown throughout this guide and the
allowance shape a generated Phoenix `DataCase` uses.

`$callers` is the entire boundary, and only the `Task` family seeds it — `Task.async/1`,
`Task.start/1`, and the `Task.Supervisor` functions. `spawn/1`, `GenServer.start_link/3`,
`Supervisor.start_child/2`, and everything else `proc_lib` starts set `$ancestors` instead, a
different entry `DBConnection.Ownership` never reads. Being started *by* the sandbox owner is
not enough: a `GenServer` the test process starts itself has the test pid at the head of its
`$ancestors`, a `$callers` of `nil`, and a first query that raises `DBConnection.OwnershipError`.
What inherits is exactly a process reached from the owner through an unbroken chain of
`Task`-family spawns — which is what `Runners.Task` starts, and why it needs nothing.

The first caveat follows from that boundary: it only works while `GeoGenius.import/1` is
actually called from the sandbox owner, or from a process whose `$callers` leads back to it. A
host that enqueues an import from a long-lived GenServer, from `Runners.PgFlow` (whose worker
does not spawn through a call chain rooted in the test process at all), or from anywhere else
`$callers` does not lead back to the owner needs the ordinary Ecto remedies for that case —
`Sandbox.allow/3` naming that process explicitly, or `Sandbox.mode(Repo, {:shared, self()})`,
which is a Repo-global setting and so also needs
[`async: false`](#publication-and-import-tests-are-async-false), like every import test already
does. These are the same two tools a host would already reach for to let any other async work
from such a process see its test data, nothing specific to this library.

The second caveat: the task only ever borrows the test's checkout, so the test must wait for
the import to finish. `enqueue/3` returns immediately, and a test that enqueues and returns
without waiting checks its connection back in and rolls its transaction back; the still-running
task's next query then raises `DBConnection.OwnershipError` — logged as a crashed task while
ExUnit reports the test green, with any later assertion reading catalog state the import never
got to write. Poll `import_run` (or `GeoGenius.status/2`) to a `completed` or `failed` status
before the test returns. Shared mode does not rescue an abandoned import either: the pool
resets to `:manual` the moment the sharing owner's checkout goes down, which is exactly when
the test ends.

## Upgrades

When a later GeoGenius release ships an adjacent schema version, generate and review its own
pinned wrapper the same way, then migrate normally:

```console
mix geo_genius.gen.migration --repo MyApp.Repo --prefix geo_genius --from 1 --to 2
mix ecto.migrate
```

Only one adjacent transition (`to = from + 1`) is accepted per invocation; there is no
multi-version jump. Back up the database before running an upgrade migration, the same as
before any other schema change.

## The down migration drops the schema, and that is deliberate

GeoGenius's `down` is destructive within its own objects: it drops every table, view, function,
and type it created, in reverse dependency order. It then drops the schema itself, but only if
nothing else remains in it - GeoGenius can be installed into a schema the host already uses for
something else, and a `CASCADE` there would take the host's unrelated tables down with it. The
drop it issues is `DROP SCHEMA "<prefix>" RESTRICT`, guarded by a check of `pg_class`, `pg_proc`,
and `pg_type` for the prefix's namespace; if that check finds any object GeoGenius did not just
drop, it raises a `NOTICE` naming how many objects remain and leaves the schema in place instead.

This is acceptable specifically because GeoGenius's own data is not authored, it is derived.
Everything in the catalog — areas, boundaries, relations, published releases — is built from
source releases and artifacts recorded with a checksum and expected size, so a rolled-back
install can always be reproduced by re-running the same import against the same manifest. A
library holding data a host typed in by hand would need a more conservative rollback; GeoGenius
does not, because nothing in it is a copy of one.

Back up before running a rollback in production anyway. `mix ecto.rollback` is a normal command
a deploy tool can invoke at the wrong target by mistake, and a backup is the recovery path for
that mistake, not for GeoGenius's own behavior.

## Uninstalling directly

`mix geo_genius.uninstall` runs directly against the Repo rather than through `Ecto.Migrator` —
routing it through the migrator would write a fabricated version row into the host's
`schema_migrations` table for a migration that was never actually run forward that way. Unlike
the down migration, it drops the prefix schema unconditionally with `DROP SCHEMA IF EXISTS
<prefix> CASCADE`, taking anything else in that schema with it. By default it only prints the
statements for review:

```console
mix geo_genius.uninstall --repo MyApp.Repo --prefix geo_genius
```

```console
-- Review carefully before running. This destroys all GeoGenius data at this prefix.
DROP SCHEMA IF EXISTS "geo_genius" CASCADE;
DELETE FROM schema_migrations WHERE version IN (20260825120000);
```

Pass `--yes` to actually execute it. Dropping the schema alone would leave the host's setup
migration recorded as applied, which makes `mix ecto.migrate` skip reinstalling it on a later
run. So `mix geo_genius.uninstall` also deletes the host's `schema_migrations` row for the
`*_setup_geo_genius.exs` wrapper it finds in the migrations directory, alongside the schema.
The wrapper file itself stays on disk, so `mix ecto.migrate` alone reinstalls the catalog from
scratch; `mix geo_genius.setup` refuses to run again while that file is there, raising
`GeoGenius setup migration already exists in <path>` rather than generating a second wrapper
for the same install. If no setup wrapper is found, uninstall prints a comment noting that no
row was removed instead of a `DELETE` statement.

## Hosts own their own projections

A host that only ever reads through the `published_*` views (see the SQL API table in the
[README](../README.md)) does not need to build anything of its own: joining those views inside
the host's own queries is the whole integration. A host that instead materializes a projection
of the catalog into its own tables — copying area names into a search index, denormalizing
codes into a lookup table, caching boundaries for a tile server — owns that projection and its
refresh entirely. GeoGenius does not know that projection exists and cannot invalidate it.

### Retired areas

`published_areas` includes retired areas, carrying their `retired_at` timestamp, rather than
filtering them out. This is deliberate: a retired area must stay addressable, because a host
may hold a saved reference to it (a stored `area_key`, a foreign key, an old export) that has to
keep resolving, and a retired area may declare a `successor_id` a host wants to follow. The
resolution functions (`resolve`, `areas_for_point`, `areas_by_code`, `search_areas`, `areas_near`,
`children_of`, `ancestors_of`, `related_areas`) apply an active-only default themselves, through
an `include_retired boolean DEFAULT false` parameter — call them with no arguments beyond the
required ones and retired areas are already excluded.

A host that joins `published_areas` directly, instead of going through a resolution function,
gets retired areas too, and must add `WHERE retired_at IS NULL` itself to see only active ones.
Counting areas through the view without that filter is the obvious way to get this wrong -
the count will include areas the collection considers gone.

`published_area_codes`, `published_area_names`, and `published_boundaries` carry no
`retired_at` column of their own - each is `published_areas` joined out to `area_code`,
`area_name`, or `boundary` on `area_id`, and retirement state is not among the columns that
join carries forward. `WHERE retired_at IS NULL` applied directly to one of these three fails
with `undefined_column`. Exclude retired areas from any of them by joining back to
`published_areas` (or to `geo_genius.area`) on `area_id` and filtering there instead:

```sql
SELECT codes.*
  FROM geo_genius.published_area_codes codes
  JOIN geo_genius.published_areas areas ON areas.area_id = codes.area_id
 WHERE areas.retired_at IS NULL;
```

### Measured versus asserted relations

A `relation` row's `intersection_area_m2`, `parent_coverage`, and `child_coverage` columns hold
either a geometry-measured value or `NULL`. `NULL` on those three columns is the entire
convention for "this relation was asserted, not measured" — nothing else on the row marks it,
and it is only legible to a reader who has been told.

`rebuild_relations` populates all three when it derives relations from boundary overlap:
`intersection_area_m2` is the measured overlap area, and `parent_coverage`/`child_coverage` are
that area as a fraction of each side's own area. `put_relation` records a relation asserted from
source data instead — a parent column in an import file, for example, where no polygon exists to
measure against — and leaves all three `NULL` deliberately; there is nothing to measure. Both
paths write the same `relation_type` values (`contains`, `mostly_contains`, `overlaps`) and the
same `relation` table, and every traversal function (`children_of`, `ancestors_of`,
`related_areas`) walks both alike: none of the three filters on the measurement columns, so a
purely asserted reference hierarchy with no polygons anywhere traverses exactly like a measured
one.

Rerunning `rebuild_relations` deletes and re-derives only geometry-measured relations (those
where `intersection_area_m2 IS NOT NULL`); it never touches a relation `put_relation` recorded.
An asserted reference hierarchy survives a rebuild intact, and a release that mixes both kinds
keeps its asserted rows exactly as written no matter how many times the measured ones are
rebuilt from updated boundaries. A `CHECK` constraint on `relation` requires the three
measurement columns to be all present or all absent - a row with, say, `intersection_area_m2`
set but `parent_coverage` left `NULL` is rejected with SQLSTATE `23514` rather than stored
half-measured.

A host reading `parent_coverage` (or either of the other two) directly must treat `NULL` as "not
measured," not as "zero" or "unknown-but-probably-high" — a `NULL` there says only that the row
came from `put_relation`.

### Traversal depth on dense graphs

`children_of` and `ancestors_of` default `max_depth` to `1` — a call with no `max_depth` argument
returns only direct children or direct parents, not a full descent. Raising it is safe and cheap
on an ordinary hierarchy, where relations run from a lower-ranked type to a higher-ranked one
(state → county → tract) and each area has few parents and children. It is not free on a densely
mutually-related graph, and the cost has a specific, measured shape worth knowing before raising
`max_depth` on one.

The recursive walk tracks a `visited` array per branch, not globally, so on a graph where many
areas mutually overlap each other, the same node can be re-reached along every distinct
permutation of the nodes visited so far before the outer `DISTINCT ON` collapses duplicates at
the end. On a synthetic 8-node complete digraph (every area asserted `overlaps` with every
other, the densest possible graph at that size), `children_of` from one node measured:

| `max_depth` | wall time | final result rows | raw recursive-term rows (pre-dedup) |
|-------------|-----------|-------------------|-------------------------------------|
| 3           | 6.156 ms  | 7                 | 259                                 |
| 5           | 13.045 ms | 7                 | 3,619                               |
| 10          | 52.304 ms | 7                 | 13,699                              |

The final, de-duplicated result is correct and stable at 7 (every other node, exactly once)
regardless of `max_depth` — raising it past the point where the graph is fully explored does not
change the answer. But the raw row count the recursion produces along the way grows combinatorially
with depth (a falling factorial in the branching factor), and wall time tracks it: roughly double
from depth 3 to 5, roughly quadruple from depth 5 to 10. At 8 nodes this is unremarkable in
absolute terms; a collection with tens or hundreds of densely mutually-overlapping areas at a
similarly generous `max_depth` would see the same growth curve produce a much larger number.
Keep `max_depth` small (the default of `1`, or a deliberately chosen small value) on collections
where areas relate to many other areas of the same or similar rank, and raise it freely on
strictly-ranked hierarchies where each area has few relations either direction.

### Reacting to publication

A host that only ever joins the `published_*` views needs no notification mechanism at all.
`publish_release` and `rollback_publication` swap one row in the `publication` table, and every
`published_*` view resolves through that pointer, so the swap changes what every view returns
atomically, under ordinary MVCC visibility, with no cache to invalidate and no refresh step to
run.

A host that materialized its own projection is different: it needs to know a swap happened so
it can refresh. The contract for that is the durable `publication_event` table. Every
`publish_release` and `rollback_publication` call appends one row there, carrying the
collection, the new and previous release, an event `kind` (`'published'` or `'rolled_back'`),
and a monotonic `sequence` column a poller can track a cursor against.

GeoGenius itself emits no `pg_notify`. Two reasons, both structural rather than incidental:

- **Channel and payload are integration policy, not library policy.** A `NOTIFY` channel name
  and payload shape are choices that belong to whatever is consuming the event, and different
  hosts consuming the same GeoGenius installation would want different ones.
- **`NOTIFY` cannot be relied on to arrive.** It is session-scoped: a listener that was not
  connected and listening at the moment of the notify never sees it, so a host process that was
  mid-restart when a release published would silently miss the signal. It is also invisible
  through a transaction-mode connection pooler (PgBouncer in `transaction` mode, for example),
  which many production Postgres deployments sit behind for exactly the pooling properties they
  need elsewhere. A durable table survives both; a session-scoped notification survives neither.

A host that wants a live signal builds its own trigger on `publication_event`, choosing its own
channel and payload:

```sql
CREATE FUNCTION my_app_geo_published() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_notify('my_app_geo', NEW.collection_id::text);
  RETURN NULL;
END;
$$;

CREATE TRIGGER my_app_geo_published
AFTER INSERT ON geo_genius.publication_event
FOR EACH ROW EXECUTE FUNCTION my_app_geo_published();
```

Because this trigger runs inside the same transaction that inserted the `publication_event` row
(the same transaction `publish_release` or `rollback_publication` ran in), it keeps
commit-then-deliver ordering: nothing is notified until the publication itself has committed.

A poller reading `publication_event` instead of listening has one caveat to account for:
`sequence` is a `GENERATED ALWAYS AS IDENTITY` value assigned when the row is inserted, which is
before that row's transaction commits. Two concurrent publications can therefore commit out of
sequence order, so a poller querying `WHERE sequence > $last_seen` can briefly observe a gap —
sequence 41 visible, 42 not yet, 43 already there — that fills in a moment later when the
still-in-flight transaction holding 42 commits. Treat the highest **contiguous** sequence value
seen so far as the watermark, or poll with a small deliberate lag, rather than treating the
single highest value observed as an immediate cursor.

A host that wants the release that was published at a specific past moment, rather than
reacting to the live pointer, does not need to reconstruct that from `publication_event` by
hand: `geo_genius.release_at(collection_key, as_of)` returns the release id a collection had
published as of that timestamp (or `NULL` if it had published nothing yet), ready to pass
straight in as a resolution function's `target_release_id`. See
[`guides/sql_api.md`](sql_api.md#time-scoped-release-lookup).
