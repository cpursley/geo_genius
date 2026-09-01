defmodule GeoGenius.Registration do
  @moduledoc """
  Translates the catalog's exact-candidate lifecycle decision into the public
  Elixir result vocabulary.

  Registration and run claiming are one database statement. The statement
  has committed before this module returns, so callers may enqueue only an
  `:enqueue` result without exposing partially registered catalog state.
  """

  alias GeoGenius.{CandidateError, Catalog, Context, Manifest}

  @decisions %{
    "enqueue" => :enqueue,
    "existing" => :existing,
    "error" => :error
  }

  @reasons %{
    "candidate_mismatch" => :candidate_mismatch,
    "completed" => :completed,
    "failed" => :failed,
    "live_import" => :live_import,
    "manifest_changed" => :manifest_changed,
    "not_failed" => :not_failed,
    "not_found" => :not_found,
    "not_latest_attempt" => :not_latest_attempt,
    "orphan_candidate" => :orphan_candidate,
    "protected" => :protected,
    "registered" => :registered,
    "retried" => :retried,
    "same_owner" => :same_owner,
    "source_definition_changed" => :source_definition_changed,
    "stale_import" => :stale_import
  }

  @type accepted_reason :: :registered | :retried | :same_owner | :completed

  @type accepted :: %{
          run_id: Ecto.UUID.t(),
          release_id: Ecto.UUID.t(),
          attempt: pos_integer(),
          reason: accepted_reason()
        }

  @type result :: {:enqueue, accepted()} | {:existing, accepted()} | {:error, CandidateError.t()}

  @doc "Atomically registers one exact manifest or diagnoses its existing import attempt."
  @spec prepare_import(Context.t(), Manifest.t(), map()) :: result()
  def prepare_import(%Context{} = context, %Manifest{} = manifest, claim) do
    context
    |> Catalog.prepare_import(Manifest.to_map(manifest), claim)
    |> translate()
  end

  @doc "Atomically replaces one failed latest attempt with an exact corrected manifest."
  @spec retry_failed(Context.t(), Ecto.UUID.t(), Manifest.t(), map()) :: result()
  def retry_failed(%Context{} = context, failed_run_id, %Manifest{} = manifest, claim) do
    context
    |> Catalog.retry_failed(failed_run_id, Manifest.to_map(manifest), claim)
    |> translate()
  end

  @doc false
  @spec translate(term()) :: result()
  def translate(
        %{
          decision: catalog_decision,
          reason: catalog_reason,
          run_id: run_id,
          release_id: release_id,
          attempt: attempt
        } = result
      ) do
    decision = Map.get(@decisions, catalog_decision)
    reason = Map.get(@reasons, catalog_reason)

    accepted = %{
      run_id: run_id,
      release_id: release_id,
      attempt: attempt,
      reason: reason
    }

    case {decision, reason} do
      {:enqueue, reason} when reason in [:registered, :retried, :same_owner] ->
        {:enqueue, accepted}

      {:existing, :completed} ->
        {:existing, accepted}

      {:error, reason} when not is_nil(reason) ->
        {:error,
         CandidateError.exception(
           reason: reason,
           release_id: release_id,
           run_id: run_id
         )}

      _other ->
        invalid_response(result)
    end
  end

  def translate(result), do: invalid_response(result)

  defp invalid_response(result) do
    {:error,
     CandidateError.exception(
       reason: :invalid_catalog_response,
       release_id: response_value(result, :release_id),
       run_id: response_value(result, :run_id),
       message:
         "GeoGenius catalog returned an invalid candidate lifecycle response: #{inspect(result)}"
     )}
  end

  defp response_value(result, key) when is_map(result), do: Map.get(result, key)
  defp response_value(_result, _key), do: nil
end
