defmodule GeoGenius.CatalogConcurrencyTest do
  @moduledoc """
  Two sessions writing the same rows at once, through the plural writes.

  A plural write locks many rows per statement where the scalar beside it locks
  one, so two of them running at once can only avoid a cycle by agreeing on an
  order. Nothing about that agreement shows up in a single-session test, and an
  assertion on the ordering SQL would pass against two functions that order by
  different keys -- which is the defect this file exists to catch. So it opens
  four real connections and fails on SQLSTATE 40P01.

  Every pair runs its two sides over the same rows in both directions, so a
  disagreement is a cycle rather than a queue. Against the divergent lock
  orders it was written for, it caught the deadlock in eight runs of eight, and
  against the orders as they stand it passed in eight of eight.
  """

  use ExUnit.Case, async: false

  alias GeoGenius.Catalog
  alias GeoGenius.Context
  alias GeoGenius.ImportFixture
  alias GeoGenius.Manifest
  alias GeoGenius.TestRepo

  # Sized to reproduce reliably rather than to be large. The window is
  # per-statement, so it widens with the number of rows one statement locks;
  # the pass count only adds chances to hit it.
  @areas 2_000
  @passes 12

  # The pairs that cross two functions need a wide statement to overlap in:
  # each side reaches its row locks after a preamble of its own length, so the
  # window is only part of the statement. A pair that runs one function against
  # itself walks exactly opposing orders on both sides and needs far less. The
  # difference matters because this file's write volume lands in a database the
  # rest of the suite shares: every pass rewrites every row it touches, and at
  # the wide size that is a million dead tuples a run.
  @narrow_areas 400
  @narrow_passes 8

  # Each test gets an authority key of its own, not just a collection of its
  # own. area_key is unique across the whole catalog rather than within a
  # collection, so tests sharing an authority key, an area type and a set of
  # codes compose the same area_keys and collide on area_area_key_uq the moment
  # one test's teardown has not finished before the next test's setup runs.
  setup do
    unique = System.unique_integer([:positive])
    collection = "concurrency_fixture_#{unique}"
    authority = "auth_#{unique}"
    context = Context.new(repo: TestRepo, prefix: "geo_genius")

    on_exit(fn -> ImportFixture.teardown!(collection) end)

    {:ok, manifest} = Manifest.from_map(manifest_map(collection, authority))
    candidate = ImportFixture.prepare!(context, manifest)
    executor_id = Ecto.UUID.generate()
    assert :claimed = Catalog.claim_import_execution(context, candidate.run_id, executor_id)
    ImportFixture.advance_to!(context, candidate.run_id, executor_id, "normalizing")

    codes = Enum.map(1..@areas, &("c" <> String.pad_leading(Integer.to_string(&1), 5, "0")))

    Catalog.upsert_area_many(
      context,
      candidate.run_id,
      executor_id,
      Enum.map(codes, &area_attrs(authority, &1))
    )

    Catalog.put_area_in_release_many(
      context,
      candidate.run_id,
      executor_id,
      Enum.map(codes, &membership_attrs(authority, &1))
    )

    {:ok,
     context: context,
     collection: collection,
     authority: authority,
     release_id: candidate.release_id,
     run_id: candidate.run_id,
     executor_id: executor_id,
     codes: codes}
  end

  # upsert_area_many and put_area_name_many are the only two writes that lock
  # area rows, so this is the one pair that can disagree about them. The other
  # plural writes reach area only through their foreign keys, which take FOR KEY
  # SHARE and cannot conflict with the FOR NO KEY UPDATE these two take.
  describe "two sessions over the same areas" do
    @tag :integration
    @tag timeout: 300_000
    test "upserting and naming", fixtures do
      race(
        fn codes -> upsert(fixtures, codes) end,
        fn codes -> name(fixtures, codes) end,
        fixtures.codes,
        @passes
      )
    end
  end

  # Each plural write against itself, over the same rows in opposing orders.
  # This is what holds each one's own insert to a single row-lock order: the
  # pairs above cross two functions and would pass a function that ordered its
  # own writes arbitrarily, as long as it did not collide with the other one.
  describe "two sessions through one write" do
    @tag :integration
    @tag timeout: 300_000
    test "upserting areas", fixtures do
      race(&upsert(fixtures, &1), &upsert(fixtures, &1), narrow(fixtures), @narrow_passes)
    end

    @tag :integration
    @tag timeout: 300_000
    test "writing names", fixtures do
      race(&name(fixtures, &1), &name(fixtures, &1), narrow(fixtures), @narrow_passes)
    end

    @tag :integration
    @tag timeout: 300_000
    test "writing codes", fixtures do
      race(&code(fixtures, &1), &code(fixtures, &1), narrow(fixtures), @narrow_passes)
    end

    @tag :integration
    @tag timeout: 300_000
    test "placing into a release", fixtures do
      race(&place(fixtures, &1), &place(fixtures, &1), narrow(fixtures), @narrow_passes)
    end

    @tag :integration
    @tag timeout: 300_000
    test "relating", fixtures do
      Catalog.advance_import(
        fixtures.context,
        fixtures.run_id,
        fixtures.executor_id,
        "relating",
        %{}
      )

      race(&relate(fixtures, &1), &relate(fixtures, &1), narrow(fixtures), @narrow_passes)
    end
  end

  # Runs `left` over `codes` and `right` over the reverse, `passes` times each,
  # on two connections at once, releasing both into every pass together.
  #
  # The barrier is what makes this a test rather than a lottery. Two loops left
  # to run free drift apart -- one statement is quicker than the other, and the
  # pair spends most of its time with only one session inside a statement,
  # where no cycle can form. Released together, both are mid-statement for the
  # whole overlap. Against the divergent lock orders this file was written for,
  # unsynchronised loops caught the defect in five runs of six; synchronised
  # and at four sessions, in every run.
  #
  # Postgres aborts whichever session it picks, so either side may report.
  defp race(left, right, codes, passes) do
    reversed = Enum.reverse(codes)
    test = self()

    # Four sessions, not two: each side runs in both directions. A plural write
    # spends most of its statement before it reaches its row locks -- resolving
    # keys, and for upsert_area_many taking one advisory lock per area -- and
    # those preambles are not the same length on both sides, so two sessions
    # released together still often reach their row phases apart. Four sessions
    # give every pass two chances to have opposing walkers in that phase at
    # once, which is what took detection of the divergent orders this file was
    # written for from five runs in six to every run.
    work = [{left, codes}, {right, reversed}, {left, reversed}, {right, codes}]

    running = Enum.map(work, &start_session(&1, test, passes))

    Enum.each(1..passes, fn _pass -> release(length(work)) end)

    assert Enum.map(running, &Task.await(&1, 280_000)) == [:ok, :ok, :ok, :ok]
  end

  defp start_session({write, order}, test, passes) do
    pass = fn -> write.(order) end
    Task.async(fn -> loop(test, pass, passes) end)
  end

  # Waits until every session has reached the barrier, then lets them all go at
  # once. Releasing each as it arrives would put them back where they started.
  defp release(sessions) do
    1..sessions
    |> Enum.map(fn _session ->
      assert_receive {:ready, session}, 280_000
      session
    end)
    |> Enum.each(&send(&1, :go))
  end

  # Keeps reporting for every pass even after it has failed, so the barrier
  # above still gets the two arrivals it waits for and the test reports the
  # deadlock rather than timing out on a task that left the loop early.
  defp loop(test, write, passes) do
    Enum.reduce(1..passes, :ok, fn _pass, outcome ->
      send(test, {:ready, self()})

      receive do
        :go -> attempt(write, outcome)
      end
    end)
  end

  defp attempt(_write, {:failed, _message} = failed), do: failed

  defp attempt(write, :ok) do
    write.()
    :ok
  rescue
    error in GeoGenius.CatalogError -> {:failed, Exception.message(error)}
  end

  defp upsert(fixtures, codes) do
    Catalog.upsert_area_many(
      fixtures.context,
      fixtures.run_id,
      fixtures.executor_id,
      Enum.map(codes, &area_attrs(fixtures.authority, &1))
    )
  end

  defp name(fixtures, codes) do
    Catalog.put_area_name_many(
      fixtures.context,
      fixtures.run_id,
      fixtures.executor_id,
      Enum.map(codes, &name_attrs(fixtures.authority, &1))
    )
  end

  defp code(fixtures, codes) do
    Catalog.put_area_code_many(
      fixtures.context,
      fixtures.run_id,
      fixtures.executor_id,
      Enum.map(codes, &code_attrs(fixtures.authority, &1))
    )
  end

  defp place(fixtures, codes) do
    Catalog.put_area_in_release_many(
      fixtures.context,
      fixtures.run_id,
      fixtures.executor_id,
      Enum.map(codes, &membership_attrs(fixtures.authority, &1))
    )
  end

  defp narrow(fixtures), do: Enum.take(fixtures.codes, @narrow_areas)

  # Pairs each area with the one halfway along, so every edge names two
  # distinct areas and the two sessions walk the pairs in opposing orders.
  defp relate(fixtures, codes) do
    {parents, children} = Enum.split(Enum.sort(codes), div(length(codes), 2))
    pairs = Enum.zip(parents, children)
    pairs = if codes == Enum.sort(codes), do: pairs, else: Enum.reverse(pairs)

    Catalog.put_relation_many(
      fixtures.context,
      fixtures.run_id,
      fixtures.executor_id,
      Enum.map(pairs, fn {parent, child} ->
        %{
          parent_area_key: area_key(fixtures.authority, parent),
          child_area_key: area_key(fixtures.authority, child),
          relation_type: "contains"
        }
      end)
    )
  end

  defp area_key(authority, code), do: authority <> ":t:" <> code

  defp area_attrs(authority, code) do
    %{authority_key: authority, area_type_key: "t", code: code}
  end

  defp name_attrs(authority, code) do
    %{area_key: area_key(authority, code), name: "Name " <> code, kind: "official", locale: nil}
  end

  defp code_attrs(authority, code) do
    %{area_key: area_key(authority, code), code_type: "fips", code_value: code}
  end

  defp membership_attrs(authority, code) do
    %{area_key: area_key(authority, code), centroid: nil, attributes: %{"code" => code}}
  end

  defp manifest_map(collection, authority) do
    %{
      "collection" => collection,
      "collection_name" => collection,
      "release" => "r1",
      "provider" => "geojson",
      "requires_geometry" => false,
      "authorities" => [%{"key" => authority, "name" => "Authority"}],
      "area_types" => [%{"key" => "t", "rank" => 10, "requires_geometry" => false}],
      "sources" => [
        %{
          "source_key" => "#{collection}:source",
          "provider" => "geojson",
          "license" => "test",
          "release_key" => "v1",
          "artifacts" => [fixture_artifact(collection)]
        }
      ],
      "options" => %{
        "code_property" => "code",
        "name_property" => "name",
        "area_type" => "t"
      }
    }
  end

  defp fixture_artifact(collection) do
    %{
      "logical_name" => "fixture.geojson",
      "url" => "https://example.test/#{collection}/fixture.geojson",
      "operator_supplied" => false,
      "format" => "geojson",
      "required" => true,
      "sha256" => String.duplicate("a", 64),
      "bytes" => 1,
      "members" => [],
      "metadata" => %{}
    }
  end
end
