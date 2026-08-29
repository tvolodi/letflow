# SECURITY-REVIEWER report — REQ-185 design artefact

Run: WF02-REQ185-20260829, Step 2c. Target:
`lib/letflow/design/req185-scheduler-firing-architecture.md`.

**Verdict: PASS.** No invariant blocked. Design-only requirement — no
implementation diff exists yet (confirmed: `git diff --stat main...HEAD`
touches only the design file and this run's own handoff JSONs).

## Invariant-by-invariant

- **INV-1 (tenant data isolation) — APPLIES, PASS.** This design's decisions
  reach a tenant-scoped table (`timers`, per-tenant Postgres schema per
  Decision 0003 Dimension B) and a tenant-scoped table already built
  (`dlq_entries`, REQ-176). Checked both design claims directly against
  source rather than taking the artefact's word:
  - §6's poller iterates tenant schemas one at a time via the
    `tenant_schemas` registry (`Letflow.TenantProvisioning.Registration`,
    living in the public schema — correct, schema identity must be
    resolvable before any tenant schema exists) and runs its claim query
    "under that schema's `:prefix`" per schema. This is the standard
    schema-per-tenant access pattern, not a global cross-schema query — one
    poller *process* iterating many schemas sequentially, each individual
    query scoped to one schema via `:prefix`, is not a cross-tenant
    exposure: it's structurally identical to any other per-tenant
    maintenance loop this codebase would need regardless of the timer
    feature. A bug in one tenant's timer-firing transaction cannot touch
    another tenant's rows because each fire happens inside its own
    transaction against its own schema's `timers` table — §7 makes this
    explicit as the reason the loop continues past a hard error rather than
    stopping (isolation is per-timer-transaction, not merely per-tenant).
  - §8's DLQ-landing decision (`entry_type: "timer"`) was checked against
    `lib/letflow/dlq/entry.ex` and
    `priv/repo/migrations/20260829000001_create_dlq_entries.exs` directly
    (not just re-stated from the design doc). Confirmed: `dlq_entries` has
    no `@schema_prefix` and its migration is guarded by `if prefix() do`
    (a tenant-scoped migration, one instance per tenant schema, same as
    every other business table in this codebase) — the design's claim that
    `dlq_entries` is tenant-scoped per REQ-176 is correct, not aspirational.
    `tenant_id` is a plain column but, per the schema's own moduledoc and
    `Letflow.Dlq.enqueue/2`'s contract (cited accurately by the design),
    it is derived server-side from the resolved prefix, not
    caller-supplied — satisfies 0003's addendum. Landing a timer's
    exhausted-retry state in this table introduces no new access path and
    no new column; it reuses an existing tenant-scoped write path with a
    new string value in an already-unconstrained `entry_type` column. No
    cross-tenant leak risk: the entry is written into the same schema the
    firing timer's own row lives in (design §8 states this explicitly —
    "no cross-schema write").

- **INV-2 (server-side field authorisation) — NOT-APPLICABLE.** No API
  response-shaping code exists or is touched; S4 has not started.

- **INV-3 (untrusted runtime sandboxing) — NOT-APPLICABLE.** No Lua/WASM
  host-function surface touched; S5 has not started.

- **INV-4 (secrets by reference only) — NOT-APPLICABLE for this diff.**
  Nothing in this design resolves, logs, or threads any secret material.
  The Oban-vs-ticker comparison (§3) doesn't touch credential handling in
  either direction — neither option requires new secret material (both
  read from the existing `Letflow.Repo` connection pool, whose credentials
  are already resolved via existing config/env, unmodified by this
  artefact).

- **INV-5 (not-found/forbidden indistinguishability) — NOT-APPLICABLE.** No
  lookup-by-ID endpoint; S4 has not started.

- **INV-6 (new data-access paths prove their scoping) — APPLIES, PASS.**
  This report is that proof: it states explicitly which invariants apply
  and how each is satisfied, per the meta-invariant's own requirement.

- **INV-7 (no SQL string interpolation) — NOT-APPLICABLE at this stage.**
  No `Repo.query`/raw-SQL call exists yet — the design specifies the claim
  query's *shape* (`SELECT ... FOR UPDATE SKIP LOCKED` scoped by tenant
  schema `:prefix`) but defers the actual Ecto implementation to REQ-186.
  Flagging forward (not a design defect, a note for the next gate): REQ-186
  must implement this via `Ecto.Query`'s `lock: "FOR UPDATE SKIP LOCKED"`
  option or an equivalent parameterised form, with the tenant schema
  supplied only via the `prefix:` option — never string-interpolated into
  a raw SQL fragment. SECURITY-REVIEWER will re-check this concretely at
  REQ-186's own Step 2c.

- **INV-8 (no unhandled crashes on realistic failure paths) — APPLIES,
  PASS.** §7 of the design is, in substance, an INV-8 compliance argument:
  it explicitly rejects "propagate every error out of the fire path" as
  the wrong design specifically because an unhandled crash in one timer's
  firing would stall accounting and delivery for every other due timer
  behind it (both within the same tenant schema and — since the ticker
  loop also crosses tenant schemas per tick — potentially timers in
  schemas not yet visited that tick). The recommended design's per-timer
  transaction boundary, with the raise caught and converted to a
  `fire_error_count` increment before the loop continues, is exactly the
  isolation INV-8 requires. No gap found.

## Specific handoff focus points, answered

- **Per-tenant-schema iteration (§6):** no cross-tenant exposure or
  cross-tenant blast-radius risk — each query is single-schema, scoped via
  `:prefix`; each fire is single-transaction, scoped to the schema the
  claimed row lives in. Sequential per-tick iteration across 500 schemas is
  a *performance* consideration (already flagged by the design itself as
  OQ-2), not a tenant-isolation defect — a slow tenant schema delaying
  other schemas' polls within the same tick is a latency/fairness question,
  not a data-exposure or crash-propagation one, and is out of this gate's
  scope.
- **DLQ landing (§8):** verified directly against `lib/letflow/dlq/entry.ex`
  and its migration — `dlq_entries` is tenant-scoped (schema-per-tenant, no
  `@schema_prefix`, `if prefix() do` migration guard), `entry_type` is an
  unconstrained extensible `:string` with `"timer"` already reserved for
  this exact use by REQ-176. No leak risk.
- **`FOR UPDATE SKIP LOCKED` (§4):** locking is confined within one tenant
  schema's own `timers` table per query; it cannot starve or block another
  tenant's schema, since each tenant's claim query is a separate statement
  against a separate schema. No cross-tenant starvation vector.
- **Oban rejection (§3):** the ticker alternative does not forgo any
  security-relevant capability. Oban's job-isolation property (catching a
  raise inside one job without affecting others) is independently
  reproduced by the design's own per-timer-transaction isolation (§5/§7);
  Oban's credential handling is irrelevant here since neither option
  introduces new credential material. The one thing genuinely forgone
  (Oban's built-in multi-node claim mechanism) is explicitly replaced by
  `FOR UPDATE SKIP LOCKED` (§4), which the design correctly identifies as
  needed "regardless of which mechanism wins" — not a capability gap left
  unaddressed.

## Note for REVIEWER (Step 2d)

The design's §3 leaves an explicit, unambiguous PENDING placeholder for
"REVIEWER sign-off on the Oban NO decision." This SECURITY-REVIEWER pass
does not resolve that placeholder — it is REVIEWER's own gate, not
SECURITY-REVIEWER's, and the design file itself names Step 2d of this run
as where it gets filled in. See the routing handoff for the explicit
instruction to record that sign-off **in the design file's §3 directly**,
not only in REVIEWER's own handoff JSON — the design artefact is the
document of record REQ-186 will read, and a sign-off recorded only in a
handoff file would not be visible to whoever picks up REQ-186 later.
