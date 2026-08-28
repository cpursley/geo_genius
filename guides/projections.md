# Projections: keeping a source's own columns

GeoGenius stores area **identity**: keys, names, codes, relations, centroids, and
boundaries. It does not store a source's own attribute columns, and it will not grow a
table for them. Every source has a different set, they change between releases, and a
catalog that absorbed them would end up with a column list that belongs to whoever
adopted the library first.

What it gives you instead is a **projection**: a table *you* own, keyed
`(release_id, area_key)`, holding whichever of a source's columns your application
actually reads, filled from the same artifacts the import consumed.

This guide shows how to build one. The library's part is finding the artifact files —
`GeoGenius.ReleaseArtifacts` — which is the part every host would otherwise have to
rediscover, and get wrong in the same way. Parsing them and writing your rows is yours:
GeoGenius never sees your columns, your types, or your file format.

The examples use an invented collection, `atlas_districts`, published by an invented
vendor whose release ships one delimited file, `districts.tsv`, carrying a `tier` and a
`service_hours` column per district. Substitute your own throughout.

## Why `(release_id, area_key)`

A release is immutable once published, and a collection can have more than one release
in the database at a time — the published one, the one being verified, and whichever
older ones you have not retired yet. Attribute values belong to a release, not to an
area: the same district can be `tier` `"a"` in one release and `"b"` in the next.

So the key is the pair.

- **`area_key`** joins your row to the catalog. It is the stable identity string —
  `authority:area_type:code` — that every read returns on `%GeoGenius.AreaMatch{}`.
- **`release_id`** is which release the values came from. Without it, a repopulation
  either overwrites values a request in flight is still reading, or leaves you unable to
  tell a stale row from a current one.

Keying this way means populating a new release is an insert, not an update: nothing your
application currently reads changes until you publish, which is exactly the guarantee the
catalog itself gives.

```sql
CREATE TABLE district_facts (
  release_id uuid NOT NULL,
  area_key   text NOT NULL,
  tier       text,
  service_hours integer,
  PRIMARY KEY (release_id, area_key)
);
```

Whether you also add a foreign key to `<prefix>.release(id)` is a real choice with a
cost either way. A foreign key gets you referential integrity and ties this migration to
the schema prefix GeoGenius is installed under; storing the uuid alone keeps your
migration independent of the library's installation and leaves pruning to you. Neither is
wrong. Decide it once and write down which you picked.

Read your projection by joining on both columns, with the release id the read you are
already doing returned:

```sql
SELECT a.area_key, a.name, f.tier
  FROM geo_genius.published_areas a
  JOIN district_facts f
    ON f.release_id = a.release_id AND f.area_key = a.area_key
 WHERE a.collection_key = 'atlas_districts';
```

## Finding the artifact

An artifact is not at a path you can compose. It arrives on the machine through
`GeoGenius.Cache`, under a key that the manifest either supplied or the catalog derived
from the collection, source, source release, and logical name. Two things follow, and
both have bitten a host already:

- An **operator-supplied** artifact — a licensed file no URL can serve, which somebody
  places by hand before the import runs — has no `url` at all. Its cache key is its only
  address.
- The directory an import staged a download in is a work directory. It is gone by the
  time you want to read the file. `priv/` is not where any of this lives either; a
  resolver that looks there works against a checked-in fixture and raises `:enoent` on a
  documented fresh install.

`GeoGenius.ReleaseArtifacts` answers it properly. `list/2` returns every artifact of a
release; `fetch/3` returns one by logical name; `path/3` returns a file you can open.

```elixir
{:ok, artifacts} = GeoGenius.ReleaseArtifacts.list("atlas_districts")

Enum.map(artifacts, &{&1.logical_name, &1.path, &1.present?})
#=> [{"districts.tsv", "/var/cache/geo_genius/atlas_districts/...", true}]
```

Each `%GeoGenius.ReleaseArtifacts.Artifact{}` carries where the file belongs
(`:path`), whether anything is actually there (`:present?`), the `:cache_key` it resolves
under, and the release and source release it came from, plus the `:expected_sha256` and
`:expected_bytes` the manifest declared if you want to verify the bytes yourself.

All three functions read the collection's **published** release. Pass `:release_id` to
read a different one — which is how you populate a projection for a release *before* you
publish it. Options otherwise are the usual ones: `:repo`, `:prefix`, and whatever your
cache adapter takes.

### The errors are the interesting part

`path/3` refuses to hand back a path to a file that is not there, because the alternative
is an `:enoent` raised from inside whatever stream you opened, naming neither the file
nor the fix.

```elixir
case GeoGenius.ReleaseArtifacts.path("atlas_districts", "districts.tsv") do
  {:ok, path} ->
    load(path)

  {:error, %GeoGenius.ArtifactError{reason: :not_cached} = error} ->
    # Names the expected path and the cache key: an operator can act on this.
    Logger.error(Exception.message(error))
    {:error, :artifact_missing}

  {:error, %GeoGenius.ArtifactError{reason: :no_published_release}} ->
    {:error, :nothing_published}
end
```

The remaining reasons are `:unknown_artifact`, for a logical name the release does not
compose (the message lists the ones it does); `:invalid_cache_key`, for a registered
artifact whose stored key cannot address anything — a defect in what was registered, not
something a retry fixes; and `:unknown_release` and `:foreign_release`, for a
`:release_id` that the catalog does not carry and one that belongs to a different
collection.

That last pair matters more than it looks. A release id you stored months ago can go
stale, and a release-scoped read filters on the id alone — so without the check, a
repopulation against a stale id would delete your rows for it and write nothing back,
emptying the projection with no error to notice. An id belonging to another collection
would be worse: you would fill your table from another collection's files. Both are
refused.

## Populating

Everything below this line is yours. GeoGenius has no opinion about your parser, and the
row shape here is invented.

```elixir
defmodule MyApp.Atlas.DistrictFacts do
  @collection "atlas_districts"
  @artifact "districts.tsv"

  alias GeoGenius.ReleaseArtifacts

  def repopulate(opts \\ []) do
    with {:ok, artifact} <- ReleaseArtifacts.fetch(@collection, @artifact, opts),
         {:ok, path} <- local_file(artifact) do
      MyApp.Repo.transaction(fn ->
        MyApp.Repo.query!("DELETE FROM district_facts WHERE release_id = $1", [
          Ecto.UUID.dump!(artifact.release_id)
        ])

        path
        |> File.stream!()
        |> Stream.map(&parse_row/1)
        |> Stream.chunk_every(1_000)
        |> Stream.each(&insert_all(artifact.release_id, &1))
        |> Stream.run()
      end)
    end
  end

  defp local_file(artifact) do
    if artifact.present?,
      do: {:ok, artifact.path},
      else: {:error, "#{artifact.logical_name} is not at #{artifact.path}"}
  end
end
```

Three things worth doing whatever your parser looks like:

- **Delete then insert, in one transaction, scoped to the one release id.** Repopulating
  is then idempotent and never leaves a half-written release visible.
- **Skip rows whose `area_key` the catalog does not carry**, rather than inserting them.
  A source file routinely describes areas the import filtered out, and a projection row
  with no area to join to is invisible and unaccounted for.
- **Populate before you publish.** Read the release id from
  `GeoGenius.import/1`'s run (`GeoGenius.status/2`), pass it as `:release_id`, populate,
  then call `GeoGenius.publish/2`. The pointer swap then makes the areas and their
  attributes visible in the same instant.

## A new release

Nothing about a projection is incremental. A new release means a new `release_id`, so
repopulation writes a disjoint set of rows and touches none of the ones being read.

If you populate after publication instead — which is fine, if a short window with areas
but no attributes is acceptable — subscribe to the `:release_published` event through a
`GeoGenius.Notifier` and repopulate from its `:release_id`. See
[`installation.md`](installation.md) for wiring a notifier.

## Retiring

`GeoGenius.Catalog.retire_releases/3` drops the bulk data of old releases — geometry,
membership, relations — and deliberately keeps the `release` rows, because import runs
and publication events reference them. It knows nothing about your table, so your rows
survive a retirement that made them useless.

Prune them on the same schedule, keeping the releases you can still be asked about:

```sql
DELETE FROM district_facts
 WHERE release_id NOT IN (
   SELECT release_id FROM geo_genius.publication
    WHERE collection_id = (
      SELECT id FROM geo_genius.collection WHERE key = 'atlas_districts')
   UNION
   SELECT previous_release_id FROM geo_genius.publication
    WHERE collection_id = (
      SELECT id FROM geo_genius.collection WHERE key = 'atlas_districts')
      AND previous_release_id IS NOT NULL
 );
```

That keeps the published release and the one a rollback would return to. If you serve
historical queries through `GeoGenius.release_at/2`, keep every release you are willing
to be asked about instead, and prune by age rather than by publication.

## What GeoGenius will not do for you

Deliberately, so that the library stays usable by hosts whose sources look nothing like
yours:

- No projection table generator, and no migration generator. You own the columns and
  their types.
- No parser. The library ships providers for the formats *ingestion* understands; a
  projection's file may be a format nothing in GeoGenius has ever read.
- No assumed column set, and no attribute vocabulary. `release_id` and `area_key` are
  the entire contract.

If you find yourself wanting one of these in the library, the thing you actually want is
a shared module in your own application, over `GeoGenius.ReleaseArtifacts`.
