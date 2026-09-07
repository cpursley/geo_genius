defmodule GeoGenius.Downloaders.Req do
  @retryable_statuses [429, 503]
  @default_max_attempts 5
  @base_backoff_ms 1_000
  @max_backoff_ms 60_000

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

  Req-level retries are fixed off and cannot be re-enabled through `opts`. The
  destination file handle is opened once and written to as chunks arrive; a
  Req-level retry re-enters the adapter with a fresh response, so the hash
  state and byte count carried on that response reset while the handle keeps
  appending. The result is a file containing both attempts concatenated
  together, with a reported `sha256`/`bytes` covering only the last one:
  corruption that passes checksum verification.

  Rate limiting is retried here instead, from the top and over a fresh handle.
  A `429` or `503` response closes the handle, removes the partial file, waits,
  and starts the request again, up to `opts[:max_attempts]` times (default
  #{@default_max_attempts}). The wait honors a `Retry-After` header given in
  seconds and otherwise doubles from #{@base_backoff_ms} ms per attempt, capped
  at #{@max_backoff_ms} ms. Any other non-200 status is final. `opts[:sleep]`
  replaces `Process.sleep/1` for tests.
  """

  @behaviour GeoGenius.Downloader

  @compile {:no_warn_undefined, [Req, Req.Request, Req.Response]}

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
      attempt(url, destination, opts, 1)
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
    {_hash_state, bytes} = Map.get(resp.private, @private_key, initial_state())
    max_bytes = max_bytes(req)
    incoming = bytes + byte_size(data)

    if is_integer(max_bytes) and incoming > max_bytes do
      raise ArgumentError, overflow_message(max_bytes)
    end

    :ok = IO.binwrite(handle, data)
    {:cont, {req, record_chunk(resp, data)}}
  end

  defp attempt(url, destination, opts, attempt_number) do
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)

    case stream(url, destination, opts) do
      {:retry, _status, retry_after_ms} when attempt_number < max_attempts ->
        sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
        sleep.(retry_after_ms || backoff_ms(attempt_number))
        attempt(url, destination, opts, attempt_number + 1)

      {:retry, status, _retry_after_ms} ->
        {:error, "GET #{url} returned #{status} after #{max_attempts} attempts"}

      result ->
        result
    end
  end

  defp backoff_ms(attempt_number) do
    min(@base_backoff_ms * Integer.pow(2, attempt_number - 1), @max_backoff_ms)
  end

  defp stream(url, destination, opts) do
    File.mkdir_p!(Path.dirname(destination))
    part_path = destination <> ".part"
    handle = File.open!(part_path, [:write, :binary, :raw])

    try do
      opts
      |> build_request(url, handle)
      |> Req.get()
      |> handle_result(url, part_path, destination)
    rescue
      error -> {:error, Exception.message(error)}
    after
      File.close(handle)
      File.rm(part_path)
    end
  end

  # The byte cap rides in the request's private map, which Req reserves for
  # libraries and exposes only through `Req.Request.put_private/3`; it is not a
  # request option, so passing it as one is rejected before any bytes move.
  defp build_request(opts, url, handle) do
    request =
      opts
      |> Keyword.take(@request_opt_keys)
      |> Keyword.merge(
        url: url,
        retry: false,
        into: into_fun(handle),
        redirect: false
      )
      |> Req.new()

    case Keyword.get(opts, :max_bytes) do
      max_bytes when is_integer(max_bytes) and max_bytes > 0 ->
        Req.Request.put_private(request, :geo_genius_max_bytes, max_bytes)

      _other ->
        request
    end
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

  defp handle_result({:ok, %{status: status} = resp}, _url, _part_path, _destination)
       when status in @retryable_statuses do
    {:retry, status, retry_after_ms(resp)}
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

  # Only the delay-seconds form of Retry-After is read; an HTTP-date value
  # falls through to the backoff schedule.
  defp retry_after_ms(resp) do
    with [value | _] <- Req.Response.get_header(resp, "retry-after"),
         {seconds, ""} <- Integer.parse(String.trim(value)),
         true <- seconds >= 0 do
      seconds * 1_000
    else
      _other -> nil
    end
  end

  defp max_bytes(%{private: private}) when is_map(private),
    do: Map.get(private, :geo_genius_max_bytes)

  defp max_bytes(_req), do: nil

  defp overflow_message(max_bytes) do
    "download exceeded the reviewed #{max_bytes} bytes before completion"
  end
end
