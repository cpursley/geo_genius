defmodule GeoGenius.ProviderTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Manifest
  alias GeoGenius.Provider.Area
  alias GeoGenius.Providers.CSV
  alias GeoGenius.Staging
  alias GeoGenius.StubProvider

  @callbacks [
    required_options: 0,
    artifacts: 1,
    stage: 5,
    normalize: 2,
    relations: 1,
    asserted_relations: 2
  ]

  test "every shipped provider implements the whole behaviour" do
    providers = GeoGenius.Config.providers()
    assert providers != %{}, "the loop below is vacuous if no provider is registered"

    for {_name, module} <- providers do
      Code.ensure_loaded!(module)

      for {fun, arity} <- @callbacks do
        assert function_exported?(module, fun, arity),
               "#{inspect(module)} does not export #{fun}/#{arity}"
      end

      behaviours =
        module.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert GeoGenius.Provider in behaviours
    end
  end

  test "the default asserted_relations helper returns no edges" do
    manifest = %GeoGenius.Manifest{
      collection: "demo",
      release: "r1",
      provider: "csv",
      authorities: [%{key: "demo", name: "Demo"}],
      sources: [],
      options: %{}
    }

    row = %GeoGenius.Staging.Row{artifact: "a", payload: %{}, geom: nil}

    assert GeoGenius.Provider.no_asserted_relations(manifest, row) == []
    assert CSV.asserted_relations(manifest, row) == []
  end

  describe "the behaviour's callback set" do
    test "does not declare an area_types callback" do
      callbacks = GeoGenius.Provider.behaviour_info(:callbacks)
      refute {:area_types, 0} in callbacks
    end

    test "declares exactly the six callbacks a provider must implement" do
      callbacks = GeoGenius.Provider.behaviour_info(:callbacks)
      optional = GeoGenius.Provider.behaviour_info(:optional_callbacks)

      assert Enum.sort(callbacks -- optional) == [
               {:artifacts, 1},
               {:asserted_relations, 2},
               {:normalize, 2},
               {:relations, 1},
               {:required_options, 0},
               {:stage, 5}
             ]
    end

    # `behaviour_info(:callbacks)` counts optional callbacks among the rest, so
    # the required set above is only meaningful alongside this: without it, a
    # callback made optional by mistake would still leave the six intact.
    test "declares validate_options/1 as its only optional callback" do
      assert GeoGenius.Provider.behaviour_info(:optional_callbacks) == [validate_options: 1]
    end
  end

  # The four implied-area cases, held against the contract rather than against
  # `GeoGenius.Providers.ImpliedAreas` alone: any provider routing its
  # `normalize/2` and `asserted_relations/2` through that module owes the same
  # answers, and a failure here says the contract broke rather than that one
  # module did.
  describe "a provider whose manifest declares implied_areas" do
    test "a row implying two tiers yields both areas and both edges" do
      manifest =
        implying_manifest([
          %{
            "area_type" => "cluster",
            "code_field" => "CLUSTER",
            "names" => %{"1" => "Cluster One"}
          },
          %{"area_type" => "outer", "code_field" => "OUTER", "names" => %{"9" => "Outer Nine"}}
        ])

      row = stub_row(%{"area_type" => "inner", "code" => "A", "CLUSTER" => "1", "OUTER" => "9"})

      assert {:ok, [own, cluster, outer]} = StubProvider.normalize(manifest, row)
      assert {own.area_type_key, own.code} == {"inner", "A"}
      assert {cluster.area_type_key, cluster.code} == {"cluster", "1"}
      assert {outer.area_type_key, outer.code} == {"outer", "9"}

      # An implied area carries no shape: the source names the grouping by
      # code only, so deriving one from this row would claim the grouping's
      # boundary is one member's boundary.
      assert cluster.geometry == nil
      assert outer.geometry == nil

      assert StubProvider.asserted_relations(manifest, row) == [
               {"demo:cluster:1", "demo:inner:A", "contains"},
               {"demo:outer:9", "demo:inner:A", "contains"}
             ]
    end

    test "a provider implying none returns the bare area and asserts nothing" do
      manifest = implying_manifest(nil)
      row = stub_row(%{"area_type" => "inner", "code" => "A"})

      # A bare `{:ok, %Area{}}`, not a one-element list: that is the shape
      # every manifest declaring no `implied_areas` already depends on.
      assert {:ok, %Area{code: "A"}} = StubProvider.normalize(manifest, row)
      assert StubProvider.asserted_relations(manifest, row) == []
    end

    test "a blank implied code is skipped while a populated one in the same release is not" do
      manifest = implying_manifest([cluster_entry()])

      populated = stub_row(%{"area_type" => "inner", "code" => "A", "CLUSTER" => "1"})
      blank = stub_row(%{"area_type" => "inner", "code" => "B", "CLUSTER" => "  "})

      assert {:ok, [%Area{code: "A"}, %Area{area_type_key: "cluster", code: "1"}]} =
               StubProvider.normalize(manifest, populated)

      # The blank row still stages its own area. A source whose grouping
      # column is populated for most rows and blank for a few is ordinary,
      # and failing the release over it would be wrong.
      assert {:ok, [%Area{code: "B"}]} = StubProvider.normalize(manifest, blank)

      assert StubProvider.asserted_relations(manifest, populated) == [
               {"demo:cluster:1", "demo:inner:A", "contains"}
             ]

      assert StubProvider.asserted_relations(manifest, blank) == []
    end

    test "an implied code absent from names fails the row naming the code and the field" do
      manifest = implying_manifest([cluster_entry()])
      row = stub_row(%{"area_type" => "inner", "code" => "A", "CLUSTER" => "2"})

      assert {:error, reason} = StubProvider.normalize(manifest, row)
      assert reason =~ "implied_areas"
      assert reason =~ "cluster"
      assert reason =~ "\"2\""
      assert reason =~ "CLUSTER"
      assert reason =~ "names"
    end
  end

  defp cluster_entry do
    %{"area_type" => "cluster", "code_field" => "CLUSTER", "names" => %{"1" => "Cluster One"}}
  end

  defp implying_manifest(entries) do
    options =
      case entries do
        nil -> %{"mode" => "default"}
        entries -> %{"mode" => "default", "implied_areas" => entries}
      end

    %Manifest{
      collection: "demo",
      release: "r1",
      provider: "stub",
      authorities: [%{key: "demo", name: "Demo"}],
      sources: [],
      options: options
    }
  end

  defp stub_row(payload) do
    %Staging.Row{artifact: "a", payload: payload, geom: nil}
  end
end
