defmodule GeoGenius.QueryError do
  @moduledoc """
  Raised when a catalog read cannot be completed.

  Carries the SQL function that was called, so a failure names the read that
  produced it rather than surfacing as a bare database error.
  """

  defexception [:message, :function, :reason]

  @type t :: %__MODULE__{message: String.t(), function: String.t(), reason: term()}

  @impl Exception
  @spec exception(keyword()) :: t()
  def exception(opts) do
    function = Keyword.fetch!(opts, :function)
    reason = Keyword.fetch!(opts, :reason)

    %__MODULE__{
      function: function,
      reason: reason,
      message: "GeoGenius read #{function} failed: #{inspect(reason)}"
    }
  end
end

defmodule GeoGenius.CatalogError do
  @moduledoc """
  Raised when a catalog write cannot be completed.

  Carries the SQL function that was called and the original driver error as
  `:reason`, so a caller can match a constraint violation the operator caused
  against a connection failure it cannot fix.
  """

  defexception [:message, :function, :reason]

  @type t :: %__MODULE__{message: String.t(), function: String.t(), reason: term()}

  @impl Exception
  @spec exception(keyword()) :: t()
  def exception(opts) do
    function = Keyword.fetch!(opts, :function)
    reason = Keyword.fetch!(opts, :reason)

    %__MODULE__{
      function: function,
      reason: reason,
      message: "GeoGenius catalog call #{function} failed: #{inspect(reason)}"
    }
  end
end

defmodule GeoGenius.ManifestError do
  @moduledoc """
  Raised when a manifest cannot be read, decoded, or validated.

  A manifest is a reviewed artifact, so every failure names the field that was
  wrong rather than reporting that the document as a whole was rejected.
  """

  defexception [:message, :path, :reason]

  @type t :: %__MODULE__{message: String.t(), path: String.t() | nil, reason: term()}

  @impl Exception
  @spec exception(keyword()) :: t()
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)
    path = Keyword.get(opts, :path)
    located = if path, do: " in #{path}", else: ""

    %__MODULE__{path: path, reason: reason, message: "GeoGenius manifest#{located}: #{reason}"}
  end
end

defmodule GeoGenius.ImportError do
  @moduledoc """
  Raised when an import run cannot continue.

  Carries the run and the phase it failed in. The run's own `error` column in
  PostgreSQL is the durable record; this exception is how the failure reaches a
  caller that is waiting synchronously.
  """

  defexception [:message, :run_id, :phase, :reason]

  @type t :: %__MODULE__{
          message: String.t(),
          run_id: Ecto.UUID.t() | nil,
          phase: String.t() | nil,
          reason: term()
        }

  @impl Exception
  @spec exception(keyword()) :: t()
  def exception(opts) do
    run_id = Keyword.get(opts, :run_id)
    phase = Keyword.get(opts, :phase)
    reason = Keyword.fetch!(opts, :reason)

    %__MODULE__{
      run_id: run_id,
      phase: phase,
      reason: reason,
      message: "GeoGenius import #{run_id} failed during #{phase}: #{inspect(reason)}"
    }
  end
end

defmodule GeoGenius.StagingError do
  @moduledoc """
  Raised when a staging table cannot be written to or read from.

  Carries the operation that was attempted (`"insert"`, `"stream"`, or
  `"count"`) and the original driver error as `:reason`, since staging issues
  raw SQL rather than calling a catalog function.
  """

  defexception [:message, :operation, :reason]

  @type t :: %__MODULE__{message: String.t(), operation: String.t(), reason: term()}

  @impl Exception
  @spec exception(keyword()) :: t()
  def exception(opts) do
    operation = Keyword.fetch!(opts, :operation)
    reason = Keyword.fetch!(opts, :reason)

    %__MODULE__{
      operation: operation,
      reason: reason,
      message: "GeoGenius staging #{operation} failed: #{inspect(reason)}"
    }
  end
end
