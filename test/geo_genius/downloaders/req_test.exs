defmodule GeoGenius.Downloaders.ReqTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Downloaders.Req, as: Downloader

  @body "the artifact body"

  setup do
    destination =
      Path.join(System.tmp_dir!(), "gg_download_#{System.unique_integer([:positive])}.bin")

    on_exit(fn ->
      File.rm_rf(destination)
      File.rm_rf(destination <> ".part")
    end)

    {:ok, destination: destination}
  end

  defp stub(fun) do
    name = :"stub_#{System.unique_integer([:positive])}"
    Req.Test.stub(name, fun)
    [plug: {Req.Test, name}]
  end

  test "reports availability" do
    assert Downloader.available?()
  end

  test "streams a body to disk and reports what it observed", %{destination: destination} do
    opts = stub(fn conn -> Plug.Conn.send_resp(conn, 200, @body) end)

    assert {:ok, observed} = Downloader.fetch("https://example.test/a", destination, opts)

    assert observed.bytes == byte_size(@body)
    assert observed.sha256 == Base.encode16(:crypto.hash(:sha256, @body), case: :lower)
    assert File.read!(destination) == @body
  end

  test "the reported byte count is the body's, not a constant", %{destination: destination} do
    long = String.duplicate("x", 5000)
    opts = stub(fn conn -> Plug.Conn.send_resp(conn, 200, long) end)

    assert {:ok, observed} = Downloader.fetch("https://example.test/a", destination, opts)
    assert observed.bytes == 5000
  end

  test "hashes incrementally across chunks rather than re-reading the file",
       %{destination: destination} do
    chunks = for n <- 1..20, do: String.duplicate(Integer.to_string(rem(n, 10)), 1000)
    body = Enum.join(chunks)

    opts =
      stub(fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(chunks, conn, fn chunk, acc ->
          {:ok, acc} = Plug.Conn.chunk(acc, chunk)
          acc
        end)
      end)

    assert {:ok, observed} = Downloader.fetch("https://example.test/a", destination, opts)

    assert observed.sha256 == Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    assert observed.bytes == byte_size(body)
    assert File.read!(destination) == body
  end

  test "a reviewed byte cap is carried on the request and a body within it downloads",
       %{destination: destination} do
    opts = stub(fn conn -> Plug.Conn.send_resp(conn, 200, @body) end)

    assert {:ok, observed} =
             Downloader.fetch(
               "https://example.test/a",
               destination,
               opts ++ [max_bytes: byte_size(@body)]
             )

    assert observed.bytes == byte_size(@body)
    assert File.read!(destination) == @body
  end

  test "a body that exceeds the reviewed byte cap is an error and leaves nothing behind",
       %{destination: destination} do
    opts = stub(fn conn -> Plug.Conn.send_resp(conn, 200, @body) end)

    assert {:error, message} =
             Downloader.fetch("https://example.test/a", destination, opts ++ [max_bytes: 4])

    assert message =~ "exceeded the reviewed 4 bytes"
    refute File.exists?(destination)
    refute File.exists?(destination <> ".part")
  end

  test "a non-200 response is an error and leaves nothing behind", %{destination: destination} do
    opts = stub(fn conn -> Plug.Conn.send_resp(conn, 404, "nope") end)

    assert {:error, reason} = Downloader.fetch("https://example.test/a", destination, opts)
    assert reason =~ "404"

    refute File.exists?(destination)
    refute File.exists?(destination <> ".part")
  end

  describe "rate limiting" do
    defp counting_stub(responses) do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      opts =
        stub(fn conn ->
          index = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
          Enum.at(responses, index, List.last(responses)).(conn)
        end)

      {opts, counter}
    end

    defp recording_sleep do
      {:ok, sleeps} = Agent.start_link(fn -> [] end)
      {fn ms -> Agent.update(sleeps, &[ms | &1]) end, sleeps}
    end

    test "a 429 is retried from the top over a fresh handle and the body is intact",
         %{destination: destination} do
      {opts, counter} =
        counting_stub([
          fn conn -> Plug.Conn.send_resp(conn, 429, "slow down") end,
          fn conn -> Plug.Conn.send_resp(conn, 429, "slow down") end,
          fn conn -> Plug.Conn.send_resp(conn, 200, @body) end
        ])

      {sleep, sleeps} = recording_sleep()

      assert {:ok, observed} =
               Downloader.fetch("https://example.test/a", destination, opts ++ [sleep: sleep])

      assert Agent.get(counter, & &1) == 3
      assert observed.bytes == byte_size(@body)
      assert observed.sha256 == Base.encode16(:crypto.hash(:sha256, @body), case: :lower)
      assert File.read!(destination) == @body
      assert Agent.get(sleeps, &Enum.reverse/1) == [1_000, 2_000]
    end

    test "a Retry-After header in seconds sets the wait instead of the backoff",
         %{destination: destination} do
      {opts, _counter} =
        counting_stub([
          fn conn ->
            conn |> Plug.Conn.put_resp_header("retry-after", "7") |> Plug.Conn.send_resp(429, "")
          end,
          fn conn -> Plug.Conn.send_resp(conn, 200, @body) end
        ])

      {sleep, sleeps} = recording_sleep()

      assert {:ok, _observed} =
               Downloader.fetch("https://example.test/a", destination, opts ++ [sleep: sleep])

      assert Agent.get(sleeps, &Enum.reverse/1) == [7_000]
    end

    test "a 503 is retried the same way", %{destination: destination} do
      {opts, counter} =
        counting_stub([
          fn conn -> Plug.Conn.send_resp(conn, 503, "") end,
          fn conn -> Plug.Conn.send_resp(conn, 200, @body) end
        ])

      {sleep, _sleeps} = recording_sleep()

      assert {:ok, _observed} =
               Downloader.fetch("https://example.test/a", destination, opts ++ [sleep: sleep])

      assert Agent.get(counter, & &1) == 2
    end

    test "gives up after the attempt budget with an error naming the status and attempts",
         %{destination: destination} do
      {opts, counter} = counting_stub([fn conn -> Plug.Conn.send_resp(conn, 429, "") end])
      {sleep, sleeps} = recording_sleep()

      assert {:error, reason} =
               Downloader.fetch(
                 "https://example.test/a",
                 destination,
                 opts ++ [sleep: sleep, max_attempts: 3]
               )

      assert reason =~ "429"
      assert reason =~ "3 attempts"
      assert Agent.get(counter, & &1) == 3
      assert Agent.get(sleeps, &Enum.reverse/1) == [1_000, 2_000]
      refute File.exists?(destination)
      refute File.exists?(destination <> ".part")
    end

    test "a 404 is not retried", %{destination: destination} do
      {opts, counter} = counting_stub([fn conn -> Plug.Conn.send_resp(conn, 404, "") end])
      {sleep, sleeps} = recording_sleep()

      assert {:error, _reason} =
               Downloader.fetch("https://example.test/a", destination, opts ++ [sleep: sleep])

      assert Agent.get(counter, & &1) == 1
      assert Agent.get(sleeps, & &1) == []
    end
  end

  test "a transport failure is an error and leaves nothing behind", %{destination: destination} do
    opts = stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, _reason} = Downloader.fetch("https://example.test/a", destination, opts)

    refute File.exists?(destination)
    refute File.exists?(destination <> ".part")
  end

  test "a failed download does not clobber a file already at the destination",
       %{destination: destination} do
    File.write!(destination, "previously fetched")
    opts = stub(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    assert {:error, _reason} = Downloader.fetch("https://example.test/a", destination, opts)
    assert File.read!(destination) == "previously fetched"
  end

  test "creates the destination directory when it does not exist" do
    destination =
      Path.join([
        System.tmp_dir!(),
        "gg_download_nested_#{System.unique_integer([:positive])}",
        "deep",
        "a.bin"
      ])

    on_exit(fn -> File.rm_rf!(Path.dirname(Path.dirname(destination))) end)

    opts = stub(fn conn -> Plug.Conn.send_resp(conn, 200, @body) end)

    assert {:ok, _observed} = Downloader.fetch("https://example.test/a", destination, opts)
    assert File.read!(destination) == @body
  end

  test "does not retry a failing response - exactly one attempt reaches the server",
       %{destination: destination} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    opts =
      stub(fn conn ->
        Agent.update(counter, &(&1 + 1))
        Plug.Conn.send_resp(conn, 500, "boom")
      end)

    assert {:error, _reason} = Downloader.fetch("https://example.test/a", destination, opts)
    assert Agent.get(counter, & &1) == 1
  end

  describe "unavailable_message/1" do
    test "names the missing dependency, both remedies, and the url" do
      message = Downloader.unavailable_message("https://example.test/artifact.zip")

      assert message =~ "https://example.test/artifact.zip"
      assert message =~ ":req"
      assert message =~ "{:req, \"~> 0.7\"}"
      assert message =~ "GeoGenius.Downloader"
      assert message =~ "cache by hand"
    end
  end

  describe "fold_chunk/3" do
    test "writes each chunk to disk as it arrives rather than buffering until the stream ends" do
      path = Path.join(System.tmp_dir!(), "gg_fold_#{System.unique_integer([:positive])}.bin")
      on_exit(fn -> File.rm_rf(path) end)

      handle = File.open!(path, [:write, :binary, :raw])

      assert {:cont, {nil, resp}} =
               Downloader.fold_chunk(handle, {:data, "first-"}, {nil, %{private: %{}}})

      assert File.read!(path) == "first-"

      assert {:cont, {nil, _resp}} =
               Downloader.fold_chunk(handle, {:data, "second"}, {nil, resp})

      File.close(handle)

      assert File.read!(path) == "first-second"
    end
  end
end
