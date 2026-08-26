defmodule GeoGenius.AppEnv do
  @moduledoc """
  Sets `:geo_genius` application environment for one test and puts back exactly
  what was there before it.

  `Application.delete_env/2` is the wrong teardown for any key `config/test.exs`
  gives a default: it erases that default for the rest of the VM, so the first
  test to run silently unsets it for every test after. That matters most for
  `:repo`. Its configured default is `GeoGenius.SandboxedRepo` -- a repo in
  `:manual` sandbox mode, which raises for any process holding no checked-out
  connection -- precisely so that a code path dropping an explicit `repo:`
  option fails loudly naming the wrong repo, rather than falling through to a
  repo that happens to work or to an absent-key `ArgumentError` that only looks
  like a pin.
  """

  @doc "Sets `key` for the calling test, restoring its prior state on exit."
  @spec put(atom(), term()) :: :ok
  def put(key, value) do
    restore_on_exit(key)
    Application.put_env(:geo_genius, key, value)
  end

  @doc """
  Restores `key` to whatever it holds now, on exit.

  For a test that deletes a key mid-body to exercise the absent-key path: the
  delete stands for the test and is undone afterwards.
  """
  @spec restore_on_exit(atom()) :: :ok
  def restore_on_exit(key) do
    previous = Application.fetch_env(:geo_genius, key)
    ExUnit.Callbacks.on_exit(fn -> restore(key, previous) end)
    :ok
  end

  @doc """
  Runs `fun` with `key` set to `value`, restoring `key`'s prior state afterwards.

  For the places `on_exit/1` cannot reach: inside an already-running `on_exit`
  callback, where registering another one is not possible and a trailing
  `Application.delete_env/2` would erase a configured default just as
  permanently as one in a teardown block.
  """
  @spec with_env(atom(), term(), (-> result)) :: result when result: term()
  def with_env(key, value, fun) when is_function(fun, 0) do
    previous = Application.fetch_env(:geo_genius, key)
    Application.put_env(:geo_genius, key, value)

    try do
      fun.()
    after
      restore(key, previous)
    end
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:geo_genius, key, value)
  defp restore(key, :error), do: Application.delete_env(:geo_genius, key)
end
