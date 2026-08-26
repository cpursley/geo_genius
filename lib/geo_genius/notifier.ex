defmodule GeoGenius.Notifier do
  @moduledoc """
  Behaviour for delivering import lifecycle events to a host application.

  A notifier is called for side effects only: logging, metrics, a webhook, a
  PubSub broadcast. It is never consulted for a decision and its return value
  is ignored. It must not be able to fail an import: `GeoGenius.Pipeline`
  wraps every `notify/3` call so that a notifier which raises or exits has its
  event logged at warning level and dropped, and the phase continues
  regardless. This behaviour does not itself guarantee that -- a notifier that
  raises still raises here -- the guarantee lives entirely in how the pipeline
  calls it.

  `events/0` returns the fixed list of events a host can receive, so a host
  notifier can pattern-match exhaustively instead of guarding against an
  open-ended atom:

  | Event | Payload keys |
  |---|---|
  | `:import_started` | `:run_id`, `:release_id`, `:collection_key`, `:release_key` |
  | `:phase_advanced` | `:run_id`, `:phase`, `:metrics` |
  | `:import_completed` | `:run_id`, `:release_id`, `:collection_key`, `:release_key` |
  | `:import_failed` | `:run_id`, `:phase`, `:reason` |
  | `:release_published` | `:release_id`, `:collection_key` |
  | `:release_rolled_back` | `:collection_key`, `:release_id` |

  `GeoGenius.Pipeline` emits the first four on every import, and
  `:release_published` when it is asked to publish what it just verified with
  `publish: true`. `GeoGenius.publish/2` emits `:release_published` for an
  explicit publication and `GeoGenius.rollback/2` emits
  `:release_rolled_back`, each after the write it reports has committed.

  A payload key may arrive `nil` when the write committed but the read that
  fills the key did not: `:collection_key` on `:release_published`, and
  `:release_id` on `:release_rolled_back`. The event fires regardless, because
  the write it reports happened.
  """

  @events [
    :import_started,
    :phase_advanced,
    :import_completed,
    :import_failed,
    :release_published,
    :release_rolled_back
  ]

  @doc "Delivers one event and its payload to the host."
  @callback notify(event :: atom(), payload :: map(), opts :: keyword()) :: :ok

  @doc "The fixed list of events a notifier may receive, in the order documented above."
  @spec events() :: [atom()]
  def events, do: @events
end
