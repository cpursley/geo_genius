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
  "authorities": [{ "key": "demo", "name": "Demo Operations" }],
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
[Providers](#providers). Collection-level `requires_geometry` is a promise about the
whole collection, checked at publication time: with it set, `verify_release` refuses a
release in which any area lacks a boundary. An `area_types` entry may also carry
`"requires_geometry": true`; that leaves the collection usable for metadata-only types
while requiring boundaries for areas of the marked type. Omitted area-type flags default
to false, and an explicit false is preserved when the manifest is stored on the release
row. A collection-level true still requires boundaries for every area, regardless of its
type. `authorities` names who is responsible for the identifiers; an
authority key is the first segment of every `area_key` keyed under it, so `demo` above
yields `demo:territory:west`. It is a list because a collection may draw on more than
one: a US release keyed partly by the Census, partly by the USPS, and partly by its own
vendor identifiers names all three, and a provider may emit areas under any of them.
Every authority an area is keyed under must be declared here, since an area naming one
the collection does not carry is refused.

`authorities` is required and must name at least one. That is stricter than
`area_types`, which may be declared as an empty list: a manifest declaring no area
types registers none, and a release that normalizes an area whose type it never declared
fails. Nothing else supplies either. A manifest with no authorities can therefore
register no area at all, and rejecting it at load names the field rather than failing
partway through normalization. `area_types` declares the ranked types this collection
uses, low rank containing high:

```json
[
  { "key": "bounded_zone", "rank": 10, "requires_geometry": true },
  { "key": "metadata_record", "rank": 20 }
]
```

`GeoGenius.Providers.GeoJSON` and `GeoGenius.Providers.CSV` key every area they emit
under one authority, which they take from `options["authority"]` or, when that is
absent, from the manifest's own single authority; a manifest declaring several must name
which one under that option.

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
Manifest validation checks that every key `required_options/0` names is present, and then
hands the whole map to `validate_options/1`, if it exports one, to check the options only
it understands. Both run for **every provider the manifest names** -- the release's own
and each source's -- and both run before any release row exists, so a manifest that is
missing a required key or carries a malformed option is rejected at load rather than
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
every write the import makes is the pipeline's, through `GeoGenius.Catalog`. Four
providers ship: `GeoGenius.Providers.GeoJSON` (`"geojson"`), `GeoGenius.Providers.CSV`
(`"csv"`), `GeoGenius.Providers.Shapefile` (`"shapefile"`), which converts its archive
with `ogr2ogr -f GeoJSONSeq -t_srs EPSG:4326 -lco RS=NO` before streaming the resulting
GeoJSON Feature sequence in bounded batches, and
`GeoGenius.Providers.SimpleMaps` (`"simplemaps"`), which has a section of its own
[below](#the-simplemaps-provider).

Shapefile staging is the only shipped provider that requires GDAL's `ogr2ogr` binary.
The conversion explicitly reprojects to EPSG:4326 and writes one Feature per line; the
sequence reader decodes and emits each configured batch before reading further, so neither
the converted artifact nor all of its staged rows are retained in memory.

`GeoGenius.Provider` declares six callbacks every provider implements, and one optional
seventh.

A source may name its own `provider`, and a source that names none inherits the release's.
That is what lets one release draw on sources in different formats: a delimited file staged
by the CSV provider beside an archive staged by the shapefile provider, converging on
`area_key` so one area carries what each source contributed. The pipeline asks `artifacts/1`
once per source with the manifest narrowed to that source, dispatches `stage/5` on the
artifact, and dispatches `normalize/2` and `asserted_relations/2` on the row's own artifact.
`relations/1` is the union: relations are rebuilt when any of a release's providers asks for
it, so a source whose areas nest spatially is still measured beside a source that carries no
geometry at all.

One caveat follows from `options` being release-level while the option vocabulary is
per-provider: an `implied_areas` entry names its code key in one provider's suffix, so a
release cannot share one between a CSV source and a GeoJSON source. A provider that reads
no options at all -- `GeoGenius.Providers.SimpleMaps` -- composes with any of them.

`required_options/0` returns the `options` keys manifest validation insists on. The
GeoJSON provider requires `"area_type"` and `"code_property"`; the CSV provider requires
`"area_type"` and `"code_column"`. SimpleMaps reads its columns by name and requires
none.

`validate_options/1` is the optional one. A provider that exports it is handed the whole
`options` map at load, once the required keys are known to be present, and the error it
returns becomes a manifest error naming the field. This is where a provider checks what
only it understands -- the shipped generic providers validate their `implied_areas`
entries here. A provider that exports none contributes no checks beyond the required
keys.

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

A row may also imply areas identified by *other* columns on itself. A record carrying a
grouping code -- a statistical grouping on an administrative record, an administrative
parent on a place record -- describes that grouping as well as itself, and the GeoJSON
and CSV providers read those columns from an `implied_areas` manifest option rather than
requiring a provider of your own:

```json
"options": {
  "area_type": "place",
  "code_property": "code",
  "implied_areas": [
    {
      "area_type": "cluster",
      "code_property": "CLUSTER",
      "names": { "1": "Outer Cluster", "2": "Inner Cluster" },
      "relation": "contains"
    }
  ]
}
```

Each entry names the area type to imply, the column carrying its code, a `names` map from
code to display name, an optional `authority` override, and an optional `relation`
defaulting to `"contains"`. The code key follows the provider's own vocabulary:
`code_property` under GeoJSON and shapefile manifests, `code_column` under CSV ones.

These entries are validated at load, through `validate_options/1`, so a missing
`area_type`, an unknown `relation`, a `names` map that is not an object, or an entry
written in the other provider's vocabulary is rejected before anything is downloaded. The
providers validate again as they read, because a `%GeoGenius.Manifest{}` built in Elixir
never passes through `GeoGenius.Manifest.from_map/2`.

An implied area carries no geometry and no centroid: a grouping a source names only by
code has no shape of its own there, and deriving one from the row's geometry would claim
the grouping's boundary is one member's boundary. A blank code implies nothing and is not
an error, since a column populated for most rows and blank for a few is ordinary. A code
that is present but missing from `names` fails the release, because keying an area with
no name would publish an unlabelled area.

The same entries drive `asserted_relations/2`, so each implied area also gets an edge to
the row's own area. That composes with `relations/1` rather than replacing it: a provider
that rebuilds measured relations from geometry can assert membership the geometry cannot
express, and both land in one release.

It may also return `{:ok, [%GeoGenius.Provider.Area{}, ...]}`, which is what a source
that denormalises a hierarchy into every row needs: a city row that also carries its
county and its state describes all three, and returning them together is cheaper and
truer than staging the same row once per level. Areas repeated across rows converge on
`area_key`, so emit an implied parent from every row that implies it rather than tracking
which ones you have already emitted.

`relations/1` returns `:rebuild` when the areas nest spatially or by code and `:none`
when the collection carries no hierarchy. The GeoJSON, CSV and shapefile providers
delegate to `GeoGenius.Provider.always_rebuild/1`; SimpleMaps returns `:none`, because it
carries centroids and no boundaries and so has no overlap to measure. Note that a rebuild
pairs a lower `area_type.rank` against a higher one, so a release built from one manifest
of one area type produces no measured relations at all; hierarchy appears when a release
composes several sources of different types.

`asserted_relations/2` returns the edges one staged row states outright, as
`{parent_area_key, child_area_key, relation_type}` tuples with `relation_type` one of
`"contains"`, `"mostly_contains"`, or `"overlaps"`. It is for the hierarchy no overlap
test can derive: a county FIPS on every city row, an admin parent code on every place, or
a source with no geometry at all. Both keys are the strings
`GeoGenius.Provider.Area.key/1` composes -- `authority_key`, `area_type_key` and `code`
joined by `:`, the same composition PostgreSQL stores in `area.area_key`. Build the area
an edge names and take its key from there rather than joining the parts by hand, so an
edge can only name a key `normalize/2` produced.

It composes with `relations/1` rather than replacing it: a provider whose areas nest
spatially may both rebuild measured relations and assert edges the geometry does not
carry, and both land in the same release. Asserted edges are written after every area
exists, so an edge may name any area the run produced rather than only the ones its own
row emitted. A provider whose source carries no hierarchy in its columns delegates to
`GeoGenius.Provider.no_asserted_relations/2`.

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
The callbacks and their responsibilities are otherwise unchanged.

`asserted_relations/2` is required, not optional. A provider written against the earlier
six-callback behaviour keeps compiling by adding one line:

```elixir
@impl GeoGenius.Provider
defdelegate asserted_relations(manifest, row), to: GeoGenius.Provider, as: :no_asserted_relations
```

## The SimpleMaps provider

`GeoGenius.Providers.SimpleMaps` (`"simplemaps"`) parses the SimpleMaps US cities and US
ZIP codes datasets: two comma-delimited files, `uscities` and `uszips`, named by the
artifact's `logical_name` rather than by a manifest option. It requires no `options` at
all. The files are licensed downloads, so the manifest this package ships,
`us_simplemaps`, declares both artifacts `operator_supplied` with a `cache_key` and no
`url`; place your copies in the cache under those keys, and replace each artifact's
`sha256` and `bytes` with the digest and size of the copy you licensed. The shipped
`license` and `attribution` describe the paid tier, whose row counts the validation rules
below are measured against, so replace those two as well if you licensed a different
tier -- the free files are CC BY 4.0. A host-shipped manifest wins over the package's
own, so the usual route is to copy it into your own `:manifest_paths` directory and edit
it there.

### Four area types

| Area type | Rank | Comes from                                              |
|-----------|------|---------------------------------------------------------|
| `state`   | 10   | the `state_id`/`state_name` columns of both files       |
| `county`  | 20   | the `county_fips_all` and county-name columns of both   |
| `city`    | 30   | a `uscities` row                                        |
| `zip`     | 40   | a `uszips` row                                          |

Only cities and ZIPs exist as rows. Counties and states are read out of columns, so they
carry only what those columns say: a code, a name, and a FIPS or ANSI code. They get no
centroid and no attributes, because a row's `lat`/`lng` and its demographic columns
measure the city or ZIP and nothing else.

Both files denormalise the whole hierarchy into every row, so `normalize/2` returns
several areas per row: a `uscities` row is its city, every county it falls in, and its
state; a `uszips` row is every county it touches, the ZIP, and its state. A ZIP row also
names a city, but only as the mailing name the USPS prefers for that ZIP, so that becomes
a `:mailing` name on the ZIP rather than a city area of its own -- the `uscities` file is
where a city gets its identity.

A row whose counties do not all lie in the state it names yields those states too, one
area each, read from the county FIPS prefixes. They carry a code and no name: `state_name`
on the row describes the row's state, not theirs.

### Three authorities, and the six state codes that key under the USPS

The manifest must declare all three. An area naming an authority the collection does not
carry is refused when the area is registered.

| Authority    | Keys                                          |
|--------------|------------------------------------------------|
| `simplemaps` | cities, under the vendor's own `id`            |
| `census`     | counties, and states that have an ANSI code    |
| `usps`       | ZIPs, and the six state codes that do not      |

`AA`, `AE` and `AP` are USPS constructs for military mail -- Armed Forces Americas, Europe
and Pacific. `FM`, `PW` and `MH` are the Freely Associated States -- Micronesia, Palau and
the Marshall Islands -- sovereign countries the USPS serves rather than states of any
kind. The Census defines none of the six and assigns none of them an ANSI code, so keying
them under `census` with an `ansi_state` code would assert two things no source says.
They key under `usps` and carry a `usps_state` external code instead.

**A host looking a state up by code must query both code types.** `ansi_state` alone
silently misses those six, and every ZIP under them; the two together are the whole set.

`AA`, `AE` and `AP` also publish nameless: `state_name` is blank in every one of their
`uszips` rows and `uscities` carries no row at all for any of the six codes, so those
three areas carry no name. Nothing invents one -- supplying "Armed Forces Europe" out of
a table in this library would manufacture a fact the source does not carry. They exist so
their ZIPs have a parent; a host that wants a label supplies its own.

### Area keys

`GeoGenius.Provider.Area.key/1` composes every one of them:

| Area type | Form                     | Example              |
|-----------|--------------------------|----------------------|
| `city`    | `simplemaps:city:<id>`   | `simplemaps:city:1840021543` |
| `county`  | `census:county:<fips>`   | `census:county:06075` |
| `state`   | `census:state:<code>`    | `census:state:CA`     |
| `state`   | `usps:state:<code>`      | `usps:state:AE`       |
| `zip`     | `usps:zip:<zip>`         | `usps:zip:94110`      |

### Relations

SimpleMaps carries centroids and no boundaries, so `relations/1` is `:none` and the whole
hierarchy comes from `asserted_relations/2`, read from the FIPS columns. A row asserts a
state-to-county edge per county it names, and a county-to-child edge per county:
`contains` when the row names one county, `overlaps` when it names several, since a place
crossing county lines is contained by neither. No edge is ever asserted between a city and
a ZIP in either direction -- a ZIP crosses city lines and neither one contains the other.

**A county's state comes from its own FIPS, never from the row's `state_id` column.** A
five-digit county FIPS begins with the two-digit FIPS of the state that assigns it, and
that is the only statement about the county's state a row cannot get wrong: ZIP `20041`
is a District of Columbia address for county `51107`, which is in Virginia, and 150 of the
source's 3,233 counties are named on rows of more than one state. A county whose prefix
names no state `GeoGenius.Providers.SimpleMaps.Fips` carries gets no state parent at all,
since the row's own column is the value already known to be describing something else.

A row naming no county asserts one edge instead: its state contains the ZIP directly.
That is the only parent such a row names, and hanging it there is truer than leaving it
with no parent at all.

### The county rules that fail a release

`GeoGenius.Providers.SimpleMaps.Validation` runs before anything is built from a row. A
row that fails ends the import, naming the column and enough of the row -- `zip`, `city`,
`state_id` -- to find it in a file of tens of thousands. Both files are checked for:

- `county_fips` present but absent from `county_fips_all`. The source is contradicting
  itself about which counties the row belongs to.
- `county_fips_all` and the county-name column (`county_name_all` on `uscities`,
  `county_names_all` on `uszips`) of different lengths. The two are paired positionally,
  so unequal lengths mean at least one FIPS is paired with the wrong name.

`uscities` is additionally checked for a row naming **no** county, and `uszips` for
`county_weights` that is blank beside a populated `county_fips_all`, that does not decode
as a JSON object, or whose keys are not exactly `county_fips_all`.

A blank code in `id`, `zip` or `state_id` is an error too, rather than the `:skip` the
CSV provider returns for a blank code column. SimpleMaps populates those columns in every
row of both files, so a blank one is a corrupt or truncated download, and `area_key` is
`<authority>:<area_type>:<code>` -- a blank code would put every such row under one
shared, meaningless key.

**The county-less asymmetry is measured, not assumed.** A `uscities` row naming no county
fails the release; a `uszips` row naming none is ordinary data. Every one of `uscities`'
109,071 rows names at least one county, because every city sits in one, so a row naming
none is corruption. 617 of `uszips`' 41,551 rows name none, because a military APO/FPO ZIP
delivers to an overseas address belonging to no US county; failing them would abort a real
import on the first one and never reach the other 616.

### What is not checked

**Every rule reads one staged row.** Nothing compares across rows or across the two
files. Cross-file agreement -- one FIPS mapping to two different states, or `uscities` and
`uszips` spelling one county's name two different ways -- cannot be seen from a single row
and is **not** checked here. GeoGenius accepts several official names for one area, so a
disagreement of that kind lands in the catalog as two names rather than as an error. A
host that needs cross-file agreement enforced verifies it itself, after the import.

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
yourself, which is worth knowing before you install it for something else. GeoGenius declares
`pgflow >= 0.3.4 and < 0.4.0` as an optional dependency: that establishes compile order when
a host opts in, without installing PgFlow for hosts that do not. For those hosts the first
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
The optional dependency edge ensures this library's job submodule compiles after `PgFlow.Job`
when the host adds PgFlow directly. PgFlow 0.3 releases may also compile dashboard modules
against their optional `phoenix`, `phoenix_live_view`, and `livefilter` packages; a host using
that dashboard opts into those dependencies too. This backend reports itself available once
`pgflow` and the job submodule are loaded and `PgFlow.Supervisor` is running; short of that it
returns an error naming what is missing rather than raising deep inside `PgFlow.enqueue/2`, and
the resolution falls through to `Runners.Task`.

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
into an unlogged table of this run's own. The table is emptied first: a resumed run stages
afresh, and an attempt killed where its cleanup could not run leaves rows behind under the
same run id.

`normalizing` reads the staged rows back in batches, calls the provider's `normalize/2`
on each, and writes the areas, names, codes, membership, and boundaries through
`GeoGenius.Catalog`.

A batch is collected in full and then written as a set: one statement for its areas, one
for its names, one for its codes, one for its memberships, through the
[set writes](sql_api.md#set-writes), and one for all its boundaries. A source that
denormalises a hierarchy names the same county in every city row of it, so a batch
describes far fewer distinct areas than it has rows, and one statement per area spends a
round trip on every repeat. Measured on the US SimpleMaps import -- 150,622 staged rows,
466,262 area writes over 153,917 distinct areas -- this phase costs 2,449 statements and
39.6 s written as sets, against 1,755,328 statements and 994.8 s written one area at a
time.

Collecting before writing also decides what a provider's own error leaves behind: an
illegal name kind, or a staged row naming an artifact this run did not stage, fails the
phase with none of that batch written, rather than partway through it. Earlier batches are
already committed, which is what makes the phase resumable; nothing opens a transaction
around a batch.

`relating` rebuilds measured relations from boundary overlap when `relations/1` asks for
it, and then writes every edge `asserted_relations/2` returns for each staged row, one
set write per batch the same way `normalizing` writes areas. The
two compose: a release can carry both. Measures `relations` (only when a rebuild ran) and
`asserted_relations`, which counts edges asserted rather than distinct edges written --
two rows asserting the same edge each add one, though the edge itself upserts to a single
row.

`indexing` runs `analyze_release`, so the release has statistics before anything plans a
query against it.

`verifying` runs `verify_release` and fails the run when the report is not `ok`. This is
the gate: a release that has no areas, that lacks a boundary somewhere the collection or
area type requires one, that carries a relation or a membership belonging to another
collection, or that declares no source releases, does not become publishable.

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

A resumed run re-runs every phase from `downloading`, rather than picking up at the phase
it stopped in. What makes that cheap is the artifact cache, which skips the network; the
staged rows of the interrupted attempt are discarded rather than reused, so a source that
changed between attempts cannot leave a deleted row in the release.

## Reading a run

`GeoGenius.import/1` returns `{:ok, run_id}` once the run is claimed and enqueued. The
work may be executing on another node, so both ways of reading it back go to PostgreSQL
rather than to a process.

```elixir
{:ok, run_id} = GeoGenius.import(collection: "demo", release: "r1")

GeoGenius.status(run_id)
# %GeoGenius.ImportRun{status: "normalizing", stage_metrics: %{"staged" => 1200}, ...}

GeoGenius.await(run_id)
# {:ok, %GeoGenius.ImportRun{status: "completed"}}
```

`status/2` returns one `%GeoGenius.ImportRun{}` snapshot, or `nil` for a run id the
catalog does not carry. `await/3` polls every 250ms until the run finishes or the timeout
elapses, returning `{:ok, run}`, `{:error, run}` for a run that finished and failed, or
`{:error, :timeout}`. Both read the `import_run_status` view described in
[`sql_api.md`](sql_api.md#views).

`await/3`'s `timeout` resolves the explicit argument first, then
`config :geo_genius, :await_timeout`, then a library default of 1,800,000ms (thirty
minutes). A full US SimpleMaps import, which carries no boundaries, runs in well under two
minutes; the thirty are sized for a boundary-carrying collection, whose geometry repair,
subdivision, and indexing can still dominate a national import even with set-based writes. Pass
`:infinity` at either level for a caller willing to wait as long as it takes:

```elixir
GeoGenius.await(run_id, :infinity)
```

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
