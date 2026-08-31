defmodule GeoGenius.Catalog do
  @moduledoc """
  Writes and publishes the catalog: collections, authorities, area types,
  areas, their names and codes, releases, sources, artifacts, and import
  runs.

  `GeoGenius.Store` is a behaviour because the read side names a host-repo
  seam as its alternative: a host may want reads routed through its own
  layer. Ingestion has no such alternative -- there is exactly one way to
  write this catalog, and it is the shipped SQL. A behaviour here would be
  one callback list with one implementation and no second caller, so this is
  a plain module instead.

  Every function that wraps more than a couple of positional SQL arguments
  takes `(context, identifier, attrs)`. Most of `attrs`'s keys are named for
  the SQL argument they fill, but a few are named for what they mean on the
  Elixir side instead, because that name reads better at every call site that
  will use it: `put_area_in_release`'s `:attributes` (SQL `data`),
  `put_boundary`'s `:geometry` (SQL `input_geom`) and `:source_release_id`
  (SQL `target_source_release_id`), and `begin_or_resume_import`'s
  `:stale_after_seconds` (SQL `stale_after`, expressed in seconds rather than
  as an interval). This shape keeps every wrapper's arity under Credo's cap
  and means a caller cannot silently transpose two same-typed arguments by
  getting their position wrong.

  Every uuid crosses this module as the hyphenated string the read layer
  already returns and accepts, never as Postgrex's raw sixteen-byte binary.
  """

  alias GeoGenius.{Context, ImportRun, Stores.Postgres}

  @view_columns """
  run_id::text AS run_id, release_id::text AS release_id, collection_key, release_key,
  attempt, status, owner, runner_backend, started_at, heartbeat_at, completed_at,
  error, stage_metrics, progress
  """

  @artifact_columns """
  release_id::text AS release_id, source_release_id::text AS source_release_id, source_key,
  source_release_key, collection_key, artifact_id::text AS artifact_id, logical_name, url,
  operator_supplied, format, expected_sha256, expected_bytes, observed_sha256,
  observed_bytes, validated_at, metadata
  """

  @doc "Creates or updates a collection, returning its id."
  @spec upsert_collection(Context.t(), map()) :: Ecto.UUID.t()
  def upsert_collection(%Context{} = context, attrs) do
    scalar(context, "upsert_collection", "$1, $2, $3, $4", [
      Map.fetch!(attrs, :key),
      Map.fetch!(attrs, :name),
      Map.get(attrs, :description),
      Map.get(attrs, :requires_geometry, false)
    ])
  end

  @doc "Creates or updates an authority within a collection, returning its id."
  @spec upsert_authority(Context.t(), String.t(), map()) :: Ecto.UUID.t()
  def upsert_authority(%Context{} = context, collection_key, attrs) do
    scalar(context, "upsert_authority", "$1, $2, $3", [
      collection_key,
      Map.fetch!(attrs, :key),
      Map.fetch!(attrs, :name)
    ])
  end

  @doc "Creates or updates an area type within a collection, returning its id."
  @spec upsert_area_type(Context.t(), String.t(), map()) :: Ecto.UUID.t()
  def upsert_area_type(%Context{} = context, collection_key, attrs) do
    scalar(context, "upsert_area_type", "$1, $2, $3, $4", [
      collection_key,
      Map.fetch!(attrs, :key),
      Map.fetch!(attrs, :rank),
      Map.get(attrs, :requires_geometry, false)
    ])
  end

  @doc "Creates or updates an area within a collection, returning its id."
  @spec upsert_area(Context.t(), String.t(), map()) :: Ecto.UUID.t()
  def upsert_area(%Context{} = context, collection_key, attrs) do
    scalar(context, "upsert_area", "$1, $2, $3, $4", [
      collection_key,
      Map.fetch!(attrs, :authority_key),
      Map.fetch!(attrs, :area_type_key),
      Map.fetch!(attrs, :code)
    ])
  end

  @doc """
  Creates or updates every area in `areas`, returning their ids in the order
  they were given.

  Each map carries `:authority_key`, `:area_type_key`, and `:code`. The three
  cross as parallel arrays and are written by one statement, so a batch costs
  one round trip rather than one per area, and `upsert_area/3` is this
  function with a one-element list. An area named twice in one batch -- the
  county every city row of that county describes -- is written once and its id
  returned at both positions.

  Returns `[]` without touching the database for an empty list.
  """
  @spec upsert_area_many(Context.t(), String.t(), [map()]) :: [Ecto.UUID.t()]
  def upsert_area_many(context, collection_key, areas)

  def upsert_area_many(%Context{}, _collection_key, []), do: []

  def upsert_area_many(%Context{} = context, collection_key, areas) do
    scalar_list(context, "upsert_area_many", "$1, $2, $3, $4", [
      collection_key,
      Enum.map(areas, &Map.fetch!(&1, :authority_key)),
      Enum.map(areas, &Map.fetch!(&1, :area_type_key)),
      Enum.map(areas, &Map.fetch!(&1, :code))
    ])
  end

  @doc "Sets one of an area's names, returning the name row's id."
  @spec put_area_name(Context.t(), String.t(), map()) :: Ecto.UUID.t()
  def put_area_name(%Context{} = context, area_key, attrs) do
    scalar(context, "put_area_name", "$1, $2, $3, $4", [
      area_key,
      Map.fetch!(attrs, :name),
      Map.fetch!(attrs, :kind),
      Map.get(attrs, :locale)
    ])
  end

  @doc """
  Sets every name in `names`, returning the name rows' ids in the order they
  were given.

  Each map carries `:area_key`, `:name`, `:kind`, and an optional `:locale`.
  This is `put_area_name/3` over a whole batch, in one round trip; `:locale`
  is the one field that may be `nil`.

  Returns `[]` without touching the database for an empty list.
  """
  @spec put_area_name_many(Context.t(), [map()]) :: [Ecto.UUID.t()]
  def put_area_name_many(context, names)

  def put_area_name_many(%Context{}, []), do: []

  def put_area_name_many(%Context{} = context, names) do
    scalar_list(context, "put_area_name_many", "$1, $2, $3, $4", [
      Enum.map(names, &Map.fetch!(&1, :area_key)),
      Enum.map(names, &Map.fetch!(&1, :name)),
      Enum.map(names, &Map.fetch!(&1, :kind)),
      Enum.map(names, &Map.get(&1, :locale))
    ])
  end

  @doc "Sets one of an area's external codes, returning the code row's id."
  @spec put_area_code(Context.t(), String.t(), map()) :: Ecto.UUID.t()
  def put_area_code(%Context{} = context, area_key, attrs) do
    scalar(context, "put_area_code", "$1, $2, $3", [
      area_key,
      Map.fetch!(attrs, :code_type),
      Map.fetch!(attrs, :code_value)
    ])
  end

  @doc """
  Sets every external code in `codes`, returning the code rows' ids in the
  order they were given.

  Each map carries `:area_key`, `:code_type`, and `:code_value`. This is
  `put_area_code/3` over a whole batch, in one round trip.

  Returns `[]` without touching the database for an empty list.
  """
  @spec put_area_code_many(Context.t(), [map()]) :: [Ecto.UUID.t()]
  def put_area_code_many(context, codes)

  def put_area_code_many(%Context{}, []), do: []

  def put_area_code_many(%Context{} = context, codes) do
    scalar_list(context, "put_area_code_many", "$1, $2, $3", [
      Enum.map(codes, &Map.fetch!(&1, :area_key)),
      Enum.map(codes, &Map.fetch!(&1, :code_type)),
      Enum.map(codes, &Map.fetch!(&1, :code_value))
    ])
  end

  @doc """
  Places an area into a release with its centroid and release-scoped
  attributes.
  """
  @spec put_area_in_release(Context.t(), Ecto.UUID.t(), String.t(), map()) :: :ok
  def put_area_in_release(%Context{} = context, release_id, area_key, attrs) do
    void(context, "put_area_in_release", "$1, $2, $3, $4", [
      dump_uuid(release_id),
      area_key,
      Map.fetch!(attrs, :centroid),
      Map.get(attrs, :attributes, %{})
    ])
  end

  @doc """
  Places every area in `memberships` into one release, in one round trip.

  Each map carries `:area_key`, `:centroid`, and optional `:attributes`.
  Membership is last-write-wins, so an area named twice in one batch keeps the
  last of the two, exactly as two `put_area_in_release/4` calls would leave it.

  Returns `:ok` without touching the database for an empty list, having
  validated `release_id` first, so a malformed release id fails the way it
  would for a batch that had rows.
  """
  @spec put_area_in_release_many(Context.t(), Ecto.UUID.t(), [map()]) :: :ok
  def put_area_in_release_many(context, release_id, memberships)

  def put_area_in_release_many(%Context{}, release_id, []) do
    dump_uuid(release_id)
    :ok
  end

  def put_area_in_release_many(%Context{} = context, release_id, memberships) do
    void(context, "put_area_in_release_many", "$1, $2, $3, $4", [
      dump_uuid(release_id),
      Enum.map(memberships, &Map.fetch!(&1, :area_key)),
      Enum.map(memberships, &Map.fetch!(&1, :centroid)),
      Enum.map(memberships, &Map.get(&1, :attributes, %{}))
    ])
  end

  @doc """
  Attaches a boundary geometry to an area within a release, attributed to the
  source release it came from.

  A zero or omitted `:simplify_tolerance` uses the set-based boundary path.
  A nonzero tolerance retains the singular SQL path so existing callers keep
  its display-geometry simplification behavior.
  """
  @spec put_boundary(Context.t(), Ecto.UUID.t(), String.t(), map()) :: :ok
  def put_boundary(%Context{} = context, release_id, area_key, attrs) do
    case Map.get(attrs, :simplify_tolerance, 0.0) do
      tolerance when tolerance in [0, 0.0] ->
        put_boundaries(context, release_id, [Map.put(attrs, :area_key, area_key)])

      tolerance ->
        void(context, "put_boundary", "$1, $2, $3, $4, $5", [
          dump_uuid(release_id),
          area_key,
          dump_uuid(Map.fetch!(attrs, :source_release_id)),
          Map.fetch!(attrs, :geometry),
          tolerance
        ])
    end
  end

  @doc """
  Attaches every boundary in `boundaries` within one release, in one round trip.

  Each map carries `:area_key`, `:source_release_id`, and `:geometry`, with
  optional `:display_tier` and `:source_properties`. A repeated area key keeps
  its last boundary, matching the state left by scalar writes in caller order.

  Returns `:ok` without touching the database for an empty list, having
  validated `release_id` first.
  """
  @spec put_boundaries(Context.t(), Ecto.UUID.t(), [map()]) :: :ok
  def put_boundaries(context, release_id, boundaries)

  def put_boundaries(%Context{}, release_id, []) do
    dump_uuid(release_id)
    :ok
  end

  def put_boundaries(%Context{} = context, release_id, boundaries) do
    void(
      context,
      "put_boundaries",
      "$1::uuid, $2::text[], $3::uuid[], $4::geometry[], $5::integer[], $6::jsonb[]",
      [
        dump_uuid(release_id),
        Enum.map(boundaries, &Map.fetch!(&1, :area_key)),
        Enum.map(boundaries, &(&1 |> Map.fetch!(:source_release_id) |> dump_uuid())),
        Enum.map(boundaries, &Map.fetch!(&1, :geometry)),
        Enum.map(boundaries, &Map.get(&1, :display_tier, 0)),
        Enum.map(boundaries, &Map.get(&1, :source_properties, %{}))
      ]
    )
  end

  @doc "Asserts a relation between two areas within a release."
  @spec put_relation(Context.t(), Ecto.UUID.t(), map()) :: :ok
  def put_relation(%Context{} = context, release_id, attrs) do
    void(context, "put_relation", "$1, $2, $3, $4", [
      dump_uuid(release_id),
      Map.fetch!(attrs, :parent_area_key),
      Map.fetch!(attrs, :child_area_key),
      Map.fetch!(attrs, :relation_type)
    ])
  end

  @doc """
  Asserts every relation in `relations` within one release, in one round trip.

  Each map carries `:parent_area_key`, `:child_area_key`, and
  `:relation_type`. A pair asserted twice in one batch keeps the last
  `:relation_type`, the way two `put_relation/3` calls would leave it.

  Returns `:ok` without touching the database for an empty list, having
  validated `release_id` first.
  """
  @spec put_relation_many(Context.t(), Ecto.UUID.t(), [map()]) :: :ok
  def put_relation_many(context, release_id, relations)

  def put_relation_many(%Context{}, release_id, []) do
    dump_uuid(release_id)
    :ok
  end

  def put_relation_many(%Context{} = context, release_id, relations) do
    void(context, "put_relation_many", "$1, $2, $3, $4", [
      dump_uuid(release_id),
      Enum.map(relations, &Map.fetch!(&1, :parent_area_key)),
      Enum.map(relations, &Map.fetch!(&1, :child_area_key)),
      Enum.map(relations, &Map.fetch!(&1, :relation_type))
    ])
  end

  @doc """
  Rebuilds a release's transitive relations, returning how many rows were
  written.

  One statement measures every pair in the release, so this is among the
  longest calls in the library. `opts` reaches `Repo.query/3`, which is how a
  caller raises `:timeout` past DBConnection's fifteen-second default for a
  release large enough to need it.
  """
  @spec rebuild_relations(Context.t(), Ecto.UUID.t(), keyword()) :: integer()
  def rebuild_relations(%Context{} = context, release_id, opts \\ []) do
    value(context, "rebuild_relations", "$1", [dump_uuid(release_id)], opts)
  end

  @doc """
  Checks a release's structural invariants, returning a report rather than
  raising.

  Every check runs in one statement across every area and boundary in the
  release, so `opts` reaches `Repo.query/3` the same way `rebuild_relations/3`
  passes a `:timeout` through.
  """
  @spec verify_release(Context.t(), Ecto.UUID.t(), keyword()) :: map()
  def verify_release(%Context{} = context, release_id, opts \\ []) do
    value(context, "verify_release", "$1", [dump_uuid(release_id)], opts)
  end

  @doc """
  Publishes a release, returning the id of the collection it publishes into.

  The SQL function re-runs `verify_release` as its first act, so a publication
  costs whatever that release's verification costs. `opts` reaches
  `Repo.query/3` for the same reason it does on `rebuild_relations/3`,
  `verify_release/3`, and `analyze_release/3`: a release large enough to need
  more than DBConnection's fifteen-second default has no other way to ask for
  it.
  """
  @spec publish_release(Context.t(), Ecto.UUID.t(), keyword()) :: Ecto.UUID.t()
  def publish_release(%Context{} = context, release_id, opts \\ []) do
    scalar(context, "publish_release", "$1", [dump_uuid(release_id)], opts)
  end

  @doc """
  Rolls a collection's publication back to its previous release, returning
  the collection's id on success.

  Returns `nil` for a collection key the catalog does not carry, since a
  caller cannot distinguish that from "nothing to roll back" by the key
  alone. Raises when the collection exists but has no previous release: that
  is an operator error worth surfacing rather than a silent no-op.
  """
  @spec rollback_publication(Context.t(), String.t()) :: Ecto.UUID.t() | nil
  def rollback_publication(%Context{} = context, collection_key) do
    scalar(context, "rollback_publication", "$1", [collection_key])
  end

  @doc """
  Drops the bulk data of every release beyond the newest `keep`, returning how
  many were retired.

  The release rows survive: `publication_event` and `import_run` reference
  them, and both are kept indefinitely. Only the partitions holding geometry,
  membership, and relations go.
  """
  @spec retire_releases(Context.t(), String.t(), pos_integer()) :: non_neg_integer()
  def retire_releases(%Context{} = context, collection_key, keep) do
    value(context, "retire_releases", "$1, $2", [collection_key, keep])
  end

  @doc "The currently published release for a collection, or `nil` if none is published."
  @spec published_release(Context.t(), String.t()) :: Ecto.UUID.t() | nil
  def published_release(%Context{} = context, collection_key) do
    scalar(context, "published_release", "$1", [collection_key])
  end

  @doc """
  Claims a fresh or existing import run for a release, returning its id.

  `:stale_after_seconds` is a plain number rather than an interval string, so
  a caller holds an integer instead of assembling `"\#{n} seconds"` at every
  call site -- the one place that string gets built is here.
  """
  @spec begin_or_resume_import(Context.t(), Ecto.UUID.t(), map()) :: Ecto.UUID.t()
  def begin_or_resume_import(%Context{} = context, release_id, attrs) do
    stale_after_seconds = Map.get(attrs, :stale_after_seconds, 900)

    # `$4` is left untyped rather than cast directly (`$4::interval`), because
    # a direct cast on a bare parameter fixes its expected wire type to
    # interval and Postgrex has no interval literal to encode a plain number
    # as. Concatenating with a text literal first types `$4` as text instead,
    # so a caller's integer seconds still crosses as an ordinary bound value.
    scalar(context, "begin_or_resume_import", "$1, $2, $3, ($4 || ' seconds')::interval", [
      dump_uuid(release_id),
      Map.fetch!(attrs, :owner),
      Map.fetch!(attrs, :runner_backend),
      to_string(stale_after_seconds)
    ])
  end

  @doc "Merges a progress patch into a run's active lease."
  @spec heartbeat_import(Context.t(), Ecto.UUID.t(), map()) :: :ok
  def heartbeat_import(%Context{} = context, run_id, progress_patch) do
    void(context, "heartbeat_import", "$1, $2", [dump_uuid(run_id), progress_patch])
  end

  @doc "Advances a run to its next status, merging a metrics patch into its stage metrics."
  @spec advance_import(Context.t(), Ecto.UUID.t(), String.t(), map()) :: :ok
  def advance_import(%Context{} = context, run_id, next_status, metrics_patch) do
    void(context, "advance_import", "$1, $2, $3", [
      dump_uuid(run_id),
      next_status,
      metrics_patch
    ])
  end

  @doc """
  Marks a run failed, storing its error detail.

  Raises 55000 for a run that has completed. Idempotent on one that already
  failed.
  """
  @spec fail_import(Context.t(), Ecto.UUID.t(), map()) :: :ok
  def fail_import(%Context{} = context, run_id, error_detail) do
    void(context, "fail_import", "$1, $2", [dump_uuid(run_id), error_detail])
  end

  @doc "One import run, or nil when no run carries that id."
  @spec import_run(Context.t(), Ecto.UUID.t()) :: ImportRun.t() | nil
  def import_run(%Context{} = context, run_id) do
    sql =
      "SELECT #{@view_columns} FROM \"#{context.prefix}\".import_run_status WHERE run_id = $1"

    read(context, sql, [dump_uuid(run_id)], "import_run", fn result ->
      result |> ImportRun.from_result() |> List.first()
    end)
  end

  @doc "Every import run recorded for a collection, most recently started first."
  @spec import_runs(Context.t(), String.t()) :: [ImportRun.t()]
  def import_runs(%Context{} = context, collection_key) do
    sql =
      "SELECT #{@view_columns} FROM \"#{context.prefix}\".import_run_status " <>
        "WHERE collection_key = $1 ORDER BY started_at DESC"

    read(context, sql, [collection_key], "import_runs", &ImportRun.from_result/1)
  end

  @doc "Creates or updates a source within a collection, returning its id."
  @spec upsert_source(Context.t(), String.t(), map()) :: Ecto.UUID.t()
  def upsert_source(%Context{} = context, collection_key, attrs) do
    scalar(context, "upsert_source", "$1, $2, $3, $4", [
      collection_key,
      Map.fetch!(attrs, :source_key),
      Map.fetch!(attrs, :provider),
      Map.fetch!(attrs, :license)
    ])
  end

  @doc "Creates or updates a source release, returning its id."
  @spec upsert_source_release(Context.t(), String.t(), map()) :: Ecto.UUID.t()
  def upsert_source_release(%Context{} = context, collection_key, attrs) do
    scalar(context, "upsert_source_release", "$1, $2, $3, $4, $5", [
      collection_key,
      Map.fetch!(attrs, :source_key),
      Map.fetch!(attrs, :release_key),
      Map.get(attrs, :source_date),
      Map.get(attrs, :metadata, %{})
    ])
  end

  @doc """
  Records an artifact belonging to a source release, returning its id.

  `:expected_sha256` and `:expected_bytes` come from the reviewed manifest and
  are what `record_artifact_observation/3` later checks a download against.
  """
  @spec put_artifact(Context.t(), Ecto.UUID.t(), map()) :: Ecto.UUID.t()
  def put_artifact(%Context{} = context, source_release_id, attrs) do
    scalar(context, "put_artifact", "$1, $2, $3, $4, $5, $6, $7, $8", [
      dump_uuid(source_release_id),
      Map.fetch!(attrs, :logical_name),
      Map.get(attrs, :url),
      Map.get(attrs, :operator_supplied, false),
      Map.fetch!(attrs, :format),
      Map.fetch!(attrs, :expected_sha256),
      Map.fetch!(attrs, :expected_bytes),
      Map.get(attrs, :metadata, %{})
    ])
  end

  @doc """
  Records what a download actually produced, checking it against the
  artifact's manifest expectation.
  """
  @spec record_artifact_observation(Context.t(), Ecto.UUID.t(), map()) :: :ok
  def record_artifact_observation(%Context{} = context, artifact_id, attrs) do
    void(context, "record_artifact_observation", "$1, $2, $3", [
      dump_uuid(artifact_id),
      Map.fetch!(attrs, :observed_sha256),
      Map.fetch!(attrs, :observed_bytes)
    ])
  end

  @doc """
  Opens a release for a collection with its reviewed manifest, returning its
  id. Reopening the same, still-unpublished release returns the same id.
  """
  @spec open_release(Context.t(), String.t(), map()) :: Ecto.UUID.t()
  def open_release(%Context{} = context, collection_key, attrs) do
    scalar(context, "open_release", "$1, $2, $3, $4", [
      collection_key,
      Map.fetch!(attrs, :release_key),
      Map.fetch!(attrs, :manifest),
      Map.get(attrs, :source_date)
    ])
  end

  @doc "Attaches a source release to a release, so the release composes it."
  @spec attach_source_release(Context.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def attach_source_release(%Context{} = context, release_id, source_release_id) do
    void(context, "attach_source_release", "$1, $2", [
      dump_uuid(release_id),
      dump_uuid(source_release_id)
    ])
  end

  @doc """
  The manifest a release was opened with, as a decoded map.

  The pipeline rebuilds its manifest from here rather than re-reading the file,
  so a resumed or retried run uses the document the release was opened with
  even if the file on disk has since changed.
  """
  @spec release_manifest(Context.t(), Ecto.UUID.t()) :: map() | nil
  def release_manifest(%Context{} = context, release_id) do
    sql = "SELECT manifest FROM \"#{context.prefix}\".release WHERE id = $1"

    read(context, sql, [dump_uuid(release_id)], "release_manifest", fn
      %Postgrex.Result{rows: [[manifest]]} -> manifest
      %Postgrex.Result{rows: []} -> nil
    end)
  end

  @doc """
  Every artifact the release composes, with the source release each is
  attributed to. Reads the `release_artifacts` view.

  Each map carries string keys matching the view's columns: `"release_id"`,
  `"artifact_id"`, `"source_release_id"`, `"source_key"`,
  `"source_release_key"`, `"collection_key"`, `"logical_name"`, `"url"`,
  `"operator_supplied"`, `"format"`, `"expected_sha256"`, `"expected_bytes"`,
  `"observed_sha256"`, `"observed_bytes"`, `"validated_at"`, and `"metadata"`.
  The two uuid columns are cast to text. Ordered by `logical_name`, so a caller
  reading a release twice sees the same sequence: the view carries no ordering
  of its own, and a caller that needs one has no way to add it.
  """
  @spec release_artifacts(Context.t(), Ecto.UUID.t()) :: [map()]
  def release_artifacts(%Context{} = context, release_id) do
    sql =
      "SELECT #{@artifact_columns} FROM \"#{context.prefix}\".release_artifacts " <>
        "WHERE release_id = $1 ORDER BY logical_name"

    read(context, sql, [dump_uuid(release_id)], "release_artifacts", &rows_to_maps/1)
  end

  @doc """
  The key of the collection a release belongs to, or `nil` for a release id the
  catalog does not carry.

  A release id reaching the catalog from outside -- one a host stored, or one
  passed as a `:release_id` option -- says nothing about which collection it
  belongs to, and every release-scoped read filters on the id alone. This is
  how a caller checks that the id it was handed is a release of the collection
  it means, rather than reading another collection's rows under its own name.
  """
  @spec release_collection_key(Context.t(), Ecto.UUID.t()) :: String.t() | nil
  def release_collection_key(%Context{} = context, release_id) do
    sql =
      "SELECT collection.key FROM \"#{context.prefix}\".release " <>
        "JOIN \"#{context.prefix}\".collection ON collection.id = release.collection_id " <>
        "WHERE release.id = $1"

    read(context, sql, [dump_uuid(release_id)], "release_collection_key", fn
      %Postgrex.Result{rows: [[collection_key]]} -> collection_key
      %Postgrex.Result{rows: []} -> nil
    end)
  end

  @doc "Creates a release's staging table, returning its name."
  @spec create_staging(Context.t(), Ecto.UUID.t()) :: String.t()
  def create_staging(%Context{} = context, run_id) do
    value(context, "create_staging", "$1", [dump_uuid(run_id)])
  end

  @doc "Drops a run's staging table, if it exists."
  @spec drop_staging(Context.t(), Ecto.UUID.t()) :: :ok
  def drop_staging(%Context{} = context, run_id) do
    void(context, "drop_staging", "$1", [dump_uuid(run_id)])
  end

  @doc """
  Runs ANALYZE against a release's partitions.

  A national release analyzes tables holding hundreds of thousands of rows in
  one statement, so `opts` reaches `Repo.query/3` here too.
  """
  @spec analyze_release(Context.t(), Ecto.UUID.t(), keyword()) :: :ok
  def analyze_release(%Context{} = context, release_id, opts \\ []) do
    void(context, "analyze_release", "$1", [dump_uuid(release_id)], opts)
  end

  # Every uuid is projected as text so it crosses as the hyphenated string the
  # read layer returns and accepts, rather than as the sixteen raw bytes
  # Postgrex decodes a uuid into.
  defp scalar(%Context{} = context, function, placeholders, params, opts \\ []) do
    sql =
      "SELECT #{function}::text AS #{function} " <>
        "FROM \"#{context.prefix}\".#{function}(#{placeholders}) AS #{function}"

    single(context.repo, sql, params, function, opts)
  end

  # The plural writes return one id per input position as a uuid[]. Casting the
  # whole array to text[] in SQL means Postgrex decodes it as the list of
  # hyphenated strings every other id crosses this module as, rather than as a
  # list of raw sixteen-byte binaries.
  defp scalar_list(%Context{} = context, function, placeholders, params, opts \\ []) do
    sql =
      "SELECT #{function}::text[] AS #{function} " <>
        "FROM \"#{context.prefix}\".#{function}(#{placeholders}) AS #{function}"

    single(context.repo, sql, params, function, opts)
  end

  defp value(%Context{} = context, function, placeholders, params, opts \\ []) do
    sql = "SELECT \"#{context.prefix}\".#{function}(#{placeholders}) AS result"
    single(context.repo, sql, params, function, opts)
  end

  defp void(%Context{} = context, function, placeholders, params, opts \\ []) do
    sql = "SELECT \"#{context.prefix}\".#{function}(#{placeholders})"

    case run(context.repo, sql, params, opts) do
      {:ok, _result} -> :ok
      {:error, reason} -> raise GeoGenius.CatalogError, function: function, reason: reason
    end
  end

  # `scalar/4` and `value/4` differ only in how they build the call's SQL --
  # one invokes the function as a row source to cast its result to text, the
  # other calls it directly -- so both reduce to reading the single column of
  # the single row a scalar-returning function produces.
  defp single(repo, sql, params, function, opts) do
    case run(repo, sql, params, opts) do
      {:ok, %Postgrex.Result{rows: [[value]]}} -> value
      {:ok, %Postgrex.Result{rows: []}} -> nil
      {:error, reason} -> raise GeoGenius.CatalogError, function: function, reason: reason
    end
  end

  # `import_run/2`, `import_runs/2`, `release_manifest/2`, and
  # `release_artifacts/2` each run a query and then shape the result
  # differently -- a single struct, a list of structs, a raw scalar, or a
  # list of plain maps -- so this shares the run-and-raise plumbing and takes
  # the shaping as a function rather than duplicating it four times.
  defp read(%Context{} = context, sql, params, function, transform) do
    case run(context.repo, sql, params) do
      {:ok, result} -> transform.(result)
      {:error, reason} -> raise GeoGenius.CatalogError, function: function, reason: reason
    end
  end

  # Only the calls a host may need to give more time pass `opts` through; every
  # other call runs on the Repo's own default, since a read of one run or one
  # release's artifacts is a single indexed lookup.
  defp run(repo, sql, params, opts \\ []) do
    repo.query(sql, params, opts)
  rescue
    error -> {:error, error}
  end

  # `release_artifacts/2` has no struct of its own to map into -- callers
  # read its rows as plain maps -- so each row becomes column name to value,
  # rather than a positional or struct mapping neither one needs.
  defp rows_to_maps(%Postgrex.Result{columns: columns, rows: rows}) do
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end

  # Postgrex binds a `uuid` parameter only from sixteen raw bytes, while every
  # function here returns and accepts the hyphenated string. The read layer
  # already does this conversion and is public for this reason, so this
  # delegates rather than carrying a second copy that could drift.
  defp dump_uuid(uuid), do: Postgres.dump_uuid(uuid)
end
