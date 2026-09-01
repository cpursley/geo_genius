defmodule GeoGenius.CandidateError do
  @moduledoc """
  A structured refusal from the exact import-candidate lifecycle.

  Candidate refusals are expected operator outcomes, not database failures.
  The reason is a closed atom vocabulary and the identifiers point at the
  candidate and attempt that prevented the requested import.
  """

  @type reason ::
          :candidate_mismatch
          | :completed
          | :failed
          | :invalid_catalog_response
          | :live_import
          | :manifest_changed
          | :not_failed
          | :not_found
          | :not_latest_attempt
          | :orphan_candidate
          | :protected
          | :source_definition_changed
          | :stale_import

  defexception [:message, :reason, :release_id, :run_id]

  @type t :: %__MODULE__{
          message: String.t(),
          reason: reason(),
          release_id: Ecto.UUID.t() | nil,
          run_id: Ecto.UUID.t() | nil
        }

  @impl Exception
  @spec exception(keyword()) :: t()
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)
    release_id = Keyword.get(opts, :release_id)
    run_id = Keyword.get(opts, :run_id)

    %__MODULE__{
      reason: reason,
      release_id: release_id,
      run_id: run_id,
      message: Keyword.get(opts, :message, message(reason, release_id, run_id))
    }
  end

  defp message(:protected, release_id, _run_id) do
    "GeoGenius candidate release #{inspect(release_id)} is published or retired and cannot " <>
      "be replaced; import under a new release key"
  end

  defp message(:live_import, release_id, run_id) do
    "GeoGenius candidate release #{inspect(release_id)} has live import #{inspect(run_id)} " <>
      "owned by another importer"
  end

  defp message(:stale_import, release_id, run_id) do
    "GeoGenius candidate release #{inspect(release_id)} has stale import #{inspect(run_id)}; " <>
      "fail that attempt explicitly before retrying"
  end

  defp message(:failed, release_id, run_id) do
    "GeoGenius candidate release #{inspect(release_id)} has failed import #{inspect(run_id)}; " <>
      "retry it explicitly with GeoGenius.retry_failed/2"
  end

  defp message(:manifest_changed, release_id, run_id) do
    "GeoGenius candidate release #{inspect(release_id)} differs from failed import " <>
      "#{inspect(run_id)}; retry it explicitly with GeoGenius.retry_failed/2"
  end

  defp message(:source_definition_changed, release_id, run_id) do
    "GeoGenius candidate release #{inspect(release_id)} changes an immutable source identity " <>
      "while considering import #{inspect(run_id)}"
  end

  defp message(:candidate_mismatch, release_id, run_id) do
    "GeoGenius retry target #{inspect(run_id)} does not belong to candidate release " <>
      "#{inspect(release_id)}"
  end

  defp message(:not_latest_attempt, release_id, run_id) do
    "GeoGenius retry target #{inspect(run_id)} is not the latest attempt for release " <>
      "#{inspect(release_id)}"
  end

  defp message(:not_failed, release_id, run_id) do
    "GeoGenius retry target #{inspect(run_id)} for release #{inspect(release_id)} is not failed"
  end

  defp message(:not_found, _release_id, run_id) do
    "GeoGenius retry target #{inspect(run_id)} does not exist"
  end

  defp message(:completed, release_id, run_id) do
    "GeoGenius candidate release #{inspect(release_id)} already completed as import " <>
      inspect(run_id)
  end

  defp message(:orphan_candidate, release_id, _run_id) do
    "GeoGenius candidate release #{inspect(release_id)} exists without import history and " <>
      "cannot be reopened automatically"
  end

  defp message(:invalid_catalog_response, release_id, run_id) do
    "GeoGenius catalog returned an invalid candidate lifecycle response for release " <>
      "#{inspect(release_id)} and import #{inspect(run_id)}"
  end
end
