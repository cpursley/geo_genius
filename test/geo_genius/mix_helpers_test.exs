defmodule GeoGenius.MixHelpersTest do
  use ExUnit.Case, async: true

  alias GeoGenius.MixHelpers

  test "parses setup args with defaults" do
    assert %{repo: nil, prefix: "geo_genius", with_extensions: false} =
             MixHelpers.parse_setup_args([])
  end

  test "parses an explicit repo, prefix, and extension flag" do
    assert %{repo: MyApp.Repo, prefix: "custom_geo", with_extensions: true} =
             MixHelpers.parse_setup_args([
               "--repo",
               "MyApp.Repo",
               "--prefix",
               "custom_geo",
               "--with-extensions"
             ])
  end

  test "rejects an invalid prefix" do
    exception =
      assert_raise Mix.Error, fn -> MixHelpers.parse_setup_args(["--prefix", "Bad Prefix"]) end

    assert exception.message == ~s(invalid PostgreSQL prefix: "Bad Prefix")
  end

  test "requires adjacent upgrade versions" do
    exception =
      assert_raise Mix.Error, fn ->
        MixHelpers.parse_upgrade_args(["--from", "1", "--to", "3"])
      end

    assert exception.message ==
             "--from and --to must describe one adjacent upgrade with --from >= 1"
  end

  test "names the integer option that is missing or unparseable" do
    missing = assert_raise Mix.Error, fn -> MixHelpers.parse_upgrade_args(["--to", "2"]) end
    assert missing.message == "--from is required and must be an integer"

    no_target = assert_raise Mix.Error, fn -> MixHelpers.parse_upgrade_args(["--from", "1"]) end
    assert no_target.message == "--to is required and must be an integer"
  end

  # `release_label/1` exists so operator output shows a bare id and names an
  # absent publication. `inspect/1` would render `"uuid"` with quotes and `nil`
  # for nothing published; every task-level assertion uses `=~`, which tolerates
  # the quoted form, so the difference is pinned here directly.
  test "labels a release id bare and an absent publication as none" do
    assert MixHelpers.release_label(nil) == "none"

    assert MixHelpers.release_label("2f1a0e7c-0000-4000-8000-000000000000") ==
             "2f1a0e7c-0000-4000-8000-000000000000"
  end

  test "renders a pinned migration body" do
    body = MixHelpers.migration_body("geo_genius", 0, 1, 1, false)

    assert body =~ ~s|def up, do: GeoGenius.Migration.up(prefix: "geo_genius", version: 1)|
    assert body =~ ~s|def down, do: GeoGenius.Migration.down(prefix: "geo_genius", version: 0)|
    refute body =~ "CREATE EXTENSION"
  end

  test "emits extension statements when requested" do
    body = MixHelpers.migration_body("geo_genius", 0, 1, 1, true)

    assert body =~ ~s|execute("CREATE EXTENSION IF NOT EXISTS postgis")|
    assert body =~ ~s|execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")|
  end

  # A fresh install runs every version in one migration, so it may target any
  # available version. An upgrade of an existing install moves one at a time.
  test "validates transitions from a fresh install and between adjacent versions" do
    assert MixHelpers.validate_transition!(0, 1, 1) == :ok
    assert MixHelpers.validate_transition!(0, 3, 3) == :ok
    assert MixHelpers.validate_transition!(1, 2, 2) == :ok

    # Payloads, not prefixes: the versions the operator asked for and the one
    # the package actually carries are the whole of what makes either message
    # actionable.
    unavailable = assert_raise Mix.Error, fn -> MixHelpers.validate_transition!(0, 4, 3) end
    assert unavailable.message == "target version 4 is unavailable; current version is 3"

    non_adjacent = assert_raise Mix.Error, fn -> MixHelpers.validate_transition!(1, 3, 3) end
    assert non_adjacent.message == "versions must be adjacent; received 1 to 3"

    beyond = assert_raise Mix.Error, fn -> MixHelpers.validate_transition!(2, 3, 2) end
    assert beyond.message == "target version 3 is unavailable; current version is 2"
  end

  test "parse_strict!/2 names the unknown option and the unexpected positional" do
    unknown =
      assert_raise Mix.Error, fn -> MixHelpers.parse_strict!(["--nope"], repo: :string) end

    assert unknown.message == "unknown option: --nope"

    positional =
      assert_raise Mix.Error, fn -> MixHelpers.parse_strict!(["stray"], repo: :string) end

    assert positional.message == "unexpected positional argument: stray"
  end

  test "required!/2 names the option in its dashed form" do
    exception = assert_raise Mix.Error, fn -> MixHelpers.required!([], :release_id) end
    assert exception.message == "--release-id is required"
  end
end
