defmodule GeoGenius.Provider.Area.Name do
  @moduledoc """
  One name a `GeoGenius.Provider.Area` carries.

  `kind` is `:official`, `:alias`, `:mailing`, or `:abbreviation` -- an atom
  rather than a bare string, so a provider that misspells it fails to
  compile against Dialyzer rather than silently writing a name nothing
  queries for. That protection is armed only where a `kind` value flows into
  a spec'd boundary -- Dialyzer checks struct keys against a literal, not
  against `@type t`'s field types on every construction -- which is why
  every provider's `normalize/2` carries an explicit `@spec`.

  `GeoGenius.Catalog.put_area_name/3` binds `attrs.kind` straight into a SQL
  parameter. That bind expects a string, not an atom, so the normalization
  phase that turns a `%GeoGenius.Provider.Area{}` into `Catalog` writes
  stringifies `kind` on the way through: `GeoGenius.Pipeline.Normalize` is that
  seam, and an atom reaching the bind without it surfaces as a Postgrex encode
  error rather than a compile-time one.
  """

  @enforce_keys [:name, :kind]
  defstruct [:name, :kind, locale: nil]

  @type kind :: :official | :alias | :mailing | :abbreviation

  @type t :: %__MODULE__{
          name: String.t(),
          kind: kind(),
          locale: String.t() | nil
        }
end

defmodule GeoGenius.Provider.Area.Code do
  @moduledoc """
  One external code a `GeoGenius.Provider.Area` carries, such as a FIPS or
  GNIS identifier.

  `code_type` is a plain string, not a closed atom like `Name.kind` -- code
  types are open-ended (FIPS, GNIS, ZIP, a source's own postal code, and
  whatever the next authority calls its own identifier), so there is no
  fixed set to close over. That means a provider that misspells a code type
  gets no Dialyzer protection the way a misspelled `Name.kind` atom would;
  a typo here surfaces only as a code nothing queries for, at runtime.
  """

  @enforce_keys [:code_type, :code_value]
  defstruct [:code_type, :code_value]

  @type t :: %__MODULE__{code_type: String.t(), code_value: String.t()}
end

defmodule GeoGenius.Provider.Area do
  @moduledoc """
  The whole vocabulary a provider has for describing one area.

  `centroid` is a `%Geo.Point{}` or `nil`. When it is `nil` and `geometry` is
  present, the pipeline leaves it `nil` rather than asking PostGIS to derive
  one, because `put_area_in_release/4` accepts a null centroid.
  """

  alias GeoGenius.Provider.Area.{Code, Name}

  @enforce_keys [:authority_key, :area_type_key, :code]
  defstruct [
    :authority_key,
    :area_type_key,
    :code,
    :centroid,
    :geometry,
    names: [],
    codes: [],
    attributes: %{}
  ]

  @typedoc "Free-form, provider-specific attributes carried onto the area as-is."
  @type attributes :: %{optional(String.t()) => term()}

  @type t :: %__MODULE__{
          authority_key: String.t(),
          area_type_key: String.t(),
          code: String.t(),
          centroid: Geo.Point.t() | nil,
          geometry: Geo.geometry() | nil,
          names: [Name.t()],
          codes: [Code.t()],
          attributes: attributes()
        }

  @doc """
  The catalog key for an area: `authority_key`, `area_type_key` and `code`
  joined by `:`.

  This is the same composition PostgreSQL stores in `area.area_key`, which is
  what makes the key a provider composes here addressable by every read.
  `c:GeoGenius.Provider.asserted_relations/2` returns those keys as strings, so
  this is how a provider names the two ends of an edge without re-deriving the
  format. An area keyed `census`, `county`, `06075` is `"census:county:06075"`.

  The agreement between this and the column is pinned by `GeoGenius.PipelineTest`,
  once, rather than per caller.
  """
  @spec key(t()) :: String.t()
  def key(%__MODULE__{} = area) do
    "#{area.authority_key}:#{area.area_type_key}:#{area.code}"
  end
end

defmodule GeoGenius.Provider do
  @moduledoc """
  Behaviour a format adapter implements to bring one kind of source into the catalog.

  A provider is called for its parsing, never for a write: `stage/5` receives
  a file path and an `emit` function and reports only whether it succeeded;
  `normalize/2` receives one staged row and returns a described area. Every
  write is the pipeline's, made through `GeoGenius.Catalog`. That is the
  contract this behaviour expresses -- callers should not hand a provider a
  `Repo` or a `GeoGenius.Context`, and a provider that follows this
  behaviour never needs one. Elixir has no module-level enforcement of that,
  so it is a discipline the pipeline and the tests hold providers to, not a
  guarantee this module itself can make.

  `emit`, passed to `stage/5`, is called with a list of rows rather than a
  single row so a provider can batch; the pipeline supplies a function that
  writes through `GeoGenius.Staging.insert/3` and heartbeats the run. A
  provider stages a large artifact in chunks rather than one `emit` call for
  the whole file, both to bound the size of a single insert and because each
  `emit` call is also where the run's lease gets renewed.

  `stage/5` also takes an `opts` keyword list, which carries adapter modules
  resolved by the pipeline -- `[command: ..., work_dir: ...]` for a provider
  that shells out to convert its source first. The `:command` a provider is
  handed is `GeoGenius.Pipeline.CommandAllowlist`, which accepts `ogr2ogr` and
  refuses everything else; it reads the adapter it wraps from
  `:command_target`, also in `opts`, and a provider passing `opts` through to
  `command.run/3` unchanged (as `GeoGenius.Providers.Shapefile` does) carries
  that along without needing to know it is there. Resolving an adapter inside a
  provider would make it impossible to override per call and would give a
  provider a reason to read application environment, which nothing else in
  this layer does. A provider that needs neither entry in `opts` ignores it.
  `normalize/2` takes no such list: it is pure, so a caller derives an area
  from a staged row with no environment and no adapter to substitute.

  `area_types/0`, `artifacts/1`, `relations/1`, and `asserted_relations/2`
  have one body most providers share, so those bodies live here as
  `no_area_types/0`, `all_artifacts/1`, `always_rebuild/1`, and
  `no_asserted_relations/2`; a provider implements the callback with a
  one-line `defdelegate`, keeping its own `@impl` and `@doc`. A provider
  whose collections declare a fixed hierarchy, whose relations need none
  rebuilt, or whose rows carry a hierarchy in their columns implements the
  callback directly instead of delegating -- `GeoGenius.Providers.SimpleMaps`
  does all three.

  ## Option vocabulary across providers

  Each shipped provider names its manifest `options` keys for the shape its
  format actually carries -- a GeoJSON feature has properties, a CSV row has
  columns -- rather than a shared, format-neutral name that would read
  wrong on the page for one format or the other. The concepts underneath are
  the same one; this table is the one place to learn the correspondence:

  | Concept                    | `GeoGenius.Providers.GeoJSON` | `GeoGenius.Providers.CSV` | Default when omitted |
  |-----------------------------|-------------------------------|----------------------------|------------------------|
  | the area's code              | `"code_property"`             | `"code_column"`            | required, no default   |
  | the area's area type          | `"area_type"` (shared key)     | `"area_type"` (shared key)  | required, no default   |
  | the area's official name     | `"name_property"`             | `"name_column"`            | `"name"`                |
  | alias names                  | `"alias_properties"`          | `"alias_columns"`          | `[]`                    |
  | free-form attributes         | `"attribute_properties"`      | `"attribute_columns"`      | `[]`                    |
  | external codes               | `"code_properties"`           | `"code_columns"`           | `[]`                    |
  | authority                    | `"authority"` (shared key)     | `"authority"` (shared key)  | the manifest's own single authority |
  | delimiter                    | n/a                            | `"delimiter"`               | `","` (CSV only)        |

  `GeoGenius.Providers.Shapefile` reads the GeoJSON vocabulary, since it
  converts its archive before parsing it. `GeoGenius.Providers.SimpleMaps` is
  outside this table entirely: it parses two fixed files, reads their columns
  by name, and takes no options at all.

  Every string value this vocabulary reads out of a payload -- a code, a
  name, an attribute, an external code -- is trimmed before use, and a
  whitespace-only value is treated the same as an absent one: see
  `GeoGenius.Providers.Fields.presence/1`. A fixed-width source that pads a
  FIPS or ZIP code with spaces would otherwise carry that padding straight
  into `area_key`, a public, stable identifier, and a later re-import of the
  same source without the padding would create a second area rather than
  updating the first.
  """

  alias GeoGenius.Manifest
  alias GeoGenius.Manifest.Artifact
  alias GeoGenius.Provider.Area
  alias GeoGenius.Staging

  @typedoc "The adapters `stage/5` may use, resolved by the pipeline rather than read from application environment."
  @type stage_opts :: [command: module(), command_target: module(), work_dir: Path.t()]

  @typedoc "The failure a provider reports for a file it cannot parse or a manifest option it cannot resolve."
  @type reason :: String.t()

  @doc """
  The area types this provider's collections use when a manifest does not
  declare its own.

  A manifest's own `area_types` always wins; this exists for a provider whose
  collections share one fixed hierarchy across every release.
  """
  @callback area_types() :: [Manifest.area_type()]

  @doc """
  The manifest `options` keys this provider requires.

  Manifest validation checks that every key named here is present in a
  manifest's `options` map before the manifest is accepted.
  """
  @callback required_options() :: [String.t()]

  @doc "The artifacts, across a manifest's sources, this provider will stage."
  @callback artifacts(manifest :: Manifest.t()) :: [Artifact.t()]

  @doc """
  Parses `path` -- the downloaded or operator-supplied copy of `artifact` --
  and hands each resulting batch of rows to `emit`.

  `opts` carries the adapters described above. Returns `{:error, reason}`
  for a file this provider cannot parse; never raises for a malformed file,
  only for a defect in the provider itself.
  """
  @callback stage(
              manifest :: Manifest.t(),
              artifact :: Artifact.t(),
              path :: Path.t(),
              emit :: ([Staging.Row.t()] -> :ok),
              opts :: stage_opts()
            ) :: :ok | {:error, reason()}

  @doc """
  Describes one staged row as an area, or as several.

  Returns `:skip` for a row that carries no area -- a header, a summary
  record, a feature with no usable code -- rather than an error, since that
  is an expected shape for some rows rather than a failure.

  A list is for a source that denormalises a hierarchy into every row: a
  city row that also carries its county and state describes all three, and
  returning them together is cheaper and truer than staging the same row
  once per level. Areas repeated across rows converge on `area_key`, so a
  provider emits an implied parent from every row that implies it rather
  than tracking which it has already emitted.
  """
  @callback normalize(manifest :: Manifest.t(), row :: Staging.Row.t()) ::
              {:ok, Area.t()} | {:ok, [Area.t()]} | :skip | {:error, reason()}

  @doc """
  Whether the areas this provider stages need `parent_area_id` relations
  rebuilt after normalization.

  `:rebuild` for a provider whose areas nest spatially or by code; `:none`
  for a provider whose collection carries no hierarchy.
  """
  @callback relations(manifest :: Manifest.t()) :: :rebuild | :none

  @doc """
  Relation edges this row asserts, which geometry cannot measure.

  A source that carries its hierarchy in columns -- a county FIPS on every
  city row, an admin parent code on every place -- knows edges no overlap
  test can derive, and a source with no geometry at all has no other way to
  express one. Each edge is `{parent_area_key, child_area_key,
  relation_type}`, where `relation_type` is `"contains"`,
  `"mostly_contains"`, or `"overlaps"`.

  Both keys are the strings `GeoGenius.Provider.Area.key/1` composes. Build
  the `%GeoGenius.Provider.Area{}` an edge names and take its key from there,
  rather than joining the three parts by hand: an edge composed a second way
  can name a key `normalize/2` never produced, and `GeoGenius.Catalog.put_relation/3`
  refuses an area the release does not carry.

  Composes with `relations/1` rather than replacing it: a provider whose
  areas nest spatially may both rebuild measured relations and assert edges
  the geometry does not carry. Edges are written after every area exists, so
  an edge may reference an area any row emitted, not only its own.

  Asserting an edge for a pair `relations/1` also rebuilds from geometry
  overwrites that measurement: `GeoGenius.Catalog.put_relation/3` upserts on
  the same `(parent_area_id, child_area_id)` pair, nulling
  `intersection_area_m2`, `parent_coverage`, and `child_coverage` and
  replacing the geometry-classified `relation_type` with the asserted one,
  with no warning that a measurement was discarded. A provider returning
  `:rebuild` should assert only pairs geometry cannot derive, keeping the two
  sets of edges disjoint.
  """
  @callback asserted_relations(manifest :: Manifest.t(), row :: Staging.Row.t()) ::
              [
                {parent_area_key :: String.t(), child_area_key :: String.t(),
                 relation_type :: String.t()}
              ]

  @doc "No area types of its own; every manifest supplies its own `area_types`."
  @spec no_area_types() :: [Manifest.area_type()]
  def no_area_types, do: []

  @doc "Every artifact declared across a manifest's sources."
  @spec all_artifacts(Manifest.t()) :: [Artifact.t()]
  def all_artifacts(%Manifest{sources: sources}), do: Enum.flat_map(sources, & &1.artifacts)

  @doc "Always rebuilds relations; the collection carries no hierarchy of its own to preserve."
  @spec always_rebuild(Manifest.t()) :: :rebuild
  def always_rebuild(%Manifest{}), do: :rebuild

  @doc "Asserts no relations; the source carries no hierarchy in its columns."
  @spec no_asserted_relations(Manifest.t(), Staging.Row.t()) :: []
  def no_asserted_relations(%Manifest{}, %Staging.Row{}), do: []
end
