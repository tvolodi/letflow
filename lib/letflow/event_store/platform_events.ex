defmodule Letflow.EventStore.PlatformEvents do
  @moduledoc """
  Translation-layer adapters between the three promotion-pipeline event
  producers (`Letflow.Definitions.Promotion`, `Letflow.Definitions`) and
  `Letflow.EventStore.append_platform_event/2` (REQ-140). See
  `lib/letflow/design/req140-platform-event-append-path.md` §2b for why
  this lives in its own `EventStore.*` submodule rather than inside
  `Letflow.EventStore` itself or beside the producers in
  `Letflow.Definitions`, and §4 for the full design these three functions
  implement.

  Each function here independently satisfies `Letflow.Definitions`'s
  `event_appender_fun/0` contract (`(event_attrs :: map(), prefix ::
  String.t() -> {:ok, %{event_id: Ecto.UUID.t()}} | {:error, term()})`),
  so each can be passed directly as `opts[:event_appender]` — e.g.
  `event_appender: &Letflow.EventStore.PlatformEvents.append_definition_promoted/2`
  — by whatever later requirement wires up the real route/context call
  sites (REQ-077). That wiring is explicitly out of scope here; only the
  three functions need to exist and satisfy the contract.

  ## Common shape all three follow (design doc §4.1)

  1. Relocate every domain field in the producer's `event_attrs` (other
     than `:event_type` and `:actor_id`, when present) into a plain map,
     JSON-encoded into the `:payload` key.
  2. Mint a deterministic `:idempotency_key` — see each function's own doc
     for its scheme (design doc §4.2).
  3. Supply `:instance_id` as `EventStore.platform_instance_id()` always —
     never taken from the producer's `event_attrs`.
  4. Supply `:actor_id` from the producer's own `event_attrs[:actor_id]`
     when present, else `EventStore.platform_actor_id()`.
  5. Unwrap `append_platform_event/2`'s `{:ok, %{event: %Event{event_id:
     event_id}}}` into `{:ok, %{event_id: event_id}}` — never a fabricated
     or stubbed id, whether this was a fresh insert or an `is_duplicate:
     true` replay of an already-claimed idempotency key (both cases carry
     the original event's real `event_id`). An `{:error, _} = error`
     passes through unchanged.
  """

  alias Letflow.EventStore

  @doc """
  Adapter for `DEFINITION_PROMOTED`, appended by
  `Letflow.Definitions.Promotion.promote_definition/3`'s step 9
  (`append_promotion_event/9`). Idempotency key:
  `"definition_promoted:" <> review_id` — `review_id` is the stable
  identifier of this specific promotion decision (design doc §4.2/§4.3).

  `review_id` is `nil` on the R10 "promote with no review"
  path (`Promotion.promote_active_definition/5`, ENV-03) — that is this
  path's normal, defining case, not an edge case, so it cannot raise.
  When `review_id` is `nil` the key is instead built from
  `"no_review:" <> source_tenant_id <> ":" <> target_tenant_id <> ":" <>
  target_definition_id`. `target_definition_id` is the id of the row the
  promotion transaction just created for *this* promotion action (fresh
  per call, decided before this adapter ever runs), so the triple still
  uniquely identifies "this specific promotion action": a retried
  event-append call for the same committed transaction reuses the same
  `target_definition_id` and lands on the same key (idempotent), while a
  genuinely new promotion mints a new row and a new key.
  """
  @spec append_definition_promoted(event_attrs :: map(), prefix :: String.t()) ::
          {:ok, %{event_id: Ecto.UUID.t()}} | {:error, term()}
  def append_definition_promoted(event_attrs, prefix) when is_map(event_attrs) do
    %{
      event_type: event_type,
      actor_id: actor_id,
      review_id: review_id,
      source_tenant_id: source_tenant_id,
      target_tenant_id: target_tenant_id,
      target_definition_id: target_definition_id
    } = event_attrs

    payload =
      event_attrs
      |> Map.drop([:event_type, :actor_id])
      |> Jason.encode!()

    promotion_key =
      case review_id do
        nil ->
          "no_review:" <>
            source_tenant_id <> ":" <> target_tenant_id <> ":" <> target_definition_id

        id ->
          id
      end

    platform_attrs = %{
      instance_id: EventStore.platform_instance_id(),
      event_type: event_type,
      actor_id: actor_id,
      payload: payload,
      idempotency_key: "definition_promoted:" <> promotion_key
    }

    platform_attrs
    |> EventStore.append_platform_event(prefix: prefix)
    |> unwrap_event_id()
  end

  @doc """
  Adapter for `DEFINITION_VERSION_ROLLED_BACK`, appended by
  `Letflow.Definitions.finish_rollback/7` after a version pointer swap
  commits. Idempotency key:
  `"definition_version_rolled_back:" <> process_key <> ":" <> from_version
  <> ":" <> to_version` — the triple identifies "this one pointer swap",
  stable across a retried event-append call for the same swap (design doc
  §4.2/§4.3, the requirement's own named double-append example).
  """
  @spec append_definition_version_rolled_back(event_attrs :: map(), prefix :: String.t()) ::
          {:ok, %{event_id: Ecto.UUID.t()}} | {:error, term()}
  def append_definition_version_rolled_back(event_attrs, prefix) when is_map(event_attrs) do
    %{
      event_type: event_type,
      actor_id: actor_id,
      process_key: process_key,
      from_version: from_version,
      to_version: to_version
    } = event_attrs

    payload =
      event_attrs
      |> Map.drop([:event_type, :actor_id])
      |> Jason.encode!()

    idempotency_key =
      "definition_version_rolled_back:" <>
        process_key <> ":" <> from_version <> ":" <> to_version

    platform_attrs = %{
      instance_id: EventStore.platform_instance_id(),
      event_type: event_type,
      actor_id: actor_id,
      payload: payload,
      idempotency_key: idempotency_key
    }

    platform_attrs
    |> EventStore.append_platform_event(prefix: prefix)
    |> unwrap_event_id()
  end

  @doc """
  Adapter for `PROMOTION_ASSERTION_TEARDOWN_FAILED`, appended by
  `Letflow.Definitions.append_teardown_failure_event/6`. The one producer
  of the three that needs both non-trivial transformations: no `actor_id`
  in the producer's map at all (`EventStore.platform_actor_id()` is
  supplied instead), and `tenant_id` is present but `append_platform_event/2`
  rejects any top-level `:tenant_id` key outright — `tenant_id` is
  relocated into `:payload` (real audit-relevant domain data), never
  dropped. Idempotency key: `"promotion_assertion_teardown_failed:" <>
  run_id` — `run_id` alone already identifies this one rerun attempt's
  teardown outcome (design doc §4.2/§4.3).
  """
  @spec append_promotion_assertion_teardown_failed(event_attrs :: map(), prefix :: String.t()) ::
          {:ok, %{event_id: Ecto.UUID.t()}} | {:error, term()}
  def append_promotion_assertion_teardown_failed(event_attrs, prefix) when is_map(event_attrs) do
    %{event_type: event_type, run_id: run_id} = event_attrs

    payload =
      event_attrs
      |> Map.drop([:event_type, :actor_id])
      |> Jason.encode!()

    platform_attrs = %{
      instance_id: EventStore.platform_instance_id(),
      event_type: event_type,
      actor_id: EventStore.platform_actor_id(),
      payload: payload,
      idempotency_key: "promotion_assertion_teardown_failed:" <> run_id
    }

    platform_attrs
    |> EventStore.append_platform_event(prefix: prefix)
    |> unwrap_event_id()
  end

  # Design doc §4.1 step 5 -- never fabricate an id; always the one
  # append_platform_event/2 itself resolved, whether this was a fresh
  # insert or an is_duplicate: true replay of an already-claimed
  # idempotency key.
  defp unwrap_event_id({:ok, %{event: %{event_id: event_id}}}), do: {:ok, %{event_id: event_id}}
  defp unwrap_event_id({:error, _reason} = error), do: error
end
