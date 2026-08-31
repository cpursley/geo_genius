defmodule GeoGenius.Migration do
  @moduledoc """
  Versioned GeoGenius schema migrations for host applications.

  Host migrations pin both the target version and the PostgreSQL prefix.
  """

  use EctoEvolver,
    otp_app: :geo_genius,
    default_prefix: "geo_genius",
    tracking_object: {:view, "geo_genius_version"},
    versions: [GeoGenius.Migrations.V01]

  @doc "Renders a deterministic SQL transition for hosts that do not run Ecto migrations."
  @spec render_sql(keyword()) :: String.t()
  def render_sql(opts) do
    GeoGenius.MigrationSQL.render!(
      opts
      |> Keyword.put_new(:to, current_version())
    )
  end

  @doc "Returns the content-addressed identity of the schema contract shipped by this package."
  @spec current_contract_revision() :: String.t()
  def current_contract_revision, do: GeoGenius.SchemaContract.revision()

  @doc "Returns the explicit capabilities required by the current schema contract."
  @spec required_capabilities() :: [String.t()]
  def required_capabilities, do: GeoGenius.SchemaContract.capabilities()

  @doc "Inspects an installed schema's version, contract marker, signatures, and capabilities."
  @spec contract_status(module(), String.t()) :: map()
  def contract_status(repo, prefix), do: GeoGenius.SchemaContract.status(repo, prefix)

  @doc "Renders one explicit, pinned v01 contract reconciliation edge as deterministic SQL."
  @spec render_reconciliation_sql(keyword()) :: String.t()
  def render_reconciliation_sql(opts), do: GeoGenius.ReconciliationSQL.render!(opts)

  @doc """
  Executes one explicit, pinned reconciliation edge inside a host-owned transactional Ecto
  migration.

  Reconciliation refuses calls outside an active Ecto migration transaction, including migrations
  that set `@disable_ddl_transaction true`, because every verification, DDL statement, and the
  prefix-scoped advisory transaction lock must share one database transaction.
  """
  @spec reconcile(keyword()) :: :ok
  def reconcile(opts), do: GeoGenius.Reconciliation.run(opts)

  @doc """
  Returns the installed GeoGenius schema version for `prefix`, read directly
  through `repo`.

  Unlike `migrated_version/1` (usable only from inside an active
  `Ecto.Migration` run, since it resolves its repo from the migration
  process), this takes an explicit repo and works from ordinary application
  or mix task code.

  Returns `0` if GeoGenius has not been installed at `prefix`.
  """
  @spec installed_version(module(), String.t()) :: non_neg_integer()
  def installed_version(repo, prefix) do
    case repo.query!(
           """
           SELECT obj_description(c.oid)
           FROM pg_class c
           JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = $1 AND c.relname = 'geo_genius_version' AND c.relkind = 'v'
           """,
           [prefix],
           log: false
         ).rows do
      [[comment]] when is_binary(comment) ->
        case Regex.run(~r/version=(\d+)/, comment, capture: :all_but_first) do
          [version] -> String.to_integer(version)
          _ -> 0
        end

      _ ->
        0
    end
  end
end
