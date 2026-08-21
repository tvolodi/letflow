# Design: ISS-0109 — tenant-fixture provisioning-completeness invariant and one-shot failure-state capture

**Run:** `WF03-ISS0109-20260821` · **Workflow:** WF-03 Step 2 (fix design) · **Author:** CODE-DESIGNER
**Issue:** ISS-0109 / GH#358 · **Diagnosis this design is built on:**
`handoffs/WF03-ISS0109-20260821/step-01-issue-fixer-diagnose.json` (`result.summary`)

> **Design artefact only.** No implementation code appears below — interfaces, `@spec`s,
> data shapes, invariants and failure modes only. ELIXIR-DEV implements it in Step 3;
> TEST-DESIGNER builds the regression tests from §7.

---

## 0. Sources read for this design

Read in full or at the cited lines; every claim below is traceable to one of these.

| Source | Used for |
|---|---|
| `handoffs/WF03-ISS0109-20260821/step-02-code-designer.json` | task, scope in/out, mandatory sections |
| `handoffs/WF03-ISS0109-20260821/step-01-issue-fixer-diagnose.json` `result.summary` + `result.issues` | the authoritative diagnosis; not re-derived here |
| `lib/letflow/tenant_provisioning.ex` | §2's verdict — lines 145–265 and 455–500 read directly |
| `lib/letflow/tenant_provisioning/registration.ex` | `@schema_name_format`, changeset contract |
| `lib/letflow/design/req022-tenant-schema-provisioning.md` lines 288–294 | the "No implicit chaining invariant" — load-bearing for §2 |
| `test/letflow/definitions/promotion_test.exs` :62–98, :173–465 | fixture site 1 |
| `test/letflow/definitions/promotion_assertion_rerun_test.exs` :95–133, :417–826 | fixture site 2 |
| `test/support/tenant_schema_reaper.ex`, `lib/letflow/design/iss064-orphaned-tenant-schemas-fix.md` | the existing test-support module this one sits beside; non-contradiction check |
| `test/support/data_case.ex` | sandbox-mode interaction |
| `docs/agents/instructions/core-directives.md` | precedence, file placement, no-speculation |

---

## 1. Scope boundary

### 1.1 In scope (the three items the handoff names)

- **(C)** The **post-provision completeness invariant** — at the layer §2 establishes is
  the correct one. Specified in §3.3/§3.4.
- **(A)** A **shared `test/support` fixture helper** providing the tenant fixture used by
  the two modules ISS-0109 names, which on a provisioning/replay/completeness failure
  captures the settling state **in one shot**. Specified in §3.
- **(B)** **Teardown logging distinguishable from a mid-test drop** — one identifiable log
  line, not a logging framework. Specified in §3.6.

### 1.2 Explicitly out of scope

Named here so the design's rationale is visibly independent of them. None of the
mechanisms below is assumed fixed, and no invariant in §4 depends on any of them.

| Out | Why it is not here |
|---|---|
| ISS-0110 / GH#364 — reaper `min_age: 300` vs a 564–609 s suite | Separately filed. Excluded as ISS-0109's cause on two independent grounds (Step 1: a 1 s-old row vs a 300 s cutoff on a *measured* shared clock basis; the reaper's SQL is `WHERE id`, unaliased, matching neither logged `DELETE`). |
| ISS-0111 / GH#365 — `identity_migration_test`'s bulk `DELETE FROM public.tenant_schemas` | Separately filed; `async: false`, self-scoped, issues no `DROP SCHEMA`. |
| ISS-0112 / GH#366 — migrating the other 39 copy-paste fixture sites | **This run adopts the helper in exactly the two modules ISS-0109 names.** §5 states the boundary and §3.1 states the design constraint that keeps later migration cheap. |
| ISS-0113 / GH#367 — `Sandbox.mode(:auto)` never restored to `:manual` | Separately filed. The helper reproduces today's `:auto` behaviour unchanged (§3.2, INV-F-6) precisely so this run does not silently absorb ISS-0113. |
| ISS-0107 / GH#357 — nested `mix test` recursion | Real, and a genuine same-database sharing channel, but Step 1 established it cannot name tenant `8111baf7…`, and a two-invocation stressor produced 828/828 passes with zero `3F000`/`42P01`. |

### 1.3 What this design deliberately does **not** claim

It does not claim to know what removed `tenant_8111baf7cec4418592f94a3a68a71722`, and it
does not propose a teardown-race fix — that mechanism is **refuted** on ExUnit source
(`ex_unit/lib/ex_unit/on_exit_handler.ex`: `exec_on_exit_callbacks/3` blocks in
`receive_runner_reply/4` and kills an over-running runner) and on the purity of
`TenantProvisioning.schema_name_for_tenant/1` (`lib/letflow/tenant_provisioning.ex:101–106`).
See §8 for the honest FIXED-vs-INSTRUMENTED verdict.

---

## 2. First job: is `insert_or_fetch_registration/2` → `re_select_registration/1` a real production defect?

**Verdict: NO for the "schema exists" half (refuted by the code), and YES-but-by-design for
the "tables exist" half (a documented separation, not a defect). The production module
`lib/letflow/tenant_provisioning.ex` requires no change, and this design proposes none.**

The lead has two halves and they resolve differently. Both are settled below on file:line
evidence, per the handoff's requirement.

### 2.1 Half one — "returns `{:ok, registration}` without guaranteeing the named schema exists": **REFUTED**

`provision_tenant_schema/1` (`lib/letflow/tenant_provisioning.ex:164`) executes, inside a
single `Repo.transaction/1` opened at **:170**, in this order:

1. **:174** — `pg_advisory_xact_lock(hashtext($1))` on the derived `schema_name`, so
   concurrent calls for the same tenant are serialized for the whole transaction.
2. **:188** — `CREATE SCHEMA IF NOT EXISTS "<schema_name>"`, **unconditionally, on every
   call**, including the idempotent second call.
3. **:190** — only then `insert_or_fetch_registration(tenant_id, schema_name)`, whose
   `re_select_registration/1` branch (**:483–:488**) is reached from **:471**.

So the "pre-existing `tenant_schemas` row" branch is not a path that *skips* schema
creation. `CREATE SCHEMA IF NOT EXISTS` at :188 has already run in the same transaction
before :190 is reached, and Postgres DDL is transactional, so at the moment
`provision_tenant_schema/1` returns `{:ok, %Registration{}}` the named schema exists.
The diagnosis's phrasing — "*returns `{:ok, registration}` for an EXISTING registry row
without re-creating anything **inside** the schema*" — is exact and correct; *inside* is
the operative word. The schema itself **is** guaranteed.

One variant is worth closing explicitly: could the re-selected row name a *different*
schema than the one :188 created? `Registration.changeset/2`
(`lib/letflow/tenant_provisioning/registration.ex:57–65`) applies
`validate_format(:schema_name, ~r/^tenant_[0-9a-f]{32}$/)` (ISS-0027/GH#85) and declares
`unique_constraint(:tenant_id)` and `unique_constraint(:schema_name)`, both backed by real
DB indexes; and `schema_name_for_tenant/1` (:101–:106) is a pure, total, injective
derivation from the tenant UUID with no I/O. A row keyed on `tenant_id` could therefore
carry a foreign `schema_name` only if something wrote it by raw SQL bypassing the
changeset — and no such writer exists in `lib/` (Step 1's enumeration item 2: zero
`tenant_schemas` inserts or deletes outside this module; the only other
`from(r in Registration, …)` in `lib/` is `mark_migrations_applied/1` at :497–:502, an
`update_all` of one timestamp column). Recorded as OQ-2 in §10, not as a defect.

### 2.2 Half two — "…or that its tables were ever fully created": **TRUE, and it is a decided design invariant, not a defect**

`provision_tenant_schema/1` creates the bare Postgres schema and the registry row. Table
creation is `replay_migrations/2` (:238), a **separate primitive**. That separation is not
incidental — it is stated in three decided artefacts:

- `lib/letflow/tenant_provisioning.ex:18–23` (moduledoc): *"two separate, composable
  primitives — neither calls the other. A future tenant-onboarding orchestration
  requirement sequences them explicitly; that orchestration is not built here."*
- `lib/letflow/design/req022-tenant-schema-provisioning.md:288–294` — the **"No implicit
  chaining invariant"**, gate-approved, justified against R-Co's own
  `bpm_provision_tenant_schema` / `runForSchema` split. Quoted precisely, that record
  decides that *"`provision_tenant_schema/1` never calls `replay_migrations/2`, and
  `replay_migrations/2` never calls `provision_tenant_schema/1`. They are two separate,
  composable steps a caller sequences explicitly"* — i.e. it forbids **chaining**, and
  leaves the onboarding orchestration to a future requirement.
- `replay_migrations/2`'s own contract (:239–:244): it returns
  `{:error, :tenant_not_provisioned}` rather than provisioning on the fly.

Making `provision_tenant_schema/1` guarantee table completeness **by chaining replay** is
squarely what that record forbids, so this design does not propose it. The narrower
variants — having `provision_tenant_schema/1` *verify* tables, or return a new error when
tables are absent — are **not literally decided by req022**; the record speaks about
calling, not verifying. They are declined here on their own merits rather than on the
record's authority: verifying table completeness inside the provisioning primitive would
make it assert an outcome that, by req022's own separation, it is not the step responsible
for producing, and would give it a failure mode no caller in `lib/` can currently cause.
Note also the precedence route: req022 is a **gate-approved design artefact** under
`lib/letflow/design/`, not a `docs/migration/decisions/` record — so
`core-directives.md` §"Instruction Precedence" ("A `docs/migration/decisions/` record is
never overridden… stop and flag") does not itself bind here. The correct route for
contradicting a gate-approved design artefact would be REVIEWER sign-off, which this
design does not need, because it **declines** the contradiction rather than resolving it.
Nor does it need to: the obligation to verify completeness
belongs to **whoever sequences the two primitives**. In both ISS-0109 failures that
sequencer is the test fixture (`promotion_test.exs:78–98`,
`promotion_assertion_rerun_test.exs:112–133`), which today asserts only that
`replay_migrations/1` returned `{:ok, _}` (`promotion_test.exs:96`,
`promotion_assertion_rerun_test.exs:130`) and never that the resulting schema is complete.
**That is the real gap, and it is at the fixture layer.**

### 2.3 Consequence for this design's shape

- **No production change.** `lib/letflow/tenant_provisioning.ex` and
  `lib/letflow/tenant_provisioning/registration.ex` are **not modified** by this design.
- **Not a tenant-data-path change.** Nothing here alters an API route, a migration, a
  response shape, secrets handling, or any query executed by shipped code. Everything lands
  under `test/support/` (compiled only under `elixirc_paths(:test)`) and in two test
  modules. SECURITY-REVIEWER's tenant-data-path trigger is therefore not armed by this
  design; §4's INV-F-8 keeps it that way (every new query is single-tenant-scoped or reads
  only catalog metadata, and no captured value crosses a tenant boundary).
- **This is the honest answer, not a minimised one.** A production change here would have
  had to contradict `req022`'s No-implicit-chaining invariant in order to exist.

---

## 3. New module — `Letflow.TenantFixture` (`test/support/tenant_fixture.ex`)

Test-only. Sits beside `Letflow.TenantSchemaReaper` and `Letflow.TenantSlugFixture` under
`test/support/`, compiled only under `elixirc_paths(:test)`. **Not** a GenServer, **not**
added to `lib/letflow/application.ex`'s supervision tree — a plain module, matching
`iss064-orphaned-tenant-schemas-fix.md` §3's established shape for this directory.

### 3.1 Why a module and not a `CaseTemplate`/`DataCase` change

The 41 copy-paste sites (Step 1, `result.issues` MINOR) differ in tenant slug prefix,
display name, and what else their `on_exit` does — a `DataCase` `setup` hook cannot absorb
that variation without touching all 41 at once, which is ISS-0112, out of scope. A plain
module with one public entry point can be adopted **one file at a time**, which is exactly
the property ISS-0112 needs later. `Letflow.DataCase` is **not** modified.

### 3.2 Public interface

Four public functions. Names, arities, argument shapes and return shapes are normative; the
`@spec`s below are the contract ELIXIR-DEV implements and CODE-DESIGN-VALIDATOR checks.

```
@type tenant_fixture :: %{
        tenant_id: Ecto.UUID.t(),
        schema_name: String.t(),
        tenant: Letflow.Identity.Tenant.t()
      }

@type opts :: [
        slug_prefix: String.t(),
        display_name: String.t(),
        oidc_mode: :enabled | :disabled,
        expected_tables: [String.t()] | :default,
        teardown: boolean()
      ]

@spec provisioned_tenant!(opts()) :: tenant_fixture()

@type schema_state :: %{
        schema_name: String.t(),
        tenant_id: Ecto.UUID.t(),
        registration_present?: boolean(),
        provisioned_at: NaiveDateTime.t() | nil,
        migrations_applied_at: NaiveDateTime.t() | nil,
        schema_present?: boolean(),
        tables_present: [String.t()],
        tables_missing: [String.t()],
        applied_versions: [integer()],
        manifest_versions: [integer()],
        versions_missing: [integer()],
        observed_at_utc: NaiveDateTime.t(),
        db_now: NaiveDateTime.t() | nil,
        pg_backend_pid: integer() | nil
      }

@spec capture_schema_state(tenant_id :: Ecto.UUID.t()) ::
        {:ok, schema_state()} | {:error, {:capture_failed, Exception.t()}}

@spec assert_schema_complete!(tenant_id :: Ecto.UUID.t(), expected :: [String.t()] | :default) ::
        :ok

@spec expected_tenant_tables() :: [String.t()]
```

`provisioned_tenant!/1` **reproduces today's fixture behaviour exactly**, then adds the
completeness check and the failure capture. Its steps, in order:

1. `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` — **unchanged from today**
   (`promotion_test.exs:79`, `promotion_assertion_rerun_test.exs:113`). Deliberately still
   not restored to `:manual`; that is ISS-0113 and is out of scope (INV-F-6).
2. Insert a `Letflow.Identity.Tenant` via `Tenant.create_changeset/3`, called with
   **exactly two cast attributes** — `slug:` from
   `Letflow.TenantSlugFixture.unique_slug(opts[:slug_prefix])` and `display_name:` from
   `opts[:display_name]` — and with `opts[:oidc_mode]` as the **third positional
   argument**, defaulting to `:disabled`.

   This is the contract as it really is, verified at source rather than inferred:

   - `Letflow.Identity.Tenant.create_changeset/3`
     (`lib/letflow/identity/tenant.ex:76–79` — `@spec` and head) has the signature
     `create_changeset(tenant, attrs, oidc_mode)` with a guard
     `when oidc_mode in [:enabled, :disabled]`. The third argument is the **OIDC mode**,
     not a status.
   - The `:disabled` appearing at both current fixture sites
     (`promotion_test.exs:62–72`, `promotion_assertion_rerun_test.exs:95–105`) is that
     third argument. Both sites pass `%{slug: …, display_name: …}` as `attrs` and pass
     **no `:status` at all**.
   - `lib/letflow/identity/tenant.ex:56` declares
     `field(:status, Ecto.Enum, values: [:active, :migrating], default: :active)`.
     `:disabled` is **not** a member of that enum; casting it produces an invalid
     changeset (`validation: :inclusion`), so a helper that passed it would raise on every
     insert.

   Consequently `opts` carries **no `:status` key**. Omitting the field is what preserves
   today's behaviour: both adopted sites currently get the schema default `:active`
   (INV-F-5). A future adopter (ISS-0112) that genuinely needs a non-default status may add
   a `:status` key then, constrained to `:active | :migrating` — the only legal values —
   but it MUST NOT be added speculatively here. `create_changeset/3` does cast `:status`
   and `:idp_realm_id`, so such an extension is possible later without changing production
   code; it is simply not part of this design.
3. Register the `on_exit/1` teardown described in §3.6 — registered **before**
   provisioning, exactly as today (`promotion_test.exs:83` precedes `:93`), so a failure in
   step 4/5/6 still cleans up.
4. `TenantProvisioning.provision_tenant_schema/1`; on anything other than
   `{:ok, %Registration{}}`, raise per §3.5 with `phase=provision_failed`.
5. `TenantProvisioning.replay_migrations/1`; on anything other than `{:ok, _}`, raise per
   §3.5 with `phase=replay_failed`.
6. `assert_schema_complete!/2` (§3.4); on incompleteness, raise per §3.5 with
   `phase=incomplete_schema`.
7. Return the `tenant_fixture()` map. Existing call sites destructure either
   `%{tenant_id: _, schema_name: _}` or, in some cases, `%{tenant_id: _}` alone
   (e.g. `promotion_test.exs:464–465`). Map destructuring is partial in Elixir, so the
   added `:tenant` key is additive and non-breaking at all 19 call sites
   (`promotion_test.exs` ×8, `promotion_assertion_rerun_test.exs` ×11) regardless of
   which subset each one binds.

`opts[:teardown]` defaults to `true`; `false` exists only so §7's fail-first tests can
construct a broken state without the fixture's own teardown racing their assertions. It is
not used by the two adopted modules.

### 3.3 The completeness oracle — `expected_tenant_tables/0`

A fully replayed tenant schema contains exactly the tables created by the
`create table(…, prefix: prefix())` migrations registered in `TenantProvisioning`'s
`@tenant_scoped_migration_manifest`, plus Ecto's own `schema_migrations` (created by
`Ecto.Migrator.run/4` in the prefix). Derived from the manifest's 31 entries, that is these
**19** tables:

```
events, instance_sequence, instance_projections, event_payload_store, events_archive,
event_idempotency, event_type_registry, process_definitions, instance_definition_snapshots,
promotion_reviews, promotion_assertion_runs, tokens, tasks, groups, tenant_role, users,
lua_script_execution_audit, instance_state_snapshots, variable_schemas
```

`schema_migrations` is **excluded** from `expected_tenant_tables/0` (it is the migrator's
bookkeeping, not a tenant table) but its *contents* are captured separately as
`applied_versions` in `schema_state()`.

**Oracle-rot guard (mandatory; mirrors REQ-082/ISS-0037's service-existence-oracle
obligation).** A hard-coded list silently rots the moment a 32nd manifest entry lands. The
helper's own test module therefore carries a test that provisions one throwaway tenant,
reads `information_schema.tables` for that schema, and asserts the observed set equals
`expected_tenant_tables/0` exactly — set equality in **both** directions, so a new
migration fails this test loudly instead of quietly weakening the oracle. This is the
mechanism that makes the list above safe to hard-code; without it, the list must not be
hard-coded.

### 3.4 The completeness invariant — `assert_schema_complete!/2` (scope item C)

Returns `:ok`, or raises `ExUnit.AssertionError`. It asserts, for the tenant's derived
schema, all three of:

1. The schema is present in `information_schema.schemata`.
2. `tables_missing == []`, where `tables_missing = expected -- tables_present` and
   `tables_present` comes from `information_schema.tables` filtered to
   `table_schema = $1 AND table_type = 'BASE TABLE'`.
3. `versions_missing == []`, where `manifest_versions` are the version integers of
   `TenantProvisioning.tenant_scoped_migrations/0` and `applied_versions` are the rows of
   `"<schema>".schema_migrations`.

Check 3 catches "replay never fully ran". Check 2 catches **failure 14's exact state** — a
recorded version whose table is nonetheless absent, which check 3 alone cannot see. Both
are required; neither subsumes the other.

The raised message embeds the full §3.5 report, so the *first* symptom of a
partially-migrated schema is a named missing-table list at the fixture, rather than an
opaque `42P01` on `promotion_assertion_runs` some 500 lines later.

### 3.5 One-shot failure capture — `capture_schema_state/1` (scope item A)

This is the artefact that converts the next occurrence from unattributable to attributable.
It is invoked at **every** raising point in `provisioned_tenant!/1` (steps 4, 5 and 6), so
the report shape is identical whichever way the fixture fails.

Every field of `schema_state()` exists because a specific question could not be answered
during the ISS-0109 diagnosis:

| Field | The question it answers | Source |
|---|---|---|
| `registration_present?`, `provisioned_at`, `migrations_applied_at` | Was the registry row deleted, or only the schema? Had replay ever completed? | `Repo.get_by(Registration, tenant_id: …)` — single-row, tenant-scoped |
| `schema_present?` | `3F000`: is the schema gone, or merely unreachable from this connection? | `information_schema.schemata`, parameterized on the one schema name |
| `tables_present`, `tables_missing` | `42P01`: which tables survived? (failure 14's decisive fact) | `information_schema.tables`, parameterized on the one schema name |
| `applied_versions`, `manifest_versions`, `versions_missing` | Did replay record versions whose tables are absent? | `"<schema>".schema_migrations` + `tenant_scoped_migrations/0` |
| `observed_at_utc` vs `provisioned_at` | The age of the row at failure — the number that excluded the reaper, and that Step 1 had to reconstruct by hand across a UTC-vs-local log skew | `NaiveDateTime.utc_now()` |
| `db_now` | Whether the BEAM clock and the Postgres clock agree, **measured** rather than assumed | `SELECT now() at time zone 'utc'` |
| `pg_backend_pid` | Which connection observed this; distinguishes a sandbox-visibility artefact from a real absence | `SELECT pg_backend_pid()` |

Failure-mode contract:

- **Never raises to its caller.** No exception escapes `capture_schema_state/1`. The
  caller then raises its own assertion error carrying whatever `capture_schema_state/1`
  returned. A capture that blew up must never replace the real failure with its own —
  this mirrors `TenantSchemaReaper.sweep_orphans/2`'s "never raises to its caller"
  contract (`test/support/tenant_schema_reaper.ex:50–56`).
- **Failure boundary — per-field `nil` vs `{:error, {:capture_failed, _}}`.** These two
  rules are not alternatives; they are nested, and the boundary between them is
  **normative**, not an implementer's choice:
  - **Each individual field is gathered inside its own guard.** If gathering *that field*
    raises (a failed query, an unexpected result shape), that field alone degrades — to
    `nil` for scalar fields and `[]` for list fields — and the call still returns
    `{:ok, schema_state()}` with every other field populated. **A single failing query is
    always a per-field degradation, never a whole-call failure.**
  - **Derived fields follow their inputs.** If `tables_present` degraded to `[]`, then
    `tables_missing` is `[]` as well — *not* "all 19 missing" — because an unobserved
    set must never be reported as an observed absence. Same for
    `applied_versions`/`versions_missing`.
  - **`{:error, {:capture_failed, exception}}` is the outer safety net only.** It is
    returned when the failure is *outside* the per-field guards — e.g. assembling the
    result map itself raises, or the `tenant_id` argument is malformed so that no field
    can be attempted at all. It is **not** reachable by any single field's query failing.
  - A tenant that simply does not exist, or whose schema is absent, is **not** a capture
    failure: it returns `{:ok, state}` with the `present?` flags `false` (INV-F-4, and
    C4's negative case in §7).
- **One shot.** All fields are gathered in one call at the moment of failure. No retry, no
  polling — a retry would observe a *different* state than the one that failed.
- **Emitted twice, deliberately:** into the raised `ExUnit.AssertionError` message (so it
  lands in the test output CI preserves) **and** via `Logger.error/1` carrying the §3.6
  marker (so it is greppable in a raw run log even when assertion output is truncated).

### 3.6 Teardown logging — distinguishable from a mid-test drop (scope item B)

The whole misdiagnosis in ISS-0109's `mechanism:` section came from a `DROP SCHEMA` /
`DELETE` / `DELETE` triple in the log that carried nothing saying *whose* it was. One line
closes that error class permanently.

The helper's `on_exit/1` teardown performs today's three statements unchanged —
`DROP SCHEMA IF EXISTS "<schema>" CASCADE`, `delete_all` on `Registration` by `tenant_id`,
`delete_all` on `Tenant` by `id` (`promotion_test.exs:84–90`) — and additionally emits
**exactly one** log line **before** the `DROP`, carrying a fixed literal marker token plus:
the phase literal `teardown`, the schema name, the tenant id, whether the schema was
present immediately before the drop, and the owning test module and name.

Normative details:

- **Marker token:** the literal string `LETFLOW_TENANT_FIXTURE` appears in the line. Fixed
  and greppable; it must not be assembled at runtime from parts.
- **Phase vocabulary, closed set:** `teardown` | `provision_failed` | `replay_failed` |
  `incomplete_schema`. `teardown` is the only phase the teardown path may emit, and the
  other three are the only phases the failure path may emit. Any future
  `LETFLOW_TENANT_FIXTURE … phase=teardown` line in a log is therefore, by construction, a
  post-test teardown and **never** a mid-test drop — precisely the inference Step 1 had to
  spend a whole diagnosis re-establishing.
- **`schema_present_before_drop`** distinguishes "we tore down a schema that was still
  there" (normal) from "we tore down a schema that had already vanished" (the ISS-0109
  shape — and the state today's `DROP SCHEMA IF EXISTS … CASCADE` silently succeeds
  against, telling nobody).
- **Cheap:** one line per fixture teardown, at `:info`. No new dependency, no formatter, no
  metadata backend, no config change. This is not a logging framework. (See OQ-4 on the
  effective test log level.)

---

## 4. Invariants

| Id | Invariant |
|---|---|
| **INV-F-1** | `Letflow.TenantFixture` is test-only. It never appears under `lib/`, is never referenced by shipped code, and is never added to `lib/letflow/application.ex`'s supervision tree. |
| **INV-F-2** | `lib/letflow/tenant_provisioning.ex` and `lib/letflow/tenant_provisioning/registration.ex` are **not modified** by this design (§2.3). |
| **INV-F-3** | The helper never calls `provision_tenant_schema/1` from inside `replay_migrations/2` or vice versa. It sequences the two primitives explicitly, as `req022` lines 288–294's No-implicit-chaining invariant requires of a caller. |
| **INV-F-4** | `capture_schema_state/1` never raises to its caller; it returns `{:error, {:capture_failed, _}}`, and the caller's own failure remains the reported failure. |
| **INV-F-5** | Teardown behaviour is today's three statements, unchanged in content and order, plus one log line. The helper does not add, reorder, or condition any teardown statement. |
| **INV-F-6** | The helper reproduces today's `Sandbox.mode(Letflow.Repo, :auto)` call and does **not** restore `:manual` (ISS-0113, out of scope). Adopting the helper must not change sandbox-mode behaviour in either direction. |
| **INV-F-7** | `expected_tenant_tables/0` is guarded by the §3.3 oracle-rot test. Removing that test invalidates the hard-coded list. |
| **INV-F-8** | Every query the helper issues is either (a) parameterized and scoped to the single tenant/schema under test, or (b) a read of Postgres catalog metadata (`information_schema.schemata` / `information_schema.tables`) filtered by `table_schema = $1`. No value belonging to another tenant is ever read, logged, or returned. No unscoped catalog enumeration. |
| **INV-F-9** | The only raw-SQL identifier interpolation the helper performs is in `DROP SCHEMA IF EXISTS "<name>" CASCADE` and `"<name>".schema_migrations`, and `<name>` is always the output of `TenantProvisioning.schema_name_for_tenant/1` — never a caller-supplied string. This is the same INV-7 argument `tenant_provisioning.ex:180–187` already makes. Everything else is `$1`-parameterized. |
| **INV-F-10** | A failing capture, a failing log call, or a stale oracle entry must never turn a *passing* test red. Only a genuinely absent schema, absent table, or missing migration version fails a test (the oracle-rot test of §3.3 is itself the one deliberate exception, and it fails only the helper's own test module). |

---

## 5. Adoption boundary — exactly two modules

Adopted in this run, and only these:

- `test/letflow/definitions/promotion_test.exs` — replace the private `insert_tenant!/0`
  (:62), `drop_schema!/1` (:74) and `provisioned_tenant/0` (:78–98) with calls to
  `Letflow.TenantFixture.provisioned_tenant!/1` (`slug_prefix: "req037-promo"`,
  `display_name: "REQ-037 Promotion Test Tenant"`). Its 8 call sites (:173, :174, :243,
  :244, :379, :380, :464, :465) keep their existing `%{tenant_id:, schema_name:}`
  destructuring.
- `test/letflow/definitions/promotion_assertion_rerun_test.exs` — same for :95, :112–133
  (`slug_prefix: "req040-assertion-rerun"`,
  `display_name: "REQ-040 Assertion Rerun Test Tenant"`); 11 call sites. **`drop_schema!/1`
  (:107) stays** in this file: it has a second, unrelated caller at :463
  (`on_exit(fn -> drop_schema!(held_schema) end)`) for a `SandboxPool`-held schema that is
  not a `TenantFixture` tenant. Removing it there is out of scope and would break that test.

**The other 39 copy-paste sites are not touched** (ISS-0112 / GH#366). The helper is
designed so they *can* migrate later — all per-site variation is carried by `opts`, and no
site would need a helper change to adopt it — but this run must not migrate them, and a
diff touching a third test module is out of scope for this design.

---

## 6. Cross-module dependencies

| Depends on | Direction | Note |
|---|---|---|
| `Letflow.TenantProvisioning` (`schema_name_for_tenant/1`, `provision_tenant_schema/1`, `replay_migrations/1,2`, `tenant_scoped_migrations/0`) | helper → production | Read-only use of the existing public API. `tenant_scoped_migrations/0` is already public (:430–:431). |
| `Letflow.TenantProvisioning.Registration` | helper → production | `Repo.get_by/2` only. |
| `Letflow.Identity.Tenant` (`create_changeset/3`) | helper → production | The same call both fixtures make today. |
| `Letflow.TenantSlugFixture.unique_slug/1` | helper → test/support | Already used by both sites. |
| `Letflow.Repo` | helper → production | |
| `Letflow.TenantSchemaReaper` | **none** | No call in either direction. The helper does not sweep, and the reaper does not know about the helper. Stated explicitly so the ISS-0110 hazard stays independent of this change. |
| `Letflow.DataCase` | **none** | Not modified (§3.1). |

**Non-contradiction check.** `lib/letflow/design/iss064-orphaned-tenant-schemas-fix.md` §1
scopes the reaper to *orphan reclamation at suite boundaries*; §5 fixes `test_helper.exs`'s
shape; §6 lists what ELIXIR-DEV must not change. Nothing in this design alters the reaper,
`test_helper.exs`, `sweep_orphans/2`'s contract, or its `min_age` default; and the
schema-name regex is not re-duplicated (the helper obtains names from
`schema_name_for_tenant/1`, so iss064 §4 INV-R-1's duplicate-regex caveat does not extend
here). No `docs/migration/decisions/` record is contradicted. §2.2 is the one place where a
contradiction was *available*, and this design declines it rather than resolving it
unilaterally. **No REVIEWER escalation is required by this design.**

---

## 7. FAIL-FIRST PROVABILITY (mandatory section)

WF-03 Step 4 needs a regression test that fails against pre-fix code and passes against
post-fix code. ISS-0109's own occurrence is intermittent and unreproduced (Step 1 attempted
it: three iterations × two concurrent `mix test` invocations, 828/828 passed, zero
`3F000`/`42P01`), so **no test here may be built by waiting for a recurrence**. Every
behaviour change below is instead made to fail first by *constructing the broken state
directly*. Each item states the construction, the pre-fix outcome, and the post-fix outcome.

All constructions below use `provisioned_tenant!(teardown: false)` plus an explicit
`on_exit` in the test itself, so the constructed damage is not repaired or raced by the
fixture's own teardown.

### 7.1 Change C1 — completeness check catches a missing **table** (failure 14's state)

- **Construct:** provision a tenant normally (`provision_tenant_schema/1` +
  `replay_migrations/1`), then `DROP TABLE "<schema>"."promotion_assertion_runs"` by raw
  SQL, leaving the schema, all other tables, and every `schema_migrations` row intact. This
  is exactly failure 14's observed state: schema present, a `promotion_reviews` insert in
  that same schema succeeds, `promotion_assertion_runs` absent.
- **Pre-fix:** the fixture's `assert {:ok, _} = replay_migrations(tenant.id)` still passes
  (the version is recorded, so `Ecto.Migrator.run/4` re-applies nothing), the fixture
  returns success, and the failure surfaces much later as `42P01`.
- **Post-fix:** `assert_schema_complete!/2` raises with
  `tables_missing == ["promotion_assertion_runs"]`.
- **Test shape:** `assert_raise ExUnit.AssertionError, fn -> …assert_schema_complete!(…) end`
  plus an assertion that the message contains the literal `promotion_assertion_runs`.
  Deterministic — no timing, no concurrency, no full-suite dependency.

### 7.2 Change C2 — completeness check catches a missing **schema** (failure 3's state)

- **Construct:** provision a tenant normally, then `DROP SCHEMA "<schema>" CASCADE` while
  leaving its `tenant_schemas` row in place — precisely the state
  `re_select_registration/1` returns `{:ok, registration}` for.
- **Pre-fix:** `capture_schema_state/1` and `assert_schema_complete!/2` do not exist, so
  nothing detects it; the state is discovered only downstream as `3F000`/`42P01`.
- **Post-fix:** `assert_schema_complete!/2` raises with `schema_present? == false`; and
  after a second `provision_tenant_schema/1` (which re-creates an *empty* schema per
  §2.1's :188), it raises with `tables_missing` listing all 19 tables.
- **Note on what this proves:** it proves the *fixture* now detects the state. It does
  **not** prove a production behaviour change — §2.1 established there is none, and this
  test must not be written as though there were. Asserting that pre-fix
  `provision_tenant_schema/1` returns `{:ok, %Registration{}}` in this state is legitimate
  and useful as a **characterization** test (it pins the documented idempotency), but it is
  not the regression assertion, and it must not be labelled as one.

### 7.3 Change C3 — completeness check catches a missing **migration version**

- **Construct:** provision a tenant, then
  `DELETE FROM "<schema>".schema_migrations WHERE version = <highest manifest version>`
  **and** drop that migration's table — i.e. a replay that stopped short.
- **Pre-fix:** fixture reports success.
- **Post-fix:** raises with both `versions_missing` and `tables_missing` non-empty.
- Deterministic.

### 7.4 Change C4 — `capture_schema_state/1` reports the constructed state faithfully

- **Construct:** the three broken states above, plus the healthy state.
- **Assert, per state:** `schema_present?`, `registration_present?`, `tables_missing` and
  `versions_missing` match the constructed truth exactly; `observed_at_utc` is not `nil`;
  `provisioned_at` is not `nil` when the row exists; `db_now` and `observed_at_utc` agree
  within a generous bound (a bound, not equality — the two clocks are read microseconds
  apart, and this assertion's purpose is to catch a *basis* error such as local-vs-UTC, of
  the kind that cost Step 1 a five-hour reconciliation, not to police jitter).
- **Fails first trivially:** the function does not exist pre-fix.
- **Plus a negative test:** call it for a `tenant_id` with no registry row and no schema and
  assert it returns `{:ok, state}` with `registration_present? == false` and
  `schema_present? == false` — i.e. that it does **not** raise (INV-F-4).

### 7.5 Change C5 — teardown log line is distinguishable

- **Construct:** exercise the helper's teardown under `ExUnit.CaptureLog`.
- **Assert:** exactly one line matching the literal `LETFLOW_TENANT_FIXTURE`, containing
  `phase=teardown`, the schema name, and a `schema_present_before_drop` value; and that the
  failure paths emit `phase=provision_failed` / `replay_failed` / `incomplete_schema` and
  **never** `phase=teardown`.
- **Fails first trivially:** no such line exists pre-fix (today's teardown emits only
  Ecto's own SQL logging, which is exactly the ambiguity that produced ISS-0109's
  `mechanism:` section).

### 7.6 Change C6 — the oracle-rot guard (§3.3)

- **Assert:** the table set observed in a freshly provisioned schema equals
  `expected_tenant_tables/0`, in both directions.
- **Fails first trivially:** the function does not exist pre-fix. Its *later* value is the
  real point — it fails the day a 32nd manifest entry lands without updating the list.

### 7.7 The one change with **no** fail-first proof — stated explicitly, as the handoff requires

**The adoption of the helper by the two named test modules (§5) cannot be shown to fail
first**, because it is a refactor with no behaviour delta by construction (INV-F-5,
INV-F-6): the same tenant is inserted, the same schema provisioned, the same replay run,
the same three teardown statements issued. There is no pre-fix state in which the two
modules behave differently post-adoption, except by *additionally* failing when a schema is
incomplete — and C1–C3 already prove that at the helper level.

**Why it still belongs in the design:** without adoption, none of C1–C6 protects the two
modules ISS-0109 actually names, and the issue's own two failure sites would keep the
uninstrumented fixture, leaving the next occurrence exactly as unattributable as this one.
The evidence standard for this item is therefore not fail-first but
**behaviour-preservation**: both modules must pass in full, pre- and post-adoption, and
TEST-RUNNER must quote both runs. That is a weaker guarantee than fail-first, and it is
flagged here as such rather than dressed up as one.

---

## 8. WHAT THIS DOES AND DOES NOT CLOSE (mandatory section)

**Verdict: INSTRUMENTED, not FIXED.**

Stated plainly, because ORCH sets ISS-0109's final status from this answer and six other
issues cross-reference the registry.

### 8.1 What is genuinely fixed

1. **A real, demonstrable gap at the fixture layer** (§2.2): the sequencer of
   `provision_tenant_schema/1` + `replay_migrations/2` never verified that the result was
   complete. After this design, a partially-migrated tenant schema fails at the fixture,
   naming the missing tables, instead of ~500 lines later as an opaque `42P01`. This is a
   real behaviour improvement with deterministic fail-first proof (§7.1–7.3) — but it is a
   *detection* improvement, not the removal of whatever produced the incomplete schema.
2. **The misdiagnosis class is closed.** §3.6's `phase=` vocabulary makes a post-test
   teardown structurally impossible to mistake for a mid-test drop. ISS-0109's `mechanism:`
   section could not have been written the way it was against a log carrying these lines.
3. **The next occurrence becomes attributable in one shot** (§3.5). The ISS-0109 diagnosis
   needed a live clock probe, an SQL-shape probe, an ExUnit source read, and a full
   enumeration of every `DROP SCHEMA` writer in the repository, and *still* could not say
   what removed the schema — because the raw log was gone and the state at failure was
   never captured. Every field in `schema_state()` is one of those unanswered questions.

### 8.2 What is **not** fixed

**The root cause of ISS-0109 remains unknown.** Nothing in this design identifies, let
alone removes, whatever removed `tenant_8111baf7cec4418592f94a3a68a71722`'s schema between
its commit and the replay, or whatever left `tenant_cb34d76b…`'s schema missing one table.
Specifically:

- No production defect was found (§2), so there is no production cause to remove.
- The failure was never reproduced (Step 1 attempted it; 828/828 passed).
- The remaining live sharing channels — ISS-0110's 300 s reaper window, ISS-0107's nested
  invocation, ISS-0111's bulk registry delete — are all out of scope here and **still
  open**. If any of them is the real cause, this design does not stop it; it only ensures
  the next occurrence says so.

### 8.3 Recommended issue status

ISS-0109 should **not** be closed as `resolved` on the strength of this design.
Recommended: keep it open (or move it to a `monitoring`/`instrumented` state if the
registry has one), with its `mechanism:` section corrected per Step 1's MAJOR finding, its
`related:` list extended with ISS-0107 and ISS-0059, and a note that the fixture is now
instrumented so the next occurrence is self-diagnosing. ORCH owns the final call at Step 5;
this section is the input to that call, not the call itself.

---

## 9. What ELIXIR-DEV must NOT change

1. `lib/letflow/tenant_provisioning.ex` — **no edit.** Not the
   `insert_or_fetch_registration/2` / `re_select_registration/1` pair (:458–:488), not
   `provision_tenant_schema/1`'s ordering (:164–:202), not `replay_migrations/2`
   (:238–:264). §2 is the reasoning; a diff here contradicts `req022` lines 288–294.
2. `lib/letflow/tenant_provisioning/registration.ex` — no edit.
3. `test/support/tenant_schema_reaper.ex` and `test/test_helper.exs` — no edit. Those are
   ISS-0064's shipped design and ISS-0110's open hazard.
4. `test/support/data_case.ex` — no edit (§3.1).
5. The other 39 copy-paste fixture sites — no edit (ISS-0112).
6. `promotion_assertion_rerun_test.exs`'s `drop_schema!/1` — keep it; :463 still calls it (§5).
7. Do **not** restore `Sandbox.mode(…, :manual)` anywhere (ISS-0113, INV-F-6).
8. Do **not** add a retry or poll loop to `capture_schema_state/1` (§3.5).

---

## 10. Open questions (explicit, not silently resolved)

- **OQ-1 — where the incomplete schema comes from.** Unresolved, deliberately. §8.2 states
  this plainly. It is the question the §3.5 capture exists to answer on the next
  occurrence; guessing at it here would put a fabricated mechanism into a second issue
  record immediately after Step 1 had to remove one from the first.
- **OQ-2 — `Registration.changeset/2` validates `schema_name`'s *shape* but not that it
  equals `schema_name_for_tenant(tenant_id)`** (`registration.ex:57–65` vs
  `tenant_provisioning.ex:101–106`). Unreachable today: no writer outside
  `provision_tenant_schema/1` exists in `lib/` (§2.1). Recorded as an observation for a
  future run, **not** fixed here, and not counted as a defect. If ORCH wants it tracked it
  is a new issue, not an addition to ISS-0109.
- **OQ-3 — should `expected_tenant_tables/0` eventually be *derived* rather than
  hard-coded?** The §3.3 oracle test makes the hard-coded list safe, but a derivation
  (parsing the manifest, or snapshotting a reference schema) would remove the maintenance
  step entirely. Not chosen here: parsing migration source is fragile, and snapshotting
  introduces a suite-order dependency. Left open rather than decided.
- **OQ-4 — `Logger` level for the two emissions.** Specified as `:error` for failures and
  `:info` for teardown. If the suite's effective log level filters `:info` in CI, the
  teardown line disappears and scope item (B) is defeated. ELIXIR-DEV must confirm the
  effective test log level and, if `:info` is filtered, raise the teardown line to
  `:warning` rather than reconfiguring the logger globally. Flagged rather than assumed.

---

## 11. Acceptance-criteria traceability

| Handoff acceptance criterion | Where satisfied |
|---|---|
| Design artefact at `lib/letflow/design/iss0109-*.md`, no implementation code | This file. Interfaces, `@spec`s, invariants, failure modes only; no function bodies, no `.ex`/`.exs` source blocks. |
| Verdict, with file:line, on `insert_or_fetch_registration/2` → `re_select_registration/1` | §2 (§2.1 refutes the schema half at `tenant_provisioning.ex:170/:188/:190/:483`; §2.2 resolves the tables half against `:18–23` and `req022:288–294`) |
| Covers (A) shared helper with one-shot capture, (B) distinguishable teardown logging, (C) completeness invariant | §3.2/§3.5 (A), §3.6 (B), §3.3–§3.4 (C) |
| Limits adoption to the two named modules; no ISS-0112 migration | §5, §9 item 5 |
| FAIL-FIRST PROVABILITY, per change, specific enough for TEST-DESIGNER to build from | §7 (C1–C6 constructed states; §7.7 names the one item with no fail-first proof and justifies it) |
| FIXED vs INSTRUMENTED stated plainly | §8 — **INSTRUMENTED**, with §8.3's status recommendation |
| No fixes proposed for ISS-0110/0111/0112/0113/0107, and rationale independent of them | §1.2, §8.2, §9 item 3 |
| No contradiction with `iss064-orphaned-tenant-schemas-fix.md` or any `docs/migration/decisions/` record | §6 non-contradiction check; §2.2 declines the one available contradiction rather than resolving it |
