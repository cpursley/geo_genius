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
