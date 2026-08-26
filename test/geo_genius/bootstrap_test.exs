defmodule GeoGenius.BootstrapTest do
  # Every test here shares the "demo" collection GraphFixture and several
  # other test files already use, torn down before and after each test so no
  # run leaks between them.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GeoGenius.AppEnv
  alias GeoGenius.Bootstrap
  alias GeoGenius.GraphFixture
  alias GeoGenius.TestRepo

  @manifest_paths [Path.expand("../support/manifests", __DIR__)]

  defmodule StubRunner do
    @moduledoc "Records every enqueue, in the calling process's mailbox."
    @behaviour GeoGenius.Runner

    @impl GeoGenius.Runner
    def name, do: "bootstrap-stub"

    @impl GeoGenius.Runner
    def available?, do: true

    @impl GeoGenius.Runner
    def enqueue(_context, run_id, args) do
      send(self(), {:bootstrap_enqueued, run_id, args})
      :ok
    end
  end

  defmodule RaisingRunner do
    @moduledoc "A runner backend whose enqueue/3 raises instead of returning an error tuple."
    @behaviour GeoGenius.Runner

    @impl GeoGenius.Runner
    def name, do: "bootstrap-raising"

    @impl GeoGenius.Runner
    def available?, do: true

    @impl GeoGenius.Runner
    def enqueue(_context, _run_id, _args), do: raise("runner exploded")
  end

  defmodule RefusingRunner do
    @moduledoc """
    A runner backend that refuses without raising, returning a plain-term
    `{:error, reason}` -- the shape `GeoGenius.Runner.enqueue/3`'s own
    callback doc calls out ("Returns `{:error, reason}` only when nothing was
    recorded"), and how `GeoGenius.PublicIngestionTest`'s own `FailingRunner`
    behaves. Every other failure path this suite exercises is either a raised
    exception or a `%ManifestError{}` struct inside the tuple; this is the
    only one that puts a non-exception term there.
    """
    @behaviour GeoGenius.Runner

    @impl GeoGenius.Runner
    def name, do: "bootstrap-refusing"

    @impl GeoGenius.Runner
    def available?, do: true

    @impl GeoGenius.Runner
    def enqueue(_context, _run_id, _args), do: {:error, "runner refused to accept work"}
  end

  defmodule CapturingNotifier do
    @moduledoc """
    Records the raw `opts` a notify/3 call receives, in the calling
    process's mailbox. `GeoGenius.notify/4` forwards `enqueue/1`'s own
    `import_opts` here unfiltered -- not through `Keyword.get/2` or
    `Keyword.fetch!/2` against named keys the way every other call site
    downstream of `GeoGenius.import/1` reads it -- so this is the boundary
    that actually observes whether an internal Bootstrap key leaked past
    the `Keyword.drop |> Keyword.merge` pipeline into third-party,
    host-authored code.
    """
    @behaviour GeoGenius.Notifier

    @impl GeoGenius.Notifier
    def notify(event, _payload, opts) do
      send(self(), {:notified_opts, event, opts})
      :ok
    end
  end

  setup do
    GraphFixture.teardown!()
    on_exit(&GraphFixture.teardown!/0)

    # Bootstrap.start_link/1 resolves :repo, :prefix, and :manifest_paths the
    # same way GeoGenius.import/1 already does -- through application
    # environment when opts do not carry them -- so a call with opts: []
    # below still reaches a real Repo and the "demo" fixture manifest.
    AppEnv.put(:repo, TestRepo)
    AppEnv.put(:prefix, "geo_genius")
    AppEnv.put(:manifest_paths, @manifest_paths)
    AppEnv.put(:runner, StubRunner)
    AppEnv.restore_on_exit(:bootstrap)

    :ok
  end

  defp put_bootstrap_config(config), do: Application.put_env(:geo_genius, :bootstrap, config)

  # Ruling EZ. The moduledoc makes three distinct forwarding promises:
  # child_spec/1 passes its opts argument through to start_link/1 (case 8),
  # resolved/2 honors an explicit opts value -- including nil -- over
  # config for each of the four precedence keys (the matrix), and
  # start_link/1 forwards every OTHER opts key -- ":repo, :prefix, :runner,
  # :manifest_paths, and so on" -- into GeoGenius.import/1 as given. Nothing
  # in this file exercised the third one: every other test relies on
  # setup's own Application.put_env for :repo, :prefix, :manifest_paths, and
  # :runner, so none of them distinguishes "opts genuinely forwarded" from
  # "import/1 quietly fell back to configuration that happened to already be
  # there". This test deletes all four from application environment for its
  # own duration and supplies them through start_link/1's opts instead,
  # following the moduledoc's own usage example
  # (`{GeoGenius.Bootstrap, repo: MyApp.Repo}`) literally rather than
  # through the harness's usual setup. `enqueue/1`'s
  # `Keyword.drop(opts, [...]) |> Keyword.merge(target(opts))` line is what
  # this pins -- replacing it with `target(opts)` alone would drop every
  # host option as a set, and this is the one test that would notice.
  test "host options reach import/1 through opts alone, with no matching application env" do
    Application.delete_env(:geo_genius, :repo)
    Application.delete_env(:geo_genius, :prefix)
    Application.delete_env(:geo_genius, :manifest_paths)
    Application.delete_env(:geo_genius, :runner)

    put_bootstrap_config(enabled: true, collection: "demo", release: "r1")

    log =
      capture_log(fn ->
        assert Bootstrap.start_link(
                 repo: TestRepo,
                 prefix: "geo_genius",
                 manifest_paths: @manifest_paths,
                 runner: StubRunner
               ) == :ignore
      end)

    refute log =~ "GeoGenius.Bootstrap"
    assert_receive {:bootstrap_enqueued, _run_id, _args}
  end

  # Ruling FC. GeoGenius.import/1's own call chain -- start_import/3 ->
  # enqueue_import/7 -> notify/4 -- forwards enqueue/1's import_opts
  # unfiltered into GeoGenius.Notifier.notify/3, a documented,
  # host-pluggable extension point ("logging, metrics, a webhook, a PubSub
  # broadcast", per its own moduledoc). That is one call past everywhere
  # fix round 5's "provably unobservable" trace looked: GeoGenius.import/1's
  # own Keyword.get/2 and Keyword.fetch!/2 reads never see :enabled, but
  # notify/4 hands the whole opts list to third-party code verbatim
  # regardless of whether anything reads it there. Narrowing enqueue/1's
  # Keyword.drop list back down (dropping :collection and :release only)
  # lets :enabled leak into that list on every enqueue where a host passes
  # it through opts -- the moduledoc's own recommended shape.
  #
  # :collection, :release, and the coerced :publish are deliberately NOT
  # asserted absent here: GeoGenius.import/1 needs :collection and :release
  # to resolve the manifest in the first place, and opts is the same,
  # never-rebuilt keyword list end to end, so both legitimately reach
  # notify/4 under correct code too -- asserting their absence would fail
  # against pristine bootstrap.ex, not just the mutation. :enabled is the
  # one key with no legitimate reason to ever reach import_opts at all; its
  # absence is what the Keyword.drop list actually exists to guarantee.
  test "an internal :enabled does not leak into a notifier's opts; forwarded host options do" do
    AppEnv.put(:notifier, CapturingNotifier)
    Application.delete_env(:geo_genius, :repo)
    Application.delete_env(:geo_genius, :prefix)
    Application.delete_env(:geo_genius, :manifest_paths)
    Application.delete_env(:geo_genius, :runner)

    assert Bootstrap.start_link(
             enabled: true,
             collection: "demo",
             release: "r1",
             repo: TestRepo,
             prefix: "geo_genius",
             manifest_paths: @manifest_paths,
             runner: StubRunner
           ) == :ignore

    assert_receive {:notified_opts, :import_started, opts}

    refute Keyword.has_key?(opts, :enabled)

    assert Keyword.get(opts, :repo) == TestRepo
    assert Keyword.get(opts, :prefix) == "geo_genius"
    assert Keyword.get(opts, :manifest_paths) == @manifest_paths
    assert Keyword.get(opts, :runner) == StubRunner
  end

  # Ruling EU. Every other test in this file calls put_bootstrap_config/1
  # first, so none of them reach bootstrap_config/0's
  # Application.get_env(:geo_genius, :bootstrap, []) with the key genuinely
  # absent -- only ever with it present and set to []. This is the module's
  # own moduledoc example and its core safety claim: a host places
  # {GeoGenius.Bootstrap, repo: MyApp.Repo} in its tree and never writes
  # config :geo_genius, :bootstrap at all, relying entirely on "disabled by
  # default". Deleting the key outright (not setting it to []) is what
  # actually reaches that default, rather than a harness-written empty list
  # standing in for it.
  #
  # Asserting on the captured log, not just :ignore and an empty mailbox, is
  # required here specifically because of Ruling ET: start_link/1's rescue
  # now covers enabled?/1 too, so a broken default (nil instead of []) no
  # longer surfaces as an uncaught raise -- it gets logged and turned into
  # :ignore, external behaviour indistinguishable from a genuinely disabled
  # boot on the return value and mailbox alone. A silent, log-free :ignore is
  # what "disabled by default" actually promises; a rescued raise is not that,
  # even though it also returns :ignore.
  test "the true zero-configuration path: no :bootstrap key anywhere stays disabled" do
    Application.delete_env(:geo_genius, :bootstrap)

    log =
      capture_log(fn ->
        assert Bootstrap.start_link([]) == :ignore
      end)

    # Not `log == ""`: this async: false module can still run alongside
    # unrelated async: true test modules that emit their own log lines during
    # this window, so an exact-equality assertion would be flaky for reasons
    # having nothing to do with Bootstrap. Refuting Bootstrap's own message
    # keeps the discriminator (a rescued raise here logs it) without that
    # fragility.
    refute log =~ "GeoGenius.Bootstrap"
    refute_receive {:bootstrap_enqueued, _run_id, _args}
  end

  # Ruling ET. start_link/1's rescue covers its whole body, not just the
  # GeoGenius.import/1 call inside enqueue/1: enabled?/1 runs for every host,
  # configured or not, so a config :geo_genius, :bootstrap of the wrong shape
  # entirely -- not a keyword list at all, rather than merely missing a key
  # -- must not raise past start_link/1 either. Keyword.get/2 requires a
  # list, so a binary here raises FunctionClauseError inside enabled?/1,
  # called directly from start_link/1, before enqueue/1 (and its own former
  # rescue) is ever reached.
  test "malformed :bootstrap config raises inside enabled?/1 but start_link/1 still logs and returns :ignore" do
    Application.put_env(:geo_genius, :bootstrap, "not-a-keyword-list")

    log =
      capture_log(fn ->
        assert Bootstrap.start_link([]) == :ignore
      end)

    assert log =~ "[error]"
    assert log =~ "GeoGenius.Bootstrap"
    refute_receive {:bootstrap_enqueued, _run_id, _args}
  end

  # Case 1. Everything else needed to actually enqueue -- collection, release,
  # a real Repo, a runner that would tell us -- is fully configured. Only
  # :enabled is left unset, which is the one thing standing between this test
  # and a genuine enqueue. A stub runner that records enqueues and a mailbox
  # assertion is what tells "disabled" apart from "enabled and silently
  # failing" -- both return :ignore, but only one leaves the mailbox empty.
  test "disabled by default: a fully configured target still enqueues nothing" do
    put_bootstrap_config(collection: "demo", release: "r1")

    assert Bootstrap.start_link([]) == :ignore
    refute_receive {:bootstrap_enqueued, _run_id, _args}
  end

  test "enabled: false explicitly disables a fully configured target the same way" do
    put_bootstrap_config(enabled: false, collection: "demo", release: "r1")

    assert Bootstrap.start_link([]) == :ignore
    refute_receive {:bootstrap_enqueued, _run_id, _args}
  end

  test "enabled: true with a collection and release enqueues an import and returns :ignore" do
    put_bootstrap_config(enabled: true, collection: "demo", release: "r1")

    assert Bootstrap.start_link([]) == :ignore
    assert_receive {:bootstrap_enqueued, _run_id, _args}
  end

  # Ruling EW. The moduledoc promises `:enabled` is compared against the
  # literal `true`, not coerced -- `enabled: "true"`, the realistic mistake
  # from an unparsed environment variable, must stay disabled. Fully
  # configured otherwise (collection, release, a real repo, the stub
  # runner), so a coercion to truthy (`!!`) is caught by a real enqueue
  # reaching the stub runner, not merely by a changed return value.
  # Log-checked rather than a bare refute_receive, for the same reason the
  # zero-configuration test is: this proves a genuinely silent disable, not
  # a crash rescued into looking like one. Case 3 below is what proves the
  # other direction -- that the literal `true` this rejects is still
  # accepted.
  test "enabled: a truthy-but-not-true config value is not coerced, and the boot stays silent" do
    put_bootstrap_config(enabled: "true", collection: "demo", release: "r1")

    log =
      capture_log(fn ->
        assert Bootstrap.start_link([]) == :ignore
      end)

    refute log =~ "GeoGenius.Bootstrap"
    refute_receive {:bootstrap_enqueued, _run_id, _args}
  end

  # Same property, through opts rather than config -- resolved/2 takes a
  # different branch (Keyword.fetch/2 on opts directly, never reaching
  # bootstrap_config/0 at all), so this is not redundant with the test above.
  test "enabled: a truthy-but-not-true opts value is not coerced, and the boot stays silent" do
    put_bootstrap_config(collection: "demo", release: "r1")

    log =
      capture_log(fn ->
        assert Bootstrap.start_link(enabled: 1) == :ignore
      end)

    refute log =~ "GeoGenius.Bootstrap"
    refute_receive {:bootstrap_enqueued, _run_id, _args}
  end

  test "publish: true is threaded through to import/1" do
    put_bootstrap_config(enabled: true, collection: "demo", release: "r1", publish: true)

    assert Bootstrap.start_link([]) == :ignore
    assert_receive {:bootstrap_enqueued, _run_id, args}
    assert args.publish == true
  end

  # Ruling EW. Same non-coercion promise, for :publish: a truthy-but-not-true
  # value must not thread through to import/1 as true. This observes the
  # actual value the stub runner receives in args.publish, not merely the
  # return value or the mailbox -- a coercion to `!!` changes precisely that
  # field and nothing else observable from start_link/1's return.
  test "publish: a truthy-but-not-true value is not coerced to true" do
    put_bootstrap_config(enabled: true, collection: "demo", release: "r1", publish: 1)

    assert Bootstrap.start_link([]) == :ignore
    assert_receive {:bootstrap_enqueued, _run_id, args}
    assert args.publish == false
  end

  test "publish defaults to false when absent from both opts and config" do
    put_bootstrap_config(enabled: true, collection: "demo", release: "r1")

    assert Bootstrap.start_link([]) == :ignore
    assert_receive {:bootstrap_enqueued, _run_id, args}
    assert args.publish == false
  end

  # Case 5. "nope" is a syntactically valid release key with no manifest file
  # behind it, so GeoGenius.import/1 returns {:error, %ManifestError{}} --
  # the tuple path, reached with no raise involved at all.
  test "a failing import (unknown manifest) logs at :error and still returns :ignore" do
    put_bootstrap_config(enabled: true, collection: "demo", release: "nope")

    log =
      capture_log(fn ->
        assert Bootstrap.start_link([]) == :ignore
      end)

    # The brief says "logs at :error" three times over, and this test's own
    # name repeats it -- asserting only message substrings would still pass
    # against a Logger.warning (or any other level config/test.exs's
    # `level: :warning` still lets through), so the level itself is pinned
    # here, not just the words in the message.
    assert log =~ "[error]"
    assert log =~ "GeoGenius.Bootstrap"
    assert log =~ "manifest"
    refute_receive {:bootstrap_enqueued, _run_id, _args}
  end

  # Case 6. With no :collection anywhere, GeoGenius.import/1 itself raises
  # KeyError from Keyword.fetch!/2 -- it is not one of the two exceptions
  # import/1 rescues -- so this is the raise path, not the {:error, _} tuple
  # path case 5 already covers. It is also this suite's proof for mutation 2:
  # narrowing Bootstrap's own rescue to `{:error, _}` tuples only would leave
  # this raise uncaught and fail the test below rather than logging and
  # returning :ignore.
  test "enabled: true with no collection returns :ignore and logs the missing key, not raise" do
    put_bootstrap_config(enabled: true, release: "r1")

    log =
      capture_log(fn ->
        assert Bootstrap.start_link([]) == :ignore
      end)

    assert log =~ "[error]"
    assert log =~ "GeoGenius.Bootstrap"
    # Pinned to KeyError's own message rather than a looser "collection"
    # substring: Bootstrap deliberately reuses GeoGenius.import/1's own
    # Keyword.fetch! error instead of deriving its own missing-key message,
    # and this is the assertion that would notice if it stopped doing that.
    assert log =~ "key :collection not found"
    refute_receive {:bootstrap_enqueued, _run_id, _args}
  end

  # A second, independent proof that Bootstrap's rescue catches raised
  # exceptions generally, not only the specific KeyError case 6 happens to
  # produce: here the raise comes from the runner backend, several calls
  # deeper into GeoGenius.import/1, well past where Keyword.fetch! runs.
  test "a runner that raises is caught by Bootstrap's own rescue, not returned as a tuple" do
    Application.put_env(:geo_genius, :runner, RaisingRunner)
    put_bootstrap_config(enabled: true, collection: "demo", release: "r1")

    log =
      capture_log(fn ->
        assert Bootstrap.start_link([]) == :ignore
      end)

    assert log =~ "[error]"
    assert log =~ "GeoGenius.Bootstrap"
    assert log =~ "runner exploded"
  end

  # This round's hardest-mutation proof (see task-16-report.md): every other
  # failure path in this file puts an exception -- raised, or wrapped in
  # `{:error, %ManifestError{}}` -- through log_failure/1, so its
  # `is_exception(reason)` branch was always taken and its `inspect(reason)`
  # fallback for a plain-term reason was never reached. A runner that refuses
  # by returning `{:error, "some string"}` -- exactly what
  # `GeoGenius.Runner.enqueue/3`'s own callback doc allows, and what
  # `GeoGenius.PublicIngestionTest.FailingRunner` actually does -- is what
  # exercises it. Simplifying log_failure/1 to call `Exception.message/1`
  # unconditionally survives every other test in this file untouched.
  test "a runner that refuses with a plain-term reason is logged without crashing" do
    Application.put_env(:geo_genius, :runner, RefusingRunner)
    put_bootstrap_config(enabled: true, collection: "demo", release: "r1")

    log =
      capture_log(fn ->
        assert Bootstrap.start_link([]) == :ignore
      end)

    assert log =~ "[error]"
    assert log =~ "GeoGenius.Bootstrap"
    assert log =~ "runner refused to accept work"
    refute_receive {:bootstrap_enqueued, _run_id, _args}
  end

  # Case 7. Config names a collection that does not exist at all, so if the
  # implementation ever let a configured value leak in ahead of (or merged
  # with) an explicit opt, GeoGenius.import/1 would fail to resolve it and
  # nothing would reach the stub runner -- refute_receive would catch that
  # silently, the same way it catches case 1 losing its guard.
  test "options passed to start_link/1 win over application environment" do
    put_bootstrap_config(enabled: false, collection: "not-a-real-collection", release: "r1")

    assert Bootstrap.start_link(enabled: true, collection: "demo", release: "r1") == :ignore
    assert_receive {:bootstrap_enqueued, _run_id, _args}
  end

  # This suite's hardest-mutation proof (see task-16-report.md): a
  # `Keyword.get(opts, key) || Keyword.get(bootstrap_config(), key)`
  # implementation of precedence -- instead of `Keyword.fetch/2` -- resolves
  # opts[:enabled] == false back to `false || true`, which evaluates the
  # config side because `false` is itself falsy in Elixir. That mutation
  # re-enables a bootstrap a host explicitly turned off. Only asserting
  # "opts wins when config is absent" (as case 7 does) does not catch it;
  # this needs config to hold the *opposite* of what opts explicitly says.
  test "an explicit enabled: false in opts overrides a config default of true" do
    put_bootstrap_config(enabled: true, collection: "demo", release: "r1")

    assert Bootstrap.start_link(enabled: false) == :ignore
    refute_receive {:bootstrap_enqueued, _run_id, _args}
  end

  # This round's hardest-mutation proof (see task-16-report.md): the
  # moduledoc promises an explicit opts value wins "even when the explicit
  # value is false or nil and the configured one is not" -- two distinct
  # cases. Every existing precedence test uses `false`; none passes an
  # explicit `nil`. A `resolved/2` that special-cases only `{:ok, nil} ->
  # fall through to config` (leaving `{:ok, false}` correctly un-touched)
  # would pass every other test in this file, including the one above.
  #
  # Set up so the two behaviours are observably different, not just
  # differently reasoned about: config names a real, resolvable collection
  # ("demo"), and opts explicitly clears it with `collection: nil`. Under the
  # documented behaviour, opts wins, :collection is genuinely absent from
  # what reaches GeoGenius.import/1, and it raises the same KeyError case 6
  # pins -- caught, logged, no enqueue. Under the nil-falls-through bug,
  # "demo" leaks in from config and the import actually proceeds, reaching
  # the stub runner. Asserting the exact KeyError message (not just
  # refute_receive) is what tells "opts nil genuinely won" apart from some
  # unrelated crash also landing on :ignore with an empty mailbox.
  test "an explicit nil in opts for :collection overrides a present config value" do
    put_bootstrap_config(enabled: true, collection: "demo", release: "r1")

    log =
      capture_log(fn ->
        assert Bootstrap.start_link(collection: nil) == :ignore
      end)

    assert log =~ "key :collection not found"
    refute_receive {:bootstrap_enqueued, _run_id, _args}
  end

  # Ruling EX. Four rounds have each found one more hole in this same
  # helper -- `case 7` missed "false is falsy" for :enabled, the `== true`
  # strictness was documented but unpinned for :enabled and :publish, the
  # nil-override promise was pinned for :collection only, and now not even
  # for :release. All four gaps were different cells of the same underlying
  # promise: every key `resolved/2` and `put_if_present/3` touch --
  # `:enabled`, `:collection`, `:release`, `:publish` -- behaves the same
  # way under the same input shape. Rather than add a fifth ad hoc test next
  # round, this is that promise enumerated as a matrix and pinned as a set.
  #
  # Dimensions:
  #   - key:    :enabled | :collection | :release | :publish
  #   - shape:  absent from opts (config decides) | opts: nil (config
  #             present, opts wins and clears) | opts: false | opts: truthy
  #             non-true | opts: the real/valid value
  #   - config: absent | false | true | truthy non-true | present (valid)
  #
  # :enabled and :publish are booleans compared against the literal `true`,
  # so all five opts shapes and all five config values apply to them --
  # rows E1-E8 and P1-P8 below (not a full 5x5 = 25 per key: several cells
  # are indistinguishable from ones already covered by a bordering cell and
  # are called out inline rather than silently dropped, per the ruling).
  #
  # :collection and :release are plain strings forwarded to
  # `GeoGenius.import/1` as-is, never compared against `true` -- "false" and
  # "truthy non-true" are not meaningful shapes for them at all (there is no
  # coercion to guard against; any non-nil value is just used). Only
  # absent / nil / present-valid / opts-overrides-invalid-config apply --
  # rows C1-C4 and R1-R4. R1-R4 mirror C1-C4 exactly: `put_if_present/3` is
  # the one helper shared by both keys, and R3 is precisely the cell the
  # round-4 survivor lived in (a mutation that special-cased `:collection`
  # but left `:release` on the buggy fallback path).
  #
  # Every row holds the other three keys at an "obviously fine" value
  # (collection/release resolvable, enabled true, publish irrelevant) so
  # each row isolates exactly one dimension of one key.
  @matrix [
    # -- :enabled (gates whether enqueue/1 runs at all) -------------------
    %{
      group: :enabled,
      label: "opts absent, config absent -> disabled, silent",
      opts: [],
      config: [collection: "demo", release: "r1"],
      expect: {:disabled, :silent}
    },
    %{
      group: :enabled,
      label: "opts absent, config: true -> enqueued",
      opts: [],
      config: [enabled: true, collection: "demo", release: "r1"],
      expect: {:enqueued, false}
    },
    %{
      group: :enabled,
      label: "opts absent, config: false -> disabled, silent",
      opts: [],
      config: [enabled: false, collection: "demo", release: "r1"],
      expect: {:disabled, :silent}
    },
    %{
      group: :enabled,
      label:
        "opts absent, config: truthy non-true (string true) -> disabled, silent, not coerced",
      opts: [],
      config: [enabled: "true", collection: "demo", release: "r1"],
      expect: {:disabled, :silent}
    },
    %{
      group: :enabled,
      label: "opts: nil, config: true -> opts nil wins, disabled, silent",
      opts: [enabled: nil],
      config: [enabled: true, collection: "demo", release: "r1"],
      expect: {:disabled, :silent}
    },
    %{
      group: :enabled,
      label: "opts: false, config: true -> opts false wins, disabled, silent",
      opts: [enabled: false],
      config: [enabled: true, collection: "demo", release: "r1"],
      expect: {:disabled, :silent}
    },
    %{
      group: :enabled,
      label: "opts: truthy non-true (1), config absent -> disabled, silent, not coerced",
      opts: [enabled: 1],
      config: [collection: "demo", release: "r1"],
      expect: {:disabled, :silent}
    },
    %{
      group: :enabled,
      label: "opts: true, config: false -> opts true wins, enqueued",
      opts: [enabled: true],
      config: [enabled: false, collection: "demo", release: "r1"],
      expect: {:enqueued, false}
    },

    # -- :publish (never gates enqueue; only observable in the args a -----
    # -- runner receives, so every row here holds enabled: true) ----------
    # This row's {opts, config, expect} is byte-identical to #2 [enabled],
    # #18 [collection], and #22 [release] below: with :publish absent from
    # both opts and an otherwise fully-populated config, all four groups
    # land on the same "everything else at its baseline, one dimension
    # untouched" scenario. Left as four rows rather than collapsed to one --
    # each documents a different dimension's baseline and each still
    # asserts and fails under mutation 3 -- but labelled honestly here as
    # what actually varies (:publish is the absent key, not the whole
    # config) rather than implying a fifth distinct scenario.
    %{
      group: :publish,
      label: "opts absent, config: publish absent from an otherwise full config -> false",
      opts: [],
      config: [enabled: true, collection: "demo", release: "r1"],
      expect: {:enqueued, false}
    },
    %{
      group: :publish,
      label: "opts absent, config: true -> true",
      opts: [],
      config: [enabled: true, collection: "demo", release: "r1", publish: true],
      expect: {:enqueued, true}
    },
    %{
      group: :publish,
      label: "opts absent, config: false -> false",
      opts: [],
      config: [enabled: true, collection: "demo", release: "r1", publish: false],
      expect: {:enqueued, false}
    },
    %{
      group: :publish,
      label: "opts absent, config: truthy non-true (1) -> false, not coerced",
      opts: [],
      config: [enabled: true, collection: "demo", release: "r1", publish: 1],
      expect: {:enqueued, false}
    },
    %{
      group: :publish,
      label: "opts: nil, config: true -> opts nil wins, false",
      opts: [publish: nil],
      config: [enabled: true, collection: "demo", release: "r1", publish: true],
      expect: {:enqueued, false}
    },
    %{
      group: :publish,
      label: "opts: false, config: true -> opts false wins, false",
      opts: [publish: false],
      config: [enabled: true, collection: "demo", release: "r1", publish: true],
      expect: {:enqueued, false}
    },
    %{
      group: :publish,
      label: "opts: truthy non-true (string true), config absent -> false, not coerced",
      opts: [publish: "true"],
      config: [enabled: true, collection: "demo", release: "r1"],
      expect: {:enqueued, false}
    },
    %{
      group: :publish,
      label: "opts: true, config: false -> opts true wins, true",
      opts: [publish: true],
      config: [enabled: true, collection: "demo", release: "r1", publish: false],
      expect: {:enqueued, true}
    },

    # -- :collection (put_if_present/3; requires enabled: true to reach it) --
    %{
      group: :collection,
      label: "opts absent, config absent -> disabled, key genuinely missing",
      opts: [],
      config: [enabled: true, release: "r1"],
      expect: {:disabled, {:log, "key :collection not found"}}
    },
    %{
      group: :collection,
      label: "opts absent, config: demo -> enqueued",
      opts: [],
      config: [enabled: true, collection: "demo", release: "r1"],
      expect: {:enqueued, false}
    },
    %{
      group: :collection,
      label: "opts: nil, config: demo -> opts nil wins, key genuinely missing",
      opts: [collection: nil],
      config: [enabled: true, collection: "demo", release: "r1"],
      expect: {:disabled, {:log, "key :collection not found"}}
    },
    %{
      group: :collection,
      label: "opts: demo, config: unresolvable -> opts wins, enqueued",
      opts: [collection: "demo"],
      config: [enabled: true, collection: "not-a-real-collection", release: "r1"],
      expect: {:enqueued, false}
    },

    # -- :release (put_if_present/3; the exact helper :collection shares -- --
    # -- the round-4 survivor special-cased :collection and left this on --
    # -- the buggy fallback, so R1-R4 mirror C1-C4 exactly) ----------------
    %{
      group: :release,
      label: "opts absent, config absent -> disabled, key genuinely missing",
      opts: [],
      config: [enabled: true, collection: "demo"],
      expect: {:disabled, {:log, "key :release not found"}}
    },
    %{
      group: :release,
      label: "opts absent, config: r1 -> enqueued",
      opts: [],
      config: [enabled: true, collection: "demo", release: "r1"],
      expect: {:enqueued, false}
    },
    %{
      group: :release,
      label: "opts: nil, config: r1 -> opts nil wins, key genuinely missing",
      opts: [release: nil],
      config: [enabled: true, collection: "demo", release: "r1"],
      expect: {:disabled, {:log, "key :release not found"}}
    },
    %{
      group: :release,
      label: "opts: r1, config: unresolvable -> opts wins, enqueued",
      opts: [release: "r1"],
      config: [enabled: true, collection: "demo", release: "not-a-real-release"],
      expect: {:enqueued, false}
    }
  ]

  # Dispatch lives in one ordinary function, run once per test via a
  # runtime call, rather than inlined into each generated test body: with
  # the row spliced in as a literal (unquote(Macro.escape(row)) below),
  # inlining this case directly into each test function lets the compiler's
  # type checker narrow row.expect's type per call site to the one literal
  # tag that row actually carries, and then warn that the other two clauses
  # can never match -- true for that literal, but not the point of a case
  # meant to handle all three shapes generically.
  defp run_matrix_row(row) do
    put_bootstrap_config(row.config)

    case row.expect do
      {:enqueued, expected_publish} ->
        # Round 4's hardest-mutation finding lives here: a success branch
        # that spuriously calls log_failure/1 anyway (a copy-paste error, or
        # a future refactor that mixes the two case clauses up) still
        # returns :ignore and still delivers the enqueue -- every assertion
        # above this comment would keep passing. Capturing the log and
        # requiring it to be silent on the success path is what catches
        # that, across every enqueued cell in the matrix at once.
        log =
          capture_log(fn ->
            assert Bootstrap.start_link(row.opts) == :ignore
          end)

        refute log =~ "GeoGenius.Bootstrap"
        assert_receive {:bootstrap_enqueued, _run_id, args}
        assert args.publish == expected_publish

      {:disabled, :silent} ->
        log =
          capture_log(fn ->
            assert Bootstrap.start_link(row.opts) == :ignore
          end)

        # Not a bare refute_receive: start_link/1's whole-body rescue turns
        # any crash into the same external :ignore a correct, silent
        # disable produces, so a positive proof that nothing was even
        # logged is what tells the two apart.
        refute log =~ "GeoGenius.Bootstrap"
        refute_receive {:bootstrap_enqueued, _run_id, _args}

      {:disabled, {:log, substring}} ->
        log =
          capture_log(fn ->
            assert Bootstrap.start_link(row.opts) == :ignore
          end)

        # Pinned to the specific downstream message, not just "something
        # was logged": that is what tells "the key is genuinely missing,
        # exactly as designed" apart from an unrelated crash that also
        # lands on :ignore with an empty mailbox.
        assert log =~ substring
        refute_receive {:bootstrap_enqueued, _run_id, _args}
    end
  end

  for {row, index} <- Enum.with_index(@matrix, 1) do
    test "put_if_present/resolved matrix ##{index} [#{row.group}]: #{row.label}" do
      run_matrix_row(unquote(Macro.escape(row)))
    end
  end

  # Case 8. Opts is a non-empty, distinguishable list here on purpose:
  # `child_spec([])` cannot tell "opts forwarded" from "opts discarded and
  # start_link([]) hardcoded" -- def child_spec(_opts) with
  # start: {__MODULE__, :start_link, [[]]} passes that call unchanged. Every
  # host following this module's own moduledoc example
  # (`{GeoGenius.Bootstrap, repo: MyApp.Repo}`) relies on this forwarding.
  test "child_spec/1 forwards opts into start_link/1 and sets restart: :temporary" do
    opts = [repo: GeoGenius.TestRepo, enabled: true]
    spec = Bootstrap.child_spec(opts)

    assert spec.id == GeoGenius.Bootstrap
    assert spec.type == :worker
    assert spec.restart == :temporary
    assert spec.start == {GeoGenius.Bootstrap, :start_link, [opts]}
  end
end
