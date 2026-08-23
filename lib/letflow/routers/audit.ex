defmodule Letflow.Routers.Audit do
  @moduledoc """
  Audit-list sub-router (REQ-078, design
  `lib/letflow/design/req078-supporting-routes.md` §6). Ports
  `src/api/routes/audit.zig`'s `handleList` (L21). Mounted at `/audit` by
  `Letflow.Plugs.ApiPipeline`, so the full path under `/api/v1` is
  `GET /api/v1/audit` — byte-identical to R-Co, and to the path
  `web/src/api/audit.ts` already calls.

  | Handler | Method/path         | Delegate                            | Permission   | Response                          |
  |---------|---------------------|-------------------------------------|--------------|-----------------------------------|
  | list    | `GET /audit`        | `Letflow.EventStore.read_global/1`  | `:AuditRead` | 200, `{items, next_cursor, count}` |

  ## Served from the event store, not an audit-entry table

  R-Co reads a dedicated `audit_entries` table (`src/obs/audit.zig:107`).
  **Letflow has no such table** — `grep -rn "audit_entries\|audit_log" priv/repo/ lib/`
  finds only a comment in one migration. REQ-078's own description redirects
  this route onto REQ-026's event read paths, so the audit list is served from
  the tenant-scoped `events` table via `Letflow.EventStore.read_global/1`.

  Consequences for the response body, all of which are visible to a caller and
  must not be mistaken for bugs:

    * `resource_type` is the constant string `"instance"`. Every Letflow event
      is instance-scoped; `events` has no second resource kind.
    * `before_state` and `after_state` are **always `null`**. Letflow's event
      model has no before/after capture. Emitting a fabricated value would be
      worse than `null`.
    * `pipeline_run_id` is `event.metadata["pipeline_run_id"]`, else `null`.
      `Letflow.Api.Context` reserves `:pipeline_run_id` as a
      documented-but-unwritten key, so nothing writes it today; the key is
      emitted as `null` rather than omitted, so the response shape is stable.
    * **`payload` is a Letflow addition**, not R-Co's `after_state`. It is the
      tenant's own event payload, returned to a caller inside that tenant
      holding `:AuditRead`. Without it the response carries no information
      about *what* changed, which would make the endpoint useless.

  ## Filter disposition — what has backing, and what does not

  R-Co's `ListAuditParams` (`audit.zig:10-19`) carries eight query params.
  None is silently dropped:

  | Param | Letflow | How |
  |---|---|---|
  | `cursor` | supported | opaque cursor over `global_seq` |
  | `page_size` | supported | `Letflow.Api.Pagination`, then `read_global/1`'s `:limit` |
  | `from` / `to` | supported | `read_global/1`'s `:from`/`:to`, inclusive bounds on `events.created_at` |
  | `actor_id` | supported | `read_global/1`'s `:actor_id` |
  | `resource_id` | supported | `read_global/1`'s `:instance_id` — R-Co's `resource_id` **is** this column |
  | `resource_type` | **not supported — accepted, and honoured truthfully** | Letflow's `events` table has exactly one resource type. A value other than `"instance"` returns an **empty page** (`items: []`, `next_cursor: null`, `count: 0`) with no query issued — a truthful answer, not a silently dropped filter. A missing param, or `"instance"`, is unfiltered. |
  | `pipeline_run_id` | **not supported — 422 if supplied non-empty** | Nothing writes `metadata["pipeline_run_id"]` yet, so filtering on it could only ever return an empty page *while looking like it worked*. An explicit 422 is honest; a silent empty page is not. Unsupported **until something populates the key** — when a writer exists, this becomes a real filter and the 422 goes away. |

  `from > to` is checked **in this route**, before any query, returning 422 —
  matching R-Co's own handler-level `invalid_time_range` check
  (`audit.zig:26-30`) rather than pushing it into the store.

  ## Two deliberate cursor divergences from R-Co, and one non-port

    * R-Co maps `InvalidCursor` -> **422** (`audit.zig:42`); **Letflow returns
      400.** Uniform cursor-error handling across the whole Letflow API beats
      per-endpoint R-Co fidelity: `lib/letflow/routers/tenants.ex:276`,
      `lib/letflow/routers/identity.ex:295` and `identity.ex:550` are all
      `Response.bad_request(conn, "invalid cursor")`, and `/audit` matches
      them.
    * R-Co maps `CursorExpired` -> **410** (`audit.zig:43`); **Letflow returns
      the same 400.** Expiry is already inside the
      `Letflow.Api.Pagination.decode_cursor/4` collapse, and `/audit` must not
      become the only Letflow endpoint that emits 410.
    * **503 `PoolExhausted`** (`audit.zig:45`) is a deliberate **non-port**,
      not an omission. Ecto/DBConnection surfaces pool exhaustion as a raised
      `DBConnection.ConnectionError`, not an `{:error, :pool_exhausted}`
      tuple, so there is no tuple to match and the clause would be a branch
      nothing can reach.

  `read_global/1`'s own `has_more` is documented there as a heuristic, not a
  proof: if exactly `limit` more rows exist and no others, `has_more` reports
  `true` and the very next page returns zero new rows. That ordinary
  cursor-pagination boundary case is inherited here unchanged.

  ## Authorization (REQ-131)

  `GET /audit` is declared via `authz_get "/", :AuditRead do ... end`
  (`Letflow.Api.AuthorizedRouter`) — `Letflow.Plugs.Authorize` evaluates
  `:AuditRead` before this module's handler ever runs. The route-local
  `with_authorization/4` copy that used to live here (a third copy of the
  helper also in `lib/letflow/routers/tenants.ex` and
  `lib/letflow/routers/identity.ex` before this requirement) is deleted, not
  adapted, per REQ-130's design §2.4.

  `Letflow.Api.Authorization.endpoint_policy_key("GET", "/audit")` already
  returns `:AuditRead`. Per `role_allows?/2`, `PLATFORM_ADMIN` and
  `PROCESS_OPERATOR` hold it; `PROCESS_DESIGNER`, `TASK_WORKER` and
  `AGENT_RUNNER` do not — so such a caller gets **403**, never a 404 and never
  an empty 200.

  ## Ordering guarantee

  Honours the contract stated in `Letflow.Routers.Tenants`'s moduledoc section
  **"Ordering guarantee (design §6.1)"**: no `Repo` call of any kind —
  including a pre-fetch read — happens before the preamble has resolved the
  scoped prefix and before `evaluate_access/2` has returned a
  non-`:Deny403` decision. A denied caller reaches no query at all. Here this
  is additionally structural: **this module performs no `Repo` call**; the one
  read is inside `Letflow.EventStore.read_global/1`, which cannot be reached
  without the prefix, because the prefix is its `opts` argument.

  ## INV-1 — the sharpest case in REQ-078

  The **only** tenant input is `Letflow.Api.Context.scoped_repo_opts/1`'s
  prefix, derived solely from `conn.assigns[:auth_context][:tenant_id]`. There
  is no query parameter, header, or body field through which another tenant's
  events could be selected: `read_global/1` is "global" only *within one
  tenant's schema*, and every filter this route passes narrows that set
  further, never widens it. An audit list that escaped scoping would disclose
  another tenant's **entire activity history in one response** — this is the
  sharpest INV-1 case in this requirement, and the reason the tenant is not
  merely filtered but physically unreachable.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.EventStore

  # A new endpoint prefix, distinct from "T:" (tenants) and "U:" (identity);
  # `decode_cursor/4`'s {:error, :wrong_endpoint} is what makes a cursor
  # minted by another endpoint fail here.
  @audit_cursor_prefix "A:"

  authz_get "/", :AuditRead do
    handle_list(conn)
  end

  match _ do
    Response.not_found(conn)
  end

  # ── GET /audit (design §6) ────────────────────────────────────────────────

  defp handle_list(conn) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    with :ok <- reject_pipeline_run_id(Map.get(query, "pipeline_run_id")),
         {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size),
         {:ok, after_global_seq} <- parse_cursor_param(Map.get(query, "cursor")),
         {:ok, from} <- parse_timestamp_param(Map.get(query, "from")),
         {:ok, to} <- parse_timestamp_param(Map.get(query, "to")),
         :ok <- check_time_range(from, to),
         {:ok, scope} <- {:ok, conn.assigns.scoped_opts} do
      if unsupported_resource_type?(Map.get(query, "resource_type")) do
        # A truthful empty page, with no query issued -- see the filter table.
        Response.ok(conn, page_body([], nil))
      else
        opts =
          Keyword.merge(scope,
            after_global_seq: after_global_seq,
            limit: page_size,
            actor_id: non_empty(Map.get(query, "actor_id")),
            instance_id: non_empty(Map.get(query, "resource_id")),
            from: from,
            to: to
          )

        render_page(conn, EventStore.read_global(opts))
      end
    else
      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")

      {:error, :invalid_cursor} ->
        Response.bad_request(conn, "invalid cursor")

      {:error, :invalid_time_range} ->
        Response.unprocessable(conn, "invalid time range")

      {:error, :invalid_filter} ->
        Response.unprocessable(conn, "invalid filter")
    end
  end

  defp render_page(conn, {:ok, %{events: events, has_more: has_more}}) do
    Response.ok(conn, page_body(events, next_cursor(events, has_more)))
  end

  defp render_page(conn, {:error, reason})
       when reason in [:invalid_actor_id, :invalid_instance_id] do
    Response.unprocessable(conn, "invalid filter")
  end

  # INV-4 -- Response.internal_error/1 has no detail slot, so no Postgrex or
  # payload-resolution detail can reach the body. No 503 branch: see the
  # moduledoc.
  defp render_page(conn, {:error, _schema_name_or_payload_or_other}) do
    Response.internal_error(conn)
  end

  # ── Parameter parsing ─────────────────────────────────────────────────────

  defp reject_pipeline_run_id(nil), do: :ok
  defp reject_pipeline_run_id(""), do: :ok
  defp reject_pipeline_run_id(_supplied), do: {:error, :invalid_filter}

  # "instance" (or absent/empty) is the only resource type `events` has.
  defp unsupported_resource_type?(nil), do: false
  defp unsupported_resource_type?(""), do: false
  defp unsupported_resource_type?("instance"), do: false
  defp unsupported_resource_type?(_other), do: true

  # Step 1 -- the COLLAPSE. Every decode_cursor/4 failure (:invalid_base64,
  # :wrong_endpoint, :expired, :invalid_cursor) folds into one route-level
  # error. Step 2 -- the STATUS -- is decided in handle_list/1's else block,
  # and it is 400, matching every other cursor call site in this codebase.
  defp parse_cursor_param(nil), do: {:ok, nil}
  defp parse_cursor_param(""), do: {:ok, nil}

  defp parse_cursor_param(raw) when is_binary(raw) do
    with {:ok, %Pagination.Cursor{inner: inner}} <-
           Pagination.decode_cursor(raw, @audit_cursor_prefix, byte_size(@audit_cursor_prefix)),
         {:ok, global_seq} <- global_seq_from_cursor(inner) do
      {:ok, global_seq}
    else
      _invalid_base64_or_wrong_endpoint_or_expired_or_invalid_cursor ->
        {:error, :invalid_cursor}
    end
  end

  # The raw payload is "A:<mint_time_us>:<global_seq>". This is the ONLY place
  # the cursor's internal layout is interpreted; no other module in REQ-078
  # parses it.
  defp global_seq_from_cursor(inner) do
    case Pagination.find_nth_colon(inner, 2) do
      nil ->
        {:error, :invalid_cursor}

      position ->
        Pagination.parse_int_from_cursor(inner, position + 1, byte_size(inner) - position - 1)
    end
  end

  defp parse_timestamp_param(nil), do: {:ok, nil}
  defp parse_timestamp_param(""), do: {:ok, nil}

  defp parse_timestamp_param(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, datetime, _utc_offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_time_range}
    end
  end

  defp check_time_range(nil, _to), do: :ok
  defp check_time_range(_from, nil), do: :ok

  defp check_time_range(from, to) do
    case DateTime.compare(from, to) do
      :gt -> {:error, :invalid_time_range}
      _lt_or_eq -> :ok
    end
  end

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value) when is_binary(value), do: value

  # ── Cursor minting ────────────────────────────────────────────────────────

  defp next_cursor([], _has_more), do: nil
  defp next_cursor(_events, false), do: nil

  defp next_cursor(events, true) do
    last = List.last(events)
    mint_time_us = System.system_time(:microsecond)

    @audit_cursor_prefix
    |> Pagination.build_raw_cursor(mint_time_us, Integer.to_string(last.global_seq))
    |> Pagination.encode_cursor()
  end

  # ── Response allowlist (INV-2) ────────────────────────────────────────────

  defp page_body(events, next_cursor) do
    items = Enum.map(events, &audit_item/1)

    %{
      "items" => items,
      "next_cursor" => next_cursor,
      # length(items), NOT a total -- matching audit.zig:54-77 and
      # web/src/api/audit.ts:36-40.
      "count" => length(items)
    }
  end

  # Hand-built, exactly ten keys -- never a Jason.Encoder derivation over
  # %Letflow.EventStore.Event{}, which would leak `sequence_number`,
  # `idempotency_key`, `global_seq` and the whole `metadata` map.
  @spec audit_item(EventStore.Event.t()) :: map()
  defp audit_item(event) do
    %{
      "audit_id" => event.event_id,
      "actor_id" => event.actor_id,
      "action" => event.event_type,
      "resource_type" => "instance",
      "resource_id" => event.instance_id,
      "pipeline_run_id" => pipeline_run_id(event.metadata),
      "timestamp" => iso8601(event.created_at),
      "before_state" => nil,
      "after_state" => nil,
      "payload" => event.payload
    }
  end

  defp pipeline_run_id(metadata) when is_map(metadata), do: Map.get(metadata, "pipeline_run_id")
  defp pipeline_run_id(_absent), do: nil

  # `events.created_at` is :utc_datetime_usec, so this is the %DateTime{}
  # clause of the same iso8601/1 convention Letflow.Routers.Tenants
  # establishes for NaiveDateTime columns.
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(nil), do: nil
end
