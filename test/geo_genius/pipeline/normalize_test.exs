defmodule GeoGenius.Pipeline.NormalizeTest do
  use ExUnit.Case, async: false

  alias GeoGenius.Catalog
  alias GeoGenius.Context
  alias GeoGenius.ImportFixture
  alias GeoGenius.Pipeline.Normalize
  alias GeoGenius.Pipeline.State
  alias GeoGenius.Provider.Area
  alias GeoGenius.Provider.Area.Name
  alias GeoGenius.Staging
  alias GeoGenius.TestRepo

  defmodule MultiAreaProvider do
    @moduledoc false
    @behaviour GeoGenius.Provider

    @impl true
    def area_types, do: [%{key: "city", rank: 30}, %{key: "state", rank: 10}]
    @impl true
    def required_options, do: []
    @impl true
    defdelegate artifacts(manifest), to: GeoGenius.Provider, as: :all_artifacts
    @impl true
    def stage(_manifest, _artifact, _path, _emit, _opts), do: :ok
    @impl true
    defdelegate relations(manifest), to: GeoGenius.Provider, as: :always_rebuild

    @impl true
    defdelegate asserted_relations(manifest, row),
      to: GeoGenius.Provider,
      as: :no_asserted_relations

    @impl true
    def normalize(_manifest, %{payload: %{"city" => city, "state" => state}}) do
      {:ok,
       [
         %Area{
           authority_key: "demo_auth",
           area_type_key: "city",
           code: city,
           centroid: nil,
           geometry: nil,
           names: [%Name{name: city, kind: :official}],
           codes: [],
           attributes: %{}
         },
         %Area{
           authority_key: "demo_auth",
           area_type_key: "state",
           code: state,
           centroid: nil,
           geometry: nil,
           names: [%Name{name: state, kind: :official}],
           codes: [],
           attributes: %{}
         }
       ]}
    end
  end

  defmodule SecondAreaBadKindProvider do
    @moduledoc false
    @behaviour GeoGenius.Provider

    @impl true
    def area_types, do: [%{key: "city", rank: 30}, %{key: "state", rank: 10}]
    @impl true
    def required_options, do: []
    @impl true
    defdelegate artifacts(manifest), to: GeoGenius.Provider, as: :all_artifacts
    @impl true
    def stage(_manifest, _artifact, _path, _emit, _opts), do: :ok
    @impl true
    defdelegate relations(manifest), to: GeoGenius.Provider, as: :always_rebuild

    @impl true
    defdelegate asserted_relations(manifest, row),
      to: GeoGenius.Provider,
      as: :no_asserted_relations

    # The row's second area carries a name kind outside `Name.kind/0`, so
    # `write_areas/4` must fail the whole row rather than land the first
    # area and silently drop the second.
    @impl true
    def normalize(_manifest, %{payload: %{"city" => city, "state" => state}}) do
      {:ok,
       [
         %Area{
           authority_key: "demo_auth",
           area_type_key: "city",
           code: city,
           centroid: nil,
           geometry: nil,
           names: [%Name{name: city, kind: :official}],
           codes: [],
           attributes: %{}
         },
         %Area{
           authority_key: "demo_auth",
           area_type_key: "state",
           code: state,
           centroid: nil,
           geometry: nil,
           names: [%Name{name: state, kind: :bogus}],
           codes: [],
           attributes: %{}
         }
       ]}
    end
  end

  defmodule MiddleAreaBadKindProvider do
    @moduledoc false
    @behaviour GeoGenius.Provider

    @impl true
    def area_types,
      do: [%{key: "city", rank: 30}, %{key: "state", rank: 10}, %{key: "zip", rank: 40}]

    @impl true
    def required_options, do: []
    @impl true
    defdelegate artifacts(manifest), to: GeoGenius.Provider, as: :all_artifacts
    @impl true
    def stage(_manifest, _artifact, _path, _emit, _opts), do: :ok
    @impl true
    defdelegate relations(manifest), to: GeoGenius.Provider, as: :always_rebuild

    @impl true
    defdelegate asserted_relations(manifest, row),
      to: GeoGenius.Provider,
      as: :no_asserted_relations

    # The rejected area sits between two writable ones, so a `write_areas/4`
    # that folded the whole list and returned the accumulated error would
    # still land the trailing area. Only halting leaves it unwritten.
    @impl true
    def normalize(_manifest, %{payload: %{"city" => city, "state" => state, "zip" => zip}}) do
      {:ok,
       [
         %Area{
           authority_key: "demo_auth",
           area_type_key: "city",
           code: city,
           centroid: nil,
           geometry: nil,
           names: [%Name{name: city, kind: :official}],
           codes: [],
           attributes: %{}
         },
         %Area{
           authority_key: "demo_auth",
           area_type_key: "state",
           code: state,
           centroid: nil,
           geometry: nil,
           names: [%Name{name: state, kind: :bogus}],
           codes: [],
           attributes: %{}
         },
         %Area{
           authority_key: "demo_auth",
           area_type_key: "zip",
           code: zip,
           centroid: nil,
           geometry: nil,
           names: [%Name{name: zip, kind: :official}],
           codes: [],
           attributes: %{}
         }
       ]}
    end
  end

  test "a row returning two areas writes both and counts both" do
    state = normalize_fixture(MultiAreaProvider, [%{"city" => "LA", "state" => "CA"}])

    assert {:ok, %State{metrics: metrics}} = Normalize.normalize(state)
    assert metrics["areas"] == 2
    assert metrics["skipped"] == 0

    keys = area_keys_in_release(state)
    assert "demo_auth:city:LA" in keys
    assert "demo_auth:state:CA" in keys
  end

  test "two rows implying the same state converge on one area" do
    rows = [%{"city" => "LA", "state" => "CA"}, %{"city" => "SF", "state" => "CA"}]
    state = normalize_fixture(MultiAreaProvider, rows)

    assert {:ok, %State{metrics: metrics}} = Normalize.normalize(state)
    assert metrics["areas"] == 4

    keys = area_keys_in_release(state)
    assert Enum.count(keys, &(&1 == "demo_auth:state:CA")) == 1
  end

  test "a bad name kind on the second area fails the row's normalization outright" do
    state = normalize_fixture(SecondAreaBadKindProvider, [%{"city" => "LA", "state" => "CA"}])

    assert {:error, reason} = Normalize.normalize(state)
    assert reason =~ "demo_auth:state:CA"
    assert reason =~ ":bogus"

    # The rejected area was never written -- it fails validation before any
    # write for it happens -- while the row's earlier, valid area landed
    # ahead of it, since a row is not written as one transaction.
    keys = area_keys_in_release(state)
    refute "demo_auth:state:CA" in keys
    assert "demo_auth:city:LA" in keys
  end

  test "a bad name kind stops the row's remaining areas from being written" do
    payloads = [%{"city" => "LA", "state" => "CA", "zip" => "90001"}]
    state = normalize_fixture(MiddleAreaBadKindProvider, payloads)

    assert {:error, reason} = Normalize.normalize(state)
    assert reason =~ "demo_auth:state:CA"

    keys = area_keys_in_release(state)
    assert "demo_auth:city:LA" in keys
    refute "demo_auth:state:CA" in keys

    # The area after the rejected one never reaches a write, so a row's
    # failure cannot be half-applied past the point it failed at.
    refute "demo_auth:zip:90001" in keys
  end

  # Registers a collection carrying `provider`'s own area types under a
  # fixed authority key, opens a release, stages `payloads` as rows, and
  # returns the `%State{}` a normalize test drives directly against
  # `GeoGenius.Pipeline.Normalize.normalize/1` -- the manifest a real run
  # would carry is never built, since nothing on this path reads it.
  defp normalize_fixture(provider, payloads) do
    context = Context.new(repo: TestRepo, prefix: "geo_genius")
    collection = "normalize_fixture_#{System.unique_integer([:positive])}"

    ExUnit.Callbacks.on_exit({__MODULE__, collection}, fn ->
      ImportFixture.teardown!(collection)
    end)

    Catalog.upsert_collection(context, %{key: collection, name: collection})
    Catalog.upsert_authority(context, collection, %{key: "demo_auth", name: "Demo Authority"})

    Enum.each(provider.area_types(), fn area_type ->
      Catalog.upsert_area_type(context, collection, area_type)
    end)

    release_id =
      Catalog.open_release(context, collection, %{
        release_key: "r1",
        manifest: %{"collection" => collection},
        source_date: ~D[2026-01-15]
      })

    run_id =
      Catalog.begin_or_resume_import(context, release_id, %{
        owner: "normalize-fixture",
        runner_backend: "test",
        stale_after_seconds: 300
      })

    on_exit({__MODULE__, {:staging, run_id}}, fn -> Staging.drop(context, run_id) end)

    Staging.create(context, run_id)
    rows = Enum.map(payloads, &%Staging.Row{artifact: "fixture", payload: &1, geom: nil})
    Staging.insert(context, run_id, rows)

    %State{
      context: context,
      run: Catalog.import_run(context, run_id),
      opts: [],
      work_dir: System.tmp_dir!(),
      publish?: false,
      batch_size: 500,
      timeout: 30_000,
      manifest: nil,
      provider: provider
    }
  end

  defp area_keys_in_release(%State{context: context, run: run}) do
    %Postgrex.Result{rows: rows} =
      TestRepo.query!(
        """
        SELECT area.area_key
          FROM "#{context.prefix}".release_area
          JOIN "#{context.prefix}".area ON area.id = release_area.area_id
         WHERE release_area.release_id = $1
        """,
        [Ecto.UUID.dump!(run.release_id)]
      )

    Enum.map(rows, fn [area_key] -> area_key end)
  end
end
