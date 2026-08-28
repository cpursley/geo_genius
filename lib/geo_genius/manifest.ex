defmodule GeoGenius.Manifest.Source do
  @moduledoc """
  One data source within a release: where it comes from, how it is licensed,
  and the artifacts that carry it.

  A release can draw from several sources -- an authority's own feed plus an
  operator-supplied correction, for instance -- so `GeoGenius.Manifest.sources`
  is a list of these rather than a single source embedded in the release.
  """

  @enforce_keys [:source_key, :provider, :license, :release_key, :artifacts]
  defstruct [
    :source_key,
    :provider,
    :license,
    :attribution,
    :release_key,
    :source_date,
    :artifacts
  ]

  @type t :: %__MODULE__{
          source_key: String.t(),
          provider: String.t(),
          license: String.t(),
          attribution: String.t() | nil,
          release_key: String.t(),
          source_date: Date.t() | nil,
          artifacts: [GeoGenius.Manifest.Artifact.t()]
        }
end

defmodule GeoGenius.Manifest.Artifact do
  @moduledoc """
  One file (or archive) a source is built from.

  An artifact is either downloadable (it carries a `url`) or operator-supplied
  (an operator has placed it in the cache by hand) -- never both and never
  neither, so a manifest cannot describe an artifact the pipeline has no way
  to obtain.
  """

  @enforce_keys [:logical_name, :format, :sha256, :bytes]
  defstruct [
    :logical_name,
    :url,
    :operator_supplied,
    :format,
    :required,
    :sha256,
    :bytes,
    :members,
    :metadata
  ]

  @type t :: %__MODULE__{
          logical_name: String.t(),
          url: String.t() | nil,
          operator_supplied: boolean(),
          format: String.t(),
          required: boolean(),
          sha256: String.t(),
          bytes: pos_integer(),
          members: [String.t()],
          metadata: map()
        }
end

defmodule GeoGenius.Manifest do
  @moduledoc """
  The reviewed document that describes one release: `<manifest_dir>/<collection>/<release>.json`.

  A manifest is how a new release becomes available -- nothing discovers or
  follows a mutable "latest" pointer. `load/3` reads and validates the file at
  that path; `from_map/2` runs the same validation over an already-decoded
  document, which is how a manifest stored on `release.manifest` is rebuilt
  without touching the filesystem again. `to_map/1` is the inverse of both:
  it produces the exact JSON-shaped map a manifest document contains, so
  `from_map(to_map(m))` round-trips.

  Every failure -- a malformed field, an unknown provider, a name that could
  escape the manifest directory -- raises or returns `GeoGenius.ManifestError`
  naming the field that was wrong.
  """

  alias GeoGenius.{Cache, Config, Files, ManifestError}
  alias GeoGenius.Manifest.{Artifact, Source}

  @enforce_keys [:collection, :release, :provider, :authorities, :sources]
  defstruct [
    :collection,
    :collection_name,
    :description,
    :release,
    :provider,
    :requires_geometry,
    :source_date,
    :authorities,
    :area_types,
    :sources,
    :options
  ]

  @typedoc "One entry of a manifest's `area_types` list."
  @type area_type :: %{key: String.t(), rank: pos_integer()}

  @typedoc """
  One entry of a manifest's `authorities` list: who is responsible for the
  identifiers a set of areas is keyed under.

  A collection may draw on more than one -- a US release keyed partly by the
  Census, partly by the USPS, and partly by its own vendor identifiers names
  all three -- so this is a list rather than a single value.

  `authorities` is required and must name at least one, unlike `area_types`,
  which a manifest may declare as an empty list: a manifest declaring no area
  types registers none, and a release that normalizes an area whose type it
  never declared fails. An empty `authorities` list is a manifest that can
  register no area at all: `upsert_area` resolves an authority with
  `SELECT ... INTO STRICT` and raises `:no_data_found` deep in normalization.
  Rejecting it here is what turns that into an error naming the field, at load.

  `:authorities` is in `@enforce_keys` for the same reason. Validation covers
  the documents `load/3` and `from_map/2` read; the enforced key covers a
  `%GeoGenius.Manifest{}` built in Elixir, which would otherwise default the
  field to `nil` and reach registration's `Enum.each/2` as a
  `Protocol.UndefinedError` rather than an error naming the field.
  """
  @type authority :: %{key: String.t(), name: String.t()}

  @type t :: %__MODULE__{
          collection: String.t(),
          collection_name: String.t() | nil,
          description: String.t() | nil,
          release: String.t(),
          provider: String.t(),
          requires_geometry: boolean(),
          source_date: Date.t() | nil,
          authorities: [authority()],
          area_types: [area_type()],
          sources: [Source.t()],
          options: map()
        }

  # collection and release are joined into a filesystem path by load/3. The
  # leading character class requires an alphanumeric and the body excludes the
  # path separator, so neither ".." nor an absolute path can match. This is a
  # traversal control, not a naming convention.
  @safe_name ~r/\A[a-z0-9][a-z0-9_.-]*\z/
  @sha256 ~r/\A[0-9a-f]{64}\z/

  @doc """
  Loads and validates the manifest for `collection`/`release` from the search
  path.

  Returns `{:error, %GeoGenius.ManifestError{}}` for a name that cannot be
  looked up, a file that is not on the search path, JSON that does not parse,
  or a document that fails validation.
  """
  @spec load(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, ManifestError.t()}
  def load(collection, release, opts \\ []) do
    with :ok <- validate_name(collection, "collection"),
         :ok <- validate_name(release, "release") do
      load_located(collection, release, opts)
    else
      {:error, reason} -> {:error, ManifestError.exception(reason: reason)}
    end
  end

  @doc "Like `load/3`, but raises `GeoGenius.ManifestError` instead of returning an error tuple."
  @spec load!(String.t(), String.t(), keyword()) :: t()
  def load!(collection, release, opts \\ []) do
    case load(collection, release, opts) do
      {:ok, manifest} -> manifest
      {:error, error} -> raise error
    end
  end

  @doc """
  Decodes a manifest document with Jason.

  `path` is carried onto any `GeoGenius.ManifestError` this returns, so a
  decode failure names the file it came from.
  """
  @spec decode(String.t(), Path.t() | nil) :: {:ok, map()} | {:error, ManifestError.t()}
  def decode(content, path \\ nil) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, other} ->
        {:error,
         ManifestError.exception(
           reason: "manifest must decode to a JSON object, got: #{inspect(other)}",
           path: path
         )}

      {:error, reason} ->
        {:error, ManifestError.exception(reason: "invalid JSON: #{inspect(reason)}", path: path)}
    end
  end

  @doc """
  Validates an already-decoded manifest document, skipping the file and
  decoding steps `load/3` performs.

  This is how a manifest stored on `release.manifest` is rebuilt without
  reading it from disk again.
  """
  @spec from_map(map(), Path.t() | nil) :: {:ok, t()} | {:error, ManifestError.t()}
  def from_map(map, path \\ nil) when is_map(map) do
    case build(map) do
      {:ok, manifest} -> {:ok, manifest}
      {:error, reason} -> {:error, ManifestError.exception(reason: reason, path: path)}
    end
  end

  @doc """
  Produces the JSON-shaped map a manifest document contains.

  `from_map(to_map(manifest))` is the identity: this is what makes storing a
  manifest on the release row lossless.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = manifest) do
    %{
      "collection" => manifest.collection,
      "collection_name" => manifest.collection_name,
      "description" => manifest.description,
      "release" => manifest.release,
      "provider" => manifest.provider,
      "requires_geometry" => manifest.requires_geometry,
      "source_date" => date_to_iso8601(manifest.source_date),
      "authorities" => Enum.map(manifest.authorities, &keys_to_strings(&1, [:key, :name])),
      "area_types" => Enum.map(manifest.area_types, &keys_to_strings(&1, [:key, :rank])),
      "sources" => Enum.map(manifest.sources, &source_to_map/1),
      "options" => manifest.options
    }
  end

  # A name rejected by validate_name/2 above never reaches here, so its
  # ManifestError carries no path. A lookup that reaches locate/3 but finds
  # nothing did try real locations, so its error carries the candidate that
  # was checked -- this is what lets a caller (and a test) tell "rejected by
  # name" apart from "the file legitimately is not there."
  defp load_located(collection, release, opts) do
    case locate(collection, release, opts) do
      {:ok, path} ->
        load_from_path(path)

      {:error, reason, candidate} ->
        {:error, ManifestError.exception(reason: reason, path: candidate)}
    end
  end

  defp load_from_path(path) do
    with {:ok, content} <- Files.read(path),
         {:ok, decoded} <- decode(content, path) do
      from_map(decoded, path)
    else
      {:error, %ManifestError{}} = error ->
        error

      {:error, reason} ->
        {:error, ManifestError.exception(reason: Files.format_error(path, reason), path: path)}
    end
  end

  defp locate(collection, release, opts) do
    filename = release <> ".json"
    paths = Config.manifest_paths(opts)
    candidates = Enum.map(paths, &Path.join([&1, collection, filename]))

    case Enum.find(candidates, &File.regular?/1) do
      nil ->
        {:error,
         "no manifest for collection #{inspect(collection)} release #{inspect(release)} " <>
           "on the search path #{inspect(paths)}", List.first(candidates)}

      path ->
        {:ok, path}
    end
  end

  defp build(map) do
    with {:ok, collection} <- required_name(map, "collection"),
         {:ok, release} <- required_name(map, "release"),
         {:ok, provider_name} <- require_string(map, "provider"),
         {:ok, provider} <- resolve_provider(provider_name),
         {:ok, source_maps} <- require_nonempty_list(map, "sources"),
         {:ok, sources} <- build_all(source_maps, &build_source(&1, provider_name)),
         {:ok, source_date} <- parse_date(Map.get(map, "source_date"), "source_date"),
         {:ok, authority_maps} <- require_nonempty_list(map, "authorities"),
         {:ok, authorities} <- build_all(authority_maps, &validate_authority/1),
         {:ok, area_types} <- validate_area_types(Map.get(map, "area_types", [])),
         :ok <- validate_options(provider, sources, Map.get(map, "options", %{})) do
      fields = %{
        collection: collection,
        release: release,
        provider_name: provider_name,
        source_date: source_date,
        authorities: authorities,
        area_types: area_types,
        sources: sources
      }

      {:ok, assemble(map, fields)}
    end
  end

  defp assemble(map, fields) do
    %__MODULE__{
      collection: fields.collection,
      collection_name: Map.get(map, "collection_name"),
      description: Map.get(map, "description"),
      release: fields.release,
      provider: fields.provider_name,
      requires_geometry: Map.get(map, "requires_geometry", false),
      source_date: fields.source_date,
      authorities: fields.authorities,
      area_types: fields.area_types,
      sources: fields.sources,
      options: Map.get(map, "options", %{})
    }
  end

  defp build_source(map, default_provider) do
    with {:ok, source_key} <- require_string(map, "source_key"),
         {:ok, provider} <- source_provider(map, default_provider),
         {:ok, license} <- require_string(map, "license"),
         {:ok, release_key} <- require_string(map, "release_key"),
         {:ok, artifact_maps} <- require_nonempty_list(map, "artifacts"),
         {:ok, artifacts} <- build_all(artifact_maps, &build_artifact/1),
         {:ok, source_date} <- parse_date(Map.get(map, "source_date"), "source_date") do
      {:ok,
       %Source{
         source_key: source_key,
         provider: provider,
         license: license,
         attribution: Map.get(map, "attribution"),
         release_key: release_key,
         source_date: source_date,
         artifacts: artifacts
       }}
    end
  end

  # A source that names no provider is staged by the release's own, which is
  # what keeps a single-provider manifest -- one source, or several in the same
  # format -- exactly as it was. The default is resolved here rather than left
  # for the pipeline, so `%Source{}` carries a concrete name everywhere
  # downstream: the catalog row `register_source/4` writes, and the document
  # `to_map/1` produces. The name is resolved as well as type-checked, because
  # a source naming a module that does not exist would otherwise fail at
  # staging, several phases into a run.
  defp source_provider(map, default_provider) do
    with {:ok, name} <- source_provider_name(map, default_provider),
         {:ok, _module} <- resolve_provider(name) do
      {:ok, name}
    end
  end

  defp source_provider_name(map, default_provider) do
    case Map.get(map, "provider") do
      nil -> {:ok, default_provider}
      "" -> {:error, "provider must not be blank"}
      value when is_binary(value) -> {:ok, value}
      other -> {:error, "provider must be a string, got: #{inspect(other)}"}
    end
  end

  defp build_artifact(map) do
    with {:ok, logical_name} <- required_name(map, "logical_name"),
         {:ok, format} <- require_string(map, "format"),
         {:ok, sha256} <- require_sha256(map),
         {:ok, bytes} <- require_positive_integer(map, "bytes"),
         :ok <- validate_location(Map.get(map, "url"), Map.get(map, "operator_supplied", false)),
         {:ok, members} <- validate_members(Map.get(map, "members")),
         {:ok, cache_key} <- validate_cache_key(Map.get(map, "cache_key")) do
      {:ok,
       %Artifact{
         logical_name: logical_name,
         url: Map.get(map, "url"),
         operator_supplied: Map.get(map, "operator_supplied", false),
         format: format,
         required: Map.get(map, "required", true),
         sha256: sha256,
         bytes: bytes,
         members: members,
         metadata: metadata_for(cache_key)
       }}
    end
  end

  # `members` names the files an archive artifact must contain, and it reaches
  # the catalog row through `artifact_metadata/1` rather than a typed column,
  # so nothing downstream would reject a value of the wrong shape. Every
  # sibling field on an artifact is type-checked here; this one is too. An
  # absent key and an explicit JSON `null` both mean the same thing, no
  # archive members, so both resolve to the empty list.
  defp validate_members(nil), do: {:ok, []}

  defp validate_members(members) do
    if is_list(members) and Enum.all?(members, &(is_binary(&1) and &1 != "")) do
      {:ok, members}
    else
      {:error, "members must be a list of non-empty strings, got: #{inspect(members)}"}
    end
  end

  # Builds each item with `builder`, short-circuiting on the first failure.
  # Shared by sources and by the artifacts within each source, so the two
  # lists are not two copies of the same reduce/case shape.
  defp build_all(items, builder) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case builder.(item) do
        {:ok, built} -> {:cont, {:ok, [built | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp reverse_ok({:ok, acc}), do: {:ok, Enum.reverse(acc)}
  defp reverse_ok({:error, _} = error), do: error

  defp required_name(map, field) do
    with {:ok, value} <- require_string(map, field),
         :ok <- validate_name(value, field) do
      {:ok, value}
    end
  end

  defp require_string(map, field) do
    case Map.get(map, field) do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> {:error, "#{field} is required"}
      "" -> {:error, "#{field} must not be blank"}
      other -> {:error, "#{field} must be a string, got: #{inspect(other)}"}
    end
  end

  defp require_nonempty_list(map, field) do
    case Map.get(map, field) do
      [_ | _] = list -> {:ok, list}
      [] -> {:error, "#{field} must be a non-empty list"}
      nil -> {:error, "#{field} is required"}
      other -> {:error, "#{field} must be a list, got: #{inspect(other)}"}
    end
  end

  defp require_positive_integer(map, field) do
    case Map.get(map, field) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      nil -> {:error, "#{field} is required"}
      other -> {:error, "#{field} must be a positive integer, got: #{inspect(other)}"}
    end
  end

  defp require_sha256(map) do
    with {:ok, sha256} <- require_string(map, "sha256") do
      if Regex.match?(@sha256, sha256) do
        {:ok, sha256}
      else
        {:error,
         "sha256 #{inspect(sha256)} does not match the expected digest format #{inspect(@sha256)}"}
      end
    end
  end

  defp validate_name(value, field) when is_binary(value) do
    if Regex.match?(@safe_name, value) do
      :ok
    else
      {:error, "#{field} #{inspect(value)} is not a valid name: expected #{inspect(@safe_name)}"}
    end
  end

  defp validate_name(value, field),
    do: {:error, "#{field} must be a string, got: #{inspect(value)}"}

  defp resolve_provider(name) do
    {:ok, Config.provider!(name)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  # An artifact is exactly one of downloadable or operator-supplied. This
  # mirrors the artifact_location_check database constraint, so a malformed
  # manifest fails before any release row exists.
  defp validate_location(url, operator_supplied) do
    case {is_binary(url), operator_supplied == true} do
      {true, false} ->
        :ok

      {false, true} ->
        :ok

      _ ->
        {:error,
         "operator_supplied must be true with no url, or false with a url present; " <>
           "got url: #{inspect(url)}, operator_supplied: #{inspect(operator_supplied)}"}
    end
  end

  # Delegates to GeoGenius.Cache.key/1 for the segment rules a cache_key must
  # follow, so the shape of a valid segment is defined in exactly one place.
  defp validate_cache_key(nil), do: {:ok, nil}

  defp validate_cache_key(cache_key) when is_binary(cache_key) do
    Cache.key(String.split(cache_key, "/"))
    {:ok, cache_key}
  rescue
    error in ArgumentError ->
      {:error, "cache_key #{inspect(cache_key)} is invalid: #{Exception.message(error)}"}
  end

  defp validate_cache_key(other),
    do: {:error, "cache_key must be a string, got: #{inspect(other)}"}

  defp metadata_for(nil), do: %{}
  defp metadata_for(cache_key), do: %{"cache_key" => cache_key}

  # Every provider a release names validates the options, not only the
  # release's own: a release staged by several providers has several sets of
  # required keys and several option vocabularies, and a manifest that
  # satisfies one but not another cannot be staged. Within each provider the
  # required-key check runs first, so an operator sent to fix an option is
  # never sent to fix the entry that is not the reason the manifest cannot be
  # used.
  defp validate_options(provider, sources, options) when is_map(options) do
    check_all(provider_modules(provider, sources), &provider_option_error(&1, options))
  end

  defp validate_options(_provider, _sources, other),
    do: {:error, "options must be a map, got: #{inspect(other)}"}

  # The release's provider first, then each source's in declaration order.
  # `build_source/2` has already resolved every source's name, so
  # `Config.provider!/1` here cannot raise.
  defp provider_modules(provider, sources) do
    Enum.uniq([provider | Enum.map(sources, &Config.provider!(&1.provider))])
  end

  defp provider_option_error(module, options) do
    case validate_provider(module, options) do
      :ok -> nil
      {:error, _reason} = error -> error
    end
  end

  defp validate_provider(module, options) do
    with :ok <- check_all(required_option_keys(module), &missing_option_key(&1, module, options)) do
      validate_provider_options(module, options)
    end
  end

  # The message names the provider, because with several staging one release
  # "for provider" alone leaves an operator guessing which one wanted the key.
  defp missing_option_key(key, module, options) do
    if Map.has_key?(options, key) do
      nil
    else
      {:error, "options is missing required key #{inspect(key)} for provider #{inspect(module)}"}
    end
  end

  # A provider module that loads and exports no `required_options/0` requires
  # no options, so it contributes no keys. A module that does not load
  # requires nothing only because nothing about it can be read, which is a
  # different answer: `Config.provider!/1` rejects it before validation
  # reaches here, and this raises rather than silently accepting every
  # options block if it ever does.
  defp required_option_keys(provider) do
    cond do
      not Code.ensure_loaded?(provider) ->
        raise ArgumentError,
              "GeoGenius provider module #{inspect(provider)} does not load, so the option " <>
                "keys it requires cannot be read"

      function_exported?(provider, :required_options, 0) ->
        provider.required_options()

      true ->
        []
    end
  end

  # `validate_options/1` is optional: a provider that exports none contributes
  # no checks beyond the required keys, rather than every manifest naming it
  # failing to load. `required_option_keys/1` has already established that the
  # module loads, so `function_exported?/3` here answers whether the callback
  # is implemented rather than whether the module is available.
  defp validate_provider_options(provider, options) do
    if function_exported?(provider, :validate_options, 1) do
      provider.validate_options(options)
    else
      :ok
    end
  end

  # Runs `check` over every item, returning the first error it produces or
  # `:ok` when every item passes. `check` returns `nil` for a passing item and
  # `{:error, reason}` for a failing one, so this doubles as the shared shape
  # for cache-key segment validation and provider-option-key validation.
  defp check_all(items, check), do: Enum.find_value(items, :ok, check)

  defp parse_date(nil, _field), do: {:ok, nil}

  defp parse_date(value, field) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        {:ok, date}

      {:error, reason} ->
        {:error, "#{field} #{inspect(value)} is not a valid date: #{inspect(reason)}"}
    end
  end

  defp parse_date(other, field), do: {:error, "#{field} must be a string, got: #{inspect(other)}"}

  defp date_to_iso8601(nil), do: nil
  defp date_to_iso8601(%Date{} = date), do: Date.to_iso8601(date)

  # An authority entry names a key and a display name, both of which reach
  # `upsert_authority` as NOT NULL columns. Validating them here is what makes
  # a malformed entry an error naming the field at load, rather than a
  # `CatalogError` naming a SQL function partway through registration. The
  # list the entry came from is carried into the message, so an authority
  # error cannot be read as an area type one.
  defp validate_authority(map) when is_map(map) do
    with {:ok, key} <- require_string(map, "key"),
         {:ok, name} <- require_string(map, "name") do
      {:ok, %{key: key, name: name}}
    else
      {:error, reason} -> {:error, "authorities entry #{reason}"}
    end
  end

  defp validate_authority(other),
    do: {:error, "authorities entry must be an object, got: #{inspect(other)}"}

  defp validate_area_types(list) when is_list(list), do: build_all(list, &validate_area_type/1)

  defp validate_area_types(other),
    do: {:error, "area_types must be a list, got: #{inspect(other)}"}

  # `rank` orders a collection's area types and is written to an integer
  # column, so a quoted or absent rank is checked here for the same reason an
  # authority's fields are: the failure names the field at load instead of
  # failing a cast inside PL/pgSQL.
  defp validate_area_type(map) when is_map(map) do
    with {:ok, key} <- require_string(map, "key"),
         {:ok, rank} <- require_positive_integer(map, "rank") do
      {:ok, %{key: key, rank: rank}}
    else
      {:error, reason} -> {:error, "area_types entry #{reason}"}
    end
  end

  defp validate_area_type(other),
    do: {:error, "area_types entry must be an object, got: #{inspect(other)}"}

  defp keys_to_strings(map, keys) when is_map(map) do
    Map.new(keys, fn key -> {Atom.to_string(key), Map.get(map, key)} end)
  end

  defp source_to_map(%Source{} = source) do
    %{
      "source_key" => source.source_key,
      "provider" => source.provider,
      "license" => source.license,
      "attribution" => source.attribution,
      "release_key" => source.release_key,
      "source_date" => date_to_iso8601(source.source_date),
      "artifacts" => Enum.map(source.artifacts, &artifact_to_map/1)
    }
  end

  defp artifact_to_map(%Artifact{} = artifact) do
    %{
      "logical_name" => artifact.logical_name,
      "url" => artifact.url,
      "operator_supplied" => artifact.operator_supplied,
      "format" => artifact.format,
      "required" => artifact.required,
      "sha256" => artifact.sha256,
      "bytes" => artifact.bytes,
      "members" => artifact.members
    }
    |> maybe_put_cache_key(artifact.metadata)
  end

  defp maybe_put_cache_key(map, metadata) do
    case Map.fetch(metadata, "cache_key") do
      {:ok, cache_key} -> Map.put(map, "cache_key", cache_key)
      :error -> map
    end
  end
end
