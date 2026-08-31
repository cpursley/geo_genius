defmodule GeoGenius.SchemaContract do
  @moduledoc false

  alias EctoEvolver.Adapters.Postgres

  @capabilities [
    "boundary_batches",
    "boundary_canonical_repair_once",
    "boundary_collection_provenance",
    "boundary_publication_serialization",
    "reversible_legacy_v01_reconciliation",
    "type_scoped_geometry_requirements"
  ]

  @signatures [
    "publish_release(uuid)->uuid",
    "put_boundaries(uuid,text[],uuid[],geometry[],integer[],jsonb[])->void",
    "put_boundary(uuid,text,uuid,geometry,double precision)->void",
    "upsert_area_type(text,text,integer)->uuid",
    "upsert_area_type(text,text,integer,boolean)->uuid",
    "verify_release(uuid)->jsonb"
  ]

  @relation_metadata [
    "area_type:ordinary_table",
    "area_type.requires_geometry:boolean:not_null:default_false"
  ]

  @function_names ~w(publish_release put_boundaries put_boundary upsert_area_type verify_release)

  @canonical_manifest Enum.map_join(
                        ["schema_version=1"] ++
                          Enum.map(@capabilities, &"capability=#{&1}") ++
                          Enum.map(@signatures, &"signature=#{&1}") ++
                          Enum.map(@relation_metadata, &"relation_metadata=#{&1}"),
                        "\n",
                        & &1
                      ) <> "\n"

  @revision "sha256:" <>
              (:crypto.hash(:sha256, @canonical_manifest) |> Base.encode16(case: :lower))

  @reviewed_revision "sha256:8c5adea2c1fab08fdbc67137ff99ea0864c69a3dff5a3952dd9d6e62d971ab25"

  @reviewed_capabilities [
    "boundary_batches",
    "boundary_canonical_repair_once",
    "boundary_collection_provenance",
    "boundary_publication_serialization",
    "reversible_legacy_v01_reconciliation"
  ]

  @reviewed_fingerprints [
    {"publish_release(target_release_id uuid)->uuid", "1fbc7b4e627418afc2447f9be28b26c9"},
    {"put_boundaries(target_release_id uuid, target_area_keys text[], target_source_release_ids uuid[], input_geometries geometry[], display_tiers integer[], source_properties_values jsonb[])->void",
     "729ab418df06c7b04fe7ff8278e308cb"},
    {"put_boundary(target_release_id uuid, target_area_key text, target_source_release_id uuid, input_geom geometry, simplify_tolerance double precision)->void",
     "6c580e90b02cfbb5f983fe9bbb49c052"},
    {"upsert_area_type(collection_key text, key text, rank integer)->uuid",
     "d8fd4afb9182614ee9aec5707ae4c774"},
    {"verify_release(target_release_id uuid)->jsonb", "5a3e77d9be44a97d9fff105107fee614"}
  ]

  @target_fingerprints [
    {"publish_release(target_release_id uuid)->uuid", "1fbc7b4e627418afc2447f9be28b26c9"},
    {"put_boundaries(target_release_id uuid, target_area_keys text[], target_source_release_ids uuid[], input_geometries geometry[], display_tiers integer[], source_properties_values jsonb[])->void",
     "729ab418df06c7b04fe7ff8278e308cb"},
    {"put_boundary(target_release_id uuid, target_area_key text, target_source_release_id uuid, input_geom geometry, simplify_tolerance double precision)->void",
     "6c580e90b02cfbb5f983fe9bbb49c052"},
    {"upsert_area_type(collection_key text, key text, rank integer)->uuid",
     "80f054a72417218c3fe5ecf7dc44a9d9"},
    {"upsert_area_type(collection_key text, key text, rank integer, requires_geometry boolean)->uuid",
     "c600390eed3b8c5551084bcc7ef902a9"},
    {"verify_release(target_release_id uuid)->jsonb", "31bc47c8b82ca9d802cc22f95325e6d4"}
  ]

  @target_relation_metadata [
    {"area_type", "958113835e7c799371edd8063ae7c206"},
    {"area_type.requires_geometry", "ebc65b5bd8edf9693e6a23213d20bbb9"}
  ]

  @absent_relation_metadata [
    {"area_type", "958113835e7c799371edd8063ae7c206"},
    {"area_type.requires_geometry", "absent"}
  ]

  @legacy_fingerprints [
    {"publish_release(target_release_id uuid)->uuid", "f5a9d32e6a27126aef1513e31f4c71c1"},
    {"put_boundary(target_release_id uuid, target_area_key text, target_source_release_id uuid, input_geom geometry, simplify_tolerance double precision)->void",
     "2aca7d62b40acffd8f861f7961439e30"},
    {"upsert_area_type(collection_key text, key text, rank integer)->uuid",
     "d8fd4afb9182614ee9aec5707ae4c774"},
    {"verify_release(target_release_id uuid)->jsonb", "5a3e77d9be44a97d9fff105107fee614"}
  ]

  @doc false
  def manifest do
    %{
      schema_version: 1,
      capabilities: @capabilities,
      signatures: @signatures,
      relation_metadata: @relation_metadata
    }
  end

  @doc false
  def canonical_manifest, do: @canonical_manifest

  @doc false
  def revision, do: @revision

  @doc false
  def capabilities, do: @capabilities

  @doc false
  def target_fingerprints, do: @target_fingerprints

  @doc false
  def legacy_fingerprints, do: @legacy_fingerprints

  @doc false
  def status(repo, prefix) do
    prefix = validate_prefix!(prefix)
    version = GeoGenius.Migration.installed_version(repo, prefix)

    if version == 0 do
      status(:not_installed, version, nil, [], [], "install GeoGenius schema v1")
    else
      marker = marker(repo, prefix)
      fingerprints = fingerprints(repo, prefix)
      relation_metadata = relation_metadata(repo, prefix)
      signatures = signatures(repo, prefix)

      classify(version, marker, fingerprints, relation_metadata, signatures, prefix)
    end
  end

  @doc false
  def validate_prefix!(prefix) when is_binary(prefix) do
    cond do
      prefix in ~w(public information_schema pg_catalog pg_toast pg_temp) ->
        raise ArgumentError, "PostgreSQL prefix #{inspect(prefix)} is reserved"

      String.starts_with?(prefix, "pg_") ->
        raise ArgumentError, "PostgreSQL prefix #{inspect(prefix)} is reserved"

      prefix == "" or byte_size(prefix) > 63 or not String.valid?(prefix) or
          String.contains?(prefix, "\0") ->
        raise ArgumentError, "invalid PostgreSQL prefix"

      true ->
        prefix
    end
  end

  def validate_prefix!(_prefix), do: raise(ArgumentError, "PostgreSQL prefix must be a string")

  defp classify(1, nil, fingerprints, relation_metadata, signatures, prefix) do
    if fingerprints == @legacy_fingerprints and
         relation_metadata == @absent_relation_metadata do
      status(
        :legacy_unmarked,
        1,
        :legacy_v01_aebc28a,
        [],
        @capabilities,
        reconciliation_remedy(prefix, :legacy_v01_aebc28a, @revision)
      )
    else
      drift_status(1, nil, signatures, prefix)
    end
  end

  defp classify(
         1,
         %{schema_version: 1, revision: @reviewed_revision, capabilities: @reviewed_capabilities},
         fingerprints,
         relation_metadata,
         signatures,
         prefix
       ) do
    if fingerprints == @reviewed_fingerprints and
         relation_metadata == @absent_relation_metadata do
      status(
        :reviewed_v01,
        1,
        @reviewed_revision,
        @reviewed_capabilities,
        @capabilities -- @reviewed_capabilities,
        reconciliation_remedy(prefix, @reviewed_revision, @revision)
      )
    else
      drift_status(
        1,
        %{revision: @reviewed_revision, capabilities: @reviewed_capabilities},
        signatures,
        prefix
      )
    end
  end

  defp classify(
         1,
         %{schema_version: 1, revision: @revision, capabilities: @capabilities},
         @target_fingerprints,
         @target_relation_metadata,
         @signatures,
         _prefix
       ) do
    status(:compatible, 1, @revision, @capabilities, [], nil)
  end

  defp classify(version, marker, _fingerprints, _relation_metadata, signatures, prefix) do
    drift_status(version, marker, signatures, prefix)
  end

  defp drift_status(version, marker, signatures, prefix) do
    installed_revision = if match?(%{revision: _}, marker), do: marker.revision, else: nil
    missing = @signatures -- signatures

    status(
      :drifted,
      version,
      installed_revision,
      if(match?(%{capabilities: _}, marker), do: marker.capabilities, else: []),
      missing,
      "schema #{prefix} does not match a supported GeoGenius contract; inspect drift before reconciliation"
    )
  end

  defp status(kind, version, installed_revision, capabilities, missing, remedy) do
    %{
      status: kind,
      compatible?: kind == :compatible,
      schema_version: version,
      installed_revision: installed_revision,
      expected_revision: @revision,
      capabilities: capabilities,
      required_capabilities: @capabilities,
      missing: missing,
      remedy: remedy
    }
  end

  defp marker(repo, prefix) do
    case repo.query!(
           """
           SELECT c.relkind
             FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = 'geo_genius_contract'
           """,
           [prefix],
           log: false
         ).rows do
      [] ->
        nil

      [["v"]] ->
        read_marker(repo, prefix)

      [[kind]] ->
        %{malformed: {:relation_kind, kind}}
    end
  end

  defp read_marker(repo, prefix) do
    expected_columns = [
      ["schema_version", "integer"],
      ["contract_revision", "text"],
      ["capabilities", "text[]"]
    ]

    %{rows: columns} =
      repo.query!(
        """
        SELECT a.attname, format_type(a.atttypid, a.atttypmod)
          FROM pg_attribute a
          JOIN pg_class c ON c.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = $1
           AND c.relname = 'geo_genius_contract'
           AND c.relkind = 'v'
           AND a.attnum > 0
           AND NOT a.attisdropped
         ORDER BY a.attnum
        """,
        [prefix],
        log: false
      )

    if columns == expected_columns do
      escaped = Postgres.escape_identifier(prefix)

      case repo.query!(
             "SELECT schema_version, contract_revision, capabilities FROM #{escaped}.geo_genius_contract",
             [],
             log: false
           ).rows do
        [[schema_version, revision, capabilities]]
        when is_integer(schema_version) and is_binary(revision) and is_list(capabilities) ->
          %{schema_version: schema_version, revision: revision, capabilities: capabilities}

        rows ->
          %{malformed: {:row_count, length(rows)}}
      end
    else
      %{malformed: {:columns, columns}}
    end
  end

  defp fingerprints(repo, prefix) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT
          p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')->' ||
            pg_get_function_result(p.oid) AS identity,
          md5(
            p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')->' ||
              pg_get_function_result(p.oid) ||
            '|arguments=' || pg_get_function_arguments(p.oid) ||
            '|language=' || l.lanname ||
            '|volatility=' || p.provolatile::text ||
            '|security_definer=' || p.prosecdef::text ||
            '|strict=' || p.proisstrict::text ||
            '|parallel=' || p.proparallel::text ||
            '|leakproof=' || p.proleakproof::text ||
            '|config=' || replace(
              coalesce(array_to_string(p.proconfig, E'\\x1f'), ''),
              format('%I', n.nspname),
              '$SCHEMA$'
            ) ||
            '|body=' || replace(p.prosrc, format('%I.', n.nspname), '$SCHEMA$.')
          ) AS fingerprint
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
          JOIN pg_language l ON l.oid = p.prolang
         WHERE n.nspname = $1
           AND p.proname = ANY($2)
         ORDER BY identity
        """,
        [prefix, @function_names],
        log: false
      )

    Enum.map(rows, fn [identity, fingerprint] -> {identity, fingerprint} end)
  end

  defp relation_metadata(repo, prefix) do
    %{rows: rows} =
      repo.query!(
        """
        WITH relation AS (
          SELECT c.oid, c.relkind::text AS relkind
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = $1
             AND c.relname = 'area_type'
        ),
        attribute AS (
          SELECT
            a.attname,
            format_type(a.atttypid, a.atttypmod) AS data_type,
            a.attnotnull,
            pg_get_expr(d.adbin, d.adrelid) AS column_default
          FROM relation r
          LEFT JOIN pg_attribute a
            ON a.attrelid = r.oid
           AND a.attname = 'requires_geometry'
           AND a.attnum > 0
           AND NOT a.attisdropped
          LEFT JOIN pg_attrdef d
            ON d.adrelid = r.oid
           AND d.adnum = a.attnum
          WHERE r.relkind = 'r'
        )
        SELECT
          identity,
          fingerprint
        FROM (
          SELECT
            'area_type' AS identity,
            CASE
              WHEN count(*) = 0 THEN 'absent'
              ELSE md5('area_type|relkind=' || max(relkind))
            END AS fingerprint
          FROM relation
          UNION ALL
          SELECT
            'area_type.requires_geometry' AS identity,
            CASE
              WHEN NOT EXISTS (SELECT 1 FROM relation WHERE relkind = 'r') THEN 'no_ordinary_table'
              WHEN count(attname) = 0 THEN 'absent'
              ELSE md5(
                'area_type.requires_geometry' ||
                '|type=' || max(data_type) ||
                '|not_null=' || bool_and(attnotnull)::text ||
                '|default=' || coalesce(max(column_default), '')
              )
            END AS fingerprint
          FROM attribute
        ) AS metadata
        ORDER BY identity
        """,
        [prefix],
        log: false
      )

    Enum.map(rows, fn [identity, fingerprint] -> {identity, fingerprint} end)
  end

  defp signatures(repo, prefix) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT p.proname || '(' || replace(oidvectortypes(p.proargtypes), ', ', ',') ||
               ')->' || format_type(p.prorettype, NULL)
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = $1
           AND p.proname = ANY($2)
         ORDER BY 1
        """,
        [prefix, @function_names],
        log: false
      )

    List.flatten(rows)
  end

  defp reconciliation_remedy(prefix, from, to) do
    "mix geo_genius.reconciliation_sql --prefix #{shell_quote(prefix)} --from #{from} --to #{to}"
  end

  defp shell_quote(argument), do: "'" <> String.replace(argument, "'", "'\"'\"'") <> "'"
end
