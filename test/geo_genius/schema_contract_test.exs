defmodule GeoGenius.SchemaContractTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Migration
  alias GeoGenius.SchemaContract

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

  test "the current revision is the sha256 identity of the canonical contract manifest" do
    assert SchemaContract.manifest() == %{
             schema_version: 1,
             capabilities: @capabilities,
             signatures: @signatures,
             relation_metadata: @relation_metadata
           }

    digest =
      :crypto.hash(:sha256, SchemaContract.canonical_manifest()) |> Base.encode16(case: :lower)

    assert Migration.current_contract_revision() == "sha256:" <> digest
    assert Migration.required_capabilities() == @capabilities
  end

  test "the canonical manifest is ordered text rather than whole migration SQL" do
    assert SchemaContract.canonical_manifest() ==
             """
             schema_version=1
             capability=boundary_batches
             capability=boundary_canonical_repair_once
             capability=boundary_collection_provenance
             capability=boundary_publication_serialization
             capability=reversible_legacy_v01_reconciliation
             capability=type_scoped_geometry_requirements
             signature=publish_release(uuid)->uuid
             signature=put_boundaries(uuid,text[],uuid[],geometry[],integer[],jsonb[])->void
             signature=put_boundary(uuid,text,uuid,geometry,double precision)->void
             signature=upsert_area_type(text,text,integer)->uuid
             signature=upsert_area_type(text,text,integer,boolean)->uuid
             signature=verify_release(uuid)->jsonb
             relation_metadata=area_type:ordinary_table
             relation_metadata=area_type.requires_geometry:boolean:not_null:default_false
             """

    refute SchemaContract.canonical_manifest() =~ "CREATE FUNCTION"
  end
end
