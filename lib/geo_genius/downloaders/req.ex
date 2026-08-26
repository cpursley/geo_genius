defmodule GeoGenius.Downloaders.Req do
  @moduledoc """
  Streams an artifact to disk with Req, hashing as it goes.

  Req is an optional dependency: a host whose artifacts are all
  operator-supplied never downloads anything and need not install it.
  `available?/0` reports whether it is loaded, and `fetch/3` says so plainly
  rather than raising `UndefinedFunctionError` deep inside a phase.

  The body is written to `destination <> ".part"` as it streams and renamed
  onto `destination` only once a 200 response has fully arrived. Any other
  status, a transport failure, a raised exception, or an `exit`/`throw`
  removes the partial file and leaves `destination` untouched.

  Retries are fixed off and cannot be re-enabled through `opts`. The
  destination file handle is opened once and written to as chunks arrive; a
  Req-level retry re-enters the adapter with a fresh response, so the hash
  state and byte count carried on that response reset while the handle keeps
  appending. The result is a file containing both attempts concatenated
  together, with a reported `sha256`/`bytes` covering only the last one:
  corruption that passes checksum verification. Retrying a failed download
  means calling `fetch/3` again from the top, over a fresh handle, which is
  what a caller's own failure path already does.
  """

  @behaviour GeoGenius.Downloader

  @compile {:no_warn_undefined, Req}

  @request_opt_keys [:plug, :headers, :receive_timeout, :connect_options]
  @private_key :geo_genius_download

  @impl GeoGenius.Downloader
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Req) and function_exported?(Req, :get, 2)

  @impl GeoGenius.Downloader
  @spec fetch(String.t(), Path.t(), keyword()) ::
          {:ok, %{bytes: non_neg_integer(), sha256: String.t()}} | {:error, term()}
  def fetch(url, destination, opts) do
    if available?() do
      stream(url, destination, opts)
    else
      {:error, unavailable_message(url)}
    end
  end

  @doc false
  @spec unavailable_message(String.t()) :: String.t()
  def unavailable_message(url) do
    "GeoGenius cannot download #{url}: the optional dependency :req is not loaded. " <>
      "Add {:req, \"~> 0.7\"} to your deps, configure a different " <>
      "GeoGenius.Downloader, or supply the artifact into the cache by hand."
  end

  @doc false
  @spec fold_chunk(File.io_device(), {:data, binary()}, {term(), map()}) ::
          {:cont, {term(), map()}}
  def fold_chunk(handle, {:data, data}, {req, resp}) do
    :ok = IO.binwrite(handle, data)
    {:cont, {req, record_chunk(resp, data)}}
  end

  defp stream(url, destination, opts) do
    File.mkdir_p!(Path.dirname(destination))
    part_path = destination <> ".part"
    handle = File.open!(part_path, [:write, :binary, :raw])

    try do
      url
      |> Req.get(build_request_opts(opts, handle))
      |> handle_result(url, part_path, destination)
    rescue
      error -> {:error, Exception.message(error)}
    after
      File.close(handle)
      File.rm(part_path)
    end
  end

  defp build_request_opts(opts, handle) do
    opts
    |> Keyword.take(@request_opt_keys)
    |> Keyword.merge(retry: false, into: into_fun(handle))
  end

  defp into_fun(handle) do
    fn event, acc -> fold_chunk(handle, event, acc) end
  end

  defp record_chunk(resp, data) do
    {hash_state, bytes} = Map.get(resp.private, @private_key, initial_state())
    updated = {:crypto.hash_update(hash_state, data), bytes + byte_size(data)}
    %{resp | private: Map.put(resp.private, @private_key, updated)}
  end

  defp handle_result({:ok, %{status: 200} = resp}, _url, part_path, destination) do
    finalize(resp, part_path, destination)
  end

  defp handle_result({:ok, %{status: status}}, url, _part_path, _destination) do
    {:error, "GET #{url} returned #{status}"}
  end

  defp handle_result({:error, exception}, _url, _part_path, _destination) do
    {:error, Exception.message(exception)}
  end

  defp finalize(resp, part_path, destination) do
    File.rename!(part_path, destination)
    {hash_state, bytes} = Map.get(resp.private, @private_key, initial_state())
    {:ok, %{bytes: bytes, sha256: Base.encode16(:crypto.hash_final(hash_state), case: :lower)}}
  end

  defp initial_state, do: {:crypto.hash_init(:sha256), 0}
end
