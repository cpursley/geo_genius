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

  `area_types/0`, `artifacts/1`, and `relations/1` are byte-identical across
  every provider this package ships, so their bodies live here as
  `no_area_types/0`, `all_artifacts/1`, and `always_rebuild/1`; a provider
  implements the callback with a one-line `defdelegate`, keeping its own
  `@impl` and `@doc`. A provider whose collections do declare a fixed
  hierarchy, or whose relations sometimes need none rebuilt, implements the
  callback directly instead of delegating.

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
  | authority                    | `"authority"` (shared key)     | `"authority"` (shared key)  | the manifest's own `authority.key` |
  | delimiter                    | n/a                            | `"delimiter"`               | `","` (CSV only)        |

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
  Describes one staged row as an area.

  Returns `:skip` for a row that carries no area -- a header, a summary
  record, a feature with no usable code -- rather than an error, since that
  is an expected shape for some rows rather than a failure.
  """
  @callback normalize(manifest :: Manifest.t(), row :: Staging.Row.t()) ::
              {:ok, Area.t()} | :skip | {:error, reason()}

  @doc """
  Whether the areas this provider stages need `parent_area_id` relations
  rebuilt after normalization.

  `:rebuild` for a provider whose areas nest spatially or by code; `:none`
  for a provider whose collection carries no hierarchy.
  """
  @callback relations(manifest :: Manifest.t()) :: :rebuild | :none

  @doc "No area types of its own; every manifest supplies its own `area_types`."
  @spec no_area_types() :: [Manifest.area_type()]
  def no_area_types, do: []

  @doc "Every artifact declared across a manifest's sources."
  @spec all_artifacts(Manifest.t()) :: [Artifact.t()]
  def all_artifacts(%Manifest{sources: sources}), do: Enum.flat_map(sources, & &1.artifacts)

  @doc "Always rebuilds relations; the collection carries no hierarchy of its own to preserve."
  @spec always_rebuild(Manifest.t()) :: :rebuild
  def always_rebuild(%Manifest{}), do: :rebuild
end
