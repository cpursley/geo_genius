defmodule GeoGenius.Caches.FileSystemTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Caches.FileSystem

  setup do
    root =
      Path.join(System.tmp_dir!(), "geo_genius_cache_test_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, opts: [cache_dir: root]}
  end

  test "fetch reports a miss for a key it has never stored", %{opts: opts} do
    assert FileSystem.fetch("demo/src/v1/areas.geojson", opts) == :miss
  end

  test "fetch reports a miss for a key whose path is a directory, not a file", %{opts: opts} do
    source = Path.join(System.tmp_dir!(), "gg_source_#{System.unique_integer([:positive])}")
    File.write!(source, "hello")
    on_exit(fn -> File.rm_rf(source) end)

    {:ok, _} = FileSystem.put("demo/src/v1/a.geojson", source, opts)

    assert FileSystem.fetch("demo/src/v1", opts) == :miss
  end

  test "put stores a file and fetch finds it", %{opts: opts} do
    source = Path.join(System.tmp_dir!(), "gg_source_#{System.unique_integer([:positive])}")
    File.write!(source, "hello")
    on_exit(fn -> File.rm_rf(source) end)

    assert {:ok, stored} = FileSystem.put("demo/src/v1/areas.geojson", source, opts)
    assert File.read!(stored) == "hello"
    assert {:ok, ^stored} = FileSystem.fetch("demo/src/v1/areas.geojson", opts)
  end

  test "put leaves the source file in place", %{opts: opts} do
    source = Path.join(System.tmp_dir!(), "gg_source_#{System.unique_integer([:positive])}")
    File.write!(source, "hello")
    on_exit(fn -> File.rm_rf(source) end)

    {:ok, _} = FileSystem.put("demo/src/v1/a.geojson", source, opts)

    assert File.exists?(source),
           "put must copy rather than move: the caller may still need the download"
  end

  test "put leaves no staging file once the copy has landed", %{root: root, opts: opts} do
    source = Path.join(System.tmp_dir!(), "gg_source_#{System.unique_integer([:positive])}")
    File.write!(source, "hello")
    on_exit(fn -> File.rm_rf(source) end)

    {:ok, _stored} = FileSystem.put("demo/src/v1/a.geojson", source, opts)

    assert Path.wildcard(Path.join([root, "**", "*.part.*"])) == [],
           "the .part.<unique> staging file must be renamed onto the final path, not left behind"
  end

  test "put returns an error tuple when the source does not exist", %{opts: opts} do
    missing_source =
      Path.join(System.tmp_dir!(), "gg_missing_source_#{System.unique_integer([:positive])}")

    refute File.exists?(missing_source)

    assert {:error, _reason} = FileSystem.put("demo/src/v1/a.geojson", missing_source, opts)
  end

  test "put cleans up its staging file when the copy succeeds but the rename fails", %{
    root: root,
    opts: opts
  } do
    # A missing source fails at File.copy/2 before any bytes land on disk, so
    # it cannot tell a real cleanup apart from an implementation that never
    # created a staging file to begin with. Pre-creating the destination as a
    # directory lets the copy succeed -- a real .part.<unique> file lands on
    # disk -- and only the final File.rename/2 fails, the same way it would
    # if something else occupied that path. That is the case cleanup must
    # actually handle.
    source = Path.join(System.tmp_dir!(), "gg_source_#{System.unique_integer([:positive])}")
    File.write!(source, "hello")
    on_exit(fn -> File.rm_rf(source) end)

    key = "demo/src/v1/a.geojson"
    destination = FileSystem.path(key, opts)
    File.mkdir_p!(destination)

    assert {:error, _reason} = FileSystem.put(key, source, opts)

    assert Path.wildcard(Path.join([root, "**", "*.part.*"])) == [],
           "a failed rename must not leave its staging file behind in the cache root"
  end

  test "concurrent put calls for the same key never truncate each other's copy", %{opts: opts} do
    key = "demo/src/v1/a.geojson"
    content_a = String.duplicate("a", 200_000)
    content_b = String.duplicate("b", 200_000)

    source_a = Path.join(System.tmp_dir!(), "gg_source_a_#{System.unique_integer([:positive])}")
    source_b = Path.join(System.tmp_dir!(), "gg_source_b_#{System.unique_integer([:positive])}")
    File.write!(source_a, content_a)
    File.write!(source_b, content_b)
    on_exit(fn -> File.rm_rf(source_a) end)
    on_exit(fn -> File.rm_rf(source_b) end)

    [result_a, result_b] =
      [source_a, source_b]
      |> Enum.map(fn source -> Task.async(fn -> FileSystem.put(key, source, opts) end) end)
      |> Task.await_many()

    assert {:ok, _} = result_a
    assert {:ok, _} = result_b

    {:ok, stored} = FileSystem.fetch(key, opts)
    assert File.read!(stored) in [content_a, content_b]
  end

  test "delete removes a stored file", %{opts: opts} do
    source = Path.join(System.tmp_dir!(), "gg_source_#{System.unique_integer([:positive])}")
    File.write!(source, "hello")
    on_exit(fn -> File.rm_rf(source) end)

    {:ok, _} = FileSystem.put("demo/src/v1/a.geojson", source, opts)
    assert :ok = FileSystem.delete("demo/src/v1/a.geojson", opts)
    assert FileSystem.fetch("demo/src/v1/a.geojson", opts) == :miss
  end

  test "path is deterministic and lands under the configured root", %{root: root, opts: opts} do
    path = FileSystem.path("demo/src/v1/a.geojson", opts)

    assert path == FileSystem.path("demo/src/v1/a.geojson", opts)
    assert String.starts_with?(Path.expand(path), Path.expand(root))
  end

  test "a key that tries to escape the cache root is refused", %{opts: opts} do
    for escape <- ["../outside", "demo/../../outside", "/etc/passwd", "demo/./..", ""] do
      assert_raise ArgumentError, fn -> FileSystem.path(escape, opts) end
    end
  end

  test "path raises ArgumentError, not FunctionClauseError, for a non-string key", %{opts: opts} do
    assert_raise ArgumentError, fn -> FileSystem.path(nil, opts) end
    assert_raise ArgumentError, fn -> FileSystem.path(123, opts) end
  end

  test "the containment check rejects a sibling directory, not just a descendant" do
    # No key can reach this branch through path/2: Cache.key/1's segment regex
    # already excludes "/" and any leading ".", so a validated key can never
    # join with a root into a path that escapes it. within_root?/2 is the
    # same check path/2 applies to that joined path, tested directly against
    # strings a valid key could never produce -- a sibling directory that
    # happens to share the root as a literal string prefix. Dropping the
    # trailing "/" from either side of the comparison (a one-line regression)
    # would make this pass, which is exactly what this test exists to catch.
    refute FileSystem.within_root?("/tmp/geo_geniusX/evil", "/tmp/geo_genius")
    assert FileSystem.within_root?("/tmp/geo_genius/demo/a.geojson", "/tmp/geo_genius")
  end

  test "a stored file survives a second put of different content", %{opts: opts} do
    source = Path.join(System.tmp_dir!(), "gg_source_#{System.unique_integer([:positive])}")
    File.write!(source, "first")
    on_exit(fn -> File.rm_rf(source) end)

    {:ok, _} = FileSystem.put("demo/src/v1/a.geojson", source, opts)
    File.write!(source, "second")
    {:ok, stored} = FileSystem.put("demo/src/v1/a.geojson", source, opts)

    assert File.read!(stored) == "second",
           "put must replace: an artifact re-fetched after a corrected manifest must win"
  end
end
