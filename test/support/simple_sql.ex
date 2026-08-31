defmodule GeoGenius.TestSimpleSQL do
  @moduledoc false

  @behaviour Postgrex.SimpleConnection

  alias Postgrex.SimpleConnection

  @connection_options [
    :hostname,
    :endpoints,
    :socket_dir,
    :socket,
    :port,
    :database,
    :username,
    :password,
    :parameters,
    :timeout,
    :connect_timeout,
    :handshake_timeout,
    :ping_timeout,
    :ssl,
    :socket_options,
    :prepare,
    :transactions,
    :types,
    :disconnect_on_error_codes
  ]

  def query!(repo, sql) when is_atom(repo) and is_binary(sql) do
    connection_options = Keyword.take(repo.config(), @connection_options)
    {:ok, connection} = SimpleConnection.start_link(__MODULE__, nil, connection_options)

    try do
      case SimpleConnection.call(connection, {:query, sql}, :infinity) do
        %Postgrex.Error{} = error -> raise error
        results when is_list(results) -> results
      end
    after
      GenServer.stop(connection)
    end
  end

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call({:query, sql}, from, nil), do: {:query, sql, from}

  @impl true
  def handle_result(result, from) do
    SimpleConnection.reply(from, result)
    {:noreply, nil}
  end

  @impl true
  def notify(_channel, _payload, _state), do: :ok
end
