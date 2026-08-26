defmodule GeoGenius.MixHelpers do
  @moduledoc false

  alias GeoGenius.Config

  @setup_switches [repo: :string, prefix: :string, with_extensions: :boolean]
  @upgrade_switches [repo: :string, prefix: :string, from: :integer, to: :integer]

  @spec parse_setup_args([String.t()]) :: %{
          repo: module() | nil,
          prefix: String.t(),
          with_extensions: boolean()
        }
  @doc "Strictly parses setup-task Repo, prefix, and extension-flag arguments."
  def parse_setup_args(args) do
    opts = parse_strict!(args, @setup_switches)

    %{
      repo: repo_option(opts[:repo]),
      prefix: validate_prefix!(opts[:prefix] || "geo_genius"),
      with_extensions: opts[:with_extensions] || false
    }
  end

  @spec parse_upgrade_args([String.t()]) :: %{
          repo: module() | nil,
          prefix: String.t(),
          from: non_neg_integer(),
          to: pos_integer()
        }
  @doc "Strictly parses an adjacent-upgrade task invocation."
  def parse_upgrade_args(args) do
    opts = parse_strict!(args, @upgrade_switches)
    from = required_integer!(opts, :from)
    to = required_integer!(opts, :to)

    if from < 1 or to != from + 1 do
      Mix.raise("--from and --to must describe one adjacent upgrade with --from >= 1")
    end

    %{
      repo: repo_option(opts[:repo]),
      prefix: validate_prefix!(opts[:prefix] || "geo_genius"),
      from: from,
      to: to
    }
  end

  @spec validate_prefix!(String.t()) :: String.t()
  @doc "Validates a PostgreSQL prefix, raising a `Mix.raise/1` error for an invalid one."
  def validate_prefix!(prefix) do
    Config.validate_prefix!(prefix)
  rescue
    ArgumentError -> Mix.raise("invalid PostgreSQL prefix: #{inspect(prefix)}")
  end

  @spec start_repo(module()) :: {boolean(), pid()}
  @doc "Starts a Repo if it is not already running, returning whether this call started it."
  def start_repo(repo) do
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    case Process.whereis(repo) do
      nil ->
        {:ok, pid} = repo.start_link(pool_size: 1)
        {true, pid}

      pid ->
        {false, pid}
    end
  end

  @spec resolve_repo(module() | nil) :: module()
  @doc "Resolves an explicit Repo or the first Repo configured by the host project."
  def resolve_repo(repo) when is_atom(repo) and not is_nil(repo), do: repo

  def resolve_repo(nil) do
    app = Mix.Project.config()[:app]
    Application.load(app)

    case Application.get_env(app, :ecto_repos, []) do
      [repo | _] ->
        repo

      [] ->
        Mix.raise(
          "no Ecto Repo is configured for #{inspect(app)}; pass --repo or configure :ecto_repos"
        )
    end
  end

  @spec validate_transition!(non_neg_integer(), pos_integer(), pos_integer()) :: :ok
  @doc """
  Validates that a requested transition is available in the package catalog.

  A fresh install (`from` 0) runs every version in one migration, so it may
  target any available version. An upgrade of an existing install must be
  adjacent, one version at a time.
  """
  def validate_transition!(0, to, current) when to > current do
    Mix.raise("target version #{to} is unavailable; current version is #{current}")
  end

  def validate_transition!(0, _to, _current), do: :ok

  def validate_transition!(from, to, _current) when to != from + 1 do
    Mix.raise("versions must be adjacent; received #{from} to #{to}")
  end

  def validate_transition!(_from, to, current) when to > current do
    Mix.raise("target version #{to} is unavailable; current version is #{current}")
  end

  def validate_transition!(_from, _to, _current), do: :ok

  @spec migration_body(String.t(), non_neg_integer(), pos_integer(), pos_integer(), boolean()) ::
          String.t()
  @doc "Builds the exact pinned migration callback body shared by all generators."
  def migration_body(prefix, from, to, current_version, with_extensions) do
    validate_transition!(from, to, current_version)

    up_body =
      if with_extensions do
        """
        def up do
          execute("CREATE EXTENSION IF NOT EXISTS postgis")
          execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
          GeoGenius.Migration.up(prefix: #{inspect(prefix)}, version: #{to})
        end
        """
      else
        "def up, do: GeoGenius.Migration.up(prefix: #{inspect(prefix)}, version: #{to})\n"
      end

    up_body <>
      "\n" <>
      "def down, do: GeoGenius.Migration.down(prefix: #{inspect(prefix)}, version: #{from})\n"
  end

  @spec render_wrapper(String.t(), keyword()) :: String.t()
  @doc "Replaces an exact empty Ecto scaffold with a pinned GeoGenius migration wrapper."
  def render_wrapper(generated, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    from = Keyword.fetch!(opts, :from)
    to = Keyword.fetch!(opts, :to)
    with_extensions = Keyword.get(opts, :with_extensions, false)

    case Regex.run(
           ~r/\A(defmodule [^\n]+ do\n[ \t]+use [^\n]+\n)\s*def change do\s*end\s*end\s*\z/,
           generated,
           capture: :all_but_first
         ) do
      [header] ->
        header <>
          "\n" <>
          indent_migration_body(migration_body(prefix, from, to, to, with_extensions)) <>
          "end\n"

      _ ->
        Mix.raise("expected an exact empty Ecto migration scaffold")
    end
  end

  @spec without_ecto_editor((-> result)) :: result when result: term()
  @doc "Runs a callback with `ECTO_EDITOR` cleared, then restores its exact previous state."
  def without_ecto_editor(fun) when is_function(fun, 0) do
    previous = System.get_env("ECTO_EDITOR")
    System.delete_env("ECTO_EDITOR")

    try do
      fun.()
    after
      restore_env(previous)
    end
  end

  @spec generate_wrapper!(module(), String.t(), String.t(), non_neg_integer(), pos_integer()) ::
          String.t()
  @doc "Generates and safely rewrites exactly one host-owned Ecto migration file."
  def generate_wrapper!(repo, migration_name, prefix, from, to) do
    generate_wrapper!(repo, migration_name, prefix, from, to, [])
  end

  @doc false
  @spec generate_wrapper!(
          module(),
          String.t(),
          String.t(),
          non_neg_integer(),
          pos_integer(),
          keyword()
        ) :: String.t()
  def generate_wrapper!(repo, migration_name, prefix, from, to, opts) do
    Mix.Ecto.ensure_repo(repo, ["--repo", inspect(repo)])

    migrations_path =
      Keyword.get_lazy(opts, :migrations_path, fn ->
        Path.join(Mix.EctoSQL.source_repo_priv(repo), "migrations")
      end)

    generator = Keyword.get(opts, :generator, &Mix.Task.run/2)
    with_extensions = Keyword.get(opts, :with_extensions, false)
    before = migration_files(migrations_path)

    without_ecto_editor(fn ->
      Mix.Task.reenable("ecto.gen.migration")

      generator.("ecto.gen.migration", [
        migration_name,
        "--repo",
        inspect(repo),
        "--migrations-path",
        migrations_path
      ])
    end)

    after_files = migration_files(migrations_path)

    case after_files -- before do
      [path] ->
        rewrite_new_wrapper!(path, prefix, from, to, with_extensions)

      paths ->
        Mix.raise(
          "expected ecto.gen.migration to create exactly one file, got: #{inspect(paths)}"
        )
    end
  after
    Mix.Task.reenable("ecto.gen.migration")
  end

  @spec parse_strict!([String.t()], keyword()) :: keyword()
  @doc """
  Strictly parses one task invocation, raising for anything the task did not declare.

  An unknown option and an unexpected positional argument are both operator
  mistakes on a task that changes what every host of a catalog sees, so
  neither is accepted silently.
  """
  def parse_strict!(args, switches) do
    case OptionParser.parse(args, strict: switches) do
      {opts, [], []} -> opts
      {_opts, [positional | _], []} -> Mix.raise("unexpected positional argument: #{positional}")
      {_opts, _positional, [{option, _value} | _]} -> Mix.raise("unknown option: #{option}")
    end
  end

  @spec repo_option(String.t() | nil) :: module() | nil
  @doc "Resolves a `--repo` string into a module, leaving an absent one as nil."
  def repo_option(nil), do: nil
  def repo_option(name), do: Module.concat([name])

  @spec required!(keyword(), atom()) :: String.t()
  @doc "Reads a required string option, raising a message naming the option when it is absent."
  def required!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) -> value
      _missing -> Mix.raise("--#{dashed(key)} is required")
    end
  end

  @spec release_label(String.t() | nil) :: String.t()
  @doc """
  Renders a release id for operator output, naming an absent publication.

  A bare id renders unquoted -- `inspect/1` would wrap it in quotes and print a
  collection that has published nothing as `nil`, neither of which is what an
  operator reading a terminal is looking at.
  """
  def release_label(nil), do: "none"
  def release_label(release_id) when is_binary(release_id), do: release_id

  @spec reason_message(term()) :: String.t()
  @doc """
  Renders a failure reason as one line for `Mix.raise/1`.

  The ingestion API returns exceptions for a manifest or catalog failure, a
  plain string for a collection the catalog does not carry, and whatever a
  runner backend chose for an enqueue failure, so all three shapes reach a
  task's error path.
  """
  def reason_message(reason) when is_exception(reason), do: Exception.message(reason)
  def reason_message(reason) when is_binary(reason), do: reason
  def reason_message(reason), do: inspect(reason)

  defp dashed(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  defp required_integer!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) -> value
      _ -> Mix.raise("--#{key} is required and must be an integer")
    end
  end

  defp restore_env(nil), do: System.delete_env("ECTO_EDITOR")
  defp restore_env(value), do: System.put_env("ECTO_EDITOR", value)

  defp migration_files(path), do: Path.wildcard(Path.join(path, "*.exs"))

  defp indent_migration_body(body) do
    body
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> "  " <> line
    end)
  end

  defp rewrite_new_wrapper!(path, prefix, from, to, with_extensions) do
    path
    |> File.read!()
    |> render_wrapper(prefix: prefix, from: from, to: to, with_extensions: with_extensions)
    |> then(&File.write!(path, &1))

    path
  rescue
    exception ->
      File.rm(path)
      reraise(exception, __STACKTRACE__)
  catch
    kind, reason ->
      File.rm(path)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end
end
