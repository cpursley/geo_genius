defmodule GeoGenius.SandboxPoolRepo do
  @moduledoc false

  # Stands in for a host Repo configured with `Ecto.Adapters.SQL.Sandbox`,
  # which is how every Ecto host pools its Repo under test. Nothing here talks
  # to a database: `query!/3` raises, so a caller that reaches the database
  # against a sandboxed Repo fails loudly instead of passing on a Repo that
  # happens to be checked out.

  @doc false
  def config, do: [pool: Ecto.Adapters.SQL.Sandbox]

  @doc false
  def query!(sql, _params \\ [], _opts \\ []) do
    raise "GeoGenius.SandboxPoolRepo was queried with: #{sql}"
  end
end
