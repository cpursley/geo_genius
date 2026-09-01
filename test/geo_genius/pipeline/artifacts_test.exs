defmodule GeoGenius.Pipeline.ArtifactsTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Context
  alias GeoGenius.ImportRun
  alias GeoGenius.Pipeline.Artifacts
  alias GeoGenius.Pipeline.State

  defmodule AttemptRepo do
    @moduledoc false

    def query(sql, params, _opts) do
      send(self(), {:artifact_query, sql, params})

      cond do
        sql =~ ".run_artifacts" -> rows(params)
        sql =~ ".release_artifacts" -> rows(params)
        sql =~ "record_artifact_observation" -> {:ok, %Postgrex.Result{rows: [], num_rows: 1}}
      end
    end

    defp rows([id]) do
      rows = Process.get({__MODULE__, id}, [])
      columns = rows |> List.first(%{}) |> Map.keys()

      {:ok,
       %Postgrex.Result{
         columns: columns,
         rows: Enum.map(rows, &Enum.map(columns, fn column -> Map.fetch!(&1, column) end)),
         num_rows: length(rows)
       }}
    end
  end

  defmodule Cache do
    @moduledoc false
    @behaviour GeoGenius.Cache

    @impl true
    def fetch(_key, opts), do: {:ok, Keyword.fetch!(opts, :artifact_path)}

    @impl true
    def put(_key, _source_path, _opts), do: raise("not used")

    @impl true
    def path(_key, _opts), do: raise("not used")

    @impl true
    def delete(_key, _opts), do: raise("not used")
  end

  setup do
    path = Path.join(System.tmp_dir!(), "geo_genius_attempt_artifact_#{System.unique_integer()}")
    File.write!(path, "attempt-exact artifact")
    on_exit(fn -> File.rm(path) end)

    {:ok, path: path}
  end

  test "download reads and records the artifact against the current run", %{path: path} do
    state = state(path)
    row = artifact_row(state)
    put_rows(state.run.run_id, [row])
    put_rows(state.run.release_id, [row])

    assert {:ok, %State{} = downloaded} = Artifacts.download(state)
    assert downloaded.resolved == %{"fixture.dat" => path}

    dumped_run_id = Ecto.UUID.dump!(state.run.run_id)
    dumped_executor_id = Ecto.UUID.dump!(state.executor_id)
    dumped_release_id = Ecto.UUID.dump!(state.run.release_id)
    dumped_artifact_id = Ecto.UUID.dump!(row["artifact_id"])

    assert_received {:artifact_query, read_sql, [^dumped_run_id]}
    assert read_sql =~ ".run_artifacts"

    assert_received {:artifact_query, observation_sql,
                     [^dumped_run_id, ^dumped_executor_id, ^dumped_artifact_id, _sha256, bytes]}

    assert observation_sql =~ "record_artifact_observation"
    assert bytes == byte_size("attempt-exact artifact")
    refute_received {:artifact_query, _sql, [^dumped_release_id]}
  end

  test "an earlier attempt's observation cannot validate the current attempt", %{path: path} do
    state = state(path)
    prior_run_id = Ecto.UUID.generate()

    prior =
      state
      |> artifact_row()
      |> Map.merge(%{
        "run_id" => prior_run_id,
        "observed_sha256" => String.duplicate("a", 64),
        "observed_bytes" => 22,
        "validated_at" => DateTime.utc_now()
      })

    current = artifact_row(state)

    put_rows(prior_run_id, [prior])
    put_rows(state.run.run_id, [current])
    put_rows(state.run.release_id, [prior])

    assert {:error, reason} = Artifacts.validate(state)
    assert reason == "no validated copy of fixture.dat"

    dumped_run_id = Ecto.UUID.dump!(state.run.run_id)
    dumped_release_id = Ecto.UUID.dump!(state.run.release_id)

    assert_received {:artifact_query, read_sql, [^dumped_run_id]}
    assert read_sql =~ ".run_artifacts"
    refute_received {:artifact_query, _sql, [^dumped_release_id]}
  end

  defp state(path) do
    run_id = Ecto.UUID.generate()
    release_id = Ecto.UUID.generate()

    %State{
      context: %Context{
        repo: AttemptRepo,
        prefix: "geo_genius",
        store: GeoGenius.Stores.Postgres,
        cache: Cache
      },
      run: %ImportRun{run_id: run_id, release_id: release_id},
      executor_id: Ecto.UUID.generate(),
      opts: [artifact_path: path],
      work_dir: System.tmp_dir!(),
      publish?: false,
      batch_size: 500,
      timeout: 30_000
    }
  end

  defp artifact_row(state) do
    %{
      "run_id" => state.run.run_id,
      "release_id" => state.run.release_id,
      "source_release_id" => Ecto.UUID.generate(),
      "artifact_id" => Ecto.UUID.generate(),
      "collection_key" => "fixture",
      "source_key" => "fixture:source",
      "source_release_key" => "v1",
      "logical_name" => "fixture.dat",
      "url" => nil,
      "operator_supplied" => true,
      "format" => "data",
      "expected_sha256" => String.duplicate("0", 64),
      "expected_bytes" => 22,
      "observed_sha256" => nil,
      "observed_bytes" => nil,
      "validated_at" => nil,
      "metadata" => %{"cache_key" => "fixture/fixture.dat"}
    }
  end

  defp put_rows(id, rows) do
    Process.put({AttemptRepo, Ecto.UUID.dump!(id)}, rows)
  end
end
