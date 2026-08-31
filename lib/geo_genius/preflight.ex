defmodule GeoGenius.PreflightError do
  @moduledoc """
  Raised when the database does not satisfy GeoGenius's prerequisites at startup.
  """

  defexception [:reasons]

  @impl Exception
  def message(%__MODULE__{reasons: reasons}) do
    "GeoGenius preflight failed:\n" <> Enum.map_join(reasons, "\n", &("  - " <> &1))
  end
end

defmodule GeoGenius.Preflight do
  @moduledoc """
  Verifies GeoGenius's database prerequisites and fails host startup when they
  are not met.

  Place this child in the host's supervision tree immediately after its Repo:

      children = [
        MyApp.Repo,
        {GeoGenius.Preflight, repo: MyApp.Repo, prefix: "geo_genius"},
        MyAppWeb.Endpoint
      ]

  The check runs once during `start_link/1` and returns `:ignore`, so no process
  remains in the tree. A failure raises `GeoGenius.PreflightError`, which aborts
  startup rather than deferring the error to the first query.

  A Repo pooled through `Ecto.Adapters.SQL.Sandbox` skips the check, because
  the supervisor starts this child from a process that owns no sandbox
  connection: the check would raise `DBConnection.OwnershipError` and take the
  host's whole test suite down with it. `guides/installation.md` covers what a
  host runs instead under the sandbox.
  """

  @default_extensions ["postgis", "pg_trgm"]

  @doc "Builds the child spec for placing this preflight check in a supervision tree."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient
    }
  end

  @doc """
  Runs the preflight check and returns `:ignore` on success.

  Raises `GeoGenius.PreflightError` on failure, aborting host startup.

  `:enabled?` decides whether the check runs. It defaults to false for a Repo
  configured with `Ecto.Adapters.SQL.Sandbox` and true for every other Repo.
  Pass it explicitly to override that: `enabled?: true` verifies a sandboxed
  Repo from a process that has checked a connection out, `enabled?: false`
  skips the check wherever the host prefers to run it by hand.
  """
  @spec start_link(keyword()) :: :ignore
  def start_link(opts) do
    repo = Keyword.fetch!(opts, :repo)

    if Keyword.get_lazy(opts, :enabled?, fn -> not sandboxed?(repo) end) do
      GeoGenius.verify!(repo, opts)
    end

    :ignore
  end

  # A Repo pooled through the SQL sandbox is a Repo under test. In the
  # sandbox's :manual mode the supervisor's own process owns no connection, so
  # the verification query raises DBConnection.OwnershipError, start_link
  # raises, Application.start fails, and every test in the host's suite errors
  # before its first setup block runs.
  defp sandboxed?(repo), do: repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox

  @doc false
  @spec run(module(), keyword()) :: :ok | {:error, [String.t()]}
  def run(repo, opts) do
    prefix = GeoGenius.Config.prefix(opts)
    required = Keyword.get(opts, :required_extensions, @default_extensions)

    reasons =
      extension_reasons(repo, required, prefix) ++
        geometry_reasons(repo) ++
        jsonb_reasons(repo) ++
        schema_reasons(repo, prefix)

    if reasons == [], do: :ok, else: {:error, reasons}
  end

  defp extension_reasons(repo, required, prefix) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT ext.extname, ns.nspname
          FROM pg_extension ext
          JOIN pg_namespace ns ON ns.oid = ext.extnamespace
         WHERE ext.extname = ANY($1)
        """,
        [required],
        log: false
      )

    installed = Map.new(rows, fn [name, schema] -> {name, schema} end)

    Enum.flat_map(required, fn name ->
      case Map.fetch(installed, name) do
        :error ->
          [
            "required PostgreSQL extension #{name} is not installed; " <>
              "run CREATE EXTENSION IF NOT EXISTS #{name} as a privileged role"
          ]

        {:ok, schema} when schema in ["pg_catalog", "public"] ->
          []

        {:ok, ^prefix} ->
          []

        {:ok, schema} ->
          # Every GeoGenius function pins search_path to pg_catalog, public,
          # and the install prefix, so an extension anywhere else is present
          # but unusable: unqualified ST_*, similarity, and % never resolve.
          [
            "required PostgreSQL extension #{name} is installed in schema #{schema}, which is " <>
              "not on the search path GeoGenius functions use (pg_catalog, public, #{prefix}); " <>
              "run ALTER EXTENSION #{name} SET SCHEMA public as a privileged role"
          ]
      end
    end)
  end

  # The remedy is a command a reader is meant to paste, so the Repo appears as
  # the module name they would type, not as an inspected term.
  defp repo_name(repo) do
    case Atom.to_string(repo) do
      "Elixir." <> name -> name
      other -> other
    end
  end

  # Postgrex raises when a types module cannot handle `geography`, so the probe
  # is the query itself rather than an inspection of what came back. A host
  # that skips this configuration would otherwise discover it on its first
  # read, with a disconnect rather than an explanation.
  defp geometry_reasons(repo) do
    repo.query!("SELECT ST_SetSRID(ST_MakePoint(0, 0), 4326)::geography", [], log: false)
    []
  rescue
    _exception ->
      [
        "the Repo #{repo_name(repo)} cannot decode PostGIS geometry; " <>
          "configure it with a Postgrex types module that registers " <>
          "Geo.PostGIS.Extension, either GeoGenius.PostgresTypes or one of your own"
      ]
  end

  # `codes` and `attributes` are jsonb and appear in every read's projection,
  # so a Repo whose Postgrex types module has no usable JSON library survives
  # the geometry probe -- geography and jsonb are decoded by different
  # extensions -- and then disconnects on the first real read. Probing a jsonb
  # decode moves that failure to boot, where the geometry one already is.
  defp jsonb_reasons(repo) do
    repo.query!("SELECT '{}'::jsonb", [], log: false)
    []
  rescue
    _exception ->
      [
        "the Repo #{repo_name(repo)} cannot decode jsonb, which every read projects as " <>
          "codes and attributes; its Postgrex types module names a JSON library that is " <>
          "not available. Drop that module's json: option so Postgrex resolves the library " <>
          "itself, or point config :postgrex, :json_library at one that loads -- left unset " <>
          "it resolves to Jason, which GeoGenius depends on and is always present"
      ]
  end

  defp schema_reasons(repo, prefix) do
    expected = GeoGenius.Migration.current_version()

    case GeoGenius.Migration.installed_version(repo, prefix) do
      0 ->
        [
          "GeoGenius is not installed in schema #{prefix}; " <>
            "run mix geo_genius.setup --repo #{repo_name(repo)} --prefix #{prefix} " <>
            "followed by mix ecto.migrate"
        ]

      ^expected ->
        case GeoGenius.Migration.contract_status(repo, prefix) do
          %{compatible?: true} ->
            []

          %{status: status, installed_revision: revision, remedy: remedy} ->
            [
              "GeoGenius schema contract mismatch in #{prefix}: status #{status}, " <>
                "installed revision #{inspect(revision)}; #{remedy}"
            ]
        end

      installed ->
        [
          "GeoGenius schema version mismatch in #{prefix}: database has #{installed}, " <>
            "loaded code expects #{expected}; " <>
            "run mix geo_genius.gen.migration --from #{installed} --to #{expected} and migrate"
        ]
    end
  end
end
