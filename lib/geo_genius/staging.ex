defmodule GeoGenius.Staging do
  @moduledoc """
  The per-run landing area between an artifact and the catalog.

  A provider parses one artifact into rows here, and normalization reads them
  back out one at a time. The indirection buys separation: normalization reads
  one row shape whatever format the artifact arrived in, the catalog is
  written to at a pace no parser sets, and a provider's parsing is testable
  against a table rather than against the catalog's constraints.

  It is not recovery input. Every attempt stages afresh from its immutable
  artifact snapshot, so a pass begins by emptying the run's table -- see
  `reset/3`.

  The table is created and dropped per run and is `UNLOGGED`, because its
  content is reproducible from a checksummed artifact and skipping WAL for a
  bulk load of hundreds of thousands of rows is the reason staging is its own
  phase.
  """

  alias GeoGenius.{Catalog, Context, StagingError}
  alias GeoGenius.Stores.Postgres

  defmodule Row do
    @moduledoc """
    One staged record.

    `artifact` is the artifact's `logical_name`, carried so normalization can
    map a row back to the source release its boundary must be attributed to.
    `payload` is whatever the provider parsed; nothing outside that provider
    interprets it. `geom` is nil for a metadata-only source.
    """

    @enforce_keys [:artifact, :payload]
    defstruct [:artifact, :payload, :geom]

    @type t :: %__MODULE__{
            artifact: String.t(),
            payload: map(),
            geom: Geo.geometry() | nil
          }
  end

  @suffix ~r/\A[0-9a-f]{32}\z/
  @default_batch_size 1000

  @doc """
  The staging table's name for a run.

  Derived from the run's uuid, so the identifier is `[0-9a-f_]+` by
  construction rather than by escaping. `staging_table_name/1` in SQL applies
  the same rule; the test asserts the two agree rather than trusting that they
  do.
  """
  @spec table_name(Ecto.UUID.t()) :: String.t()
  def table_name(run_id) when is_binary(run_id) do
    suffix = String.replace(run_id, "-", "")

    if Regex.match?(@suffix, suffix) do
      "staging_" <> suffix
    else
      raise ArgumentError,
            "expected a uuid to derive a staging table name from, got: #{inspect(run_id)}"
    end
  end

  @doc "Creates a run's staging table, if it does not already exist, returning its name."
  @spec create(Context.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def create(%Context{} = context, run_id, executor_id),
    do: Catalog.create_staging(context, run_id, executor_id)

  @doc """
  Empties a run's staging table, creating it if it is not there, and returns
  its name.

  `create/3` alone is `CREATE UNLOGGED TABLE IF NOT EXISTS`, which is what a
  staging pass wants on the second call and not what it wants at the start of
  execution. A table can survive an abrupt worker or VM death, or be created
  manually before the pipeline starts. Neither case authorizes those rows as
  input to a future executor.

  So a pass starts from a table that is empty by construction. The table is
  dropped rather than truncated, which also resets the identity sequence the
  keyset pagination in `stream/3` reads through, and leaves nothing of the
  previous attempt's shape behind for this one to inherit.

  Nothing durable is lost by emptying it: staging is reproducible scratch
  space, not attempt evidence or a recovery checkpoint. A corrected retry has
  a new run and stages from its own artifact snapshot. What makes that retry
  cheap is the artifact cache, which skips the network.
  """
  @spec reset(Context.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def reset(%Context{} = context, run_id, executor_id) do
    create(context, run_id, executor_id)
    :ok = drop(context, run_id, executor_id)
    create(context, run_id, executor_id)
  end

  @doc "Drops a terminal or orphaned run's staging table, if it exists."
  @spec drop(Context.t(), Ecto.UUID.t()) :: :ok
  def drop(%Context{} = context, run_id), do: Catalog.drop_staging(context, run_id)

  @doc "Drops the current executor's active staging table, if it exists."
  @spec drop(Context.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def drop(%Context{} = context, run_id, executor_id),
    do: Catalog.drop_staging(context, run_id, executor_id)

  @doc """
  Every staging table no run still needs.

  A table is leaked when its run has reached a terminal status, and also when
  no `import_run` row carries its id at all. The second case is the one that
  cannot be recovered any other way: an earlier version of this function
  joined `import_run` to `pg_class`, so a table whose run row was gone had
  nothing to join to, never appeared here, and `mix geo_genius.sweep_staging`
  could never drop it. The schema down migration refuses to drop a non-empty schema, so
  an unreclaimable table eventually blocks an uninstall outright.

  The scan therefore starts from `pg_class` and left-joins `import_run`.
  Candidate names must match `staging_` followed by 32 hex characters, and
  the run id is read back out of the name, so a table with no run row still
  yields the id `GeoGenius.Catalog.drop_staging/2` needs. That id is then
  round-tripped: a row survives only when `staging_table_name(id)` reproduces
  the table's own name exactly, which keeps PostgreSQL the authority on how a
  staging table is named and means nothing whose name this library did not
  derive is ever offered up for dropping.

  Returns `{run_id, table_name}` pairs ordered by table name.
  """
  @spec leaked(Context.t()) :: [{Ecto.UUID.t(), String.t()}]
  def leaked(%Context{} = context) do
    sql = """
    WITH candidate AS MATERIALIZED (
      SELECT staging.relname
        FROM pg_catalog.pg_class AS staging
        JOIN pg_catalog.pg_namespace AS schema
          ON schema.oid = staging.relnamespace
       WHERE schema.nspname = '#{context.prefix}'
         AND staging.relkind = 'r'
         AND staging.relname ~ '^staging_[0-9a-f]{32}$'
    ),
    named AS MATERIALIZED (
      SELECT candidate.relname,
             regexp_replace(
               substring(candidate.relname from 9),
               '^(.{8})(.{4})(.{4})(.{4})(.{12})$',
               '\\1-\\2-\\3-\\4-\\5'
             )::uuid AS run_id
        FROM candidate
    )
    SELECT named.run_id::text, named.relname
      FROM named
      LEFT JOIN "#{context.prefix}".import_run
        ON import_run.id = named.run_id
     WHERE "#{context.prefix}".staging_table_name(named.run_id) = named.relname
       AND (import_run.id IS NULL OR import_run.status IN ('completed', 'failed'))
     ORDER BY named.relname
    """

    %Postgrex.Result{rows: rows} = execute(context, sql, [], "leaked")
    Enum.map(rows, fn [run_id, table] -> {run_id, table} end)
  end

  @doc """
  Bulk-inserts `rows`, returning the number of rows written.

  Issues one round trip regardless of batch size: the three fields unzip into
  parallel arrays and cross as a single `unnest` insert rather than as one
  statement per row. `payload` binds as a list of maps, never as pre-encoded
  JSON text -- a string would decode back as a jsonb string value holding an
  escaped object rather than the object itself, and no constraint catches
  that because a JSON string is valid jsonb.

  Returns `0` without touching the database for an empty list, but still
  validates `run_id` first, so a malformed run id fails the same way it would
  for a non-empty batch rather than being masked by the empty-list shortcut.

  `opts` reaches `Repo.query/3`. One batch of a national artifact is a single
  multi-megabyte `unnest` insert, which is exactly the shape DBConnection's
  fifteen-second default cuts short, so a caller raises `:timeout` here rather
  than on its whole Repo. The insert always forces `checkout_retries: 0`: after
  a disconnect, only the pipeline can safely decide whether to start a new
  import attempt rather than repeating an ambiguously completed mutation.
  """
  @spec insert(Context.t(), Ecto.UUID.t(), Ecto.UUID.t(), [Row.t()], keyword()) ::
          non_neg_integer()
  def insert(context, run_id, executor_id, rows, opts \\ [])

  def insert(%Context{}, run_id, executor_id, [], _opts) do
    table_name(run_id)
    Postgres.dump_uuid(executor_id)
    0
  end

  def insert(%Context{} = context, run_id, executor_id, rows, opts) when is_list(rows) do
    table_name(run_id)

    artifacts = Enum.map(rows, & &1.artifact)
    payloads = Enum.map(rows, & &1.payload)
    geoms = Enum.map(rows, & &1.geom)

    sql =
      "SELECT \"#{context.prefix}\".insert_staging_many($1, $2, $3, $4, $5) AS result"

    %Postgrex.Result{rows: [[num_rows]]} =
      execute(
        context,
        sql,
        [Postgres.dump_uuid(run_id), Postgres.dump_uuid(executor_id), artifacts, payloads, geoms],
        "insert",
        Keyword.put(opts, :checkout_retries, 0)
      )

    num_rows
  end

  @doc """
  Streams a run's staged rows in insertion order.

  Reads through keyset pagination -- `WHERE id > $1 ORDER BY id LIMIT $2` --
  rather than `Ecto.Adapters.SQL.stream/4`, which needs an enclosing
  transaction. Normalization writes hundreds of thousands of rows through
  separate statements after each row is read, and holding one transaction
  open for that whole phase would pin a connection and a snapshot for as long
  as the slowest phase in the pipeline runs. Each page carries the last row's
  `id` forward as the next page's lower bound rather than an offset, since
  `OFFSET` re-scans and a concurrent insert would shift it.

  `:batch_size` defaults to #{@default_batch_size} and must be a positive
  integer -- a batch size of zero would page with `LIMIT 0`, which always
  returns no rows and would silently stream nothing rather than fail.
  """
  @spec stream(Context.t(), Ecto.UUID.t(), keyword()) :: Enumerable.t()
  def stream(%Context{} = context, run_id, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    validate_batch_size!(batch_size)
    table = table_name(run_id)

    Stream.resource(
      fn -> {:cont, 0} end,
      &next_page(&1, context, table, batch_size),
      fn _state -> :ok end
    )
  end

  @doc "The number of rows currently staged for a run."
  @spec count(Context.t(), Ecto.UUID.t()) :: non_neg_integer()
  def count(%Context{} = context, run_id) do
    table = table_name(run_id)
    sql = "SELECT count(*) FROM \"#{context.prefix}\".\"#{table}\""

    %Postgrex.Result{rows: [[count]]} = execute(context, sql, [], "count")
    count
  end

  defp validate_batch_size!(batch_size) when is_integer(batch_size) and batch_size > 0, do: :ok

  defp validate_batch_size!(batch_size) do
    raise ArgumentError,
          "expected :batch_size to be a positive integer, got: #{inspect(batch_size)}"
  end

  defp next_page(:halt, _context, _table, _batch_size), do: {:halt, :halt}

  defp next_page({:cont, last_id}, context, table, batch_size) do
    case fetch_page(context, table, last_id, batch_size) do
      {[], _next_id} -> {:halt, :halt}
      {rows, _next_id} when length(rows) < batch_size -> {rows, :halt}
      {rows, next_id} -> {rows, {:cont, next_id}}
    end
  end

  defp fetch_page(context, table, last_id, batch_size) do
    sql = """
    SELECT id, artifact, payload, geom
      FROM "#{context.prefix}"."#{table}"
     WHERE id > $1
     ORDER BY id
     LIMIT $2
    """

    case execute(context, sql, [last_id, batch_size], "stream") do
      %Postgrex.Result{rows: []} -> {[], last_id}
      %Postgrex.Result{rows: rows} -> {Enum.map(rows, &to_row/1), last_row_id(rows)}
    end
  end

  defp last_row_id(rows) do
    [id | _] = List.last(rows)
    id
  end

  defp to_row([_id, artifact, payload, geom]) do
    %Row{artifact: artifact, payload: payload, geom: geom}
  end

  defp execute(%Context{repo: repo}, sql, params, operation, opts \\ []) do
    case run(repo, sql, params, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise StagingError, operation: operation, reason: reason
    end
  end

  # `StagingError` reports trouble whichever way the driver hits it. A
  # statement Postgres rejects comes back as an error tuple, but a value the
  # driver cannot encode -- a plain map where `:geom` wants a `Geo` struct,
  # say -- raises before the statement is ever sent. Both carry the original
  # as the exception's `:reason`.
  defp run(repo, sql, params, opts) do
    repo.query(sql, params, opts)
  rescue
    error -> {:error, error}
  end
end
