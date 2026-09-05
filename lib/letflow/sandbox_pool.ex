defmodule Letflow.SandboxPool do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Ephemeral Postgres-schema sandbox pool (ports R-Co's `src/definition/sandbox_pool.zig`
  per PRM-06/PRM-07 — see `src/design/prm-batch1-promotion-assertion-rerun.md`).

  `claim/1` provisions a fresh, empty Postgres schema (already scaffolded with every
  `Letflow.TenantProvisioning.tenant_scoped_migrations/0` table, so it looks exactly like
  a real tenant schema) under a hard `max_concurrent_sandboxes` quota; `release/1` drops
  it. Sandbox schemas are NOT tenant schemas — they carry no
  `Letflow.TenantProvisioning.Registration` row and use their own `"sandbox_" <> hex`
  naming scheme, never `"tenant_" <> hex`.

  ## Process-per-instance vs. row-based state (REQ-039's open question, resolved here)

  PROVENANCE (historical, not current decision authority):
  REQ-039 explicitly flagged this as an open question rather than assuming an answer,
  citing `docs/migration/stage-2-event-store-definitions.md`'s "Early findings" section
  (process-vs-row) and `sandbox_pool.zig`'s own moduledoc ("The pool records every active
  claim in a process-local table"). CODE-DESIGNER resolved it in
  `lib/letflow/design/req039-sandbox-pool-fixture-loader.md` §2: this module is a single
  supervised `GenServer` (not a `DynamicSupervisor`-per-claim, and not a plain Ecto row),
  because `claim/1`'s blocking-quota-wait requirement (two callers racing for the last
  free slot must never both win, and a losing caller must park until either a slot frees
  or its own wait window elapses) needs one serialization point to arbitrate correctly —
  a property a single process's mailbox provides natively and a row-based design would
  need to re-derive via an additional DB-level lock. This is distinct from why
  `Letflow.InstanceSupervisor` uses one process *per* instance: that exists for crash
  isolation between autonomous, long-lived actors, which a claimed sandbox (inert data
  between `claim` and `release`) is not (REQ-052 deleted the once-analogous
  `Letflow.ApprovalSupervisor`, per its own design doc §2). See the design
  doc §2 for the full reasoning, including the accepted trade-off that pool state does
  not survive a `SandboxPool` process restart (design doc §11 OQ-3).

  ## Same-process claim/release contract

  A claim belongs to the process that called `claim/2` — it must be that same process
  which later calls `release/2` for the returned `sandbox_id`. This is enforced by the
  owner-monitor mechanism, not merely documented: `claim/2` monitors whichever process
  calls it, so handing the claim to a different process (e.g. via `Task.async`, whose
  spawned process exits as soon as it returns its value) looks identical, from the
  pool's perspective, to that process crashing, and the slot is reclaimed accordingly.
  This mirrors the same idiom OTP itself uses for its own lock-shaped resources — e.g.
  `:global.set_lock/3`'s lock is likewise tied to the calling process — rather than
  providing an explicit ownership-transfer primitive (which OTP itself only offers,
  e.g. `:ets.give_away/3`, when transfer is a genuine requirement; it is not one here).
  See `lib/letflow/design/iss-0048-sandbox-pool-owner-crash-reclaim.md` §13 for the full
  reasoning.

  ## One serialized DB worker: no `Repo` call runs inside a pool callback

  Until ISS-0224 both `provision_sandbox/0` and `drop_schema/1` ran *inside* the pool's
  own callbacks. A `GenServer` executing a callback processes no other message, so for
  the whole duration of a provisioning — a `CREATE SCHEMA` plus a replay of 31
  migrations, measured at 411 ms at its very fastest — the pool's mailbox was frozen,
  including a parked waiter's own `{:claim_timeout, _}` timer message. `max_wait_ms` was
  therefore not honoured under contention: a waiter overshot its window by up to one
  full provisioning (measured: +246..+528 ms against `max_wait_ms` values of 100-200).

  Every `Repo` call now runs in a `Task.Supervisor.async_nolink/3` worker instead, and
  the pool owns a FIFO queue (`db_queue`) of pending DB operations — `{:provision, _}`
  and `{:drop, _}` alike. **At most one DB operation is in flight at any time**:
  `in_flight` is either `nil` or exactly one record, so there is nowhere to put a
  second, and the serialization is structural rather than an invariant to maintain.
  That is what keeps peak concurrent `DBConnection` checkouts attributable to the pool
  at **2** — a provisioning's own checkout plus `Ecto.Migrator`'s inner `Task.async` —
  exactly what the fully-synchronous module peaked at, so the pool still imposes no
  coupling between `max_concurrent` and the Repo's `pool_size`. FIFO ordering also means
  a pending DROP always runs before a later provisioning, so the two never contend.

  Pool *state* mutation is still serialized at the one arbitration point this module
  exists to provide: the worker receives plain strings and returns a result, and mutates
  no pool state whatsoever. What now overlaps in wall-clock time is only the DDL side
  effect, and always against a freshly-minted, globally-unique schema.

  A slot is reserved — and its owner monitored — *before* any DB work starts, so no
  window exists in which a provisioning is in progress and its slot uncounted, or in
  which a claim-in-progress has no owner monitor. `Task.await/2`, `Task.yield/2` and
  `Task.shutdown/2` must never be called from a callback in this module: each of them
  re-blocks the mailbox and reverts this design while leaving the code looking correct.
  See `lib/letflow/design/iss0224-sandbox-pool-async-provisioning.md`.

  ## Two budgets: queue wait vs. provisioning

  Until ISS-0220 `claim/2` conflated two unrelated waits into one number. They are now
  separate, and separately derived:

    * `max_wait_ms` -- passed per call -- bounds **queue parking only**: how long a
      caller may sit in the pool's `waiting` queue for a slot to free. Its meaning, its
      guard and its `Process.send_after/3` timer are unchanged.
    * `provision_timeout_ms/0` bounds **one provisioning**: a `CREATE SCHEMA` plus a
      replay of every `Letflow.TenantProvisioning.tenant_scoped_migrations/0` migration
      into it -- 31 migrations, 32 transactions.

  `claim/2`'s `GenServer.call/3` timeout is therefore the sum of the two
  (`claim_call_timeout/1`): the queue wait the caller explicitly asked for, plus one
  calibrated provisioning. Some such budget is a mechanical necessity -- without it
  `GenServer.call`'s own default 5_000 ms would raise a caller-side `:timeout` exit
  before the pool ever replied, whenever `max_wait_ms` approached or exceeded it.

  `release/2` uses the provisioning budget alone (`release_call_timeout/0`). That is
  **not** because a `DROP SCHEMA ... CASCADE` costs anything like that -- it is two
  orders of magnitude cheaper. Since ISS-0224 it is also no longer true that nothing
  blocks the pool's mailbox ahead of a release: the mailbox is never blocked at all any
  more, but a release's own DROP is queued behind an in-flight provisioning, so the
  release path's real requirement is now "one provisioning plus one DROP" rather than
  the DROP alone. The budget is unchanged and remains correctly sized for that
  (measured: 441-601 ms against 44 000 ms). Its original reason stands untouched too:
  `Letflow.Definitions.safe_release/2` contains release failures with `rescue`, which
  structurally cannot catch the `exit` a call timeout raises, so an over-budget release
  escapes the one wrapper built to swallow it -- and does so on the path that is already
  handling an exception.

  Both budgets are **caller-side allowances, not server-side aborts**: nothing aborts a
  slow provisioning. `Ecto.Migrator` runs with `timeout: :infinity` at every level it
  controls, so when the budget elapses the *caller* exits with
  `{:timeout, {GenServer, :call, ...}}` while the pool keeps provisioning to completion.

  The default budget is derived from measurement in
  `lib/letflow/design/iss0220-sandbox-pool-provision-timeout.md` §4 -- do not change
  that number without redoing the derivation.
  """

  use GenServer
  require Logger

  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  defmodule SandboxClaim do
    @moduledoc """
    A single claimed sandbox: its opaque `sandbox_id` and the real Postgres schema
    name provisioned for it. Plain struct, not an `Ecto.Schema` — this value is never
    persisted (see `lib/letflow/design/req039-sandbox-pool-fixture-loader.md` §4.1).
    """

    @enforce_keys [:sandbox_id, :schema_name]
    defstruct [:sandbox_id, :schema_name]

    @type t :: %__MODULE__{sandbox_id: String.t(), schema_name: String.t()}
  end

  # Default per-provisioning budget, in milliseconds -- see the moduledoc's "Two
  # budgets" section. Supersedes the @call_timeout_buffer_ms 5_000 that stood here
  # before ISS-0220, which was sized against GenServer.call/2's own default rather
  # than against what one provisioning actually costs.
  @default_provision_timeout_ms 44_000

  # The named Task.Supervisor every DB operation runs under (ISS-0224). A name, not a
  # tunable -- no number, nothing to derive. Letflow.Application starts it BEFORE
  # {Letflow.SandboxPool, []}: a supervisor started after its dependant would make
  # Task.Supervisor.async_nolink/3 exit :noproc inside a pool callback and kill the
  # pool, for any claim arriving in that window.
  @task_supervisor Letflow.SandboxPool.TaskSupervisor

  # A unit of DB work queued in `db_queue` and executed, one at a time, by a worker
  # Task (design §5). `sandbox_id`/`schema_name` are pre-minted by the pool rather
  # than by the worker: that is the only thing that lets the pool issue a compensating
  # drop when a worker CRASHES without returning a value, and without it a crashed
  # worker's half-created schema would be unnameable and leak permanently.
  @typep provision_op :: %{
           from: GenServer.from(),
           owner_ref: reference(),
           sandbox_id: String.t(),
           schema_name: String.t(),
           owner_down?: boolean()
         }

  # `purpose` decides exactly two things at completion and nothing else: whether a
  # reply is owed (`:release` only -- the other three carry `from: nil`) and whether a
  # FAILED drop retains the `active` entry (`:release` only -- INV-SP-5 is a
  # live-owner guarantee; with no live owner there is nobody to retry, so
  # INV-SP-DOWN-3 governs instead and the slot is never held hostage).
  # `:release_orphaned` is produced ONLY by rewriting an existing `:release` op in
  # place when its owner dies (handle_info/2 clause B case 4b) -- never enqueued fresh.
  @typep drop_op :: %{
           schema_name: String.t(),
           sandbox_id: String.t(),
           from: GenServer.from() | nil,
           owner_ref: reference() | nil,
           purpose: :release | :reclaim | :orphan | :release_orphaned
         }

  @typep op :: {:provision, provision_op()} | {:drop, drop_op()}

  # ISS-0226: the closed set of values run_op/1 (and therefore a worker Task) may ever
  # return. Before this fix nothing enforced that these four shapes were the only ones
  # -- a fifth, unanticipated shape reached complete_op/3's four exact-match clauses
  # with no catch-all and raised FunctionClauseError INSIDE handle_info/2, crashing the
  # single supervised GenServer that holds every slot's bookkeeping. See
  # lib/letflow/design/iss0226-sandbox-pool-worker-result-typing.md §3.1 for why this
  # is a tagged-tuple union (matching exactly what provision_sandbox/2 and
  # drop_schema/1 already return) rather than a new wrapping struct.
  @typep provision_result :: {:ok, SandboxClaim.t()} | {:error, :provision_failed}
  @typep drop_result :: :ok | {:error, :release_failed}
  @typep worker_result :: provision_result() | drop_result()

  # Client API

  @doc """
  Starts the pool. `opts` accepts `:name` (default `__MODULE__`) and
  `:max_concurrent` (default: `config :letflow, :sandbox_pool, max_concurrent_sandboxes`).
  """
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    max_concurrent =
      Keyword.get_lazy(opts, :max_concurrent, fn ->
        Application.fetch_env!(:letflow, :sandbox_pool)[:max_concurrent_sandboxes]
      end)

    GenServer.start_link(__MODULE__, %{max_concurrent: max_concurrent}, name: name)
  end

  @doc """
  The configured per-provisioning budget, in milliseconds: how long one sandbox
  schema may take to `CREATE` + migrate before a caller gives up.

  Defaults to #{@default_provision_timeout_ms} ms; override with
  `config :letflow, :sandbox_pool, provision_timeout_ms: n` where `n` is a positive
  integer. Derived from measurement in
  `lib/letflow/design/iss0220-sandbox-pool-provision-timeout.md` §4 -- do not change
  this number without redoing that derivation.
  """
  @spec provision_timeout_ms() :: pos_integer()
  def provision_timeout_ms do
    case Application.get_env(:letflow, :sandbox_pool)[:provision_timeout_ms] do
      nil ->
        @default_provision_timeout_ms

      n when is_integer(n) and n > 0 ->
        n

      other ->
        raise ArgumentError,
              "config :letflow, :sandbox_pool, provision_timeout_ms: expects a " <>
                "positive integer (milliseconds), got: #{inspect(other)} -- see " <>
                "lib/letflow/design/iss0220-sandbox-pool-provision-timeout.md §6"
    end
  end

  @doc """
  The `GenServer.call/3` timeout `claim/2` uses for a given `max_wait_ms`:
  `max_wait_ms + provision_timeout_ms()`.

  Public so callers and tests derive their own bounds from this one source of truth,
  rather than re-deriving a second constant that can drift (ISS-0220).
  """
  @spec claim_call_timeout(max_wait_ms :: non_neg_integer()) :: pos_integer()
  def claim_call_timeout(max_wait_ms) when is_integer(max_wait_ms) and max_wait_ms >= 0 do
    max_wait_ms + provision_timeout_ms()
  end

  @doc """
  The `GenServer.call/3` timeout `release/2` uses: `provision_timeout_ms()` -- the same
  calibrated number, so the release path has a derived bound rather than
  `GenServer.call/2`'s implicit 5_000 ms default.

  It is not sized from the `DROP SCHEMA` cost. Since ISS-0224 the release path's real
  requirement is one provisioning plus one DROP -- the DROP is queued behind any
  in-flight provisioning -- which this budget already covers. See the moduledoc's "Two
  budgets" section.
  """
  @spec release_call_timeout() :: pos_integer()
  def release_call_timeout, do: provision_timeout_ms()

  @doc """
  Claims a sandbox: provisions one immediately if a slot is free, otherwise blocks
  (without busy-polling) until either a slot frees or `max_wait_ms` elapses, in which
  case it returns `{:error, :sandbox_unavailable}`.

  The process that calls `claim/2` must be the same process that later calls
  `release/2` for the returned `sandbox_id` — handing a claim to a different process
  and releasing from there is indistinguishable, by design, from that process leaking
  the claim (see moduledoc's owner-monitor section) and will be reclaimed automatically.

  Two budgets are in play here and only one of them is `max_wait_ms`: `max_wait_ms`
  bounds the queue parking described above, while this function's own
  `GenServer.call/3` timeout is `claim_call_timeout(max_wait_ms)` -- that queue wait
  plus one calibrated provisioning. See the moduledoc's "Two budgets" section.
  """
  @spec claim(max_wait_ms :: non_neg_integer(), pool :: GenServer.server()) ::
          {:ok, SandboxClaim.t()}
          | {:error, :sandbox_unavailable}
          | {:error, :provision_failed}
          | {:error, term()}
  def claim(max_wait_ms, pool \\ __MODULE__)
      when is_integer(max_wait_ms) and max_wait_ms >= 0 do
    GenServer.call(pool, {:claim, max_wait_ms}, claim_call_timeout(max_wait_ms))
  end

  @doc """
  Releases a previously claimed sandbox: drops its schema and frees its quota slot.
  `schema_name` is looked up internally from `sandbox_id` — never caller-supplied.

  Its `GenServer.call/3` timeout is `release_call_timeout/0`, not
  `GenServer.call/2`'s implicit 5_000 ms default: `Letflow.Definitions.safe_release/2`
  wraps this call in a `rescue`, which cannot catch the `exit` a call timeout raises,
  so an unbudgeted release escapes the one wrapper built to contain release failures.
  See the moduledoc's "Two budgets" section.
  """
  @spec release(sandbox_id :: String.t(), pool :: GenServer.server()) ::
          :ok
          | {:error, :not_found}
          | {:error, :release_failed}
  def release(sandbox_id, pool \\ __MODULE__) do
    GenServer.call(pool, {:release, sandbox_id}, release_call_timeout())
  end

  # GenServer callbacks

  # State shape (design §5). `active` and `waiting` are UNCHANGED by ISS-0224, in key
  # set and in value shape -- which is what keeps
  # promotion_assertion_rerun_test.exs's `%{active: active} = :sys.get_state(pool)`
  # partial map match working untouched.
  #
  #   %{
  #     max_concurrent: pos_integer(),
  #     active:  %{optional(sandbox_id :: String.t()) =>
  #                  %{schema_name: String.t(), owner_ref: reference()}},
  #     waiting: :queue.queue({GenServer.from(),
  #                            caller_ref :: reference(),
  #                            timer_ref :: reference()}),
  #     db_queue:  :queue.queue(op()),   # NEW -- pending DB work, FIFO, both op kinds
  #     in_flight: nil | %{              # NEW -- at most one; nil means "idle"
  #                  op:          op(),
  #                  task_ref:    reference(),
  #                  task_pid:    pid()
  #                }
  #   }
  @impl true
  def init(%{max_concurrent: max_concurrent}) do
    {:ok,
     %{
       max_concurrent: max_concurrent,
       active: %{},
       waiting: :queue.new(),
       db_queue: :queue.new(),
       in_flight: nil
     }}
  end

  @impl true
  def handle_call({:claim, max_wait_ms}, from, state) do
    if slots_in_use(state) < state.max_concurrent do
      # Reserve the slot and monitor the owner NOW, strictly before any schema
      # exists, then let pump/1 start the work iff the worker is idle. The caller
      # stays blocked in its own GenServer.call and is replied to from clause A.
      {:noreply, from |> reserve_slot(state) |> pump()}
    else
      handle_queue_or_reject(max_wait_ms, from, state)
    end
  end

  def handle_call({:release, sandbox_id}, from, state) do
    case Map.fetch(state.active, sandbox_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, %{schema_name: schema_name, owner_ref: owner_ref}} ->
        # The `active` entry is RETAINED until the DROP's result is known -- the slot
        # is not reusable while a schema may still exist -- and `owner_ref` is
        # deliberately COPIED into the op rather than moved out of the entry: the
        # monitor must stay live across a failed DROP so that a later death of that
        # same owner still reaches the reclaim path (the pre-ISS-0224 module kept it
        # live on :release_failed for exactly this reason; cancelling it here would
        # turn a recoverable failure into a permanent slot leak). The consequence --
        # one ref living in two places for the op's lifetime -- is precisely what
        # clause B case 4b exists to resolve.
        op =
          {:drop,
           %{
             schema_name: schema_name,
             sandbox_id: sandbox_id,
             from: from,
             owner_ref: owner_ref,
             purpose: :release
           }}

        {:noreply, state |> enqueue_op(op) |> pump()}
    end
  end

  @impl true
  def handle_info({:claim_timeout, caller_ref}, state) do
    case find_waiter(state.waiting, caller_ref) do
      nil ->
        {:noreply, state}

      {from, ^caller_ref, _timer_ref} ->
        Process.demonitor(caller_ref, [:flush])
        GenServer.reply(from, {:error, :sandbox_unavailable})
        {:noreply, %{state | waiting: remove_waiter(state.waiting, caller_ref)}}
    end
  end

  # Clause A (design §7 step 3): the worker Task returned a value. There is exactly
  # ONE clause per message SHAPE, and the discriminator (state.in_flight.task_ref) is
  # branched on in the BODY, not in the head -- it is unreachable from a head or a
  # guard, so writing the "unknown ref" no-op as a second clause would make that
  # clause unreachable and turn `mix letflow.check`'s compile --warnings-as-errors
  # into a red build.
  def handle_info({ref, result}, state) when is_reference(ref) do
    if state.in_flight == nil or ref != state.in_flight.task_ref do
      {:noreply, state}
    else
      # Flush, so a normally-returning worker never ALSO delivers a :DOWN that
      # clause B would misread as a crash. This must happen BEFORE classification,
      # unconditionally, regardless of whether `result` turns out to be a legal
      # worker_result() or not (ISS-0226 design §4.2 step 1 -- load-bearing ordering).
      Process.demonitor(ref, [:flush])

      new_state =
        case classify_worker_result(state.in_flight.op, result) do
          {:ok, validated_result} ->
            # Legal shape -- unchanged from pre-ISS-0226 behavior.
            state
            |> complete_op(state.in_flight.op, validated_result)
            |> service_next_waiter()
            |> pump()

          :invalid ->
            # ISS-0226: `result` is not one of worker_result()'s four legal shapes.
            # complete_op/3 was never written to accept it (no catch-all clause), so
            # routing here instead of into complete_op/3 is what keeps this callback
            # total and avoids a FunctionClauseError crashing the pool. Logged first
            # so an operator can find the root cause without a crash dump, then
            # recovered via the same conservative path clause B case 1 already uses
            # for an actual worker crash -- design §5's reasoning is that "worker
            # returned a value I don't recognize" and "worker died without returning
            # anything" are the same kind of uncertainty from the pool's point of view.
            Logger.error(
              "SandboxPool: worker returned an unrecognized result for " <>
                "op_kind=#{inspect(op_kind(state.in_flight.op))} " <>
                "sandbox_id=#{inspect(op_sandbox_id(state.in_flight.op))}: " <>
                inspect(result)
            )

            state
            |> handle_worker_death()
            |> service_next_waiter()
            |> pump()
        end

      {:noreply, new_state}
    end
  end

  # Clause B (design §7 step 3): six live cases plus a no-op.
  #
  # The cases are ORDERED, not merely disjoint (INV-SP-A3(iv)). Cases 1 and 2 are
  # exact `==` against singly-stored references and are evaluated first. CASE 4b MUST
  # PRECEDE CASE 5: handle_call({:release, _}) copies `owner_ref` into the
  # {:drop, purpose: :release} op while RETAINING the `active` entry it came from, so
  # for that op's whole lifetime the same ref matches both cases. Case 4b is the
  # strictly more informative of the two -- it alone knows a drop is already scheduled
  # -- and letting case 5 win instead would delete the `active` entry AND enqueue a
  # SECOND drop for the same schema, breaking the db_queue bound. Swapping them, or
  # folding 4b into 5, re-breaks it.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    waiter = find_waiter(state.waiting, ref)
    pending_provision = find_pending_provision_by_owner_ref(state.db_queue, ref)
    release_drop = find_release_drop_by_owner_ref(state, ref)
    active_entry = find_active_by_owner_ref(state.active, ref)

    cond do
      state.in_flight != nil and ref == state.in_flight.task_ref ->
        # (1) THE WORKER DIED without returning. Necessarily abnormal: a normal
        #     return is handled in clause A, which demonitors with [:flush] first.
        new_state =
          state
          |> handle_worker_death()
          |> service_next_waiter()
          |> pump()

        {:noreply, new_state}

      in_flight_provision_owner_ref(state) == ref ->
        # (2) THE OWNER DIED WHILE ITS PROVISIONING IS RUNNING. Do NOT kill the
        #     worker (Ecto.Migrator runs with timeout: :infinity throughout, so
        #     killing it mid-run abandons an open transaction and a half-migrated
        #     schema), and do NOT free the slot yet -- a schema is being created right
        #     now and must be dropped deterministically once its name is known. Just
        #     record the death; clause A then discards the result and enqueues the
        #     drop.
        Process.demonitor(ref, [:flush])
        {:provision, p} = state.in_flight.op
        in_flight = %{state.in_flight | op: {:provision, %{p | owner_down?: true}}}
        {:noreply, %{state | in_flight: in_flight}}

      waiter != nil ->
        # (3) A PARKED WAITER DIED -- unchanged (INV-SP-6).
        {_from, ^ref, timer_ref} = waiter
        Process.cancel_timer(timer_ref)
        {:noreply, %{state | waiting: remove_waiter(state.waiting, ref)}}

      pending_provision != nil ->
        # (4) An owner died while its {:provision, _} op was still QUEUED. No schema
        #     exists yet, so there is nothing to drop; just free the slot.
        new_state = %{
          state
          | db_queue: remove_pending_provision_by_owner_ref(state.db_queue, ref)
        }

        {:noreply, new_state |> service_next_waiter() |> pump()}

      release_drop != nil ->
        # (4b) An owner died while ITS OWN {:drop, purpose: :release} op was still
        #      queued or in flight. Reachable in practice: Definitions.safe_release/2
        #      calls release/2 from a `rescue` path. Free the slot in THIS callback
        #      exactly as case 5 does, and retarget the already-scheduled op rather
        #      than enqueue a second one.
        new_state = orphan_release_drop(state, ref, release_drop)
        {:noreply, new_state |> service_next_waiter() |> pump()}

      active_entry != nil ->
        # (5) ISS-0048's dead-owner reclaim. Behaviour preserved, execution relocated:
        #     the `active` entry is removed IMMEDIATELY and unconditionally
        #     (INV-SP-DOWN-3 -- the slot must not be held hostage by a DROP nobody is
        #     left to retry), and the DROP is enqueued rather than run inline.
        {sandbox_id, %{schema_name: schema_name}} = active_entry

        op =
          {:drop,
           %{
             schema_name: schema_name,
             sandbox_id: sandbox_id,
             from: nil,
             owner_ref: nil,
             purpose: :reclaim
           }}

        new_state =
          %{state | active: Map.delete(state.active, sandbox_id)}
          |> enqueue_op(op)
          |> service_next_waiter()
          |> pump()

        {:noreply, new_state}

      true ->
        # (6) An unrelated ref -- unchanged no-op.
        {:noreply, state}
    end
  end

  # No free slot right now: reject immediately for an already-elapsed wait
  # window, otherwise park the caller in `waiting` (design doc §4.4 step 3).
  defp handle_queue_or_reject(max_wait_ms, _from, state) when max_wait_ms <= 0 do
    {:reply, {:error, :sandbox_unavailable}, state}
  end

  defp handle_queue_or_reject(max_wait_ms, {caller_pid, _tag} = from, state) do
    caller_ref = Process.monitor(caller_pid)
    timer_ref = Process.send_after(self(), {:claim_timeout, caller_ref}, max_wait_ms)
    new_waiting = :queue.in({from, caller_ref, timer_ref}, state.waiting)
    {:noreply, %{state | waiting: new_waiting}}
  end

  # Reserves a quota slot for `from`: monitors the CALLER (never the worker -- the
  # worker's ref is only ever in_flight.task_ref, and storing it as an owner_ref would
  # build a pool that reclaims every claim the instant its provisioning finishes),
  # mints the sandbox identity pool-side, and appends the {:provision, _} op. Runs no
  # DB work and never replies.
  @spec reserve_slot(from :: GenServer.from(), state :: map()) :: map()
  defp reserve_slot(from, state) do
    owner_pid = elem(from, 0)
    owner_ref = Process.monitor(owner_pid)
    {sandbox_id, schema_name} = mint_sandbox_identity()

    op =
      {:provision,
       %{
         from: from,
         owner_ref: owner_ref,
         sandbox_id: sandbox_id,
         schema_name: schema_name,
         owner_down?: false
       }}

    enqueue_op(state, op)
  end

  @spec enqueue_op(state :: map(), op :: op()) :: map()
  defp enqueue_op(state, op) do
    %{state | db_queue: :queue.in(op, state.db_queue)}
  end

  # THE PUMP INVARIANT: `in_flight == nil` implies `db_queue` is empty, between
  # callbacks. pump/1 is called after every state transition that either enqueues an
  # op or clears `in_flight`, and it starts work whenever both are possible -- so a
  # callback never returns with an idle worker and pending work. That is what makes
  # case 4b's FIFO argument sound in the queued arm: an op still sitting in `db_queue`
  # when a :DOWN arrives is there because the worker is busy with an EARLIER op, not
  # because nobody pumped, so the DROP that case 4b retargets is guaranteed to run
  # before anything the freed slot subsequently admits.
  #
  # Idempotent, and a no-op while in_flight != nil -- which is what holds DB work to
  # one operation at a time (concurrent Ecto.Migrator runs under Sandbox :auto need
  # pool_size >= P + 1 and deadlock at exactly P).
  @spec pump(state :: map()) :: map()
  defp pump(%{in_flight: nil} = state) do
    case :queue.out(state.db_queue) do
      {{:value, op}, rest} ->
        task = Task.Supervisor.async_nolink(@task_supervisor, fn -> run_op(op) end)

        in_flight = %{
          op: op,
          task_ref: task.ref,
          task_pid: task.pid
        }

        %{state | db_queue: rest, in_flight: in_flight}

      {:empty, _rest} ->
        state
    end
  end

  defp pump(state), do: state

  # Runs INSIDE the worker Task -- the only context from which any Repo call in this
  # module is ever executed. Spec ADDED by ISS-0226 (was unspecced): declares the
  # closed contract this function must honor -- no behavioral change to its body.
  @spec run_op(op :: op()) :: worker_result()
  defp run_op({:provision, %{sandbox_id: sandbox_id, schema_name: schema_name}}) do
    provision_sandbox(sandbox_id, schema_name)
  end

  defp run_op({:drop, %{schema_name: schema_name}}), do: drop_schema(schema_name)

  # ISS-0226 §3.2/§4.3: the single enforcement point for worker_result()'s closed
  # type. Total over (op(), term()) -- the four legal (op-kind, result) pairings
  # (term-for-term the same four pairings complete_op/3's four existing clauses
  # already match on) return {:ok, result}; anything else -- a shape complete_op/3 was
  # never written to accept -- returns :invalid. This is what lets complete_op/3 stay
  # exactly as it is (§4.3): once classify_worker_result/2 has returned {:ok, _}, the
  # result is guaranteed by construction to be one of the four shapes complete_op/3
  # already covers.
  @spec classify_worker_result(op :: op(), result :: term()) ::
          {:ok, worker_result()} | :invalid
  defp classify_worker_result({:provision, _}, {:ok, %SandboxClaim{}} = result), do: {:ok, result}

  defp classify_worker_result({:provision, _}, {:error, :provision_failed} = result),
    do: {:ok, result}

  defp classify_worker_result({:drop, _}, :ok = result), do: {:ok, result}

  defp classify_worker_result({:drop, _}, {:error, :release_failed} = result),
    do: {:ok, result}

  defp classify_worker_result(_op, _result), do: :invalid

  # ISS-0226 §6: small accessors for the Logger.error/1 call in handle_info/2's new
  # :invalid branch -- one clause per op kind rather than a new idiom. ISS-0226 wrote
  # this comment citing `op_schema_name/1` as the idiom being mirrored; ISS-0227
  # removed that function (it was the only reader of the `in_flight.schema_name` copy
  # it also removed), so the citation now points at `run_op/1` just above, which has
  # the same shape and is not going anywhere.
  @spec op_kind(op :: op()) :: :provision | :drop
  defp op_kind({:provision, _}), do: :provision
  defp op_kind({:drop, _}), do: :drop

  @spec op_sandbox_id(op :: op()) :: String.t()
  defp op_sandbox_id({:provision, %{sandbox_id: sandbox_id}}), do: sandbox_id
  defp op_sandbox_id({:drop, %{sandbox_id: sandbox_id}}), do: sandbox_id

  # Applies a completed op's result to the state and replies where a `from` exists.
  # Always clears `in_flight`.
  @spec complete_op(state :: map(), op :: op(), result :: term()) :: map()
  defp complete_op(state, {:provision, p}, {:ok, %SandboxClaim{} = claim}) do
    if p.owner_down? do
      # The owner died mid-provisioning (clause B case 2 already demonitored it), so a
      # schema now exists for a dead owner: enqueue its drop and free the slot. No
      # reply -- the caller is gone.
      op =
        {:drop,
         %{
           schema_name: claim.schema_name,
           sandbox_id: p.sandbox_id,
           from: nil,
           owner_ref: nil,
           purpose: :orphan
         }}

      enqueue_op(%{state | in_flight: nil}, op)
    else
      new_active =
        Map.put(state.active, claim.sandbox_id, %{
          schema_name: claim.schema_name,
          owner_ref: p.owner_ref
        })

      GenServer.reply(p.from, {:ok, claim})
      # The reservation converts into an `active` entry -- slots_in_use is unchanged.
      %{state | in_flight: nil, active: new_active}
    end
  end

  defp complete_op(state, {:provision, p}, {:error, :provision_failed}) do
    # The worker's own rescue already ran its compensating drop, on the worker's own
    # checkout -- no extra connection and no extra op are needed here.
    if not p.owner_down? do
      Process.demonitor(p.owner_ref, [:flush])
      GenServer.reply(p.from, {:error, :provision_failed})
    end

    %{state | in_flight: nil}
  end

  defp complete_op(state, {:drop, d}, :ok) do
    if d.from != nil do
      # d.purpose == :release only; the other three purposes carry from: nil.
      Process.demonitor(d.owner_ref, [:flush])
      GenServer.reply(d.from, :ok)
    end

    # Map.delete/2 is idempotent: on the :reclaim, :orphan and :release_orphaned paths
    # the entry was already removed in the :DOWN callback.
    %{state | in_flight: nil, active: Map.delete(state.active, d.sandbox_id)}
  end

  defp complete_op(state, {:drop, d}, {:error, :release_failed}) do
    if d.purpose == :release do
      # INV-SP-5 is a LIVE-OWNER guarantee: the owner has just been told the release
      # failed and may retry release/2, and if it dies instead its still-live
      # owner_ref reaches clause B case 5 and the slot is reclaimed. So the `active`
      # entry is retained and the monitor left live, exactly as the pre-ISS-0224
      # module did.
      GenServer.reply(d.from, {:error, :release_failed})
    end

    # :reclaim | :orphan | :release_orphaned: no `from` to reply to, and the `active`
    # entry is already absent -- with no live owner there is nobody to retry, so the
    # slot is never held hostage by a DROP that failed (INV-SP-DOWN-3). The schema may
    # leak; that is ISS-0048's existing, accepted trade -- slot before schema.
    %{state | in_flight: nil}
  end

  # The worker died without returning a value (clause B case 1). Always clears
  # `in_flight`; never runs DB work inline.
  defp handle_worker_death(%{in_flight: %{op: {:provision, p}}} = state) do
    # Possible ONLY because the pool pre-minted the schema name: the worker returned
    # nothing, so this is the sole remaining handle on whatever it may have created.
    op =
      {:drop,
       %{
         schema_name: p.schema_name,
         sandbox_id: p.sandbox_id,
         from: nil,
         owner_ref: nil,
         purpose: :orphan
       }}

    if not p.owner_down? do
      Process.demonitor(p.owner_ref, [:flush])
      GenServer.reply(p.from, {:error, :provision_failed})
    end

    enqueue_op(%{state | in_flight: nil}, op)
  end

  defp handle_worker_death(%{in_flight: %{op: {:drop, d}}} = state) do
    if d.purpose == :release do
      # Exactly the same live-owner/dead-owner split as complete_op/3's
      # :release_failed branch, for the same reason: entry retained, monitor left
      # live. On :reclaim / :orphan / :release_orphaned there is no `from` to reply to
      # and the entry is already absent.
      GenServer.reply(d.from, {:error, :release_failed})
    end

    %{state | in_flight: nil}
  end

  # Clause B case 4b. Frees the slot in the same callback as the :DOWN (so
  # INV-SP-DOWN-2 holds verbatim) and REWRITES the already-scheduled release-drop in
  # place rather than enqueuing a second one. Safe because deleting the `active` entry
  # frees only a COUNTER, not a name: any claim admitted into the freed slot mints a
  # fresh globally-unique schema, and FIFO ordering guarantees the pending DROP runs
  # before that new provisioning, so nothing the freed slot admits can collide with
  # the schema still being dropped.
  #
  # NOTE: the owner_ref is deliberately NOT demonitored when the release-drop is
  # enqueued (see handle_call({:release, _})), and must not be -- doing so would
  # strand the slot permanently whenever the DROP then fails, since the retained
  # `active` entry would have no live monitor left to trigger a reclaim.
  defp orphan_release_drop(state, ref, {location, d}) do
    Process.demonitor(ref, [:flush])

    # No reply is sent: this op's `from` is the release caller, which is the process
    # that just died.
    orphaned = {:drop, %{d | from: nil, owner_ref: nil, purpose: :release_orphaned}}
    new_state = %{state | active: Map.delete(state.active, d.sandbox_id)}

    case location do
      :in_flight ->
        # Legal: in_flight.op is pool-local data. The worker holds only the
        # schema_name STRING and is unaffected; the rewrite changes only what
        # complete_op/3 does when its result arrives.
        %{new_state | in_flight: %{new_state.in_flight | op: orphaned}}

      :queued ->
        %{new_state | db_queue: replace_queued_op(new_state.db_queue, {:drop, d}, orphaned)}
    end
  end

  # Quota accounting (design §5). A slot is counted from the moment reserve_slot/2
  # returns -- BEFORE any DB work starts -- until its `active` entry is deleted or its
  # reservation is discarded on a failure path, so N in-flight provisionings can never
  # all see the same free slot.
  @spec slots_in_use(state :: map()) :: non_neg_integer()
  defp slots_in_use(state), do: map_size(state.active) + provision_ops_pending(state)

  @spec provision_ops_pending(state :: map()) :: non_neg_integer()
  defp provision_ops_pending(state) do
    queued = Enum.count(:queue.to_list(state.db_queue), &match?({:provision, _}, &1))
    if match?(%{op: {:provision, _}}, state.in_flight), do: queued + 1, else: queued
  end

  # Promotes AT MOST ONE parked waiter into a reservation. It no longer runs DB work
  # and no longer replies; the promoted caller stays blocked in its own
  # GenServer.call until clause A replies. The slots_in_use/1 guard is what makes this
  # correct -- not every event that calls it frees a slot (a successful provisioning
  # frees none: the reservation converts into an `active` entry).
  defp service_next_waiter(state) do
    if slots_in_use(state) >= state.max_concurrent do
      state
    else
      case :queue.out(state.waiting) do
        {{:value, {from, caller_ref, timer_ref}}, rest} ->
          Process.cancel_timer(timer_ref)
          Process.demonitor(caller_ref, [:flush])
          reserve_slot(from, %{state | waiting: rest})

        {:empty, _rest} ->
          state
      end
    end
  end

  defp find_waiter(queue, caller_ref) do
    Enum.find(:queue.to_list(queue), fn {_from, ref, _timer_ref} -> ref == caller_ref end)
  end

  defp remove_waiter(queue, caller_ref) do
    queue
    |> :queue.to_list()
    |> Enum.reject(fn {_from, ref, _timer_ref} -> ref == caller_ref end)
    |> :queue.from_list()
  end

  defp find_active_by_owner_ref(active, owner_ref) do
    Enum.find(Map.to_list(active), fn {_sandbox_id, %{owner_ref: ref}} -> ref == owner_ref end)
  end

  # The owner_ref of an in-flight PROVISION op, or nil when the worker is idle or busy
  # with a drop. References are never nil, so a nil return never matches a real ref.
  defp in_flight_provision_owner_ref(%{in_flight: %{op: {:provision, p}}}), do: p.owner_ref
  defp in_flight_provision_owner_ref(_state), do: nil

  # Same small-bounded-collection linear-scan idiom as find_waiter/2 and
  # find_active_by_owner_ref/2, preferred over a separately-maintained counter or
  # index, which would be a second source of truth for the same fact.
  @spec find_pending_provision_by_owner_ref(
          db_queue :: :queue.queue(),
          owner_ref :: reference()
        ) :: provision_op() | nil
  defp find_pending_provision_by_owner_ref(db_queue, owner_ref) do
    Enum.find_value(:queue.to_list(db_queue), fn
      {:provision, %{owner_ref: ^owner_ref} = p} -> p
      _other -> nil
    end)
  end

  @spec remove_pending_provision_by_owner_ref(
          db_queue :: :queue.queue(),
          owner_ref :: reference()
        ) :: :queue.queue()
  defp remove_pending_provision_by_owner_ref(db_queue, owner_ref) do
    db_queue
    |> :queue.to_list()
    |> Enum.reject(&match?({:provision, %{owner_ref: ^owner_ref}}, &1))
    |> :queue.from_list()
  end

  # Searches BOTH db_queue AND in_flight.op for the {:drop, purpose: :release} op
  # belonging to `owner_ref`, and reports which of the two holds it, so clause B case
  # 4b knows whether to rewrite in_flight or to replace the op in place inside
  # db_queue. At most one such op can exist per slot.
  @spec find_release_drop_by_owner_ref(state :: map(), owner_ref :: reference()) ::
          {:in_flight, drop_op()} | {:queued, drop_op()} | nil
  defp find_release_drop_by_owner_ref(state, owner_ref) do
    case state.in_flight do
      %{op: {:drop, %{purpose: :release, owner_ref: ^owner_ref} = d}} ->
        {:in_flight, d}

      _other ->
        queued =
          Enum.find_value(:queue.to_list(state.db_queue), fn
            {:drop, %{purpose: :release, owner_ref: ^owner_ref} = d} -> d
            _other -> nil
          end)

        case queued do
          nil -> nil
          d -> {:queued, d}
        end
    end
  end

  # Replaces one op inside db_queue while PRESERVING ITS FIFO POSITION -- a rebuild of
  # the queue, never a remove-then-append: reordering would let a later provisioning
  # overtake a pending DROP, which the FIFO argument above relies on not happening.
  @spec replace_queued_op(db_queue :: :queue.queue(), old :: op(), new :: op()) ::
          :queue.queue()
  defp replace_queued_op(db_queue, old, new) do
    db_queue
    |> :queue.to_list()
    |> Enum.map(fn
      ^old -> new
      other -> other
    end)
    |> :queue.from_list()
  end

  # Minted POOL-SIDE, not by the worker (design §5): the pool must know the schema
  # name before the worker exists, so that a crashed worker's half-created schema is
  # still nameable and can be dropped. Same fixed construction as before ISS-0224 --
  # "sandbox_" <> Ecto.UUID.generate() with hyphens stripped, producing only
  # sandbox_[0-9a-f]{32} and never reading a caller value (INV-SP-4 / INV-7).
  defp mint_sandbox_identity do
    sandbox_id = Ecto.UUID.generate()
    {sandbox_id, "sandbox_" <> String.replace(sandbox_id, "-", "")}
  end

  # Provisioning sequence (design doc §4.4 step 4): CREATE SCHEMA, then replay every
  # tenant-scoped migration into it via the same Ecto.Migrator.run/4 mechanism
  # Letflow.TenantProvisioning.replay_migrations/2 uses internally -- not
  # provision_tenant_schema/1 or replay_migrations/2 themselves, both of which
  # are registry-coupled (require an existing Registration row) and
  # inappropriate for an ephemeral, non-tenant sandbox schema (design doc §4.6).
  #
  # RUNS INSIDE THE WORKER TASK, never in a pool callback (ISS-0224).
  defp provision_sandbox(sandbox_id, schema_name) do
    # schema_name is never caller-supplied here -- it is always the fixed
    # "sandbox_" <> Ecto.UUID.generate()-derived construction minted by
    # mint_sandbox_identity/0, matching the identifier-injection safety argument
    # tenant_provisioning.ex:111-122 already documents (INV-7). No IF NOT EXISTS:
    # every claim mints a fresh UUID, so a collision here is a genuine defect, not
    # a legitimate retry.
    Repo.query!(~s(CREATE SCHEMA "#{schema_name}"))

    Ecto.Migrator.run(Repo, TenantProvisioning.tenant_scoped_migrations(), :up,
      all: true,
      prefix: schema_name,
      log: false
    )

    {:ok, %SandboxClaim{sandbox_id: sandbox_id, schema_name: schema_name}}
  rescue
    _exception ->
      # Best-effort compensating cleanup -- swallow its own failure, this is
      # cleanup, not the primary error path (design doc §4.4 step 4e). It reuses the
      # worker's own checkout, so it costs no extra connection.
      drop_schema(schema_name)
      {:error, :provision_failed}
  end

  # `schema_name` here is only ever either freshly minted by mint_sandbox_identity/0
  # or read back out of state.active by sandbox_id (never directly caller-supplied)
  # -- same injection-safety argument as tenant_provisioning.ex:111-122 and
  # provision_sandbox/2 above (INV-7).
  #
  # RUNS INSIDE THE WORKER TASK, never in a pool callback (ISS-0224).
  defp drop_schema(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
    :ok
  rescue
    _exception -> {:error, :release_failed}
  end
end
