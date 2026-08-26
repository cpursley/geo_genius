defmodule GeoGenius.Providers.ManifestOptions do
  @moduledoc """
  Manifest `options` lookups and payload-field extraction shared by every
  provider that reads a code, names, attributes, and external codes out of
  a manifest and a staged payload the way `GeoGenius.Providers.GeoJSON` and
  `GeoGenius.Providers.CSV` both do.

  A provider resolves its own format-specific option keys (`"code_property"`
  vs `"code_column"`, and so on -- see the table in `GeoGenius.Provider`'s
  moduledoc) and passes the resolved field name or field list in here; this
  module never reads the vocabulary a specific format calls its own.
  """

  alias GeoGenius.Manifest
  alias GeoGenius.Provider.Area.Code
  alias GeoGenius.Provider.Area.Name
  alias GeoGenius.Providers.Fields

  @doc "Fetches `key` out of `options`, returning an error naming the key rather than raising."
  @spec require_option(map(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def require_option(options, key) do
    case Map.fetch(options, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "manifest options is missing required key #{inspect(key)}"}
    end
  end

  @doc """
  Resolves the authority key from `options["authority"]`, falling back to the
  manifest's own authority when the option is absent.
  """
  @spec authority_key(Manifest.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def authority_key(manifest, options) do
    case Map.fetch(options, "authority") do
      {:ok, authority} -> {:ok, authority}
      :error -> authority_key_from_manifest(manifest)
    end
  end

  @doc """
  Resolves the three keys every area needs -- its code field, area type, and
  authority -- into one map rather than three positional strings.

  `code_option_key` is the format-specific option key naming the code field
  (`"code_property"` for GeoJSON, `"code_column"` for CSV); `"area_type"` is
  the same key for every provider. Returning a map rather than a
  `{code_field, area_type_key, authority_key}` tuple means a caller cannot
  transpose `area_type_key` and `authority_key` by getting their position
  wrong -- both are plain strings, so a transposition here would type-check
  and silently mis-file every area in the catalog.
  """
  @spec area_keys(Manifest.t(), map(), String.t()) ::
          {:ok, %{code_field: String.t(), area_type_key: String.t(), authority_key: String.t()}}
          | {:error, String.t()}
  def area_keys(manifest, options, code_option_key) do
    with {:ok, code_field} <- require_option(options, code_option_key),
         {:ok, area_type_key} <- require_option(options, "area_type"),
         {:ok, authority_key} <- authority_key(manifest, options) do
      {:ok, %{code_field: code_field, area_type_key: area_type_key, authority_key: authority_key}}
    end
  end

  @doc """
  Builds the official and alias names for one payload.

  `name_field` names the payload key holding the official name; `alias_fields`
  names the payload keys holding alias names. Both are already resolved by
  the caller from its own format-specific option keys and defaults.
  """
  @spec names(map(), String.t(), [String.t()]) :: [Name.t()]
  def names(payload, name_field, alias_fields) do
    official_name(payload, name_field) ++ alias_names(payload, alias_fields)
  end

  @doc """
  Takes the manifest-selected attribute fields out of `payload`, keyed by
  `option_key` (`"attribute_properties"` for GeoJSON, `"attribute_columns"`
  for CSV).

  Defaults to `[]` when `option_key` is absent from `options` -- an explicit,
  provider-agreed default rather than "every other field", which would
  silently widen a catalog's attributes the moment a source added a column
  nobody asked to carry forward.
  """
  @spec attributes(map(), map(), String.t()) :: map()
  def attributes(payload, options, option_key) do
    fields = Map.get(options, option_key, [])
    Map.take(payload, fields)
  end

  @doc """
  Builds external codes for one payload from a manifest-configured list of
  `%{"type" => code_type, field_key => payload_field}` entries.

  `option_key` names the manifest option carrying that list
  (`"code_properties"` for GeoJSON, `"code_columns"` for CSV); `field_key`
  names the key each entry uses for the payload field
  (`"property"` for GeoJSON, `"column"` for CSV). Defaults to `[]`. A row
  whose named payload field is blank produces no code for that entry, rather
  than a `%Code{}` with an empty `code_value`.
  """
  @spec codes(map(), map(), String.t(), String.t()) :: [Code.t()]
  def codes(payload, options, option_key, field_key) do
    options
    |> Map.get(option_key, [])
    |> Enum.map(&code_for(payload, &1, field_key))
    |> Enum.reject(&is_nil/1)
  end

  defp authority_key_from_manifest(%Manifest{authority: %{key: key}}), do: {:ok, key}

  defp authority_key_from_manifest(%Manifest{authority: nil}) do
    {:error, "manifest has no authority, and options has no \"authority\" override"}
  end

  defp official_name(payload, name_field) do
    case Fields.presence(Map.get(payload, name_field)) do
      nil -> []
      name -> [%Name{name: name, kind: :official}]
    end
  end

  defp alias_names(payload, alias_fields) do
    alias_fields
    |> Enum.map(&Fields.presence(Map.get(payload, &1)))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&%Name{name: &1, kind: :alias})
  end

  defp code_for(payload, entry, field_key) do
    code_type = Map.fetch!(entry, "type")
    field = Map.fetch!(entry, field_key)

    case Fields.presence(Map.get(payload, field)) do
      nil -> nil
      value -> %Code{code_type: code_type, code_value: value}
    end
  end
end
