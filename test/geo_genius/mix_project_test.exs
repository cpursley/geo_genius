defmodule GeoGenius.MixProjectTest do
  use ExUnit.Case, async: true

  test "the package supports every Postgrex minor in the documented compatibility window" do
    requirement =
      GeoGenius.MixProject.project()
      |> Keyword.fetch!(:deps)
      |> Enum.find_value(fn
        {:postgrex, requirement} -> requirement
        _dependency -> nil
      end)

    assert Version.match?("0.20.0", requirement)
    assert Version.match?("0.21.1", requirement)
    assert Version.match?("0.22.4", requirement)
    refute Version.match?("0.19.3", requirement)
    refute Version.match?("0.23.0", requirement)
  end

  test "PgFlow is an optional dependency that establishes integration compile order" do
    deps = GeoGenius.MixProject.project() |> Keyword.fetch!(:deps)

    assert {:pgflow, requirement, opts} =
             Enum.find(deps, &match?({:pgflow, _, _}, &1))

    refute Version.match?("0.3.3", requirement)
    assert Version.match?("0.3.4", requirement)
    refute Version.match?("0.4.0", requirement)
    assert opts[:optional] == true
    refute Keyword.has_key?(opts, :only)

    for package <- [:phoenix, :phoenix_live_view, :livefilter] do
      assert {^package, _requirement, package_opts} =
               Enum.find(deps, &match?({^package, _, _}, &1))

      assert package_opts[:optional] == true
    end
  end
end
