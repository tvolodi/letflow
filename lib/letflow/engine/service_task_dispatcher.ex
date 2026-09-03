defmodule Letflow.Engine.ServiceTaskDispatcher do
  @moduledoc """
  REQ-214 — SERVICE_TASK dispatch-orchestration core: HTTP transport, the
  SSRF gate, the `service_catalog` stub, and the poll-claim-decide loop
  against the `service_task_dispatches` table. See
  `lib/letflow/design/service_task_dispatcher.md` for the full design this
  module implements (gate-approved after one rework round). Plain Ecto
  context module, no process — same shape as `Letflow.Scheduler`/
  `Letflow.Dlq`. `Letflow.Engine.ServiceTaskDispatcher.Poller` (a separate
  module) calls into this one; this module itself starts no processes and
  owns no state.

  ## Scope boundary (design §1) — restated here, not re-decided

  This module does NOT touch `lib/letflow/engine/transition.ex` or
  `lib/letflow/engine.ex`. It never calls `Letflow.Engine.set_instance_error/2`,
  `Letflow.Engine.VariableMerge.merge/3`, or any token-advancement function —
  every `attempt_dispatch/2` call returns a typed `dispatch_outcome()` and
  stops; a FUTURE requirement (REQ-215) is the caller that acts on that
  outcome. `dispatch_node/4`'s own `:SERVICE_TASK` clause, and the
  activation-time caller that renders a URL template and INSERTs the first
  `service_task_dispatches` row, are both REQ-215's job — not built here.

  ## `route_kind: :catalog_service` — stub only (design §5.3)

  `catalog_lookup_stub/2` returns `{:error, :not_registered}`
  unconditionally for every `service_id`, because S6's real
  `service_catalog` subsystem (a DB-backed lookup resolving a `service_id`
  to a URL template) does not exist anywhere in this codebase yet. This is a
  REAL, CURRENT LIMITATION, not a placeholder to silently work around — a
  future S6 requirement is expected to replace this stub with a real
  lookup. No dispatch row with `route_kind: :catalog_service` can ever
  reach `:advance` through this module's own poll loop today; every such
  attempt gives up immediately (§5.3, §6, INV-STD-8).

  BLOCKER fix (TEST-DESIGNER finding, queue task 415): `do_attempt_dispatch/2`
  explicitly branches on `config.route_kind` — `:inline_url` goes through
  `http_transport/3` as before; `:catalog_service` calls
  `catalog_lookup_stub/2` instead and never reaches `:httpc.request/4` at
  all. The stub's `{:error, :not_registered}` is folded into the SAME
  `:request_build_error` failure_kind the SSRF-block and malformed-config
  paths already use — deterministic, non-retriable, no new failure_kind
  introduced.

  ## SSRF gate placement (INV-9, BLOCKER — design §5.2)

  `http_transport/3` is this module's single `transport_fun()`
  implementation and the ONLY call site in this module (and in
  `Poller`) that reaches `:httpc.request/4`. `Letflow.Webhooks.UrlValidator.validate/2`
  is called immediately before every such call, for `route_kind: :inline_url`
  (the only `route_kind` that ever reaches `http_transport/3` — see the
  `:catalog_service` section above) — unconditionally, with no bypass path
  in production. A blocked URL never reaches `:httpc.request/4`; it is
  classified `{:request_build_error, :target_url_not_allowed}` instead
  (design §5.2, §6).

  ## Test-only SSRF-validation bypass seam (TEST-DESIGNER finding, queue
  task 415)

  `http_transport/3` reads `Application.get_env(:letflow,
  :service_task_ssrf_validation_enabled, true)` and, only when explicitly
  set to `false`, delegates to a `dns_resolver()`-injectable `/4` variant
  instead of the real `UrlValidator.validate/1`/`default_resolver/1` path —
  mirroring `Letflow.Webhooks.dispatch_http/3,4`'s own identical mechanism
  (`lib/letflow/webhooks.ex:373-392`) exactly, including the flag name
  pattern (`:webhook_ssrf_validation_enabled` there, `:service_task_ssrf_validation_enabled`
  here). Defaults to `true` (validation ON) in every environment; only
  `test/letflow/engine/service_task_dispatcher_test.exs` ever sets it to
  `false`, scoped to individual tests via `Application.put_env/3` +
  `on_exit/1`, the same way `test/letflow/webhooks_delivery_test.exs` does.
  This is the ONLY way any test in this codebase can reach a genuine 2xx
  `:advance` outcome or a genuine retriable failure kind through this
  module — without it, `UrlValidator`'s unconditional 127.0.0.0/8 block
  makes `test/support/webhook_test_server.ex` (which only ever binds
  `127.0.0.1`) permanently unreachable through the real gate.

  ## URL freeze-at-INSERT / never-re-render / always-re-validate (OQ-3,
  RESOLVED — design §10)

  `config_snapshot["rendered_url"]` is frozen once, at INSERT time, by
  REQ-215's future activation-time caller. This module never renders a URL
  template and never writes `config_snapshot` — it only ever reads
  `row.config_snapshot["rendered_url"]` back, unchanged, on every attempt of
  a given row, first attempt and every `:retry`-driven re-claim alike.
  What changes attempt-to-attempt is only that `http_transport/3`'s own
  `UrlValidator.validate/2` call re-runs against that SAME frozen string
  every time — mirroring `Letflow.Webhooks.dispatch_http/3,4`'s own
  re-validate-every-attempt, never-re-render behavior
  (`lib/letflow/webhooks.ex:373-392`).
  """

  import Ecto.Query

  alias Letflow.Engine.ServiceTask
  alias Letflow.EventStore
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.Webhooks.UrlValidator

  @default_poll_interval_ms 5_000
  @default_jitter_ms 0
  @default_max_dispatches_per_cycle 64
  @default_backoff_base_ms 1_000
  @default_backoff_cap_ms 60_000

  @http_content_type ~c"application/json"

  defmodule ServiceTaskDispatch do
    @moduledoc """
    Ecto schema for the `service_task_dispatches` table. See
    `lib/letflow/design/service_task_dispatcher.md` §4. Ordinary
    `Ecto.Schema`, no process, no `gen_statem` — matches
    `Letflow.Scheduler.Timer`'s own plain-CRUD-table precedent. Nested here
    (rather than its own file, unlike `Timer`) per design §2/§10 OQ-1 — a
    deliberate, flagged, non-blocking deviation from the `timers` precedent,
    chosen because this schema has only 3 small changesets, not `Timer`'s 5.

    ## No `@schema_prefix`

    Like every other tenant-scoped table in this codebase, `service_task_dispatches`
    lives in many Postgres schemas — one per tenant — so every read and
    write must pass `prefix: schema_name` explicitly at call time.

    ## `status` — plain `:string`, not `Ecto.Enum` (design §3.1)

    DB-level CHECK constraint (`chk_service_task_dispatches_status`, the
    migration) restricts it to exactly `"pending"`/`"advanced"`/`"given_up"`
    — the DB constraint is the acceptance-criterion-mandated backstop, so
    this schema stays plain `:string` (mirrors `Timer.status`'s own
    rationale).

    ## No `timestamps/1`

    `next_attempt_at`/`dispatched_at`/`created_at` are specific, narrow
    timestamp columns this table's own contract names — not a generic
    last-modified column nothing in the acceptance criteria requires.

    ## Changesets — one per distinct write path (design §4.2)

    `arm_changeset/2` — defined here (this module owns the schema) but
    called only by REQ-215's future activation-time caller, exactly the
    same division-of-labor `Timer.rearm_changeset/2`'s own moduledoc note
    describes. `retry_changeset/2` and `terminal_changeset/2` back
    `attempt_dispatch/2`'s own same-transaction updates.
    """

    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: false}
    schema "service_task_dispatches" do
      field(:tenant_id, Ecto.UUID)
      field(:instance_id, Ecto.UUID)
      field(:token_id, Ecto.UUID)

      field(:node_id, :string)
      field(:config_snapshot, :map)

      field(:attempt_index, :integer, default: 0)
      field(:next_attempt_at, :utc_datetime_usec)

      field(:status, :string, default: "pending")
      field(:last_failure_kind, :string)
      field(:dispatched_at, :utc_datetime_usec)

      field(:created_at, :utc_datetime_usec)
    end

    @type config_snapshot :: %{
            required(String.t()) => String.t() | non_neg_integer() | map() | nil
          }

    @type t :: %__MODULE__{
            id: Ecto.UUID.t(),
            tenant_id: Ecto.UUID.t(),
            instance_id: Ecto.UUID.t(),
            token_id: Ecto.UUID.t(),
            node_id: String.t(),
            config_snapshot: config_snapshot(),
            attempt_index: non_neg_integer(),
            next_attempt_at: DateTime.t(),
            status: String.t(),
            last_failure_kind: String.t() | nil,
            dispatched_at: DateTime.t() | nil,
            created_at: DateTime.t()
          }

    @statuses ~w(pending advanced given_up)

    @doc """
    Structural changeset for the (REQ-215-owned) INSERT path — defined here,
    called only by REQ-215's future activation-time caller (design §4.2).
    `attempt_index` and `status` are not castable through this changeset —
    always forced to `0` and `"pending"` respectively by the caller,
    matching `Timer.arm_changeset/2`'s "status is not castable" discipline.
    """
    @spec arm_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
    def arm_changeset(dispatch, attrs) do
      dispatch
      |> cast(attrs, [
        :id,
        :tenant_id,
        :instance_id,
        :token_id,
        :node_id,
        :config_snapshot,
        :next_attempt_at,
        :created_at
      ])
      |> validate_required([
        :id,
        :tenant_id,
        :instance_id,
        :token_id,
        :node_id,
        :config_snapshot,
        :next_attempt_at,
        :created_at
      ])
    end

    @doc """
    Structural changeset for the `:retry` decision's same-transaction update
    (design §5.6). `status` stays `"pending"` — not cast, never changes on a
    retry.
    """
    @spec retry_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
    def retry_changeset(dispatch, attrs) do
      dispatch
      |> cast(attrs, [:attempt_index, :next_attempt_at, :last_failure_kind])
      |> validate_required([:attempt_index, :next_attempt_at])
    end

    @doc """
    Structural changeset for the `:advance`/`:give_up` terminal update
    (design §5.6). `status` must be cast to exactly `"advanced"` or
    `"given_up"` by the caller.
    """
    @spec terminal_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
    def terminal_changeset(dispatch, attrs) do
      dispatch
      |> cast(attrs, [:status, :last_failure_kind, :dispatched_at])
      |> validate_required([:status, :dispatched_at])
      |> validate_inclusion(:status, @statuses)
    end
  end

  # ===========================================================================
  # Config accessors (design §5.1)
  # ===========================================================================

  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms do
    dispatcher_config()[:poll_interval_ms] || @default_poll_interval_ms
  end

  @spec jitter_ms() :: non_neg_integer()
  def jitter_ms do
    dispatcher_config()[:jitter_ms] || @default_jitter_ms
  end

  @spec max_dispatches_per_cycle() :: pos_integer()
  def max_dispatches_per_cycle do
    dispatcher_config()[:max_dispatches_per_cycle] || @default_max_dispatches_per_cycle
  end

  @spec default_backoff_base_ms() :: pos_integer()
  def default_backoff_base_ms do
    dispatcher_config()[:default_backoff_base_ms] || @default_backoff_base_ms
  end

  @spec default_backoff_cap_ms() :: pos_integer()
  def default_backoff_cap_ms do
    dispatcher_config()[:default_backoff_cap_ms] || @default_backoff_cap_ms
  end

  defp dispatcher_config, do: Application.get_env(:letflow, :service_task_dispatcher, [])

  # ===========================================================================
  # http_transport/3 -- design §5.2. The single :httpc.request/4 call site.
  # ===========================================================================

  @doc """
  The concrete `Letflow.Engine.ServiceTask.transport_fun()` value this
  module supplies. `rendered_url` is the value frozen once at the claimed
  row's own INSERT time (`row.config_snapshot["rendered_url"]`) — this
  function never renders anything, it only ever receives an
  already-rendered string, on every attempt including every retry.

  SSRF gate (INV-9, BLOCKER): `UrlValidator.validate/2` is called
  IMMEDIATELY before the `do_http_transport/3` step that issues
  `:httpc.request/4` — no intervening code path reaches `:httpc.request/4`
  without passing this check first (the gate lives here, inside the
  transport itself, not duplicated per-`route_kind` — so it is
  structurally unbypassable by construction).

  `:service_task_ssrf_validation_enabled` defaults to `true`; set to
  `false` in tests only so a real local `:gen_tcp` test server's
  `http://127.0.0.1:PORT` URL passes — mirrors
  `Letflow.Webhooks.dispatch_http/3`'s own identical
  `:webhook_ssrf_validation_enabled` mechanism exactly
  (`lib/letflow/webhooks.ex:373-381`).
  """
  @spec http_transport(
          ServiceTask.Config.t(),
          rendered_url :: String.t(),
          rendered_body :: String.t() | nil
        ) ::
          ServiceTask.raw_outcome()
  def http_transport(%ServiceTask.Config{} = config, rendered_url, rendered_body)
      when is_binary(rendered_url) do
    if Application.get_env(:letflow, :service_task_ssrf_validation_enabled, true) do
      http_transport(config, rendered_url, rendered_body, &UrlValidator.default_resolver/1)
    else
      do_http_transport(config, rendered_url, rendered_body)
    end
  end

  @doc """
  Test-injectable variant taking an explicit `dns_resolver()`, mirroring
  `Letflow.Webhooks.dispatch_http/4`'s own identical shape
  (`lib/letflow/webhooks.ex:384-392`). Not part of `transport_fun()`'s
  3-arity contract — used directly only by
  `test/letflow/engine/service_task_dispatcher_test.exs` for DNS-rebinding-
  style coverage; ordinary dispatch always goes through the 3-arity clause
  above.
  """
  @spec http_transport(
          ServiceTask.Config.t(),
          rendered_url :: String.t(),
          rendered_body :: String.t() | nil,
          dns_resolver :: UrlValidator.dns_resolver()
        ) ::
          ServiceTask.raw_outcome()
  def http_transport(%ServiceTask.Config{} = config, rendered_url, rendered_body, dns_resolver)
      when is_binary(rendered_url) do
    case UrlValidator.validate(rendered_url, dns_resolver) do
      {:error, :target_url_not_allowed} ->
        {:request_build_error, :target_url_not_allowed}

      :ok ->
        do_http_transport(config, rendered_url, rendered_body)
    end
  end

  @spec do_http_transport(
          ServiceTask.Config.t(),
          rendered_url :: String.t(),
          rendered_body :: String.t() | nil
        ) ::
          ServiceTask.raw_outcome()
  defp do_http_transport(%ServiceTask.Config{} = config, rendered_url, rendered_body) do
    request =
      {String.to_charlist(rendered_url), headers_from(config), @http_content_type,
       body_or_empty(rendered_body)}

    method_atom(config.method)
    |> :httpc.request(request, [{:timeout, config.timeout_ms}], [])
    |> case do
      {:ok, {{_http_version, status, _reason_phrase}, _resp_headers, resp_body}} ->
        {:http, status, to_string_or_nil(resp_body)}

      {:error, :timeout} ->
        :timeout

      {:error, reason} ->
        {:network, reason}
    end
  end

  @spec method_atom(ServiceTask.Config.http_method()) :: :get | :post | :put | :patch | :delete
  defp method_atom(:GET), do: :get
  defp method_atom(:POST), do: :post
  defp method_atom(:PUT), do: :put
  defp method_atom(:PATCH), do: :patch
  defp method_atom(:DELETE), do: :delete

  # Always injects content-type from config.body_template's presence,
  # mirroring Webhooks.do_dispatch_http/3's own hardcoded
  # `content-type: application/json` header (design §5.2, §10 OQ-2).
  defp headers_from(%ServiceTask.Config{headers: headers, body_template: body_template}) do
    base =
      Enum.map(headers, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)

    if body_template do
      [{~c"content-type", @http_content_type} | base]
    else
      base
    end
  end

  defp body_or_empty(nil), do: ~c""
  defp body_or_empty(body) when is_binary(body), do: body

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(body), do: to_string(body)

  # ===========================================================================
  # catalog_lookup_stub/2 -- design §5.3
  # ===========================================================================

  @doc """
  Unconditional `{:error, :not_registered}` for every input, matching
  REQ-056's `catalog_lookup_fun()` type exactly. S6's real
  `service_catalog` does not exist anywhere in this codebase yet — this
  stub exists so the type/contract is concretely satisfied, not to silently
  approximate real catalog resolution.
  """
  @spec catalog_lookup_stub(service_id :: String.t(), tenant_id :: Ecto.UUID.t()) ::
          {:error, :not_registered}
  def catalog_lookup_stub(service_id, tenant_id)
      when is_binary(service_id) and is_binary(tenant_id) do
    {:error, :not_registered}
  end

  # ===========================================================================
  # claim_due_dispatch_ids/2 -- design §5.4, the hot claim query
  # ===========================================================================

  @doc """
  Two-step select-then-lock (design §5.4, reworked per
  CODE-DESIGN-VALIDATOR's BLOCKER finding). Step 1 selects eligible ids via
  an UNLOCKED joined query (`instance_projections.status == :active`
  filter) — no `lock/1` call anywhere in that query. Step 2 locks ONLY
  `service_task_dispatches` rows, by id, in a second, single-table query —
  mirrors `Letflow.Scheduler.claim_due_timer_ids/2`'s own bare
  `lock("FOR UPDATE SKIP LOCKED")` idiom exactly (no join present in the
  locking query at all, so there is no `FOR UPDATE OF <binding>`
  ambiguity to resolve).

  A row whose instance is no longer `:active` is excluded from step 1
  entirely — never selected, never reaches step 2's lock, its own `status`
  column left untouched (INV-STD-4).
  """
  @spec claim_due_dispatch_ids(tenant_schema :: String.t(), limit :: pos_integer()) :: [
          Ecto.UUID.t()
        ]
  def claim_due_dispatch_ids(tenant_schema, limit)
      when is_binary(tenant_schema) and is_integer(limit) and limit > 0 do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    eligible_ids =
      ServiceTaskDispatch
      |> join(:inner, [d], p in InstanceProjection, on: p.instance_id == d.instance_id)
      |> where(
        [d, p],
        d.status == "pending" and d.next_attempt_at <= ^now and p.status == :active
      )
      |> order_by([d], asc: d.next_attempt_at)
      |> limit(^limit)
      |> select([d], d.id)
      |> Repo.all(prefix: tenant_schema)

    ServiceTaskDispatch
    |> where([d], d.id in ^eligible_ids)
    |> select([d], d.id)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all(prefix: tenant_schema)
  end

  # ===========================================================================
  # poll_and_dispatch/1 -- design §5.5, the tick entry point
  # ===========================================================================

  @type dispatch_poll_result :: %{
          tenant_schema: String.t(),
          claimed: non_neg_integer(),
          advanced: non_neg_integer(),
          retried: non_neg_integer(),
          given_up: non_neg_integer()
        }

  @doc """
  Called once per tenant schema per tick by `ServiceTaskDispatcher.Poller`,
  never by application code directly. Never raises — every per-row failure
  is caught internally (`attempt_dispatch/2`'s own `Repo.transaction/1`
  boundary) and folded into the returned counts (design §5.5, INV-STD-5).
  """
  @spec poll_and_dispatch(tenant_schema :: String.t()) :: dispatch_poll_result()
  def poll_and_dispatch(tenant_schema) when is_binary(tenant_schema) do
    dispatch_ids = claim_due_dispatch_ids(tenant_schema, max_dispatches_per_cycle())

    Enum.reduce(
      dispatch_ids,
      %{
        tenant_schema: tenant_schema,
        claimed: length(dispatch_ids),
        advanced: 0,
        retried: 0,
        given_up: 0
      },
      fn dispatch_id, acc ->
        fold_attempt_result(attempt_dispatch(dispatch_id, tenant_schema), acc)
      end
    )
  end

  defp fold_attempt_result({:ok, {:advance, _decoded_body}}, acc),
    do: %{acc | advanced: acc.advanced + 1}

  defp fold_attempt_result({:ok, :retry_scheduled}, acc), do: %{acc | retried: acc.retried + 1}

  defp fold_attempt_result({:ok, {:give_up, _standalone_error_attrs}}, acc),
    do: %{acc | given_up: acc.given_up + 1}

  defp fold_attempt_result({:ok, :already_final}, acc), do: acc
  defp fold_attempt_result({:error, _reason}, acc), do: acc

  # ===========================================================================
  # attempt_dispatch/2 -- design §5.6, one row, one transaction
  # ===========================================================================

  @type dispatch_outcome ::
          {:advance, decoded_body :: map()}
          | {:give_up, Letflow.Engine.standalone_error_attrs()}
          | :retry_scheduled

  @doc """
  Mirrors `Letflow.Scheduler.fire_timer/2`'s one-`Repo.transaction/1`-per-
  claimed-row shape exactly (design §5.6). Never calls
  `Letflow.Engine.set_instance_error/2` or `ExecutionError.append_multi/3`
  anywhere in this function or its helpers (INV-STD-2).

  BLOCKER fix (SECURITY-REVIEWER, queue task 415): the `Repo.transaction/1`
  call is wrapped in an outer `try/rescue`, mirroring
  `Letflow.Scheduler.attempt_fire/2`'s own boundary
  (`lib/letflow/scheduler.ex:415-421`) exactly. `Repo.transaction/1` does
  NOT swallow a raise — only `Repo.rollback/1`'s cooperative throw becomes
  `{:error, reason}` — so this outer boundary is what actually makes
  `poll_and_dispatch/1`'s "never raises" contract (design §5.5, INV-STD-5)
  true, for any raise this function's helpers produce, anticipated or not.
  `config_from_snapshot/1`'s own two helpers (`route_kind_atom/1`,
  `method_from_snapshot/1`) are additionally hardened to return a typed
  error instead of raising in the first place (belt and suspenders) — see
  their own docs below.
  """
  @spec attempt_dispatch(dispatch_id :: Ecto.UUID.t(), tenant_schema :: String.t()) ::
          {:ok, dispatch_outcome()} | {:ok, :already_final} | {:error, term()}
  def attempt_dispatch(dispatch_id, tenant_schema) when is_binary(tenant_schema) do
    try do
      Repo.transaction(fn ->
        case fetch_and_lock_dispatch(dispatch_id, tenant_schema) do
          nil ->
            {:ok, :already_final}

          %ServiceTaskDispatch{status: status} when status != "pending" ->
            {:ok, :already_final}

          %ServiceTaskDispatch{} = row ->
            do_attempt_dispatch(row, tenant_schema)
        end
        |> case do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    rescue
      exception -> {:error, {:raised, exception}}
    end
  end

  defp fetch_and_lock_dispatch(dispatch_id, tenant_schema) do
    ServiceTaskDispatch
    |> where([d], d.id == ^dispatch_id)
    |> lock("FOR UPDATE")
    |> Repo.one(prefix: tenant_schema)
  end

  defp do_attempt_dispatch(%ServiceTaskDispatch{} = row, tenant_schema) do
    case config_from_snapshot(row) do
      {:ok, %ServiceTask.Config{route_kind: :inline_url} = config} ->
        rendered_url = row.config_snapshot["rendered_url"]
        rendered_body = row.config_snapshot["body_template"]

        raw_outcome = http_transport(config, rendered_url, rendered_body)

        case ServiceTask.classify_failure_kind(raw_outcome) do
          {:success, decoded_body} ->
            handle_success(row, tenant_schema, decoded_body)

          failure_kind ->
            handle_failure(row, tenant_schema, config.retry_limit, failure_kind)
        end

      # BLOCKER fix (TEST-DESIGNER finding, queue task 415): route_kind:
      # :catalog_service must call catalog_lookup_stub/2, not
      # http_transport/3 -- S6's real service_catalog does not exist yet
      # (§5.3 above), so this row can never advance today. The stub's
      # {:error, :not_registered} is classified identically to a
      # {:request_build_error, _} raw_outcome would be (design §5.2/§5.6's
      # existing :request_build_error precedent) -- no new failure_kind,
      # and :httpc.request/4 is never called for this route_kind at all.
      {:ok, %ServiceTask.Config{route_kind: :catalog_service} = config} ->
        {:error, :not_registered} = catalog_lookup_stub(config.service_id, row.tenant_id)
        handle_failure(row, tenant_schema, config.retry_limit, :request_build_error)

      {:error, _malformed_reason} ->
        # BLOCKER fix (SECURITY-REVIEWER, queue task 415) -- a malformed
        # config_snapshot (bad route_kind or bad method string) can never
        # build a request in the first place, so it is classified exactly
        # like ServiceTask.classify_failure_kind/1's own
        # {:request_build_error, _} raw_outcome clause would classify it
        # (design §5.2/§5.6's existing :request_build_error failure_kind) --
        # no new failure_kind is introduced, and http_transport/3 is never
        # called for this row. retry_limit is read directly from the
        # snapshot (never from the Config.t() this branch failed to build)
        # since it does not depend on route_kind/method at all.
        handle_failure(
          row,
          tenant_schema,
          row.config_snapshot["retry_limit"],
          :request_build_error
        )
    end
  end

  # Rebuilds a Config.t() from row.config_snapshot -- a plain map-to-struct
  # projection. Does NOT call parse_config_from_node_attributes/1 again
  # (design §5.6 step 1) -- the snapshot was already parsed once by
  # REQ-215's activation-time caller.
  #
  # BLOCKER fix (SECURITY-REVIEWER, queue task 415): returns {:error, _}
  # instead of raising when the snapshot is malformed -- a single corrupt
  # row (a future bug elsewhere, a manual DB edit, a genuinely-never-
  # interned atom after a BEAM restart) must fold into a per-row outcome,
  # not crash the shared Poller process and take down every other tenant's
  # pending rows in the same poll cycle.
  @spec config_from_snapshot(ServiceTaskDispatch.t()) ::
          {:ok, ServiceTask.Config.t()} | {:error, :invalid_route_kind | :invalid_method}
  defp config_from_snapshot(%ServiceTaskDispatch{config_snapshot: snapshot, node_id: node_id}) do
    with {:ok, route_kind} <- route_kind_atom(snapshot["route_kind"]),
         {:ok, method} <- method_from_snapshot(snapshot["method"]) do
      {:ok,
       %ServiceTask.Config{
         node_id: node_id,
         route_kind: route_kind,
         url_template: snapshot["url_template"],
         service_id: snapshot["service_id"],
         method: method,
         body_template: snapshot["body_template"],
         headers: snapshot["headers"] || %{},
         timeout_ms: snapshot["timeout_ms"],
         retry_limit: snapshot["retry_limit"]
       }}
    end
  end

  @spec route_kind_atom(term()) ::
          {:ok, :inline_url | :catalog_service} | {:error, :invalid_route_kind}
  defp route_kind_atom("inline_url"), do: {:ok, :inline_url}
  defp route_kind_atom("catalog_service"), do: {:ok, :catalog_service}
  defp route_kind_atom(_other), do: {:error, :invalid_route_kind}

  # Bounded, explicit mapping over the known method strings -- never
  # String.to_existing_atom/1 (BLOCKER fix, SECURITY-REVIEWER, queue task
  # 415). Unbounded to_existing_atom on stored/external-adjacent data is a
  # hazard independent of the crash bug: the atom table is finite, and
  # whether a given string was ever interned is not something this module
  # controls or should depend on. Mirrors ServiceTask's own closed
  # @valid_methods ~w(GET POST PUT PATCH DELETE)a set
  # (lib/letflow/engine/service_task.ex:165).
  @spec method_from_snapshot(term()) ::
          {:ok, ServiceTask.Config.http_method()} | {:error, :invalid_method}
  defp method_from_snapshot("GET"), do: {:ok, :GET}
  defp method_from_snapshot("POST"), do: {:ok, :POST}
  defp method_from_snapshot("PUT"), do: {:ok, :PUT}
  defp method_from_snapshot("PATCH"), do: {:ok, :PATCH}
  defp method_from_snapshot("DELETE"), do: {:ok, :DELETE}
  defp method_from_snapshot(_other), do: {:error, :invalid_method}

  defp handle_success(%ServiceTaskDispatch{} = row, tenant_schema, decoded_body) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row
    |> ServiceTaskDispatch.terminal_changeset(%{status: "advanced", dispatched_at: now})
    |> Repo.update(prefix: tenant_schema)
    |> case do
      {:ok, _updated} -> {:ok, {:advance, decoded_body}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # Takes retry_limit directly (not a Config.t()) so a malformed-snapshot
  # row -- which never successfully builds a Config.t() -- can still reach
  # this same failure-handling path (BLOCKER fix, SECURITY-REVIEWER, queue
  # task 415). retry_limit does not depend on route_kind/method, so reading
  # it straight from the snapshot is always valid here.
  defp handle_failure(%ServiceTaskDispatch{} = row, tenant_schema, retry_limit, failure_kind) do
    case ServiceTask.decide_failure(failure_kind, row.attempt_index, retry_limit) do
      :retry -> handle_retry(row, tenant_schema, failure_kind)
      :give_up -> handle_give_up(row, tenant_schema, failure_kind, retry_limit)
    end
  end

  defp handle_retry(%ServiceTaskDispatch{} = row, tenant_schema, failure_kind) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    next_delay_ms =
      ServiceTask.compute_service_task_backoff_ms(
        row.attempt_index,
        default_backoff_base_ms(),
        default_backoff_cap_ms()
      )

    retry_attrs = %{
      attempt_index: row.attempt_index + 1,
      next_attempt_at: DateTime.add(now, next_delay_ms, :millisecond),
      last_failure_kind: to_string(failure_kind)
    }

    row
    |> ServiceTaskDispatch.retry_changeset(retry_attrs)
    |> Repo.update(prefix: tenant_schema)
    |> case do
      {:ok, _updated} -> {:ok, :retry_scheduled}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp handle_give_up(%ServiceTaskDispatch{} = row, tenant_schema, failure_kind, retry_limit) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    idempotency_key =
      ServiceTask.build_idempotency_key(
        row.instance_id,
        row.node_id,
        row.token_id,
        row.attempt_index
      )

    # design §10 OQ-4 -- this module holds no InstanceState and calls no
    # Letflow.Engine.Reconstruction/snapshot-reading function; `variables`
    # is populated as %{} and `actor_id` as EventStore.platform_actor_id()
    # (the same "no human/API actor" sentinel Letflow.Scheduler's own
    # TIMER_FIRED event append already uses), both flagged placeholders per
    # the design's own resolution -- not silently invented here.
    give_up_context = %{
      instance_id: row.instance_id,
      node_id: row.node_id,
      actor_id: EventStore.platform_actor_id(),
      idempotency_key: idempotency_key,
      variables: %{},
      last_failure_kind: failure_kind,
      attempt_index: row.attempt_index,
      retry_limit: retry_limit
    }

    standalone_error_attrs = ServiceTask.build_service_task_give_up_error_attrs(give_up_context)

    terminal_attrs = %{
      status: "given_up",
      dispatched_at: now,
      last_failure_kind: to_string(failure_kind)
    }

    row
    |> ServiceTaskDispatch.terminal_changeset(terminal_attrs)
    |> Repo.update(prefix: tenant_schema)
    |> case do
      {:ok, _updated} -> {:ok, {:give_up, standalone_error_attrs}}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
