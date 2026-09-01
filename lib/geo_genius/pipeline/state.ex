defmodule GeoGenius.Pipeline.State do
  @moduledoc """
  One run's working set, threaded through every phase.

  Everything durable about a run lives in PostgreSQL; this carries only what
  one phase hands the next: the rebuilt manifest and the providers it resolves
  to, the local path and attributed source release of each artifact the
  download phase obtained, and the metrics the last phase measured, which the
  next phase boundary writes onto the run.

  A release names a provider per source, so there is no single provider for a
  run. `artifact_providers` maps a logical name to the module that stages it,
  which is how staging dispatches on an artifact and how normalizing and
  relating dispatch on `row.artifact`. `providers` is the same set without the
  keys, in declaration order, for the release-level question `relations/1`
  asks.
  """

  alias GeoGenius.Context
  alias GeoGenius.ImportRun
  alias GeoGenius.Manifest

  @enforce_keys [
    :context,
    :run,
    :executor_id,
    :opts,
    :work_dir,
    :publish?,
    :batch_size,
    :timeout
  ]
  defstruct [
    :context,
    :run,
    :executor_id,
    :opts,
    :work_dir,
    :publish?,
    :batch_size,
    :timeout,
    :manifest,
    providers: [],
    artifact_providers: %{},
    manifest_artifacts: %{},
    resolved: %{},
    sources: %{},
    metrics: %{}
  ]

  @typedoc "What a phase measured, as the jsonb `stage_metrics` merge patch it becomes."
  @type metrics :: %{optional(String.t()) => non_neg_integer()}

  @typedoc "What every phase function returns, whichever module it lives in."
  @type result :: {:ok, t()} | {:error, String.t()}

  @type t :: %__MODULE__{
          context: Context.t(),
          run: ImportRun.t(),
          executor_id: Ecto.UUID.t(),
          opts: keyword(),
          work_dir: Path.t(),
          publish?: boolean(),
          batch_size: pos_integer(),
          timeout: timeout(),
          manifest: Manifest.t() | nil,
          providers: [module()],
          artifact_providers: %{optional(String.t()) => module()},
          manifest_artifacts: %{optional(String.t()) => Manifest.Artifact.t()},
          resolved: %{optional(String.t()) => Path.t()},
          sources: %{optional(String.t()) => Ecto.UUID.t()},
          metrics: metrics()
        }

  @doc """
  Turns a phase's own accumulator into the phase contract.

  An error passes through untouched; anything else is handed to `fun`, which
  returns the state the next phase receives. Every phase reduces over
  something -- artifacts, staged artifacts, batches of rows -- and each one
  needs the same two-line tail, which is here once rather than in all three
  phase modules.
  """
  @spec with_metrics(term(), (term() -> t())) :: result()
  def with_metrics({:error, _reason} = error, _fun), do: error
  def with_metrics(accumulator, fun), do: {:ok, fun.(accumulator)}
end
