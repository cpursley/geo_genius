defmodule GeoGenius.AppEnvTest do
  # Mutates `:geo_genius` application environment, which is global.
  use ExUnit.Case, async: false

  alias GeoGenius.AppEnv

  # `config/test.exs` gives exactly one plain key a default, and it is the key
  # the whole helper exists for: a teardown that deleted `:repo` instead of
  # restoring it would erase that default for the rest of the VM, turning the
  # suite's positive wrong-repo pins back into absent-key accidents.
  @configured GeoGenius.SandboxedRepo
  @absent_key :app_env_test_absent_key

  setup do
    assert Application.fetch_env(:geo_genius, :repo) == {:ok, @configured}
    assert Application.fetch_env(:geo_genius, @absent_key) == :error
    :ok
  end

  describe "put/2" do
    test "an absent key is absent again afterwards" do
      # Registered before AppEnv's own callback, so LIFO runs it last -- after
      # the restore rather than before it.
      on_exit(fn -> assert Application.fetch_env(:geo_genius, @absent_key) == :error end)

      AppEnv.put(@absent_key, :something)
      assert Application.fetch_env(:geo_genius, @absent_key) == {:ok, :something}
    end

    test "a key with a configured default is restored to that default, not deleted" do
      on_exit(fn -> assert Application.fetch_env(:geo_genius, :repo) == {:ok, @configured} end)

      AppEnv.put(:repo, GeoGenius.TestRepo)
      assert Application.fetch_env(:geo_genius, :repo) == {:ok, GeoGenius.TestRepo}
    end

    test "a mid-body delete of a defaulted key is undone" do
      on_exit(fn -> assert Application.fetch_env(:geo_genius, :repo) == {:ok, @configured} end)

      AppEnv.put(:repo, GeoGenius.TestRepo)
      Application.delete_env(:geo_genius, :repo)
      assert Application.fetch_env(:geo_genius, :repo) == :error
    end

    test "repeated puts on one key still land back on the original value" do
      on_exit(fn -> assert Application.fetch_env(:geo_genius, :repo) == {:ok, @configured} end)

      AppEnv.put(:repo, GeoGenius.TestRepo)
      AppEnv.put(:repo, GeoGenius.SandboxPoolRepo)
      AppEnv.put(:repo, GeoGenius.TestRepo)
    end
  end

  describe "restore_on_exit/1" do
    test "a mid-body delete of a defaulted key is undone" do
      on_exit(fn -> assert Application.fetch_env(:geo_genius, :repo) == {:ok, @configured} end)

      AppEnv.restore_on_exit(:repo)
      Application.delete_env(:geo_genius, :repo)
      assert Application.fetch_env(:geo_genius, :repo) == :error
    end
  end

  describe "with_env/3" do
    test "restores a present value as soon as the body returns, and returns its value" do
      assert AppEnv.with_env(:repo, GeoGenius.TestRepo, fn ->
               assert Application.fetch_env(:geo_genius, :repo) == {:ok, GeoGenius.TestRepo}
               :body_value
             end) == :body_value

      assert Application.fetch_env(:geo_genius, :repo) == {:ok, @configured}
    end

    test "restores an absent key as soon as the body returns" do
      AppEnv.with_env(@absent_key, :something, fn ->
        assert Application.fetch_env(:geo_genius, @absent_key) == {:ok, :something}
      end)

      assert Application.fetch_env(:geo_genius, @absent_key) == :error
    end

    # The three callbacks that use `with_env/3` run inside an already-running
    # `on_exit`, where nothing else would put the value back. Without the
    # `after`, a body that raises leaves the key at the callback's value for
    # the rest of the VM -- and none of those three bodies raises in a green
    # run, so only this asserts it.
    test "restores a present value even when the body raises" do
      assert_raise RuntimeError, "body exploded", fn ->
        AppEnv.with_env(:repo, GeoGenius.TestRepo, fn -> raise "body exploded" end)
      end

      assert Application.fetch_env(:geo_genius, :repo) == {:ok, @configured}
    end

    test "restores a present value even when the body throws or exits" do
      catch_throw(AppEnv.with_env(:repo, GeoGenius.TestRepo, fn -> throw(:nope) end))
      assert Application.fetch_env(:geo_genius, :repo) == {:ok, @configured}

      catch_exit(AppEnv.with_env(:repo, GeoGenius.TestRepo, fn -> exit(:nope) end))
      assert Application.fetch_env(:geo_genius, :repo) == {:ok, @configured}
    end
  end
end
