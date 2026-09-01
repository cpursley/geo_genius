defmodule GeoGenius.Providers.SimpleMaps.Rows do
  @moduledoc """
  Turns one staged SimpleMaps row into the areas it describes.

  This is the only module that knows SimpleMaps column names, so a source
  that renames a column is a change here and nowhere else.

  Both files denormalise the hierarchy into every row, so one row is several
  areas: a `uscities` row is a city, every county it falls in, and its state;
  a `uszips` row is a ZIP, every county it touches, and its state. A ZIP row
  also names a city, but only as the mailing name USPS prefers for that ZIP,
  which is why it becomes a name on the ZIP rather than a city area -- the
  `uscities` file is where a city gets its identity, and inventing a second
  one from a ZIP row would key the same city twice.

  A state is keyed under the authority that defines its code. Most states key
  under `census` and carry an `ansi_state` code. Six do not. `AA`, `AE` and
  `AP` are USPS constructs for military mail -- Armed Forces Americas, Europe
  and Pacific. `FM`, `PW` and `MH` are the Freely Associated States --
  Micronesia, Palau and the Marshall Islands -- sovereign countries the USPS
  serves rather than states of any kind. The Census defines none of the six
  and assigns none of them an ANSI code, so keying them under `census` with
  an `ansi_state` code would assert two things no source says. They key under
  `usps` and carry a `usps_state` code instead. The code is carried rather
  than omitted because it is true and it leaves a host the same external-code
  join every other area offers; an area with no code at all would be
  reachable only by key. Their area type defaults to `state` for compatibility,
  but `areas/2` and `edges/2` accept the separately declared type selected by
  the SimpleMaps manifest's `non_census_state_area_type` option.

  Nothing else about them changes: a name is read from `state_name` the way
  every other state's is. `FM`, `PW` and `MH` carry one and get it. `AA`, `AE`
  and `AP` publish nameless: `state_name` is blank in every one of their
  `uszips` rows, and `uscities` carries no row at all for any of the six
  codes, so nothing anywhere supplies a name and none is invented to fill
  the gap. Supplying
  "Armed Forces Europe" out of a table in this library would manufacture a
  fact the source does not carry, the same way a centroid copied off a row
  would. Those three exist so their ZIPs have a parent, and a host that wants
  a label for them supplies its own.

  A county belongs to the state its FIPS is assigned within -- the first two
  digits of a five-digit county FIPS -- and not to whatever state the row
  carrying it names. The two disagree wherever a mailing address crosses a
  state line, and `GeoGenius.Providers.SimpleMaps.Fips` is where the prefix is
  read. A row whose county lies in another state yields that state as an area
  of its own beside the row's, so the hierarchy `edges/1` asserts from the
  same prefix can only name areas `areas/1` produced.

  A county and a state are read out of columns rather than off rows of their
  own, so they carry only what those columns say: their code, their name, and
  their FIPS or ANSI code. They get no centroid, because the row's `lat`/`lng`
  measures the city or ZIP and nothing else; a centroid copied from the row
  would make `areas_near` return a fact nobody measured. They get no
  attributes for the same reason -- the demographic columns of a row describe
  the city or ZIP, and hanging them on the county would let the last row
  imported decide what the county's median income is.

  `edges/2` reads the same county columns `areas/2` does, through the same
  helpers, so the hierarchy this provider asserts can only ever name keys
  `areas/2` produced.

  This module knows SimpleMaps column names and how to parse them.
  `GeoGenius.Providers.SimpleMaps.Validation` reuses `list/2`, `field/2`,
  `label/1`, and the two counties-column-name accessors here rather than
  re-deriving them, so the two modules can never disagree about how a column
  is read. `areas/2` runs `Validation.check/1` before building anything, so a
  row whose county columns contradict each other fails the release instead of
  being silently reconciled.
  """

  alias GeoGenius.Provider.Area
  alias GeoGenius.Provider.Area.Code
  alias GeoGenius.Provider.Area.Name
  alias GeoGenius.Providers.Fields
  alias GeoGenius.Providers.SimpleMaps.Fips
  alias GeoGenius.Providers.SimpleMaps.Validation
  alias GeoGenius.Staging

  # `uscities` spells its counties column "county_name_all" (singular
  # "name"); `uszips` spells the same column "county_names_all" (plural). A
  # row's artifact decides which of the two is paired with "county_fips_all".
  @cities_county_names "county_name_all"
  @zips_county_names "county_names_all"

  # "county_fips_all" and the counties column are pipe-delimited lists,
  # positionally paired: the nth fips is named by the nth name.
  @separator "|"

  # Read in this order into the description of a row an error names. These
  # three public place-name columns are the whole allowlist, and widening it
  # to whatever the row carries is what would put payload content -- a
  # demographic figure, an internal identifier -- into an error persisted on
  # the import run.
  @label_columns ["zip", "city", "state_id"]

  # A blank required column means a corrupt or truncated download, which in a
  # CSV usually means broken quoting, and a mis-quoted field can swallow a
  # whole line into one cell. Each value the label names is capped so the
  # error stays a description of the row rather than a copy of it.
  @label_value_length 64

  @doc """
  Returns the areas one staged row describes, in hierarchy order.

  A `uscities` row yields its city, its counties, and its state; a `uszips`
  row yields its counties, its ZIP, and its state. Any other artifact is an
  error, since this provider parses only the two files it declares.

  `Validation.check/1` runs first, so a row whose county columns contradict
  each other -- a primary `county_fips` missing from `county_fips_all`, a
  counties column of a different length than `county_fips_all`, or a ZIP's
  `county_weights` naming a county set that disagrees with it -- is an error
  before anything is built from it.

  A row whose counties do not all lie in the state it names yields the states
  they do lie in as well, one area each, read from their FIPS prefixes. A ZIP
  in the District of Columbia naming a county in Virginia describes Virginia,
  however little of it, and the county has to hang somewhere.

  A row whose city, ZIP, or state code is blank is an error rather than an
  area: `area_key` is `<authority>:<area_type>:<code>`, so a blank code would
  put every such row under one shared, meaningless key.

  That is a deliberate divergence from `GeoGenius.Providers.CSV`, which
  returns `:skip` for a row whose code column is blank. A CSV collection is
  described by a manifest that may name a column the source populates only
  sometimes, so skipping is the right read of a gap there. SimpleMaps
  populates these columns in every row of both files, so a blank one is a
  corrupt or truncated download rather than a shape to tolerate, and failing
  the release is better than publishing a hierarchy missing the rows nobody
  was told about. The error names the column and enough of the row to find
  it in a file of tens of thousands.
  """
  @spec areas(Staging.Row.t()) :: {:ok, [Area.t()]} | {:error, String.t()}
  def areas(%Staging.Row{} = row), do: areas(row, "state")

  @doc "Like `areas/1`, with the area type selected for the six USPS-only state codes."
  @spec areas(Staging.Row.t(), String.t()) :: {:ok, [Area.t()]} | {:error, String.t()}
  def areas(%Staging.Row{} = row, non_census_state_area_type) do
    with :ok <- Validation.check(row) do
      build(row, non_census_state_area_type)
    end
  end

  defp build(%Staging.Row{artifact: "uscities", payload: payload}, non_census_state_area_type) do
    with {:ok, id} <- require_field(payload, "id"),
         {:ok, state_id} <- require_field(payload, "state_id") do
      counties = counties(payload, @cities_county_names)

      {:ok,
       [city(id, payload) | counties] ++
         [
           state(state_id, payload, non_census_state_area_type)
           | county_states(counties, state_id, non_census_state_area_type)
         ]}
    end
  end

  defp build(%Staging.Row{artifact: "uszips", payload: payload}, non_census_state_area_type) do
    with {:ok, code} <- require_field(payload, "zip"),
         {:ok, state_id} <- require_field(payload, "state_id") do
      counties = counties(payload, @zips_county_names)

      {:ok,
       counties ++
         [
           zip(code, payload),
           state(state_id, payload, non_census_state_area_type)
           | county_states(counties, state_id, non_census_state_area_type)
         ]}
    end
  end

  defp build(%Staging.Row{artifact: other}, _non_census_state_area_type) do
    {:error, "unknown artifact #{other}"}
  end

  @doc false
  @spec cities_county_names_column() :: String.t()
  def cities_county_names_column, do: @cities_county_names

  @doc false
  @spec zips_county_names_column() :: String.t()
  def zips_county_names_column, do: @zips_county_names

  @doc """
  Returns the relation edges one staged row asserts, parent first.

  SimpleMaps carries centroids and no boundaries, so nothing here can be
  measured by overlap; the FIPS columns are the only statement of hierarchy
  the source makes, and these edges are that statement.

  A `uscities` row asserts one state-to-county edge per county it names and
  one county-to-city edge per county; a `uszips` row asserts the same
  state-to-county edges and a county-to-zip edge per county. The state on a
  county's edge is the one its own FIPS prefix names, never the one the row
  carrying it does, and a county whose prefix names no state this provider
  knows gets no state edge at all rather than a false one. A ZIP row's
  `city` column is the mailing name USPS prefers for that ZIP, so no edge is
  asserted between a city and a ZIP in either direction -- a ZIP crosses city
  lines, and neither one contains the other.

  Every edge names the parent first, the order
  `GeoGenius.Catalog.put_relation/4` takes: a swapped pair writes
  successfully and silently inverts `GeoGenius.children_of/2` and
  `GeoGenius.ancestors_of/2`.

  A row naming no county asserts one edge instead: its state contains the ZIP
  directly. A military or Freely Associated States ZIP is in its state and in
  no county, so the state is the only parent it has, and hanging it there is
  truer than leaving it with no parent at all. That edge is emitted only for
  a row with no county -- where counties exist they already connect the ZIP,
  and a state-to-zip edge beside them would assert a second path to the same
  place. A `uscities` row never takes this path, because
  `GeoGenius.Providers.SimpleMaps.Validation.check/1` fails a city row that
  names no county before this is reached.

  Returns `[]` for an artifact this provider does not parse, since
  `areas/1` is what reports that as an error.
  """
  @spec edges(Staging.Row.t()) :: [{String.t(), String.t(), String.t()}]
  def edges(%Staging.Row{} = row), do: edges(row, "state")

  @doc "Like `edges/1`, with the area type selected for the six USPS-only state codes."
  @spec edges(Staging.Row.t(), String.t()) :: [{String.t(), String.t(), String.t()}]
  def edges(
        %Staging.Row{artifact: "uscities", payload: payload},
        non_census_state_area_type
      ) do
    payload
    |> counties(@cities_county_names)
    |> hierarchy(payload, key_of(payload, "id", &city/2), non_census_state_area_type)
  end

  def edges(%Staging.Row{artifact: "uszips", payload: payload}, non_census_state_area_type) do
    payload
    |> counties(@zips_county_names)
    |> hierarchy(payload, key_of(payload, "zip", &zip/2), non_census_state_area_type)
  end

  def edges(%Staging.Row{}, _non_census_state_area_type), do: []

  # A row naming no county hangs its child straight off the state, which is
  # the only parent it has: a military or Freely Associated States ZIP is in
  # its state and in no county, and 617 rows of `uszips` are that shape. The
  # edge is emitted only here. Where the row does name counties they already
  # carry the connection, and a state-to-child edge beside them would assert
  # a second, redundant path to the same place. A `uscities` row never
  # reaches this clause: `GeoGenius.Providers.SimpleMaps.Validation.check/1`
  # fails a city row naming no county before normalization.
  defp hierarchy([], payload, child_key, non_census_state_area_type) do
    state_builder = fn state_id, state_payload ->
      state(state_id, state_payload, non_census_state_area_type)
    end

    edge(key_of(payload, "state_id", state_builder), child_key, "contains")
  end

  # A county FIPS is assigned within a state and its first two digits name
  # that state, so each county hangs under the state its own code states
  # rather than under the one the row's `state_id` column carries: ZIP 20041
  # is a District of Columbia address for county 51107, which is in Virginia,
  # and 150 of the source's 3,233 counties are named on rows of more than one
  # state. The city or ZIP is contained only where the row names one county;
  # a row naming several describes a place crossing county lines, which each
  # of those counties overlaps rather than contains.
  defp hierarchy(counties, _payload, child_key, non_census_state_area_type) do
    child_type = child_relation_type(counties)

    Enum.flat_map(counties, fn county ->
      county_key = Area.key(county)

      edge(state_key_of(county, non_census_state_area_type), county_key, "contains") ++
        edge(county_key, child_key, child_type)
    end)
  end

  # A county whose FIPS names no state this provider carries a code for gets
  # no state parent, rather than the row's own state: the row's column
  # describes the row's address, which is a different claim, and it is wrong
  # about the county often enough to be why the prefix is read at all.
  # `edge/3` drops a nil parent, so the county keeps its child edge and loses
  # only the assertion nothing supports.
  defp state_key_of(county, non_census_state_area_type) do
    case county_state(county, non_census_state_area_type) do
      nil -> nil
      state -> Area.key(state)
    end
  end

  # The state a county belongs to, built through the same `state/2` every
  # other state area is, so a derived one carries the authority, code type and
  # key the row's own would. It carries no name: `state_name` on the row
  # describes the row's state, and copying it onto a different state would
  # label Virginia "District of Columbia".
  defp county_state(%Area{code: fips}, non_census_state_area_type) do
    case Fips.state_code(fips) do
      nil -> nil
      code -> state(code, %{}, non_census_state_area_type)
    end
  end

  # The states a row's counties lie in that the row itself does not name.
  # `GeoGenius.Catalog.put_relation/4` requires both ends of an edge to be
  # members of the release, so the state a county hangs under has to be an
  # area this row produced, not one another row is assumed to have produced.
  defp county_states(counties, state_id, non_census_state_area_type) do
    counties
    |> Enum.map(&county_state(&1, non_census_state_area_type))
    |> Enum.reject(&(is_nil(&1) or &1.code == state_id))
    |> Enum.uniq_by(& &1.code)
  end

  defp child_relation_type([_county]), do: "contains"
  defp child_relation_type(_counties), do: "overlaps"

  defp edge(nil, _child_key, _type), do: []
  defp edge(_parent_key, nil, _type), do: []
  defp edge(parent_key, child_key, type), do: [{parent_key, child_key, type}]

  # Builds the area whose key an edge names rather than composing the key
  # from raw cells, so an edge can only ever name a key `areas/1` produced.
  # `Area.key/1` is the one statement of the format, shared with the pipeline
  # and with PostgreSQL's own `area_key`.
  defp key_of(payload, code_column, build) do
    case field(payload, code_column) do
      nil -> nil
      code -> code |> build.(payload) |> Area.key()
    end
  end

  defp require_field(payload, column) do
    case Fields.presence(Map.get(payload, column)) do
      nil -> {:error, "row carries no value in the #{inspect(column)} column (#{label(payload)})"}
      value -> {:ok, value}
    end
  end

  # An import halts on the first row it cannot normalize, so the error has to
  # say which of tens of thousands of rows that was. The columns naming the
  # row are the same ones that can be blank, so a row is described by whatever
  # of them it does carry. Exposed for `Validation` to describe the same row
  # the same way.
  @doc false
  @spec label(map()) :: String.t()
  def label(payload) do
    @label_columns
    |> Enum.map(&{&1, field(payload, &1)})
    |> Enum.reject(fn {_column, value} -> is_nil(value) end)
    |> Enum.map_join(", ", fn {column, value} -> "#{column}=#{capped(value)}" end)
    |> case do
      "" -> "no other column identifies it"
      label -> label
    end
  end

  defp capped(value) do
    case String.slice(value, 0, @label_value_length) do
      ^value -> value
      prefix -> prefix <> "..."
    end
  end

  defp city(id, payload) do
    %Area{
      authority_key: "simplemaps",
      area_type_key: "city",
      code: id,
      centroid: point(payload),
      geometry: nil,
      names: city_names(payload),
      codes: [],
      attributes: payload
    }
  end

  # "county_fips_all" always contains the primary "county_fips", which
  # Validation enforces, so the primary needs no separate append. Pairing
  # happens before de-duplication so a repeated fips keeps the name it was
  # first listed with rather than the last.
  defp counties(payload, names_column) do
    names = list(payload, names_column)

    payload
    |> list("county_fips_all")
    |> Enum.with_index()
    |> Enum.uniq_by(fn {fips, _index} -> fips end)
    |> Enum.map(fn {fips, index} -> county(fips, Enum.at(names, index)) end)
  end

  defp county(fips, name) do
    %Area{
      authority_key: "census",
      area_type_key: "county",
      code: fips,
      centroid: nil,
      geometry: nil,
      names: official_names(name),
      codes: [%Code{code_type: "county_fips", code_value: fips}],
      attributes: %{}
    }
  end

  defp state(state_id, payload, non_census_state_area_type) do
    if Fips.non_census_state_code?(state_id) do
      state_area(state_id, payload, "usps", non_census_state_area_type, "usps_state")
    else
      state_area(state_id, payload, "census", "state", "ansi_state")
    end
  end

  defp state_area(state_id, payload, authority, area_type, code_type) do
    %Area{
      authority_key: authority,
      area_type_key: area_type,
      code: state_id,
      centroid: nil,
      geometry: nil,
      names: payload |> field("state_name") |> official_names(),
      codes: [%Code{code_type: code_type, code_value: state_id}],
      attributes: %{}
    }
  end

  defp zip(code, payload) do
    %Area{
      authority_key: "usps",
      area_type_key: "zip",
      code: code,
      centroid: point(payload),
      geometry: nil,
      names: mailing_names(payload),
      codes: [%Code{code_type: "usps_zip", code_value: code}],
      attributes: payload
    }
  end

  # "city_ascii" is the official name with its diacritics folded away and
  # "city_alt" another name the place goes by, so both are aliases of the
  # one official name rather than names of their own. Either can repeat the
  # official name -- most rows have an ascii name identical to it -- and a
  # repeat is dropped rather than written as an alias of itself.
  defp city_names(payload) do
    official = field(payload, "city")

    aliases =
      ["city_ascii", "city_alt"]
      |> Enum.map(&field(payload, &1))
      |> Enum.reject(&(is_nil(&1) or &1 == official))
      |> Enum.uniq()
      |> Enum.map(&%Name{name: &1, kind: :alias})

    official_names(official) ++ aliases
  end

  defp mailing_names(payload) do
    case field(payload, "city") do
      nil -> []
      name -> [%Name{name: name, kind: :mailing}]
    end
  end

  defp official_names(nil), do: []
  defp official_names(name), do: [%Name{name: name, kind: :official}]

  @doc false
  @spec field(map(), String.t()) :: String.t() | nil
  def field(payload, column), do: Fields.presence(Map.get(payload, column))

  # Splits a pipe-delimited column into its present values. Exposed for
  # `Validation` to read `county_fips_all` and the counties column the same
  # way this module pairs them.
  @doc false
  @spec list(map(), String.t()) :: [String.t()]
  def list(payload, column) do
    payload
    |> Map.get(column, "")
    |> to_string()
    |> String.split(@separator, trim: true)
    |> Enum.map(&Fields.presence/1)
    |> Enum.reject(&is_nil/1)
  end

  defp point(payload) do
    with lng when is_binary(lng) <- field(payload, "lng"),
         lat when is_binary(lat) <- field(payload, "lat"),
         {lng, ""} <- Float.parse(lng),
         {lat, ""} <- Float.parse(lat) do
      %Geo.Point{coordinates: {lng, lat}, srid: 4326}
    else
      _other -> nil
    end
  end
end
