defmodule GeoGenius.Providers.ImpliedAreas do
  @moduledoc """
  Areas a source row implies through columns other than its own code.

  A row that carries a grouping code -- a statistical grouping on an
  administrative record, an administrative parent on a place record --
  describes that grouping as well as itself. This module reads those columns
  from a manifest option and returns both the implied areas and the edges
  from each implied area to the row's own area.

  An implied area carries no geometry and no centroid. A grouping a source
  names only by code has no shape of its own in that source, and deriving one
  from the row's geometry would claim the grouping's boundary is one member's
  boundary.

  The option is a list under `"implied_areas"`. Each entry names an
  `"area_type"`, the column carrying the code, an optional `"names"` map from
  code to display name, an optional `"authority"` override, and an optional
  `"relation"` defaulting to `"contains"`. The column key is the calling
  provider's own: `"code_property"` for `GeoGenius.Providers.GeoJSON`,
  `"code_column"` for `GeoGenius.Providers.CSV`.

  Argument order matches `GeoGenius.Providers.ManifestOptions`, this module's
  sibling: payload first, option keys last.
  """

  alias GeoGenius.Provider.Area
  alias GeoGenius.Provider.Area.Name
  alias GeoGenius.Providers.Fields

  @relations ~w(contains mostly_contains overlaps)

  @typedoc "One parsed `implied_areas` entry."
  @type entry :: %{
          area_type_key: String.t(),
          code_field: String.t(),
          names: %{optional(String.t()) => String.t()},
          relation: String.t(),
          authority_key: String.t() | nil
        }

  @doc """
  Parses the `implied_areas` option, reading each entry's code column under
  `code_option_key`.

  An absent option is not an error: most manifests imply nothing.
  """
  @spec parse(map(), String.t()) :: {:ok, [entry()]} | {:error, String.t()}
  def parse(options, code_option_key) do
    case Map.get(options, "implied_areas", []) do
      [] -> {:ok, []}
      list when is_list(list) -> parse_entries(list, code_option_key)
      other -> {:error, "implied_areas must be a list, got: #{inspect(other)}"}
    end
  end

  @doc """
  `:ok` when every `implied_areas` entry parses under `code_option_key`, or the
  first entry's error.

  This is the shape `c:GeoGenius.Provider.validate_options/1` returns, so a
  provider whose only manifest-wide check is its implied areas delegates here
  rather than discarding `parse/2`'s entries at each call site.
  """
  @spec validate(map(), String.t()) :: :ok | {:error, String.t()}
  def validate(options, code_option_key) do
    case parse(options, code_option_key) do
      {:ok, _entries} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The areas `payload` implies, one per entry whose code column is populated.

  A blank code implies no area and is not an error: a source whose grouping
  column is populated for most rows and blank for a few is ordinary, and
  failing the release over it would be wrong. A populated code with no entry
  in `names` is an error, because keying an area with no name would publish
  an unlabelled area.

  `authority_key` is the row's own authority, used for any entry that
  declares no `"authority"` of its own.
  """
  @spec areas(map(), [entry()], String.t()) :: {:ok, [Area.t()]} | {:error, String.t()}
  def areas(payload, entries, authority_key) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case area(payload, entry, authority_key) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, area} -> {:cont, {:ok, [area | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp area(payload, entry, authority_key) do
    case Fields.presence(Map.get(payload, entry.code_field)) do
      nil ->
        {:ok, nil}

      code ->
        case Map.fetch(entry.names, code) do
          {:ok, name} ->
            {:ok,
             %Area{
               authority_key: authority_of(entry, authority_key),
               area_type_key: entry.area_type_key,
               code: code,
               names: [%Name{name: name, kind: :official}]
             }}

          :error ->
            {:error,
             "implied_areas #{entry.area_type_key} code #{inspect(code)} from " <>
               "#{inspect(entry.code_field)} has no entry in names"}
        end
    end
  end

  @doc """
  `area` alone when the manifest implies nothing, or `area` followed by every
  area `payload` implies.

  A provider whose manifest declares no `implied_areas` keeps returning a bare
  `{:ok, %Area{}}` from `c:GeoGenius.Provider.normalize/2`, which is the shape
  every existing manifest depends on. Only a manifest that actually implies
  something sees the list form.

  This lives here rather than in each provider because both generic providers
  need exactly this, and the substance it wraps -- `areas/3` -- is already this
  module's.
  """
  @spec with_implied(Area.t(), map(), [entry()], String.t()) ::
          {:ok, Area.t()} | {:ok, [Area.t()]} | {:error, String.t()}
  def with_implied(%Area{} = area, _payload, [], _authority_key), do: {:ok, area}

  def with_implied(%Area{} = area, payload, entries, authority_key) do
    case areas(payload, entries, authority_key) do
      {:ok, implied} -> {:ok, [area | implied]}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The edges `payload` asserts, one per entry whose code column is populated,
  each running from the implied area to the row's own area.

  The parent end is composed through `GeoGenius.Provider.Area.key/1` rather
  than by joining strings, and `child_area_key` must have been composed the
  same way by the caller: an edge composed a second way can name a key
  `normalize/2` never produced, and `GeoGenius.Catalog.put_relation_many/3`,
  which is what the relating phase calls, refuses an area the release does not
  carry.

  Returns a bare list because `c:GeoGenius.Provider.asserted_relations/2`
  does. An entry that cannot be parsed has already failed `normalize/2`,
  which runs first.
  """
  @spec edges(map(), [entry()], String.t(), String.t()) ::
          [{String.t(), String.t(), String.t()}]
  def edges(payload, entries, authority_key, child_area_key) do
    Enum.flat_map(entries, fn entry ->
      case Fields.presence(Map.get(payload, entry.code_field)) do
        nil -> []
        code -> [{parent_key(entry, authority_key, code), child_area_key, entry.relation}]
      end
    end)
  end

  defp parent_key(entry, authority_key, code) do
    Area.key(%Area{
      authority_key: authority_of(entry, authority_key),
      area_type_key: entry.area_type_key,
      code: code
    })
  end

  defp authority_of(%{authority_key: nil}, authority_key), do: authority_key
  defp authority_of(%{authority_key: override}, _authority_key), do: override

  defp parse_entries(list, code_option_key) do
    list
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case parse_entry(entry, code_option_key) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_entry(entry, code_option_key) when is_map(entry) do
    with {:ok, area_type_key} <- require_string(entry, "area_type"),
         {:ok, code_field} <- require_string(entry, code_option_key),
         {:ok, names} <- parse_names(entry),
         {:ok, relation} <- parse_relation(entry) do
      {:ok,
       %{
         area_type_key: area_type_key,
         code_field: code_field,
         names: names,
         relation: relation,
         authority_key: Map.get(entry, "authority")
       }}
    end
  end

  defp parse_entry(other, _code_option_key),
    do: {:error, "implied_areas entry must be an object, got: #{inspect(other)}"}

  defp require_string(entry, key) do
    case Map.get(entry, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "implied_areas entry requires #{inspect(key)}"}
    end
  end

  defp parse_names(entry) do
    case Map.get(entry, "names", %{}) do
      names when is_map(names) -> validate_names(names)
      other -> {:error, "implied_areas names must be an object, got: #{inspect(other)}"}
    end
  end

  # Every `names` entry becomes a `%Name{}` field bound straight to Postgrex,
  # so a non-string key or value here would otherwise surface as an encode
  # error deep inside normalization rather than as a manifest error naming
  # the offending entry.
  defp validate_names(names) do
    Enum.reduce_while(names, {:ok, names}, fn
      {key, value}, acc when is_binary(key) and is_binary(value) ->
        {:cont, acc}

      {key, value}, _acc ->
        {:halt,
         {:error,
          "implied_areas names entry #{inspect(key)} => #{inspect(value)} must have a " <>
            "string key and a string value"}}
    end)
  end

  defp parse_relation(entry) do
    case Map.get(entry, "relation", "contains") do
      relation when relation in @relations ->
        {:ok, relation}

      other ->
        {:error,
         "implied_areas relation must be one of #{Enum.join(@relations, ", ")}, " <>
           "got: #{inspect(other)}"}
    end
  end
end
