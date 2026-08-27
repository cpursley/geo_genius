defmodule GeoGenius.Providers.SimpleMaps.Validation do
  @moduledoc """
  Row-scoped consistency checks for SimpleMaps' denormalised county columns.

  Neither `uscities` nor `uszips` carries a county as a row of its own; each
  row denormalises the counties it touches into `county_fips`,
  `county_fips_all`, and a counties-name column -- `county_name_all` on
  `uscities`, `county_names_all` on `uszips` -- and `uszips` additionally
  carries `county_weights`. Those columns can disagree with each other
  inside one row, and GeoGenius accepts multiple official names for one
  area, so a source that contradicts itself would otherwise be reconciled by
  picking a name lexically rather than by authority -- a coin toss, not
  reconciliation. `check/1` fails the row instead, before
  `GeoGenius.Providers.SimpleMaps.Rows.areas/1` builds anything from it.

  One rule reads a single column rather than a pair of them: a `uscities`
  row naming no county at all. Two blank columns agree with each other, so
  that is the one self-contradiction the pairing rules cannot see, and the
  row it would otherwise let through publishes a city with nothing above it
  but a state.

  That rule is `uscities`-only, and its absence from `uszips` is measured
  rather than overlooked. Every city sits in a county, so a `uscities` row
  naming none is corruption. A ZIP need not: military APO/FPO ZIPs deliver
  to overseas addresses that sit in no US county, and they are a sizeable
  minority of the file rather than a curiosity. So a `uszips` row with no
  county and no `county_weights` is valid, while one that names counties and
  carries no weights for them is the corruption case.

  **Only what one row can prove.** Every rule here reads a single staged row
  and never compares across rows or across `uscities`/`uszips`. Cross-file
  agreement -- one FIPS mapping to two different states, or `uscities` and
  `uszips` spelling one county's name two different ways -- cannot be seen
  from a single row and is not checked here. That agreement is left to the
  host's own import verification.
  """

  alias GeoGenius.Providers.SimpleMaps.Rows
  alias GeoGenius.Staging

  @doc """
  Checks a staged SimpleMaps row's county columns for self-contradiction.

  Returns `:ok` for an artifact other than `uscities` or `uszips` --
  `GeoGenius.Providers.SimpleMaps.Rows.areas/1` is what rejects an unknown
  artifact, so this does not duplicate that error.
  """
  @spec check(Staging.Row.t()) :: :ok | {:error, String.t()}
  def check(%Staging.Row{artifact: "uscities", payload: payload}) do
    with :ok <- primary_in_all(payload),
         :ok <- names_pair_with_fips(payload, Rows.cities_county_names_column()) do
      names_a_county(payload)
    end
  end

  def check(%Staging.Row{artifact: "uszips", payload: payload}) do
    with :ok <- primary_in_all(payload),
         :ok <- names_pair_with_fips(payload, Rows.zips_county_names_column()) do
      weights_match_fips(payload)
    end
  end

  def check(%Staging.Row{}), do: :ok

  # `county_fips_all` is documented to always contain the primary
  # `county_fips`; a row where it does not is a source contradicting itself
  # about which counties it belongs to, not a shape `Rows.counties/2` can
  # reconcile by picking one.
  defp primary_in_all(payload) do
    all = Rows.list(payload, "county_fips_all")

    case Rows.field(payload, "county_fips") do
      nil ->
        :ok

      primary ->
        if primary in all do
          :ok
        else
          {:error,
           "county_fips #{primary} is not among county_fips_all #{inspect(all)} " <>
             "(#{Rows.label(payload)})"}
        end
    end
  end

  # A `uscities` row with a blank `county_fips_all` and a blank
  # `county_name_all` satisfies both rules above -- two blanks are an equal,
  # zero length, and a blank `county_fips` is skipped -- and then normalizes
  # into a city and a state with no county between them. `Rows.edges/1` then
  # files that city straight under its state, which is a tier too high: a
  # state does not contain a city the way this hierarchy means containment,
  # and the county that does is simply absent. The rule rests on the
  # measurement rather than on that shape -- every one of the source's
  # 109,071 rows names at least one county, so a row naming none is a
  # corrupt or truncated download.
  #
  # This rule is `uscities`-only, and deliberately has no `uszips`
  # counterpart. Every one of `uscities`' 109,071 rows names a county,
  # because every city sits in one; 617 of `uszips`' 41,551 rows name none,
  # because a military APO/FPO ZIP delivers to an overseas address that sits
  # in no US county. The same blank column is therefore corruption in one
  # file and ordinary data in the other -- see `weights_match_fips/1`.
  defp names_a_county(payload) do
    case Rows.list(payload, "county_fips_all") do
      [] -> {:error, "county_fips_all names no county (#{Rows.label(payload)})"}
      _fips -> :ok
    end
  end

  # `Rows.counties/2` pairs `county_fips_all` and the counties column
  # positionally, by index -- a list one shorter than the other means at
  # least one fips is paired with the wrong name, or a name with no fips at
  # all, either of which is a contradiction to fail rather than reconcile.
  defp names_pair_with_fips(payload, names_column) do
    fips = Rows.list(payload, "county_fips_all")
    names = Rows.list(payload, names_column)

    if length(fips) == length(names) do
      :ok
    else
      {:error,
       "county_fips_all lists #{length(fips)} county FIPS but #{names_column} lists " <>
         "#{length(names)} county name#{plural(length(names))} (#{Rows.label(payload)})"}
    end
  end

  # A `uszips` row naming no county at all is valid, the opposite of the
  # `uscities` rule above, because the two files measure differently: every
  # one of `uscities`' 109,071 rows names a county, while 617 of `uszips`'
  # 41,551 rows name none. Those 617 are military APO/FPO ZIPs -- `state_id`
  # AE, AP or AA, `military` TRUE -- delivering to overseas addresses that
  # belong to no US county. They yield a ZIP and a state with no county
  # between them, and the ZIP hangs off that state directly -- the only
  # parent such a row names. Failing them would abort a real import on the
  # first one and never reach the other 616.
  #
  # A blank `county_weights` beside a populated `county_fips_all` is a
  # different row entirely: the counties are named and their weighting has
  # vanished, which is the corrupt or truncated download this rule is for.
  defp weights_match_fips(payload) do
    weights_match_fips(
      payload,
      Rows.list(payload, "county_fips_all"),
      Rows.field(payload, "county_weights")
    )
  end

  defp weights_match_fips(_payload, [], nil), do: :ok

  defp weights_match_fips(payload, fips, nil) do
    {:error,
     "county_weights is blank but county_fips_all names #{inspect(fips)} " <>
       "(#{Rows.label(payload)})"}
  end

  defp weights_match_fips(payload, fips, text) do
    case decode_weights(text) do
      {:ok, weights} -> compare_weight_keys(payload, MapSet.new(fips), weights)
      {:error, reason} -> {:error, "county_weights #{reason} (#{Rows.label(payload)})"}
    end
  end

  defp compare_weight_keys(payload, fips, weights) when is_map(weights) do
    keys = weights |> Map.keys() |> MapSet.new()

    if MapSet.equal?(fips, keys) do
      :ok
    else
      {:error,
       "county_weights keys #{inspect(Enum.sort(keys))} do not match county_fips_all " <>
         "#{inspect(Enum.sort(fips))} (#{Rows.label(payload)})"}
    end
  end

  defp compare_weight_keys(payload, _fips, weights) do
    {:error,
     "county_weights did not decode to an object, got: #{inspect(weights)} (#{Rows.label(payload)})"}
  end

  defp decode_weights(text) do
    case Jason.decode(text) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, "could not be parsed: " <> Exception.message(error)}
    end
  end

  defp plural(1), do: ""
  defp plural(_count), do: "s"
end
