defmodule GeoGenius.WrapperGenerationTest do
  # Mix.Task state is global, so these do not run alongside other tests.
  use ExUnit.Case, async: false

  alias GeoGenius.MixHelpers

  # Byte-for-byte what `mix ecto.gen.migration` writes. `render_wrapper`
  # accepts only this exact scaffold, so a drift in Ecto's generator has to
  # fail loudly here rather than silently produce a wrapper with no callbacks.
  @scaffold """
  defmodule GeoGenius.TestRepo.Migrations.SetupGeoGenius do
    use Ecto.Migration

    def change do
    end
  end
  """

  setup do
    path = Path.join(System.tmp_dir!(), "gg_wrapper_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    {:ok, migrations_path: path}
  end

  defp generator(migrations_path, contents) do
    fn _task, _args ->
      migrations_path
      |> Path.join("20260825120000_setup_geo_genius.exs")
      |> File.write!(contents)
    end
  end

  defp generate(migrations_path, contents, opts) do
    MixHelpers.generate_wrapper!(
      GeoGenius.TestRepo,
      "setup_geo_genius",
      Keyword.fetch!(opts, :prefix),
      Keyword.fetch!(opts, :from),
      Keyword.fetch!(opts, :to),
      [migrations_path: migrations_path, generator: generator(migrations_path, contents)] ++
        Keyword.take(opts, [:with_extensions])
    )
  end

  test "rewrites the generated scaffold into a pinned wrapper", %{migrations_path: path} do
    written = generate(path, @scaffold, prefix: "custom_geo", from: 0, to: 1)

    body = File.read!(written)

    assert body =~ ~s|def up, do: GeoGenius.Migration.up(prefix: "custom_geo", version: 1)|
    assert body =~ ~s|def down, do: GeoGenius.Migration.down(prefix: "custom_geo", version: 0)|
    refute body =~ "def change"
    refute body =~ "CREATE EXTENSION"
  end

  test "emits extension statements when asked", %{migrations_path: path} do
    body =
      path
      |> generate(@scaffold, prefix: "geo_genius", from: 0, to: 1, with_extensions: true)
      |> File.read!()

    assert body =~ ~s|execute("CREATE EXTENSION IF NOT EXISTS postgis")|
    assert body =~ ~s|execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")|
  end

  # A half-written wrapper in the host's migrations directory is worse than
  # none: `mix ecto.migrate` would pick it up. The generator removes the file
  # it created when the rewrite fails.
  test "removes the generated file when the scaffold is not recognized", %{
    migrations_path: path
  } do
    unexpected = """
    defmodule GeoGenius.TestRepo.Migrations.SetupGeoGenius do
      use Ecto.Migration

      def up do
        execute("SELECT 1")
      end
    end
    """

    exception =
      assert_raise Mix.Error, fn ->
        generate(path, unexpected, prefix: "geo_genius", from: 0, to: 1)
      end

    assert exception.message == "expected an exact empty Ecto migration scaffold"

    assert Path.wildcard(Path.join(path, "*.exs")) == [],
           "a failed rewrite left a migration behind in the host's migrations directory"
  end

  test "refuses when the generator creates more than one migration", %{migrations_path: path} do
    multi = fn _task, _args ->
      for name <- ~w(20260825120000_setup_geo_genius.exs 20260825120001_other.exs) do
        path |> Path.join(name) |> File.write!(@scaffold)
      end
    end

    exception =
      assert_raise Mix.Error, fn ->
        MixHelpers.generate_wrapper!(GeoGenius.TestRepo, "setup_geo_genius", "geo_genius", 0, 1,
          migrations_path: path,
          generator: multi
        )
      end

    # The payload is the list of files it found: without it the operator is
    # told the generator misbehaved and not which files to remove.
    assert exception.message =~ "expected ecto.gen.migration to create exactly one file, got:"
    assert exception.message =~ "20260825120000_setup_geo_genius.exs"
    assert exception.message =~ "20260825120001_other.exs"
  end
end
