defmodule GeoGenius.EnqueueError do
  @moduledoc """
  A structured failure to confirm an import runner enqueue.

  `:certainty` distinguishes a definite pre-acceptance rejection from a call
  whose durable acceptance cannot be proved either way. `:acceptance` gives
  the same distinction in operational terms, while `:guidance` tells the
  caller how to inspect or safely redeliver the exact attempt.
  """

  @type certainty :: :not_enqueued | :outcome_unknown
  @type acceptance :: :rejected | :unknown
  @type terminalization :: :recorded_failed | :not_applicable | {:not_recorded, term()}

  defexception [
    :message,
    :run_id,
    :runner_backend,
    :certainty,
    :acceptance,
    :reason,
    :terminalization,
    :guidance
  ]

  @type t :: %__MODULE__{
          message: String.t(),
          run_id: Ecto.UUID.t(),
          runner_backend: String.t(),
          certainty: certainty(),
          acceptance: acceptance(),
          reason: term(),
          terminalization: terminalization(),
          guidance: String.t()
        }

  @impl Exception
  @spec exception(keyword()) :: t()
  def exception(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    runner_backend = Keyword.fetch!(opts, :runner_backend)
    certainty = Keyword.fetch!(opts, :certainty)
    lifecycle = Keyword.fetch!(opts, :lifecycle)
    reason = Keyword.fetch!(opts, :reason)
    terminalization = Keyword.get(opts, :terminalization, :not_applicable)
    acceptance = acceptance(certainty)
    guidance = guidance(certainty, lifecycle, terminalization)

    %__MODULE__{
      run_id: run_id,
      runner_backend: runner_backend,
      certainty: certainty,
      acceptance: acceptance,
      reason: reason,
      terminalization: terminalization,
      guidance: guidance,
      message:
        "GeoGenius runner #{inspect(runner_backend)} could not confirm enqueue for import " <>
          "#{run_id} (#{certainty}): #{inspect(reason)}. #{guidance}"
    }
  end

  defp acceptance(:not_enqueued), do: :rejected
  defp acceptance(:outcome_unknown), do: :unknown

  defp guidance(:not_enqueued, lifecycle, :recorded_failed)
       when lifecycle in [:registered, :retried] do
    "The runner definitely rejected the enqueue. GeoGenius marked this attempt failed; " <>
      "status/2 will confirm it. Fix the runner, then call retry_failed/2 with this run_id."
  end

  defp guidance(:not_enqueued, lifecycle, {:not_recorded, _reason})
       when lifecycle in [:registered, :retried] do
    "The runner definitely rejected the enqueue, but GeoGenius could not record the attempt " <>
      "as failed. Check status/2 and resolve the catalog error before choosing a recovery path."
  end

  defp guidance(:not_enqueued, :same_owner, _terminalization) do
    "The runner definitely rejected this delivery. The existing attempt remains pending; " <>
      "check status/2, then repeat import/1 with the same manifest and same :owner."
  end

  defp guidance(:outcome_unknown, _lifecycle, _terminalization) do
    "The runner may have accepted the enqueue, so the attempt remains pending. Check status/2; " <>
      "if an executor_id is present and no worker is alive, fail that executor then retry_failed/2. " <>
      "Otherwise, if redelivery is needed, call import/1 with the same manifest and same :owner."
  end

  defp guidance(_certainty, _lifecycle, _terminalization) do
    "Check status/2 for this run_id. Do not retry unless the attempt is failed; " <>
      "then call retry_failed/2 with this run_id."
  end
end
