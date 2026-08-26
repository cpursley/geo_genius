# Ingesting a collection

An import turns a reviewed document into a verified release. You write a manifest naming
the collection, the release, the provider that parses it, and every file it is built
from. `GeoGenius.import/1` registers that manifest in the catalog, claims a durable
import run, and hands the run to a runner. The pipeline downloads, checks, stages,
normalizes, relates, analyzes, and verifies. Nothing any host reads changes until you
publish, which is a separate call.

This guide covers the manifest, the provider contract, the four adapters, the runner
backends, the phases, and the five mix tasks. For reading a published catalog see
[`reading.md`](reading.md); for installing the schema see
[`installation.md`](installation.md).

## The manifest

A manifest is the whole description of one release. Nothing discovers a release and
nothing follows a mutable "latest" pointer: a new release becomes available because
somebody reviewed a document and committed it.

```json
{
  "collection": "demo",
  "collection_name": "Demo Territories",
  "description": "Operator-drawn delivery zones",
  "release": "r1",
  "provider": "geojson",
  "requires_geometry": true,
  "source_date": "2026-01-15",
  "authority": { "key": "demo", "name": "Demo Operations" },
  "area_types": [{ "key": "territory", "rank": 100 }],
  "sources": [
    {
      "source_key": "demo:territories",
      "provider": "geojson",
      "license": "CC0-1.0",
      "attribution": "Demo Corp",
      "release_key": "2026-01",
      "source_date": "2026-01-15",
      "artifacts": [
        {
          "logical_name": "territories.geojson",
          "url": "https://example.test/territories.geojson",
          "operator_supplied": false,
          "format": "geojson",
          "required": true,
          "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
          "bytes": 4096,
          "members": ["territories.geojson"]
        }
      ]
    }
  ],
  "options": {
    "code_property": "territory_id",
    "name_property": "territory_name",
    "area_type": "territory"
  }
}
```

`collection` and `release` are required, and both must match
`~r/\A[a-z0-9][a-z0-9_.-]*\z/`. That is a path-traversal control rather than a naming
style: `GeoGenius.Manifest.load/3` joins the two into a filesystem path, and the
character class excludes the separator while requiring an alphanumeric first character,
so neither `..` nor an absolute path can match. `collection_name` and `description` are
what the collection row carries; leaving `collection_name` out names the collection after
its key.

`provider` must resolve through the registry described under
[Providers](#providers). `requires_geometry` is a promise about the collection, checked
at publication time: with it set, `verify_release` refuses a release in which any area
lacks a boundary. `authority` names who is responsible for the identifiers, and it is the
first segment of every `area_key` the release produces, so `demo` above yields
`demo:territory:west`. `area_types` declares the ranked types this collection uses, low
rank containing high; a provider that has a fixed hierarchy of its own supplies it when
the manifest declares none.

`sources` is a list because a release can draw on more than one feed: an authority's own
publication plus an operator-supplied correction, for instance. Each source needs a
`source_key`, a `provider`, a `license`, a `release_key` naming the vintage, and at least
one artifact. `attribution` is the credit line the license asks you to carry.

Each artifact is either downloadable or operator-supplied, never both and never neither.
A downloadable artifact carries a `url` and `operator_supplied: false`; an
operator-supplied one omits the `url` and sets `operator_supplied: true`, and you place
the file in the cache yourself before the run. Both carry `sha256` and `bytes`, which are
expectations rather than observations: the pipeline hashes whatever it actually got,
cache hit and fresh download alike, and PostgreSQL refuses the mismatch.

`required` defaults to true. `required: false` means exactly one thing: an artifact with
no `url`, and no copy in the cache, is counted in the `optional_missing` metric instead of
failing the run. It is not a promise that the artifact is skippable in general. An
optional artifact that names a `url` is downloaded like any other, and a download that
fails ends the import, because a URL the manifest declares and the network refuses is a
condition the operator has to see rather than a file the release can quietly go without.
An optional artifact that has to tolerate a failing source is one that belongs in the
cache, not on a URL.

`members` names the files expected inside an archive, which is what the shapefile provider
reads to find its `.shp` among the rest. It is validated as a list of non-empty strings.

An artifact may also carry a `cache_key`. Use it for a licensed file no URL can serve, so
the operator chooses the name they will place the file under rather than reverse
engineering the one the pipeline would have derived. When you leave it out, the key is
`<collection>/<source_key>/<source release_key>/<logical_name>`. Either way the segments
are validated, because a segment carrying a separator would put the file outside the
cache root.

`options` is the provider's own configuration and nothing outside the provider reads it.
Manifest validation checks that every key the provider's `required_options/0` names is
present, so a manifest missing one is rejected before any release row exists rather than
several phases into a run.

`GeoGenius.Manifest.to_map/1` produces exactly the document above, and
`from_map(to_map(manifest))` is the identity. That is what makes storing the manifest on
the release row lossless: the pipeline rebuilds the manifest it was given from
`release.manifest` without reading the file again.

## Where manifests are found

`GeoGenius.import(collection: "demo", release: "r1")` looks for
`<dir>/demo/r1.json` under each directory in the search path, in order, and uses the
first one that is a regular file. The search path is `opts[:manifest_paths]`, then
`config :geo_genius, :manifest_paths`, and always the package's own
`priv/geo_genius/manifests` last:

```elixir
config :geo_genius, manifest_paths: ["priv/geo_genius/manifests"]
```

The package's directory is searched last on purpose, so a host shipping a corrected
manifest under the same name takes precedence over one the package carries. A lookup that
finds nothing returns `{:error, %GeoGenius.ManifestError{}}` naming the candidate path it
checked, which is what tells "rejected by name" apart from "the file is not there".

You can skip the search entirely by handing `GeoGenius.import/1` a manifest you built
yourself:

```elixir
{:ok, manifest} = GeoGenius.Manifest.from_map(decoded)
GeoGenius.import(manifest: manifest)
```

## Providers

A provider adapts one source format. It is called for parsing and never for a write:
every write the import makes is the pipeline's, through `GeoGenius.Catalog`. Three
providers ship: `GeoGenius.Providers.GeoJSON` (`"geojson"`), `GeoGenius.Providers.CSV`
(`"csv"`), and `GeoGenius.Providers.Shapefile` (`"shapefile"`), the last of which
converts its archive with `ogr2ogr` before parsing the result as GeoJSON.

`GeoGenius.Provider` declares six callbacks.

`area_types/0` returns the ranked hierarchy this provider's collections use when a
manifest declares none. All three shipped providers have none of their own, so they
delegate to `GeoGenius.Provider.no_area_types/0` and let the manifest decide.

`required_options/0` returns the `options` keys manifest validation insists on. The
GeoJSON provider requires `"area_type"` and `"code_property"`; the CSV provider requires
`"area_type"` and `"code_column"`.

`artifacts/1` returns the artifacts, across the manifest's sources, this provider will
stage. The shipped providers stage every declared artifact and so delegate to
`GeoGenius.Provider.all_artifacts/1`.

`stage/5` receives the manifest, one artifact, the local path the artifact was resolved
to, an `emit` function, and an options list. It parses the file and hands `emit` lists of
`%GeoGenius.Staging.Row{}`. Emit in chunks rather than once for the whole file: each call
bounds the size of a single insert, and each call is also where the run's lease is
renewed, so a provider that emits once at the end of a two-hour parse lets its own lease
go stale. The options list carries `:work_dir`, a directory resolved per run and removed
when the run ends, and `:command`, the command adapter to shell out through. Return
`{:error, reason}` for a file you cannot parse; raise only for a defect in the provider
itself.

`normalize/2` receives the manifest and one staged row and returns
`{:ok, %GeoGenius.Provider.Area{}}`. It is pure: no adapters, no environment, no
database. Return `:skip` for a row that carries no area, such as a summary record or a
feature with no usable code, since that is an expected shape rather than a failure.

`relations/1` returns `:rebuild` when the areas nest spatially or by code and `:none`
when the collection carries no hierarchy. All three shipped providers delegate to
`GeoGenius.Provider.always_rebuild/1`. Note that a rebuild pairs a lower `area_type.rank`
against a higher one, so a release built from one manifest of one area type produces no
measured relations at all; hierarchy appears when a release composes several sources of
different types.

To write your own, implement the behaviour and register the module under the name your
manifests will use:

```elixir
config :geo_genius, providers: %{"acme" => MyApp.AcmeProvider}
```

Shipped providers are merged ahead of your registrations, so registering your own module
under `"geojson"` replaces the one this package carries. A name pointing at a module that
does not load is a configuration error and says so, rather than being read as a provider
with no requirements, which would make manifest validation accept every options block
written for it.

The spec these providers were built against writes `stage/2` and `normalize/1`. The
shipped arities are `stage/5` and `normalize/2`, because a provider needs the manifest on
every call and `stage` needs somewhere to emit to and an adapter to shell out through.
The six callbacks and their responsibilities are otherwise unchanged.

## The adapters

Four adapter roles are resolved the same way: `opts` on the call, then application
environment, then the shipped default.

| Role          | Config key   | Default                        | What it does                                      |
|---------------|--------------|--------------------------------|---------------------------------------------------|
| `:cache`      | `:cache`     | `GeoGenius.Caches.FileSystem`  | Where artifacts live between runs                 |
| `:downloader` | `:downloader`| `GeoGenius.Downloaders.Req`    | Streams a remote artifact to a local path         |
| `:command`    | `:command`   | `GeoGenius.Commands.System`    | Invokes an external executable                    |
| `:notifier`   | `:notifier`  | `GeoGenius.Notifiers.Noop`     | Delivers import lifecycle events                  |

Substitute one for every import by configuring it, or for a single call by passing it:

```elixir
config :geo_genius, notifier: MyApp.GeoGeniusNotifier

GeoGenius.import(collection: "demo", release: "r1", cache: MyApp.S3Cache)
```

The cache is checked before the downloader is ever consulted, which is what makes a
rerun cheap and what makes an operator-supplied artifact work at all. The shipped cache
stores artifacts as files under `opts[:cache_dir]`, then
`config :geo_genius, :cache_dir`, then a `geo_genius` directory under the system
temporary directory. A cache hit is hashed on every run, including one whose artifact row
already carries a `validated_at`, because trusting that column would mean a corrupted or
swapped cache entry is never noticed again.

`GeoGenius.Downloaders.Req` needs `req`, which is an optional dependency: add
`{:req, "~> 0.7"}` to your own `mix.exs` if you import anything downloadable. A
downloader reports only what it observed, never whether that matched an expectation. The
comparison lives in `record_artifact_observation` in PostgreSQL, and only there, which is
what keeps the two from disagreeing.

The command adapter is only reached by a provider that shells out. What the pipeline
actually hands a provider is `GeoGenius.Pipeline.CommandAllowlist`, which accepts
`ogr2ogr` and refuses everything else by name. That is a guardrail rather than a sandbox:
it bounds what a provider does by accident, not what it does deliberately.

A notifier is called for side effects only and its return value is ignored. It cannot
fail an import: the pipeline wraps every call, so one that raises or exits has its event
logged at warning level and dropped, and the phase continues. The events are
`:import_started`, `:phase_advanced`, `:import_completed`, `:import_failed`,
`:release_published`, and `:release_rolled_back`; `GeoGenius.Notifier.events/0` returns
that fixed list so your notifier can match exhaustively.

## Choosing a runner

A runner decides where `GeoGenius.Pipeline.execute/3` actually runs. It owns none of the
run's state: `enqueue/3` starts the work and returns, and the run's status, progress, and
error all live in PostgreSQL. Three backends ship, and with nothing configured the first
available one wins, in this order: `Runners.PgFlow`, then `Runners.Task`, then
`Runners.Inline`.

`GeoGenius.Runners.PgFlow` therefore takes precedence if you have installed `pgflow`
yourself, which is worth knowing before you install it for something else. This library
does not declare `pgflow`, so for every host that has not gone looking for it the first
available backend is `Runners.Task`.

`GeoGenius.Runners.Task` is what a host gets with no configuration and no pgflow. It runs
each import as a supervised task under `GeoGenius.TaskSupervisor`, a `Task.Supervisor` the
`:geo_genius` application starts itself. `GeoGenius.import/1` returns as soon as the task
starts, and you read the outcome back with `GeoGenius.status/2` or `GeoGenius.await/3`.

One exception is worth knowing: setting `config :geo_genius, :task_supervisor` selects
this backend whether or not anything is actually running under that name. A host that
named a supervisor and never started it gets a named error from `enqueue/3` saying so,
rather than a silent downgrade to `Runners.Inline`, which would block the caller for the
length of an import without ever saying why.

**If you care about shutdown ordering, configure your own supervisor:**

```elixir
config :geo_genius, :task_supervisor, MyApp.TaskSupervisor
```

with `MyApp.TaskSupervisor` listed in your own children *after* `MyApp.Repo`. Here is
why. Applications start in dependency order and stop in the reverse of it, so
`:geo_genius` starts before your application and therefore stops after it. With no
configuration, the library's own supervisor sits outside your tree: on shutdown your Repo
finishes stopping first, and an import still running at that moment keeps running against
a Repo that is already gone, failing on every call it makes for the whole length of your
shutdown. A supervisor you place after your Repo does not have that problem, because a
supervisor terminates its children in the reverse of their start order, so the tasks
under it are stopped before the Repo is. Setting the key at boot also tells GeoGenius to
start no supervisor of its own. Either way, killing a running import is not graceful: a
`Task` does not trap exits, so it dies wherever it happens to be, and what recovers the
run is what always recovers it, the lease being reclaimed once `stale_after` elapses.

`GeoGenius.Runners.Inline` runs the import in the calling process and does not return
until it has finished. Choose it deliberately for tests and for scripts, where blocking is
the point and the outcome is already durable by the time the call returns. It is also
where the resolution above ends up when neither other backend can accept work, which for
a national vintage means blocking the caller for hours.

More on `GeoGenius.Runners.PgFlow`: it runs the import as a durable PgFlow job.
**This library does not declare `pgflow`**, in either the ordinary or the optional form,
because as of 0.3.1 it does not compile unless `phoenix` and `phoenix_live_view` are also
present. If you add it, this backend reports itself available once `pgflow` is loaded,
this library's own job submodule is compiled, and `PgFlow.Supervisor` is running; short of
that it returns an error naming what is missing rather than raising deep inside
`PgFlow.enqueue/2`, and the resolution falls through to `Runners.Task`.

Pin a backend for every import or for one call:

```elixir
config :geo_genius, runner: GeoGenius.Runners.Inline

GeoGenius.import(collection: "demo", release: "r1", runner: GeoGenius.Runners.Inline)
```

The backend a run was claimed under is recorded on `import_run.runner_backend`, so a run
stays readable after you change the configuration. There is no Oban backend; a host that
wants one implements `GeoGenius.Runner`'s three callbacks, which is the reason the
behaviour exists rather than a fixed backend list.

## The phases

An import walks a fixed sequence, advancing the durable run row at each boundary. A phase
that fails stops the sequence and records the failure.

`downloading` resolves every artifact the release composes to a local file. The cache is
checked first, a miss is downloaded, and whatever came back is hashed and recorded
against the manifest's expectation. Measures `artifacts`, `downloaded`, `cached`, and
`bytes`.

`validating` re-reads the artifacts and checks that every required one carries a
`validated_at`, counting the optional ones nothing could obtain. It re-reads rather than
trusting what the previous phase believed, which is what makes it a check.

`staging` calls the provider's `stage/5` for each artifact and writes the emitted rows
into an unlogged table of this run's own.

`normalizing` reads the staged rows back in batches, calls the provider's `normalize/2`
on each, and writes the areas, names, codes, membership, and boundaries through
`GeoGenius.Catalog`.

`relating` rebuilds measured relations from boundary overlap when the provider asks for
it, and does nothing when it does not.

`indexing` runs `analyze_release`, so the release has statistics before anything plans a
query against it.

`verifying` runs `verify_release` and fails the run when the report is not `ok`. This is
the gate: a release that has no areas, that lacks a boundary somewhere `requires_geometry`
demands one, that carries a relation or a membership belonging to another collection, or
that declares no source releases, does not become publishable.

`verify_release` also reports boundaries with invalid geometry, though nothing an import
does can produce one: `put_boundary` repairs its input with `ST_MakeValid` before storing
it, and the `boundary_geom_valid_chk` constraint refuses an invalid geometry written to
the table by any other route. That check is a backstop against a writer that bypasses
both, not a condition an import reaches.

`publishing` runs only when you passed `publish: true`, and it does exactly what
`GeoGenius.publish/2` does.

The import opens no transaction. Every catalog function is atomic on its own, and the
state machine is deliberately resumable, so wrapping the run would roll back the progress
a resumed run wants to start from and would hold one connection for the length of the
slowest phase. The staging table is dropped on success and on failure alike.

## Reading a run

`GeoGenius.import/1` returns `{:ok, run_id}` once the run is claimed and enqueued. The
work may be executing on another node, so both ways of reading it back go to PostgreSQL
rather than to a process.

```elixir
{:ok, run_id} = GeoGenius.import(collection: "demo", release: "r1")

GeoGenius.status(run_id)
# %GeoGenius.ImportRun{status: "normalizing", stage_metrics: %{"staged" => 1200}, ...}

GeoGenius.await(run_id, 600_000)
# {:ok, %GeoGenius.ImportRun{status: "completed"}}
```

`status/2` returns one `%GeoGenius.ImportRun{}` snapshot, or `nil` for a run id the
catalog does not carry. `await/3` polls every 250ms until the run finishes or the timeout
elapses, returning `{:ok, run}`, `{:error, run}` for a run that finished and failed, or
`{:error, :timeout}`. Both read the `import_run_status` view described in
[`sql_api.md`](sql_api.md#views).

`stage_metrics` accumulates what each phase measured; `progress` is the lease's rolling
progress object, updated by heartbeats during a phase. A failed run carries the reason on
`error`. A terminal run holds no lease, so its `progress` reads as an empty map and its
`heartbeat_at` falls back to the run's own column.

`:owner` defaults to the node name, so a worker restarting on the same node resumes its
own run rather than waiting out its lease. Pass `:owner` explicitly if you run two
importers on one node. A second owner claiming a release whose lease is still live is
refused, which is the property that keeps two workers from writing one release.

## Publishing and rolling back

An import produces a verified candidate. Making it visible is a separate act, and that is
deliberate: you can import a vintage on Friday, look at it, and publish it on Monday
without either step implying the other.

```elixir
{:ok, release_id} = GeoGenius.publish(release_id)
{:ok, previous_id} = GeoGenius.rollback("demo")
GeoGenius.published_release("demo")
```

`publish/2` verifies and publishes atomically, returning `{:error, exception}` rather
than raising when the release fails verification. Publishing the release that is already
published is a no-op that leaves the rollback target untouched, so a rollback still
reaches the last release actually swapped away from.

`rollback/2` swaps the publication pointer back to the previous release, not to the
oldest one, and returns `{:error, reason}` without clearing the publication when there is
nothing to roll back to. Both are pointer swaps under MVCC: readers see one release or
the other, never a partial catalog, and a published release is immutable, so changing
what hosts see always means building and publishing a new release.

`publish: true` on `GeoGenius.import/1` is the convenience for a caller that wants both
in one go, and it is the same call, run as one more phase.

## Enqueuing a release at boot

`GeoGenius.Bootstrap` is an optional supervised child that enqueues a configured release
when your application starts. GeoGenius does not add it to its own tree, because starting
an application must never download or import anything on its own; you place it in yours,
after your Repo, the way you place `GeoGenius.Preflight`:

```elixir
children = [
  MyApp.Repo,
  {GeoGenius.Preflight, repo: MyApp.Repo},
  {GeoGenius.Bootstrap, repo: MyApp.Repo},
  MyAppWeb.Endpoint
]

config :geo_genius, :bootstrap,
  enabled: true,
  collection: "us_counties",
  release: "2026",
  publish: true
```

It is disabled by default: without `enabled: true` you get a no-op child. Registering a
manifest is idempotent end to end, so a node booting against a release the catalog
already carries re-registers the same rows rather than duplicating them, and only the
first node's claim takes the lease. A node that is refused logs at error and returns
`:ignore` like every other outcome, because nothing here may stop a host from booting:
whatever release is already published is still readable.

## The mix tasks

Five tasks drive the same public API from a shell or a deploy step. Each takes `--repo`
and `--prefix`, and each resolves the Repo from your application configuration when you
leave `--repo` out.

`mix geo_genius.import` registers a release from its manifest and enqueues the run.
Without `--await` it prints the run id and returns immediately, because the work may run
elsewhere. With `--await` it waits and exits non-zero for a run that failed or did not
finish in time, so a deploy step can gate on the outcome.

```console
$ mix geo_genius.import --collection us_counties --release 2026 --await --publish
```

`mix geo_genius.publish` publishes a verified release, named either by id or by
collection and release key. Supplying both selectors is refused rather than resolved,
since the two can name different releases. A release that fails verification exits
non-zero. `--timeout` bounds the publication statement, which re-runs the release's
verification inside itself, and defaults to 900000 milliseconds.

```console
$ mix geo_genius.publish --collection us_counties --release 2026
```

A known limitation: `mix geo_genius.import --publish` has no equivalent switch. Its
publishing phase is bounded by the window the run was claimed under, 900 seconds by
default, and the task exposes no way to move it. A release whose verification needs
longer is imported without `--publish` and published afterwards with
`mix geo_genius.publish --timeout`.

`mix geo_genius.rollback` swaps a collection back to its previous release. It changes
what every host reading that collection sees, so it prints what it would do and does
nothing without `--yes`.

```console
$ mix geo_genius.rollback --collection us_counties --yes
```

A rollback that committed exits zero even when the release it landed on could not be read
back afterwards; the unreadable outcome goes to stderr naming the rollback as done. That
is deliberate. The publication has already moved by then, and a non-zero exit under a
"failed" label would invite a deploy script retrying on exit code to roll the collection
back a second step. `GeoGenius.rollback/2` reports the same case as
`{:error, {:unread, message}}`, a shape distinct from the exception a failed rollback
returns and from the string an unknown collection returns.

`mix geo_genius.status` reports one run with `--run-id`, or every run for a collection
newest first, plus what that collection currently publishes, with `--collection`. The two
are mutually exclusive.

```console
$ mix geo_genius.status --collection us_counties
```

`mix geo_genius.sweep_staging` drops per-run staging tables left behind by runs that have
already finished. The pipeline drops its own table in an `after` clause, and that drop is
deliberately rescued so a database failure during cleanup cannot destroy the run's
failure record, which means a host whose database dies mid-cleanup leaks a table that
nothing else reclaims. Like the rollback task, it prints what it would drop and does
nothing without `--yes`.

```console
$ mix geo_genius.sweep_staging --yes
```

The installation tasks (`mix geo_genius.setup`, `mix geo_genius.gen.migration`,
`mix geo_genius.check_schema`, and `mix geo_genius.uninstall`) are covered in
[`installation.md`](installation.md).
