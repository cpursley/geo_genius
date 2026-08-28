defmodule GeoGenius.PublishedSqlTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL
  alias GeoGenius.Published
  alias GeoGenius.Published.{Area, AreaCode, AreaName, AreaRelation}
  alias GeoGenius.TestRepo

  # Every schema and the view it reads. The prefix is the compile-time one, so
  # a schema that hardcoded "geo_genius" instead of reading it would pass here
  # and fail for a host installed anywhere else. Every assertion in this file
  # that names a source qualifies it through `qualified/1`, which reads the
  # same configuration the schemas read, so none of them holds only while the
  # prefix happens to be the default.
  @schemas [
    {Area, "published_areas"},
    {AreaCode, "published_area_codes"},
    {AreaName, "published_area_names"},
    {AreaRelation, "published_area_relations"}
  ]

  # The release-scoped base an explicit `:release_id` swaps each schema onto.
  # Pointing a schema at a source is only sound while the source carries every
  # column the schema declares, which is what the parity test below pins.
  @release_sources [
    {Area, "release_areas"},
    {AreaCode, "release_area_codes"},
    {AreaName, "release_area_names"},
    {AreaRelation, "release_relations"}
  ]

  @release_id "0198e1cb-2b6e-7a2d-9f3a-0a1b2c3d4e5f"

  defp statement(query) do
    {sql, _params} = SQL.to_sql(:all, TestRepo, query)
    sql
  end

  defp params(query) do
    {_sql, params} = SQL.to_sql(:all, TestRepo, query)
    params
  end

  # Column names come back as strings and are compared as strings. Casting them
  # to atoms would turn the one case this test exists to catch -- a view column
  # no schema declares, so no atom for it exists yet -- into an ArgumentError
  # from String.to_existing_atom/1 rather than a readable diff.
  defp view_columns(view) do
    %{rows: rows} =
      TestRepo.query!(
        """
        SELECT column_name FROM information_schema.columns
         WHERE table_schema = $1 AND table_name = $2
        """,
        [Published.prefix(), view]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  defp schema_columns(schema) do
    schema.__schema__(:fields) |> Enum.map(&Atom.to_string/1) |> Enum.sort()
  end

  # The qualified source name Ecto emits under the compiled prefix.
  defp qualified(source), do: ~s("#{Published.prefix()}"."#{source}")

  describe "the schemas" do
    test "each reads its published view under the configured prefix" do
      for {schema, view} <- @schemas do
        assert schema.__schema__(:source) == view
        assert schema.__schema__(:prefix) == Published.prefix()
      end
    end

    # Requirement one: no silent narrowing. Comparing against
    # information_schema rather than a hand-copied list means a column added to
    # a view and not to its schema fails here, which a pinned literal list
    # would not catch.
    test "each exposes every column of its view, and no column the view lacks" do
      for {schema, view} <- @schemas do
        assert {view, schema_columns(schema)} == {view, view_columns(view)}
      end
    end

    test "each release-scoped base carries exactly the columns its schema declares" do
      for {schema, view} <- @release_sources do
        assert {view, schema_columns(schema)} == {view, view_columns(view)}
      end
    end

    test "the columns the function-backed select drops survive into the query" do
      sql = statement(Published.areas())

      assert sql =~ "release_id"
      assert sql =~ "collection_key"
      assert sql =~ "authority"
      assert sql =~ "type_rank"
    end
  end

  describe "areas/1" do
    test "reads the view rather than a set-returning function" do
      sql = statement(Published.areas())

      assert sql =~ qualified("published_areas")
      refute sql =~ "children_of("
      refute sql =~ "areas_by_code("
    end

    test "excludes retired areas unless asked for them" do
      assert statement(Published.areas()) =~ ~s|"retired_at" IS NULL|
      refute statement(Published.areas(include_retired: true)) =~ ~s|"retired_at" IS NULL|
    end

    test "binds a release id given as a hyphenated string or as raw bytes alike" do
      release_id = "0198e1cb-2b6e-7a2d-9f3a-0a1b2c3d4e5f"
      raw = Ecto.UUID.dump!(release_id)

      assert params(Published.areas(release_id: release_id)) ==
               params(Published.areas(release_id: raw))

      assert raw in params(Published.areas(release_id: release_id))
    end

    test "leaves out a filter whose option is absent" do
      assert params(Published.areas()) == []
      assert params(Published.areas(collections: ["demo"])) == [["demo"]]
    end
  end

  describe "named bindings" do
    test "areas/1 names its area binding" do
      assert Ecto.Query.has_named_binding?(Published.areas(), :area)
    end

    test "children_of/2 and ancestors_of/2 name both the area and the relation" do
      for query <- [Published.children_of(["a"]), Published.ancestors_of(["a"])] do
        assert Ecto.Query.has_named_binding?(query, :area)
        assert Ecto.Query.has_named_binding?(query, :relation)
      end
    end

    test "areas_by_code/3 names the code it matched on" do
      query = Published.areas_by_code("slug", ["shared"])

      assert Ecto.Query.has_named_binding?(query, :area)
      assert Ecto.Query.has_named_binding?(query, :code)
    end
  end

  describe "set-keyed arguments" do
    test "the plural forms bind one array rather than one query per key" do
      keys = ["a", "b", "c"]

      assert keys in params(Published.children_of(keys))
      assert keys in params(Published.ancestors_of(keys))
      assert keys in params(Published.areas(area_keys: keys))
    end

    test "a single binary is accepted as a one-element set" do
      assert params(Published.children_of("a")) == params(Published.children_of(["a"]))
    end
  end

  test "children_of/2 keeps the relation and the area on the same release" do
    sql = statement(Published.children_of(["a"]))

    assert sql =~ qualified("published_area_relations")
    assert sql =~ ~s|(p1."release_id" = p0."release_id")|
  end

  describe "release-scoped sources" do
    test "an explicit release id swaps every source onto its release-scoped base" do
      opts = [release_id: @release_id]

      for {sql, base, published} <- [
            {statement(Published.areas(opts)), "release_areas", "published_areas"},
            {statement(Published.codes(opts)), "release_area_codes", "published_area_codes"},
            {statement(Published.names(opts)), "release_area_names", "published_area_names"},
            {statement(Published.relations(opts)), "release_relations",
             "published_area_relations"}
          ] do
        assert sql =~ qualified(base)
        refute sql =~ qualified(published)
      end
    end

    test "the joined sources swap too, so no query reads one of each" do
      children = statement(Published.children_of(["a"], release_id: @release_id))
      by_code = statement(Published.areas_by_code("slug", ["a"], release_id: @release_id))

      assert children =~ qualified("release_areas")
      assert children =~ qualified("release_relations")
      refute children =~ "published_"

      assert by_code =~ qualified("release_areas")
      assert by_code =~ qualified("release_area_codes")
      refute by_code =~ "published_"
    end

    test "no release id leaves every source on its published view" do
      for query <- [
            Published.areas(),
            Published.codes(),
            Published.names(),
            Published.relations(),
            Published.children_of(["a"]),
            Published.ancestors_of(["a"]),
            Published.areas_by_code("slug", ["a"])
          ],
          {_schema, base} <- @release_sources do
        refute statement(query) =~ qualified(base)
      end
    end

    test "the release-scoped read still binds the release id and excludes retired areas" do
      sql = statement(Published.areas(release_id: @release_id))

      assert Ecto.UUID.dump!(@release_id) in params(Published.areas(release_id: @release_id))
      assert sql =~ ~s|"retired_at" IS NULL|

      refute statement(Published.areas(release_id: @release_id, include_retired: true)) =~
               ~s|"retired_at" IS NULL|
    end

    # The release-mixing guard, in SQL shape on both paths. The behavioural
    # proof is in GeoGenius.PublishedTest, where two releases hold different
    # edges over the same areas.
    test "every join between two release-carrying sources equates their release ids" do
      for query <- [
            Published.children_of(["a"]),
            Published.children_of(["a"], release_id: @release_id),
            Published.ancestors_of(["a"]),
            Published.ancestors_of(["a"], release_id: @release_id),
            Published.areas_by_code("slug", ["a"]),
            Published.areas_by_code("slug", ["a"], release_id: @release_id)
          ] do
        assert statement(query) =~ ~r/[a-z]\d+\."release_id" = [a-z]\d+\."release_id"/
      end
    end
  end
end
