defmodule GeoGenius.StubDownloader do
  @moduledoc false
  @behaviour GeoGenius.Downloader

  @impl GeoGenius.Downloader
  def available?, do: true

  @impl GeoGenius.Downloader
  def fetch(url, destination, opts) do
    bodies = Keyword.fetch!(opts, :bodies)

    case Map.fetch(bodies, url) do
      {:ok, body} ->
        File.mkdir_p!(Path.dirname(destination))
        File.write!(destination, body)
        if pid = opts[:test_pid], do: send(pid, {:downloaded, url})

        {:ok,
         %{
           bytes: byte_size(body),
           sha256: Base.encode16(:crypto.hash(:sha256, body), case: :lower)
         }}

      :error ->
        {:error, "stub downloader has no body for #{url}"}
    end
  end
end
