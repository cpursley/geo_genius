defmodule GeoGenius.PreflightTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GeoGenius.{NoJsonRepo, Preflight, SandboxPoolRepo, StockTypesRepo, TestRepo}

  setup do
    TestRepo.query!(~s(DROP SCHEMA IF EXISTS "preflight_probe" CASCADE))
    on_exit(fn -> TestRepo.query!(~s(DROP SCHEMA IF EXISTS "preflight_probe" CASCADE)) end)
    :ok
  end

  test "passes against an installed schema at the default prefix" do
    assert GeoGenius.verify(TestRepo, prefix: "geo_genius") == :ok
    assert GeoGenius.verify!(TestRepo, prefix: "geo_genius") == :ok
  end

  test "reports a missing schema with the migration remedy" do
    assert {:error, reasons} = GeoGenius.verify(TestRepo, prefix: "preflight_probe")
    assert Enum.any?(reasons, &(&1 =~ "not installed"))
    assert Enum.any?(reasons, &(&1 =~ "mix geo_genius.setup"))
  end

  # Both codec probes fire only for a Repo whose Postgrex types module cannot
  # handle the type, so pinning them needs a real Repo of that shape rather
  # than a stub: the probe is the query, and a stub would assert the test's own
  # idea of what Postgrex raises. Neither Repo is configured in
  # `config/test.exs`; each is started with explicit options for its one test
  # so that nothing else in the suite can resolve to a Repo that cannot decode.
  test "reports a Repo whose types module cannot decode PostGIS geometry" do
    start_codec_repo!(StockTypesRepo, [])

    reasons = verify_reasons!(StockTypesRepo)
    assert Enum.any?(reasons, &(&1 =~ "cannot decode PostGIS geometry"))
    assert Enum.any?(reasons, &(&1 =~ "Geo.PostGIS.Extension"))

    # The remedy names the Repo the reader would type, not an inspected term.
    assert Enum.any?(reasons, &(&1 =~ "GeoGenius.StockTypesRepo"))
    refute Enum.any?(reasons, &(&1 =~ "cannot decode jsonb"))
  end

  test "reports a Repo whose types module names a JSON library that is not available" do
    start_codec_repo!(NoJsonRepo, types: GeoGenius.NoJsonTypes)

    reasons = verify_reasons!(NoJsonRepo)
    assert Enum.any?(reasons, &(&1 =~ "cannot decode jsonb"))
    assert Enum.any?(reasons, &(&1 =~ "config :postgrex, :json_library"))

    # `Geo.PostGIS.Extension` is registered on this types module, so geography
    # decodes and only the jsonb probe fires. A single combined "codecs" check
    # would report both and this assertion would fail.
    refute Enum.any?(reasons, &(&1 =~ "cannot decode PostGIS geometry"))
  end

  test "reports a missing extension by name" do
    assert {:error, reasons} =
             GeoGenius.verify(TestRepo,
               prefix: "geo_genius",
               required_extensions: ["postgis", "no_such_extension"]
             )

    assert Enum.any?(reasons, &(&1 =~ "no_such_extension"))
    refute Enum.any?(reasons, &(&1 =~ "postgis"))
  end

  test "verify! raises PreflightError carrying every reason" do
    assert_raise GeoGenius.PreflightError, ~r/no_such_extension/, fn ->
      GeoGenius.verify!(TestRepo,
        prefix: "geo_genius",
        required_extensions: ["no_such_extension"]
      )
    end
  end

  test "the supervisor child returns :ignore when the check passes" do
    assert Preflight.start_link(repo: TestRepo, prefix: "geo_genius") == :ignore
  end

  test "the supervisor child raises when the check fails" do
    assert_raise GeoGenius.PreflightError, fn ->
      Preflight.start_link(repo: TestRepo, prefix: "preflight_probe")
    end
  end

  # A host places this child in application.ex, where the supervisor starts it
  # from a process that owns no sandbox connection. Verifying there would raise
  # DBConnection.OwnershipError and abort the host's suite before its first
  # setup block, so a sandboxed Repo is left alone.
  test "the supervisor child skips verification for a Repo pooled through the SQL sandbox" do
    assert Preflight.start_link(repo: SandboxPoolRepo, prefix: "geo_genius") == :ignore
  end

  test "the supervisor child still verifies a sandboxed Repo when enabled? says so" do
    assert_raise RuntimeError, ~r/SandboxPoolRepo was queried/, fn ->
      Preflight.start_link(repo: SandboxPoolRepo, prefix: "geo_genius", enabled?: true)
    end
  end

  test "a version mismatch is reported with both versions" do
    TestRepo.query!(
      ~s(COMMENT ON VIEW "geo_genius"."geo_genius_version" IS 'GeoGenius version=99')
    )

    assert {:error, reasons} = GeoGenius.verify(TestRepo, prefix: "geo_genius")
    assert Enum.any?(reasons, &(&1 =~ "99"))

    TestRepo.query!(
      ~s(COMMENT ON VIEW "geo_genius"."geo_genius_version" IS 'GeoGenius version=#{GeoGenius.Migration.current_version()}')
    )
  end

  defp start_codec_repo!(repo, extra) do
    connection =
      TestRepo.config()
      |> Keyword.take([:username, :password, :hostname, :port, :database])
      |> Keyword.merge(pool_size: 1, log: false)
      |> Keyword.merge(extra)

    GeoGenius.AppEnv.restore_on_exit(repo)
    Application.put_env(:geo_genius, repo, connection)

    {:ok, pid} = repo.start_link(connection)
    on_exit(fn -> stop_quietly(repo, pid) end)
    :ok
  end

  # A probe that fires kills the connection it ran on, so the pool is already
  # tearing down by the time this runs and `stop/0` exits with `:shutdown`.
  # The Repo going away is the outcome either way.
  defp stop_quietly(repo, pid) do
    if Process.alive?(pid) do
      try do
        repo.stop()
      catch
        :exit, _reason -> :ok
      end
    end
  end

  # The probes work by running the query and rescuing, so a probe that fires
  # logs a disconnect. That noise is the mechanism, not a defect.
  defp verify_reasons!(repo) do
    {result, _log} = with_log(fn -> GeoGenius.verify(repo, prefix: "geo_genius") end)
    assert {:error, reasons} = result
    reasons
  end
end
