defmodule GeoGenius.SchemaContractTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Migration
  alias GeoGenius.SchemaContract

  @capabilities [
    "artifact_observation_publication_gate",
    "atomic_failed_candidate_retry",
    "atomic_import_completion",
    "atomic_import_publication",
    "boundary_batches",
    "boundary_canonical_repair_once",
    "boundary_collection_provenance",
    "boundary_publication_serialization",
    "exact_attempt_artifact_snapshots",
    "exact_attempt_manifest_snapshots",
    "executor_fenced_staging_cleanup",
    "failed_candidate_requires_explicit_retry",
    "idempotent_executor_reclaim",
    "immutable_failure_evidence",
    "publication_constraint_triggers",
    "release_retention_preserves_history",
    "release_scoped_catalog_declarations",
    "run_fenced_ingestion",
    "single_executor_import_claim",
    "strict_import_phase_transitions",
    "type_scoped_geometry_requirements"
  ]

  @signatures Enum.sort([
                "advance_import(uuid,uuid,text,jsonb)->void",
                "analyze_import(uuid,uuid)->void",
                "analyze_release(uuid)->void",
                "assert_import_write(uuid,uuid,text[])->uuid",
                "assert_required_artifact_observations(uuid)->void",
                "assert_release_mutable(uuid)->void",
                "attach_artifact(uuid,uuid)->void",
                "attach_source_release(uuid,uuid)->void",
                "claim_import_execution(uuid,uuid)->text",
                "complete_import(uuid,uuid,jsonb)->uuid",
                "create_release_partitions(uuid)->void",
                "create_staging(uuid,uuid)->text",
                "drop_release_partitions(uuid)->void",
                "drop_staging(uuid)->void",
                "drop_staging(uuid,uuid)->void",
                "fail_import(uuid,uuid,jsonb)->void",
                "heartbeat_import(uuid,uuid,jsonb)->void",
                "insert_staging_many(uuid,uuid,text[],jsonb[],geometry[])->bigint",
                "open_release(text,text,jsonb,date)->uuid",
                "prepare_import(jsonb,jsonb)->record",
                "partition_lock_key()->bigint",
                "publication_lock_key(text)->bigint",
                "publication_release_is_publishable()->trigger",
                "publish_import(uuid,uuid)->uuid",
                "publish_release(uuid)->uuid",
                "published_release(text)->uuid",
                "put_area_code(uuid,uuid,text,text,text)->uuid",
                "put_area_code_many(uuid,uuid,text[],text[],text[])->uuid[]",
                "put_area_in_release(uuid,uuid,text,geography,jsonb)->void",
                "put_area_in_release_many(uuid,uuid,text[],geography[],jsonb[])->void",
                "put_area_name(uuid,uuid,text,text,text,text)->uuid",
                "put_area_name_many(uuid,uuid,text[],text[],text[],text[])->uuid[]",
                "put_artifact(uuid,text,text,boolean,text,text,bigint,jsonb)->uuid",
                "put_boundaries(uuid,uuid,text[],uuid[],geometry[],integer[],jsonb[])->void",
                "put_boundary(uuid,uuid,text,uuid,geometry,double precision)->void",
                "put_relation(uuid,uuid,text,text,text)->void",
                "put_relation_many(uuid,uuid,text[],text[],text[])->void",
                "rebuild_relations(uuid,uuid)->bigint",
                "record_artifact_observation(uuid,uuid,uuid,text,bigint)->void",
                "relation_lock_key(uuid)->bigint",
                "release_at(text,timestamp with time zone)->uuid",
                "release_lock_key(text,text)->bigint",
                "retry_failed(uuid,jsonb,jsonb)->record",
                "retire_releases(text,integer)->integer",
                "rollback_publication(text)->uuid",
                "upsert_area(text,text,text,text)->uuid",
                "upsert_area_many(text,text[],text[],text[])->uuid[]",
                "upsert_area_many(uuid,uuid,text[],text[],text[])->uuid[]",
                "upsert_area_type(text,text,integer)->uuid",
                "upsert_area_type(text,text,integer,boolean)->uuid",
                "upsert_authority(text,text,text)->uuid",
                "upsert_collection(text,text,text,boolean)->uuid",
                "upsert_source(text,text,text,text)->uuid",
                "upsert_source_release(text,text,text,date,jsonb)->uuid",
                "verify_import(uuid,uuid)->jsonb",
                "verify_release(uuid)->jsonb"
              ])

  @relation_metadata Enum.sort([
                       "area_type:key_only_identity",
                       "artifact:immutable_semantic_definition",
                       "authority:key_only_identity",
                       "boundary:partitioned_release_geometry",
                       "boundary_part:partitioned_release_geometry_parts",
                       "collection:key_only_identity",
                       "import_run:manifest_snapshot:not_null",
                       "import_run_artifact:attempt_artifact_snapshot",
                       "import_run_lease:single_executor_claim",
                       "import_run_status:executor_and_manifest",
                       "published_area_codes:release_attachment_projection",
                       "published_area_names:release_attachment_projection",
                       "published_area_relations:release_scoped_type_order",
                       "published_areas:release_scoped_declarations",
                       "published_boundaries:release_scoped_projection",
                       "publication:current_and_previous_release_pointer",
                       "publication_event:immutable_publication_history",
                       "relation:partitioned_release_hierarchy",
                       "release:lifecycle_and_retention",
                       "release_area_code:release_attachment",
                       "release_area_codes:release_attachment_projection",
                       "release_area_name:release_attachment",
                       "release_area_names:release_attachment_projection",
                       "release_area_type:release_declaration",
                       "release_areas:release_scoped_declarations",
                       "release_artifact:release_attachment",
                       "release_artifacts:latest_completed_attempt_observations",
                       "release_authority:release_declaration",
                       "release_collection_policy:release_declaration",
                       "release_relations:release_scoped_type_order",
                       "release_source:release_attachment",
                       "release_area:partitioned_release_membership",
                       "run_artifacts:exact_attempt_selection",
                       "source:immutable_semantic_definition",
                       "source_release:immutable_semantic_definition"
                     ])

  @trigger_metadata [
    "publication_completed_release_check:publication_release_constraint",
    "release_publication_check:release_mutation_constraint"
  ]

  defmodule ContractRepo do
    def put_state(state), do: Process.put({__MODULE__, :state}, state)

    def query!(sql, _params, _opts) do
      state = Process.get({__MODULE__, :state}, %{})

      rows =
        cond do
          sql =~ "obj_description" ->
            if Map.get(state, :installed?, true), do: [["geo_genius;version=1"]], else: []

          sql =~ "SELECT c.relkind" ->
            [["v"]]

          sql =~ "SELECT a.attname" and sql =~ "geo_genius_contract" ->
            [
              ["schema_version", "integer"],
              ["contract_revision", "text"],
              ["capabilities", "text[]"]
            ]

          sql =~ "SELECT schema_version, contract_revision, capabilities" ->
            [
              [
                1,
                Map.get(state, :revision, SchemaContract.revision()),
                Map.get(state, :capabilities, SchemaContract.capabilities())
              ]
            ]

          sql =~ "pg_get_function_identity_arguments" ->
            Map.get(state, :fingerprints, SchemaContract.target_fingerprints())
            |> Enum.map(&Tuple.to_list/1)

          sql =~ "relation_contract" ->
            Map.get(state, :relation_metadata, SchemaContract.target_relation_metadata())
            |> Enum.map(&Tuple.to_list/1)

          sql =~ "trigger_contract" ->
            Map.get(state, :trigger_metadata, SchemaContract.target_trigger_metadata())
            |> Enum.map(&Tuple.to_list/1)

          sql =~ "oidvectortypes" ->
            Map.get(state, :signatures, SchemaContract.manifest().signatures)
            |> Enum.map(&List.wrap/1)
        end

      %{rows: rows}
    end
  end

  test "the current revision is the sha256 identity of the canonical current-only contract" do
    assert SchemaContract.manifest() == %{
             schema_version: 1,
             capabilities: @capabilities,
             signatures: @signatures,
             relation_metadata: @relation_metadata,
             trigger_metadata: @trigger_metadata
           }

    digest =
      :crypto.hash(:sha256, SchemaContract.canonical_manifest()) |> Base.encode16(case: :lower)

    assert Migration.current_contract_revision() == "sha256:" <> digest
    assert Migration.required_capabilities() == @capabilities
  end

  test "the canonical manifest is sorted semantic text rather than migration SQL" do
    lines = String.split(SchemaContract.canonical_manifest(), "\n", trim: true)

    assert lines ==
             ["schema_version=1"] ++
               Enum.map(@capabilities, &"capability=#{&1}") ++
               Enum.map(@signatures, &"signature=#{&1}") ++
               Enum.map(@relation_metadata, &"relation_metadata=#{&1}") ++
               Enum.map(@trigger_metadata, &"trigger_metadata=#{&1}")

    refute SchemaContract.canonical_manifest() =~ "CREATE FUNCTION"
    refute SchemaContract.canonical_manifest() =~ "reconciliation"
  end

  test "only the exact current schema contract is compatible" do
    ContractRepo.put_state(%{})

    assert %{status: :compatible, compatible?: true, remedy: nil} =
             SchemaContract.status(ContractRepo, "geo_genius")

    ContractRepo.put_state(%{revision: "sha256:obsolete"})

    assert %{status: :drifted, compatible?: false, installed_revision: "sha256:obsolete"} =
             SchemaContract.status(ContractRepo, "geo_genius")
  end

  test "same marker with publication function drift is incompatible" do
    fingerprints = SchemaContract.target_fingerprints()

    {identity, fingerprint} =
      List.keyfind!(fingerprints, "publication_release_is_publishable()->trigger", 0)

    ContractRepo.put_state(%{
      fingerprints: List.keyreplace(fingerprints, identity, 0, {identity, fingerprint <> "drift"})
    })

    assert %{status: :drifted} = SchemaContract.status(ContractRepo, "geo_genius")
  end

  test "same marker with publication structure drift is incompatible" do
    relations = SchemaContract.target_relation_metadata()
    {relation, fingerprint} = List.keyfind!(relations, "publication", 0)

    ContractRepo.put_state(%{
      relation_metadata:
        List.keyreplace(relations, relation, 0, {relation, fingerprint <> "drift"})
    })

    assert %{status: :drifted} = SchemaContract.status(ContractRepo, "geo_genius")
  end

  test "same marker with publication constraint trigger drift is incompatible" do
    triggers = SchemaContract.target_trigger_metadata()
    {trigger, fingerprint} = List.keyfind!(triggers, "release_publication_check", 0)

    ContractRepo.put_state(%{
      trigger_metadata: List.keyreplace(triggers, trigger, 0, {trigger, fingerprint <> "drift"})
    })

    assert %{status: :drifted} = SchemaContract.status(ContractRepo, "geo_genius")
  end

  test "same marker with an extra unsafe overload is incompatible" do
    ContractRepo.put_state(%{
      signatures: @signatures ++ ["put_area_name(text,text,text,text)->uuid"]
    })

    assert %{status: :drifted, missing: []} =
             SchemaContract.status(ContractRepo, "geo_genius")
  end

  test "an absent schema is not installed and does not enter a reconciliation state" do
    ContractRepo.put_state(%{installed?: false})

    assert %{
             status: :not_installed,
             compatible?: false,
             installed_revision: nil,
             remedy: "install GeoGenius schema v1"
           } = SchemaContract.status(ContractRepo, "geo_genius")
  end
end
