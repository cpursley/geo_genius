defmodule GeoGenius.Providers.SimpleMaps.FipsTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Providers.SimpleMaps.Fips

  # The codes SimpleMaps constructs for military mail and the Freely
  # Associated States. No FIPS numbers any of them, so no county can be
  # assigned within one.
  @non_census_state_codes ["AA", "AE", "AP", "FM", "PW", "MH"]

  test "a county FIPS names the state its first two digits are assigned to" do
    assert Fips.state_code("51107") == "VA"
    assert Fips.state_code("11001") == "DC"
    assert Fips.state_code("50101") == "VT"
  end

  # A state FIPS below ten carries its leading zero in the column, and a table
  # keyed on the integer would miss every county in nine states.
  test "a state FIPS below ten is read with its leading zero" do
    assert Fips.state_code("06037") == "CA"
    assert Fips.state_code("02016") == "AK"
    assert Fips.state_code("09001") == "CT"
  end

  # The territories carry county equivalents and appear in the source as
  # ordinary `state_id` values, so leaving them out would strand every one of
  # their ZIPs.
  test "the territories the Census assigns a state FIPS to are carried" do
    assert Fips.state_code("72097") == "PR"
    assert Fips.state_code("78010") == "VI"
    assert Fips.state_code("66010") == "GU"
    assert Fips.state_code("60010") == "AS"
    assert Fips.state_code("69110") == "MP"
  end

  test "a prefix that names no state is nil rather than a guess" do
    assert Fips.state_code("99107") == nil
    assert Fips.state_code("00001") == nil
    assert Fips.state_code("ab001") == nil
  end

  # 03, 07, 14, 43 and 52 were never assigned, and 64, 68 and 70 were
  # withdrawn with the Freely Associated States. A five-digit number starting
  # with one of them is not a county of anywhere.
  test "an unassigned or withdrawn prefix is nil" do
    for prefix <- ~w(03 07 14 43 52 64 68 70 74) do
      assert Fips.state_code(prefix <> "001") == nil, "#{prefix} names no state"
    end
  end

  test "a code that is not five characters names no state" do
    assert Fips.state_code("511") == nil
    assert Fips.state_code("511070") == nil
    assert Fips.state_code("") == nil
  end

  # The whole table at once: a county's state is a state the Census defines,
  # so no prefix may resolve to a code that keys under the USPS instead. A
  # county filed under one would name a parent whose authority segment the
  # rest of the provider spells differently.
  test "no prefix resolves to a code the Census assigns no FIPS" do
    for prefix <- 0..99 do
      code = prefix |> Integer.to_string() |> String.pad_leading(2, "0")

      refute Fips.state_code(code <> "001") in @non_census_state_codes,
             "#{code} must not name a state the Census defines no FIPS for"
    end
  end
end
