defmodule GeoGenius.ProviderTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Providers.CSV

  @callbacks [
    area_types: 0,
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
end
