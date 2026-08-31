defmodule GeoGenius.Reconciliation do
  @moduledoc false

  import Ecto.Migration, only: [execute: 1]

  @doc false
  @spec run(keyword()) :: :ok
  def run(opts) do
    repo = migration_repo!()

    unless function_exported?(repo, :in_transaction?, 0) and repo.in_transaction?() do
      raise ArgumentError, transaction_error()
    end

    opts
    |> GeoGenius.ReconciliationSQL.statements!()
    |> Enum.each(&execute/1)

    :ok
  end

  defp migration_repo! do
    case current_migration_repo() do
      {:ok, repo} -> repo
      :error -> raise ArgumentError, transaction_error()
    end
  end

  defp current_migration_repo do
    {:ok, Ecto.Migration.repo()}
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  defp transaction_error do
    "GeoGenius reconciliation requires an active transactional Ecto migration; " <>
      "do not set @disable_ddl_transaction true"
  end
end
