defmodule GeoGenius.StubProvider do
  @moduledoc false

  @behaviour GeoGenius.Provider

  alias GeoGenius.Manifest
  alias GeoGenius.Provider
  alias GeoGenius.Provider.Area
  alias GeoGenius.Staging

  # A provider whose whole behaviour is driven by the manifest's `options`,
  # so one module covers every shape the pipeline has to survive:
  #
  #   "mode"      -- "default", "raise", "exit", "bad_kind", "bad_code_type",
  #                  "stage_error", "command_probe", or "bad_relation"
  #   "rows"      -- the row specs `stage/5` emits, each with "code", "name",
  #                  "area_type", and an optional GeoJSON "geometry"
  #   "relations" -- "rebuild" (default) or "none"

  @impl Provider
  def area_types, do: []

  @impl Provider
  def required_options, do: ["mode"]

  @impl Provider
  defdelegate artifacts(manifest), to: Provider, as: :all_artifacts

  @impl Provider
  def stage(%Manifest{} = manifest, artifact, _path, emit, opts) do
    if pid = opts[:test_pid], do: send(pid, {:staged, artifact.logical_name, opts[:work_dir]})

    case mode(manifest) do
      "command_probe" -> probe_command(opts)
      "stage_error" -> {:error, "stub provider refuses to stage #{artifact.logical_name}"}
      _other -> emit_rows(manifest, artifact, emit)
    end
  end

  @impl Provider
  def normalize(%Manifest{} = manifest, %Staging.Row{} = row) do
    case mode(manifest) do
      "raise" -> raise "stub provider exploded normalizing #{row.payload["code"]}"
      "exit" -> exit({:stub_provider_left, row.payload["code"]})
      "bad_kind" -> {:ok, area(row, names: [%Area.Name{name: "Bad", kind: :offical}])}
      "bad_code_type" -> {:ok, area(row, codes: [%Area.Code{code_type: 12, code_value: "x"}])}
      _other -> {:ok, area(row, [])}
    end
  end

  @impl Provider
  def relations(%Manifest{options: options}) do
    case Map.get(options, "relations", "rebuild") do
      "none" -> :none
      "rebuild" -> :rebuild
    end
  end

  # "bad_relation" names a child area no row -- this one or any other in the
  # run -- ever produces, so `Catalog.put_relation/3` raises rather than
  # writing anything: the fixture for a phase whose failure comes from the
  # database, not from the provider's own validation.
  @impl Provider
  def asserted_relations(%Manifest{} = manifest, row) do
    case mode(manifest) do
      "bad_relation" -> [{"demo:region:north", "demo:region:ghost", "contains"}]
      _other -> Provider.no_asserted_relations(manifest, row)
    end
  end

  defp mode(%Manifest{options: options}), do: Map.fetch!(options, "mode")

  defp emit_rows(manifest, artifact, emit) do
    rows =
      manifest.options
      |> Map.get("rows", [])
      |> Enum.map(&staging_row(artifact, &1))

    if rows == [], do: :ok, else: emit.(rows)
  end

  defp staging_row(artifact, spec) do
    %Staging.Row{
      artifact: artifact.logical_name,
      payload: spec,
      geom: geometry(Map.get(spec, "geometry"))
    }
  end

  defp geometry(nil), do: nil
  defp geometry(geojson), do: Geo.JSON.decode!(geojson)

  # Reaches for an executable the pipeline has no business letting a provider
  # run, and reports what the adapter it was handed said about it.
  defp probe_command(opts) do
    command = Keyword.fetch!(opts, :command)

    case command.run("psql", ["-c", "SELECT 1"], opts) do
      {:ok, output} -> {:error, "psql ran: #{output}"}
      {:error, {status, output}} -> {:error, "psql refused (#{status}): #{output}"}
    end
  end

  defp area(%Staging.Row{payload: payload} = row, overrides) do
    %Area{
      authority_key: Map.get(payload, "authority", "demo"),
      area_type_key: Map.fetch!(payload, "area_type"),
      code: Map.fetch!(payload, "code"),
      geometry: row.geom,
      names: Keyword.get(overrides, :names, [%Area.Name{name: payload["name"], kind: :official}]),
      codes: Keyword.get(overrides, :codes, []),
      attributes: Map.take(payload, ["name"])
    }
  end
end
