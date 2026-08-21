defmodule Letflow.SandboxPool do
  @moduledoc """
  Ephemeral Postgres-schema sandbox pool (ports R-Co's `src/definition/sandbox_pool.zig`
  per PRM-06/PRM-07 — see `src/design/prm-batch1-promotion-assertion-rerun.md`).

  `claim/1` provisions a fresh, empty Postgres schema (already scaffolded with every
  `Letflow.TenantProvisioning.tenant_scoped_migrations/0` table, so it looks exactly like
  a real tenant schema) under a hard `max_concurrent_sandboxes` quota; `release/1` drops
  it. Sandbox schemas are NOT tenant schemas — they carry no
  `Letflow.TenantProvisioning.Registration` row and use their own `"sandbox_" <> hex`
  naming scheme, never `"tenant_" <> hex`.

  ## Process-per-instance vs. row-based state (REQ-039's open question, resolved here)

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
  orders of magnitude cheaper -- and **not** because anything currently blocks the
  pool's mailbox ahead of a release; nothing does, since every present caller holds at
  most one claim in flight. It is so the release path has a *derived* bound instead of
  `GenServer.call/2`'s implicit 5_000 ms default: `Letflow.Definitions.safe_release/2`
  contains release failures with `rescue`, which structurally cannot catch the `exit` a
  call timeout raises, so an over-budget release escapes the one wrapper built to
  swallow it -- and does so on the path that is already handling an exception. It is
  also already correctly sized for the day provisioning stops blocking the pool's
  mailbox.

  Both budgets are **caller-side allowances, not server-side aborts**: nothing aborts a
  slow provisioning. `Ecto.Migrator` runs with `timeout: :infinity` at every level it
  controls, so when the budget elapses the *caller* exits with
  `{:timeout, {GenServer, :call, ...}}` while the pool keeps provisioning to completion.

  The default budget is derived from measurement in
  `lib/letflow/design/iss0220-sandbox-pool-provision-timeout.md` §4 -- do not change
  that number without redoing the derivation.
  """

  use GenServer

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

  It is not sized from the `DROP SCHEMA` cost, and not because anything currently
  blocks the pool's mailbox ahead of a release. See the moduledoc's "Two budgets"
  section.
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

  @impl true
  def init(%{max_concurrent: max_concurrent}) do
    {:ok, %{max_concurrent: max_concurrent, active: %{}, waiting: :queue.new()}}
  end

  @impl true
  def handle_call({:claim, max_wait_ms}, from, state) do
    if map_size(state.active) < state.max_concurrent do
      handle_provision_now(from, state)
    else
      handle_queue_or_reject(max_wait_ms, from, state)
    end
  end

  def handle_call({:release, sandbox_id}, from, state) do
    case Map.fetch(state.active, sandbox_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, %{schema_name: schema_name, owner_ref: owner_ref}} ->
        case drop_schema(schema_name) do
          :ok ->
            Process.demonitor(owner_ref, [:flush])
            GenServer.reply(from, :ok)
            new_state = %{state | active: Map.delete(state.active, sandbox_id)}
            {:noreply, service_next_waiter(new_state)}

          {:error, :release_failed} = error ->
            {:reply, error, state}
        end
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

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case find_waiter(state.waiting, ref) do
      {_from, ^ref, timer_ref} ->
        Process.cancel_timer(timer_ref)
        {:noreply, %{state | waiting: remove_waiter(state.waiting, ref)}}

      nil ->
        case find_active_by_owner_ref(state.active, ref) do
          {sandbox_id, %{schema_name: schema_name}} ->
            # The owner of an already-granted claim died before release/2 was
            # called -- best-effort reclaim (design doc §5.4, INV-SP-DOWN-2/3).
            drop_schema(schema_name)
            new_active = Map.delete(state.active, sandbox_id)
            new_state = service_next_waiter(%{state | active: new_active})
            {:noreply, new_state}

          nil ->
            {:noreply, state}
        end
    end
  end

  # Immediate-provisioning path: a slot was free at the moment handle_call ran.
  # Returns {:reply, ..., state} directly -- GenServer replies to the caller
  # using handle_call/3's own `from` argument, not one threaded through here.
  defp handle_provision_now(from, state) do
    case provision_sandbox() do
      {:ok, %SandboxClaim{} = claim} ->
        owner_ref = Process.monitor(elem(from, 0))

        new_active =
          Map.put(state.active, claim.sandbox_id, %{
            schema_name: claim.schema_name,
            owner_ref: owner_ref
          })

        {:reply, {:ok, claim}, %{state | active: new_active}}

      {:error, :provision_failed} = error ->
        {:reply, error, state}
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

  # Pops the oldest waiter (if any), provisions a sandbox for it, and replies
  # directly via GenServer.reply/2 -- called after a release frees a slot
  # (design doc §4.4 step 5). A failed hand-off does not retry against the
  # next waiter; the slot is simply left free for normal contention.
  defp service_next_waiter(state) do
    case :queue.out(state.waiting) do
      {{:value, {from, caller_ref, timer_ref}}, rest} ->
        Process.cancel_timer(timer_ref)
        Process.demonitor(caller_ref, [:flush])

        case provision_sandbox() do
          {:ok, %SandboxClaim{} = claim} ->
            owner_ref = Process.monitor(elem(from, 0))
            GenServer.reply(from, {:ok, claim})

            new_active =
              Map.put(state.active, claim.sandbox_id, %{
                schema_name: claim.schema_name,
                owner_ref: owner_ref
              })

            %{state | active: new_active, waiting: rest}

          {:error, :provision_failed} = error ->
            GenServer.reply(from, error)
            %{state | waiting: rest}
        end

      {:empty, _rest} ->
        state
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

  # Provisioning sequence (design doc §4.4 step 4): mint a fresh sandbox_id,
  # derive its schema_name from it, CREATE SCHEMA, then replay every
  # tenant-scoped migration into it via the same Ecto.Migrator.run/4 mechanism
  # Letflow.TenantProvisioning.replay_migrations/2 uses internally -- not
  # provision_tenant_schema/1 or replay_migrations/2 themselves, both of which
  # are registry-coupled (require an existing Registration row) and
  # inappropriate for an ephemeral, non-tenant sandbox schema (design doc §4.6).
  defp provision_sandbox do
    sandbox_id = Ecto.UUID.generate()
    schema_name = "sandbox_" <> String.replace(sandbox_id, "-", "")

    try do
      # schema_name is never caller-supplied here -- it is always this fixed
      # "sandbox_" <> Ecto.UUID.generate()-derived construction, matching the
      # identifier-injection safety argument tenant_provisioning.ex:111-122
      # already documents (INV-7). No IF NOT EXISTS: every claim mints a fresh
      # UUID, so a collision here is a genuine defect, not a legitimate retry.
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
        # cleanup, not the primary error path (design doc §4.4 step 4e).
        drop_schema(schema_name)
        {:error, :provision_failed}
    end
  end

  # `schema_name` here is only ever either freshly derived by provision_sandbox/0
  # or read back out of state.active by sandbox_id (never directly
  # caller-supplied) -- same injection-safety argument as
  # tenant_provisioning.ex:111-122 and provision_sandbox/0 above (INV-7).
  defp drop_schema(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
    :ok
  rescue
    _exception -> {:error, :release_failed}
  end
end
