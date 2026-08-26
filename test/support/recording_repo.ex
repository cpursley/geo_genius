defmodule GeoGenius.RecordingRepo do
  @moduledoc false

  # Delegates every query to the real test repo and reports the options it was
  # called with. Under an inline runner the pipeline runs in the calling
  # process, so a test reads the record straight out of its own mailbox; a
  # runner that executes in a process of its own (Runners.Task) sends the
  # record there too, once the test has named itself with `record_to/1` --
  # the executing process's mailbox dies with it. `fail_on/1` makes one
  # named statement fail there the way a dead connection would.

  @fail_key :recording_repo_fail_on
  @fail_skip_key :recording_repo_fail_skip
  @recipient_key :recording_repo_recipient

  @doc """
  Reports the real test repo's adapter, so `Mix.Ecto.ensure_repo/2` accepts
  this module as a Repo.

  A mix task resolves its `--repo` through `ensure_repo/2` and starts it
  through `GeoGenius.MixHelpers.start_repo/1` before it calls anything, so a
  recording seam that only implements `query/3` cannot be reached from a task
  at all -- and the forwarding a task promises would go unasserted.
  """
  @spec __adapter__() :: module()
  def __adapter__, do: GeoGenius.TestRepo.__adapter__()

  @doc """
  Starts a placeholder process so `start_repo/1` has something to stop.

  Every query delegates to `GeoGenius.TestRepo`, which the test suite already
  has running, so this owns no connection pool of its own.
  """
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(_opts), do: Agent.start_link(fn -> :recording end)

  @spec query(String.t(), list(), keyword()) ::
          {:ok, Postgrex.Result.t()} | {:error, Exception.t()}
  def query(sql, params, opts \\ []) do
    send(recipient(), {:query, sql, params, opts})
    refuse_if_named(sql)
    GeoGenius.TestRepo.query(sql, params, opts)
  end

  @doc """
  Routes every recorded query to `pid` instead of the executing process,
  until `stop_recording_to/0`.

  Register the test's own pid before handing this repo to a runner that
  executes the pipeline in a separate process, then drain with `recorded/0`
  after the run reaches a terminal status -- each record is sent before its
  statement executes, so a status a later statement wrote cannot be visible
  before the earlier records have arrived.
  """
  @spec record_to(pid()) :: :ok
  def record_to(pid) when is_pid(pid) do
    Application.put_env(:geo_genius, @recipient_key, pid)
  end

  @doc "Restores the default: records go to the executing process."
  @spec stop_recording_to() :: :ok
  def stop_recording_to do
    Application.delete_env(:geo_genius, @recipient_key)
  end

  defp recipient do
    Application.get_env(:geo_genius, @recipient_key) || self()
  end

  @doc """
  Makes every later query whose SQL contains `fragment` fail as a dead
  connection would.

  `:after` lets the first N matching queries through before the failures
  start, which is how a test fails one call in a loop whose statements are
  identical and whose only difference is a bound parameter: a sweep dropping
  its second staging table runs exactly the SQL its first one did.
  """
  @spec fail_on(String.t(), keyword()) :: :ok
  def fail_on(fragment, opts \\ []) do
    Process.put(@fail_key, fragment)
    Process.put(@fail_skip_key, Keyword.get(opts, :after, 0))
    :ok
  end

  @doc "Every `{sql, opts}` pair recorded so far, oldest first, draining the mailbox."
  @spec recorded() :: [{String.t(), keyword()}]
  def recorded do
    receive do
      {:query, sql, _params, opts} -> [{sql, opts} | recorded()]
    after
      0 -> []
    end
  end

  @doc "The options of the first recorded query whose SQL contains `fragment`."
  @spec options_for([{String.t(), keyword()}], String.t()) :: keyword() | nil
  def options_for(recorded, fragment) do
    Enum.find_value(recorded, fn {sql, opts} -> if sql =~ fragment, do: opts end)
  end

  defp refuse_if_named(sql) do
    fragment = Process.get(@fail_key)

    if is_binary(fragment) and sql =~ fragment, do: refuse_or_skip(fragment)
  end

  defp refuse_or_skip(fragment) do
    case Process.get(@fail_skip_key, 0) do
      remaining when remaining > 0 ->
        Process.put(@fail_skip_key, remaining - 1)
        :ok

      _none ->
        raise DBConnection.ConnectionError,
              "the recording repo was told to fail every query naming #{fragment}"
    end
  end
end
