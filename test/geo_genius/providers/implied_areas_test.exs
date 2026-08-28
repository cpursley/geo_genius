defmodule GeoGenius.Providers.ImpliedAreasTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Provider.Area
  alias GeoGenius.Providers.ImpliedAreas

  describe "parse/2" do
    test "returns an empty list when the option is absent" do
      assert {:ok, []} = ImpliedAreas.parse(%{}, "code_property")
    end

    test "reads area type, code field, names and relation" do
      options = %{
        "implied_areas" => [
          %{
            "area_type" => "cluster",
            "code_property" => "CLUSTER",
            "names" => %{"1" => "First", "2" => "Second"},
            "relation" => "contains"
          }
        ]
      }

      assert {:ok, [entry]} = ImpliedAreas.parse(options, "code_property")
      assert entry.area_type_key == "cluster"
      assert entry.code_field == "CLUSTER"
      assert entry.names == %{"1" => "First", "2" => "Second"}
      assert entry.relation == "contains"
      assert entry.authority_key == nil
    end

    test "defaults relation to contains" do
      options = %{"implied_areas" => [%{"area_type" => "cluster", "code_property" => "C"}]}
      assert {:ok, [%{relation: "contains"}]} = ImpliedAreas.parse(options, "code_property")
    end

    test "carries an authority override" do
      options = %{
        "implied_areas" => [
          %{"area_type" => "cluster", "code_property" => "C", "authority" => "other"}
        ]
      }

      assert {:ok, [%{authority_key: "other"}]} = ImpliedAreas.parse(options, "code_property")
    end

    test "reads the provider's own code option key" do
      options = %{"implied_areas" => [%{"area_type" => "cluster", "code_column" => "C"}]}
      assert {:ok, [%{code_field: "C"}]} = ImpliedAreas.parse(options, "code_column")
      assert {:error, reason} = ImpliedAreas.parse(options, "code_property")
      assert reason =~ "code_property"
    end

    test "rejects a non-list option" do
      assert {:error, reason} = ImpliedAreas.parse(%{"implied_areas" => "no"}, "code_property")
      assert reason =~ "must be a list"
    end

    test "rejects an entry that is not an object" do
      assert {:error, reason} = ImpliedAreas.parse(%{"implied_areas" => ["no"]}, "code_property")
      assert reason =~ "must be an object"
    end

    test "rejects an entry with no area type" do
      options = %{"implied_areas" => [%{"code_property" => "C"}]}
      assert {:error, reason} = ImpliedAreas.parse(options, "code_property")
      assert reason =~ "area_type"
    end

    test "rejects an entry with an empty area_type" do
      options = %{"implied_areas" => [%{"area_type" => "", "code_property" => "C"}]}
      assert {:error, reason} = ImpliedAreas.parse(options, "code_property")
      assert reason =~ "area_type"
    end

    test "rejects an entry with an empty code column key" do
      options = %{"implied_areas" => [%{"area_type" => "cluster", "code_property" => ""}]}
      assert {:error, reason} = ImpliedAreas.parse(options, "code_property")
      assert reason =~ "code_property"
    end

    test "rejects a names value that is not an object" do
      options = %{
        "implied_areas" => [%{"area_type" => "cluster", "code_property" => "C", "names" => []}]
      }

      assert {:error, reason} = ImpliedAreas.parse(options, "code_property")
      assert reason =~ "names must be an object"
    end

    test "rejects a names entry whose value is not a string" do
      options = %{
        "implied_areas" => [
          %{"area_type" => "cluster", "code_property" => "C", "names" => %{"1" => 42}}
        ]
      }

      assert {:error, reason} = ImpliedAreas.parse(options, "code_property")
      assert reason =~ "names"
      assert reason =~ "42"
    end

    test "rejects a names entry whose key is not a string" do
      options = %{
        "implied_areas" => [
          %{"area_type" => "cluster", "code_property" => "C", "names" => %{1 => "First"}}
        ]
      }

      assert {:error, reason} = ImpliedAreas.parse(options, "code_property")
      assert reason =~ "names"
    end

    test "rejects an unknown relation" do
      options = %{
        "implied_areas" => [
          %{"area_type" => "cluster", "code_property" => "C", "relation" => "near"}
        ]
      }

      assert {:error, reason} = ImpliedAreas.parse(options, "code_property")
      assert reason =~ "relation must be one of"
    end

    test "reports the first invalid entry rather than the last" do
      options = %{
        "implied_areas" => [
          %{"area_type" => "first", "code_property" => "C", "relation" => "near"},
          %{"code_property" => "D"}
        ]
      }

      assert {:error, reason} = ImpliedAreas.parse(options, "code_property")
      assert reason =~ "relation must be one of"
    end
  end

  describe "areas/3" do
    setup do
      {:ok, entries} =
        ImpliedAreas.parse(
          %{
            "implied_areas" => [
              %{
                "area_type" => "cluster",
                "code_property" => "CLUSTER",
                "names" => %{"1" => "First", "9" => "Ninth"}
              }
            ]
          },
          "code_property"
        )

      {:ok, entries: entries}
    end

    test "builds one area per populated entry", %{entries: entries} do
      assert {:ok, [area]} = ImpliedAreas.areas(%{"CLUSTER" => "1"}, entries, "auth")
      assert area.authority_key == "auth"
      assert area.area_type_key == "cluster"
      assert area.code == "1"
      assert [%{name: "First", kind: :official}] = area.names
    end

    test "carries no geometry and no centroid", %{entries: entries} do
      assert {:ok, [area]} = ImpliedAreas.areas(%{"CLUSTER" => "1"}, entries, "auth")
      assert area.geometry == nil
      assert area.centroid == nil
    end

    test "implies nothing when the code column is blank", %{entries: entries} do
      assert {:ok, []} = ImpliedAreas.areas(%{"CLUSTER" => ""}, entries, "auth")
      assert {:ok, []} = ImpliedAreas.areas(%{"CLUSTER" => nil}, entries, "auth")
      assert {:ok, []} = ImpliedAreas.areas(%{}, entries, "auth")
    end

    test "errors when a present code has no name", %{entries: entries} do
      assert {:error, reason} = ImpliedAreas.areas(%{"CLUSTER" => "4"}, entries, "auth")
      assert reason =~ "\"4\""
      assert reason =~ "names"
    end

    test "prefers an entry's authority override to the row's authority" do
      {:ok, entries} =
        ImpliedAreas.parse(
          %{
            "implied_areas" => [
              %{
                "area_type" => "cluster",
                "code_property" => "CLUSTER",
                "names" => %{"1" => "First"},
                "authority" => "other"
              }
            ]
          },
          "code_property"
        )

      assert {:ok, [area]} = ImpliedAreas.areas(%{"CLUSTER" => "1"}, entries, "auth")
      assert area.authority_key == "other"
    end

    test "builds one area per entry across several tiers" do
      {:ok, entries} =
        ImpliedAreas.parse(
          %{
            "implied_areas" => [
              %{"area_type" => "outer", "code_property" => "O", "names" => %{"1" => "Outer"}},
              %{"area_type" => "inner", "code_property" => "I", "names" => %{"2" => "Inner"}}
            ]
          },
          "code_property"
        )

      assert {:ok, [outer, inner]} =
               ImpliedAreas.areas(%{"O" => "1", "I" => "2"}, entries, "auth")

      assert outer.area_type_key == "outer"
      assert inner.area_type_key == "inner"
    end

    test "implies only the populated tier when one is blank" do
      {:ok, entries} =
        ImpliedAreas.parse(
          %{
            "implied_areas" => [
              %{"area_type" => "outer", "code_property" => "O", "names" => %{"1" => "Outer"}},
              %{"area_type" => "inner", "code_property" => "I", "names" => %{"2" => "Inner"}}
            ]
          },
          "code_property"
        )

      assert {:ok, [only]} = ImpliedAreas.areas(%{"O" => "1", "I" => ""}, entries, "auth")
      assert only.area_type_key == "outer"
    end
  end

  describe "edges/4" do
    setup do
      {:ok, entries} =
        ImpliedAreas.parse(
          %{
            "implied_areas" => [
              %{
                "area_type" => "cluster",
                "code_property" => "CLUSTER",
                "names" => %{"1" => "First"},
                "relation" => "mostly_contains"
              }
            ]
          },
          "code_property"
        )

      {:ok, entries: entries}
    end

    test "names the implied area as parent and the row's area as child", %{entries: entries} do
      assert [{parent, child, relation}] =
               ImpliedAreas.edges(%{"CLUSTER" => "1"}, entries, "auth", "auth:place:X")

      assert parent == "auth:cluster:1"
      assert child == "auth:place:X"
      assert relation == "mostly_contains"
    end

    test "composes the parent key the same way areas/3 keys the area", %{entries: entries} do
      {:ok, [area]} = ImpliedAreas.areas(%{"CLUSTER" => "1"}, entries, "auth")

      [{parent, _child, _relation}] =
        ImpliedAreas.edges(%{"CLUSTER" => "1"}, entries, "auth", "auth:place:X")

      assert parent == Area.key(area)
    end

    test "asserts no edge when the code column is blank", %{entries: entries} do
      assert [] == ImpliedAreas.edges(%{"CLUSTER" => ""}, entries, "auth", "auth:place:X")
      assert [] == ImpliedAreas.edges(%{}, entries, "auth", "auth:place:X")
    end

    test "defaults the relation to contains" do
      {:ok, entries} =
        ImpliedAreas.parse(
          %{"implied_areas" => [%{"area_type" => "cluster", "code_property" => "C"}]},
          "code_property"
        )

      assert [{_parent, _child, "contains"}] =
               ImpliedAreas.edges(%{"C" => "1"}, entries, "auth", "auth:place:X")
    end

    test "asserts one edge per populated tier" do
      {:ok, entries} =
        ImpliedAreas.parse(
          %{
            "implied_areas" => [
              %{"area_type" => "outer", "code_property" => "O"},
              %{"area_type" => "inner", "code_property" => "I"}
            ]
          },
          "code_property"
        )

      edges = ImpliedAreas.edges(%{"O" => "1", "I" => "2"}, entries, "auth", "auth:place:X")

      assert [
               {"auth:outer:1", "auth:place:X", "contains"},
               {"auth:inner:2", "auth:place:X", "contains"}
             ] = edges
    end

    test "honours an authority override in the parent key" do
      {:ok, entries} =
        ImpliedAreas.parse(
          %{
            "implied_areas" => [
              %{"area_type" => "cluster", "code_property" => "C", "authority" => "other"}
            ]
          },
          "code_property"
        )

      assert [{"other:cluster:1", _child, _relation}] =
               ImpliedAreas.edges(%{"C" => "1"}, entries, "auth", "auth:place:X")
    end
  end

  describe "parse/2 relation whitelist" do
    test "accepts overlaps" do
      options = %{
        "implied_areas" => [
          %{"area_type" => "cluster", "code_property" => "C", "relation" => "overlaps"}
        ]
      }

      assert {:ok, [%{relation: "overlaps"}]} = ImpliedAreas.parse(options, "code_property")
    end

    test "accepts mostly_contains" do
      options = %{
        "implied_areas" => [
          %{"area_type" => "cluster", "code_property" => "C", "relation" => "mostly_contains"}
        ]
      }

      assert {:ok, [%{relation: "mostly_contains"}]} =
               ImpliedAreas.parse(options, "code_property")
    end
  end

  describe "with_implied/4" do
    setup do
      {:ok, entries} =
        ImpliedAreas.parse(
          %{
            "implied_areas" => [
              %{
                "area_type" => "cluster",
                "code_property" => "CLUSTER",
                "names" => %{"1" => "First"}
              }
            ]
          },
          "code_property"
        )

      area = %Area{authority_key: "auth", area_type_key: "place", code: "X"}
      {:ok, entries: entries, area: area}
    end

    test "returns the bare area when nothing is implied", %{area: area} do
      assert {:ok, ^area} = ImpliedAreas.with_implied(area, %{"CLUSTER" => "1"}, [], "auth")
    end

    test "returns the area followed by what the payload implies", %{
      entries: entries,
      area: area
    } do
      assert {:ok, [^area, implied]} =
               ImpliedAreas.with_implied(area, %{"CLUSTER" => "1"}, entries, "auth")

      assert implied.area_type_key == "cluster"
    end

    test "returns a one-element list when the implied code is blank", %{
      entries: entries,
      area: area
    } do
      assert {:ok, [^area]} = ImpliedAreas.with_implied(area, %{"CLUSTER" => ""}, entries, "auth")
    end

    test "propagates an unnamed implied code as an error", %{entries: entries, area: area} do
      assert {:error, reason} =
               ImpliedAreas.with_implied(area, %{"CLUSTER" => "9"}, entries, "auth")

      assert reason =~ "names"
    end
  end
end
