defmodule GeoGenius.Providers.SimpleMaps.Fips do
  @moduledoc """
  The state a county FIPS code is assigned within.

  A county FIPS is five digits: the two-digit FIPS of the state that assigns
  it, then a three-digit county code. `51107` is Loudoun County, and the `51`
  in front of it is Virginia. That prefix is the only statement of a county's
  state either SimpleMaps file makes that cannot disagree with itself -- a
  row's own `state_id` column describes the row, not the county, and the two
  differ wherever a mailing address crosses a state line. ZIP `20041` carries
  `state_id` DC and `county_fips` 51107: Dulles-area mail with a District of
  Columbia address, delivered to a county in Virginia. 150 of the source's
  3,233 counties are named on rows of more than one state.

  So the mapping has to run the other way -- from FIPS to state, not from the
  row -- and neither file carries it. `uscities` and `uszips` name states only
  by their two-letter postal code, never by state FIPS, and no row anywhere
  states that `51` is `VA`. Deriving the pair from the rows themselves is what
  the row-scoped provider callbacks cannot do: `GeoGenius.Provider` hands
  `normalize/2` and `asserted_relations/2` one staged row at a time with no
  accumulator between them, and the row that needs the answer -- the ZIP whose
  state and county disagree -- is exactly the row that gets it wrong. The
  table is therefore stated here.

  It is US knowledge, and it lives in the provider because that is what a
  provider is: `GeoGenius.Providers.SimpleMaps` parses one vendor's two US
  files and nothing else. Nothing outside `lib/geo_genius/providers/` knows a
  FIPS code from a postcode.

  ## What is in the table

  The fifty states, the District of Columbia, and the five inhabited
  territories the Census assigns a state-level FIPS to: American Samoa (60),
  Guam (66), the Northern Mariana Islands (69), Puerto Rico (72), and the US
  Virgin Islands (78). Every one of them appears in `uszips` as a `state_id`
  and has counties or county equivalents under it.

  Three codes deliberately absent are the Freely Associated States -- `FM`,
  `PW` and `MH` -- which FIPS 5-2 once numbered 64, 70 and 68 before the
  standard was withdrawn. They are sovereign countries the USPS serves, they
  have no US counties, and no row of either file carries a `county_fips`
  under them. Listing withdrawn codes would invite a five-digit number that
  happens to start with `64` to be read as a county of Micronesia.

  `AA`, `AE` and `AP` are absent for a stronger reason: they are USPS
  constructs for military mail, not places, and no FIPS numbers them at all.
  A county can never belong to one, which is precisely the assertion the row's
  own state column was making before the prefix was consulted.
  """

  # Two-digit state FIPS to the two-letter postal code
  # `GeoGenius.Providers.SimpleMaps.Rows` keys a state area under.
  @states %{
    "01" => "AL",
    "02" => "AK",
    "04" => "AZ",
    "05" => "AR",
    "06" => "CA",
    "08" => "CO",
    "09" => "CT",
    "10" => "DE",
    "11" => "DC",
    "12" => "FL",
    "13" => "GA",
    "15" => "HI",
    "16" => "ID",
    "17" => "IL",
    "18" => "IN",
    "19" => "IA",
    "20" => "KS",
    "21" => "KY",
    "22" => "LA",
    "23" => "ME",
    "24" => "MD",
    "25" => "MA",
    "26" => "MI",
    "27" => "MN",
    "28" => "MS",
    "29" => "MO",
    "30" => "MT",
    "31" => "NE",
    "32" => "NV",
    "33" => "NH",
    "34" => "NJ",
    "35" => "NM",
    "36" => "NY",
    "37" => "NC",
    "38" => "ND",
    "39" => "OH",
    "40" => "OK",
    "41" => "OR",
    "42" => "PA",
    "44" => "RI",
    "45" => "SC",
    "46" => "SD",
    "47" => "TN",
    "48" => "TX",
    "49" => "UT",
    "50" => "VT",
    "51" => "VA",
    "53" => "WA",
    "54" => "WV",
    "55" => "WI",
    "56" => "WY",
    "60" => "AS",
    "66" => "GU",
    "69" => "MP",
    "72" => "PR",
    "78" => "VI"
  }

  @non_census_state_codes ~w(AA AE AP FM MH PW)

  @doc "Returns whether SimpleMaps' state code has a USPS identity but no Census state identity."
  @spec non_census_state_code?(term()) :: boolean()
  def non_census_state_code?(code), do: code in @non_census_state_codes

  @doc """
  Returns the postal code of the state a five-digit county FIPS is assigned
  within, or `nil` when the code names no state this table carries.

  `nil` is the answer for anything that is not five characters long, and for a
  five-character code whose first two are not a state FIPS -- a truncated
  cell, a county equivalent from a numbering scheme this table does not
  describe, or a value the source simply got wrong. A caller that cannot name
  the state asserts nothing about it rather than falling back on the row's own
  state column, which is the value that is wrong in the case this exists for.
  """
  @spec state_code(String.t()) :: String.t() | nil
  def state_code(<<prefix::binary-size(2), _county::binary-size(3)>>) do
    Map.get(@states, prefix)
  end

  def state_code(_other), do: nil
end
