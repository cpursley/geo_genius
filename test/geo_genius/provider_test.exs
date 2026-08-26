defmodule GeoGenius.ProviderTest do
  use ExUnit.Case, async: true

  @callbacks [
    area_types: 0,
    required_options: 0,
    artifacts: 1,
    stage: 5,
    normalize: 2,
    relations: 1
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
end
