# Design: ISS-0112b — `idp_realm_id` opt for `Letflow.TenantFixture.provisioned_tenant!/1`

**Run:** WF03-ISS0112b · **Workflow:** WF-02 Step 1 (requirement/gap fix design) · **Author:** CODE-DESIGNER
**Parent:** ISS-0112 / GH#366, Batch 4 migration · **Base module:** `test/support/tenant_fixture.ex`,
implementing `lib/letflow/design/iss0109-provisioning-completeness-and-fixture-instrumentation.md`

> **Design artefact only.** No implementation code below — interfaces, `@spec`s, data
> shapes, invariants, and open questions only. ELIXIR-DEV implements it; TEST-DESIGNER
> builds tests from §7.

---

## 0. Sources read for this design

| Source | Used for |
|---|---|
| `test/support/tenant_fixture.ex` (full file) | current `@type opts`, `provisioned_tenant!/1` body, its own design-doc-tracks-implementation discipline |
| `lib/letflow/design/iss0109-provisioning-completeness-and-fixture-instrumentation.md` (full) | the module's own stated constraints — INV-F-1..F-10, §3.2's normative `opts` shape, §2.3's "not a tenant-data-path change" precedent |
| `lib/letflow/identity/tenant.ex` :71, :85–110, :376–399 | `create_changeset/3`'s exact cast list and validation behaviour for `idp_realm_id` |
| `test/letflow/plugs/auth_pipeline_test.exs` :88–137 | `insert_tenant!/1`, `insert_tenant_for_realm!/1`, `insert_bpm_default_tenant!/0` |
| `test/letflow/plugs/auth_pipeline_configurable_verifier_test.exs` :51–125, :140–225 | `insert_tenant_for_realm!/1`; grepped for `bpm-default` — none found |
| `test/letflow/plugs/iss0736_oidc_live_revocation_test.exs` :57–106 | `insert_tenant!/1`, `insert_bpm_default_tenant!/0` (ported verbatim from auth_pipeline_test.exs) |
| `test/letflow/api/authorization_ac9_test.exs` :1–75 | `insert_tenant_for_realm!/1`; moduledoc explicitly states it avoids `"bpm-default"` |
| `test/support/bpm_default_realm_displacement.ex` (full) | `displace!/0`/`with_lock/1`, the ISS-0766 self-healing repair, the advisory-lock mutual-exclusion mechanism |
| `test/support/tenant_slug.ex` | `unique_slug/1` always appends `Ecto.UUID.generate/0` — a fixture-generated slug can never equal `"bpm-default"` exactly |
| `test/letflow/support/tenant_fixture_test.exs` | where this extension's tests belong; existing `describe` naming convention (C1..C6) |

---

## 1. Correction to the task's premise — stated explicitly, not silently absorbed

The handoff states "3 of the 4 files pin to the literal value `\"bpm-default\"`". Reading
all four files' insertion code directly (not inferred) shows this is **not accurate**:

| File | `idp_realm_id` source | Pins `"bpm-default"`? |
|---|---|---|
| `auth_pipeline_test.exs` | `insert_tenant_for_realm!/1`: dynamic (`unique_realm/1`, caller-supplied). `insert_bpm_default_tenant!/0`: literal `"bpm-default"`, preceded by `BpmDefaultRealmDisplacement.displace!()` | **Yes**, via its `insert_bpm_default_tenant!/0` helper only |
| `auth_pipeline_configurable_verifier_test.exs` | `insert_tenant_for_realm!/1`: dynamic (`unique_realm/1`) only, at every call site (:157, :171, :184, :225) | **No** — grepped for `"bpm-default"` outside the moduledoc/comment; zero insertion call sites use it |
| `iss0736_oidc_live_revocation_test.exs` | `insert_tenant!/1`: fully caller-supplied `attrs`. `insert_bpm_default_tenant!/0`: literal `"bpm-default"`, preceded by `displace!()` — ported verbatim from `auth_pipeline_test.exs` | **Yes**, via its `insert_bpm_default_tenant!/0` helper only |
| `authorization_ac9_test.exs` | `insert_tenant_for_realm!/1`: dynamic (`unique_realm/1`) only | **No** — its own moduledoc states it *deliberately avoids* `"bpm-default"` specifically to sidestep the ISS-0108 collision class |

**Corrected count: 2 of 4 files (`auth_pipeline_test.exs`, `iss0736_oidc_live_revocation_test.exs`)
pin the literal `"bpm-default"`; the other 2 use exclusively dynamic, per-test-unique realm
strings.** This does not change §3's or §4's conclusions (the collision-risk mechanism
below is identical whether triggered by a hard-coded literal or by two tests that happen to
generate the same dynamic string — the latter is structurally prevented by `unique_realm/1`'s
`System.unique_integer/1` suffix, so in practice only the `"bpm-default"` literal path is a
live hazard), but the premise correction is recorded per this design's own no-speculation
obligation rather than silently building on an unverified count.

All four files, regardless of which realm source they use, share one relevant joint fact:
every one of them passes `oidc_mode: :enabled` (either as `create_changeset/3`'s third
positional argument directly, or via `insert_tenant!/1`'s hard-coded `:enabled`) — never
`TenantFixture.provisioned_tenant!/1`'s current default of `:disabled`. §2.2 below is why
that joint fact is load-bearing for this design, not incidental.

---

## 2. The `opts` key to add

### 2.1 Shape

```
@type opts :: [
        slug_prefix: String.t(),
        display_name: String.t(),
        oidc_mode: :enabled | :disabled,
        idp_realm_id: String.t() | nil,
        expected_tables: [String.t()] | :default,
        teardown: boolean(),
        template: :clone | :replay
      ]
```

One new key, `idp_realm_id: String.t() | nil`, inserted into the existing `opts` keyword
list type (position in the type declaration is not itself normative — Elixir keyword-list
opts have no positional meaning — but list it adjacent to `oidc_mode` since §2.2 makes them
interact). Default **`nil`**, meaning: cast no realm value at all, reproducing every
existing call site's current behaviour exactly (none of them passes `idp_realm_id` today,
so the column is left at its schema default, which is `nil` — `lib/letflow/identity/tenant.ex`
declares `field(:idp_realm_id, :string)` with no `default:` option).

### 2.2 Interaction with `oidc_mode` — the one joint consideration, made explicit

`Tenant.create_changeset/3`'s validation is not independent of `oidc_mode`
(`lib/letflow/identity/tenant.ex:391–399`):

- `oidc_mode == :disabled` → `idp_realm_id` stays optional regardless of value (§`validate_idp_realm_id_required(changeset, :disabled)` is a no-op).
- `oidc_mode == :enabled` **and** the changeset's `slug` is not exactly `"bpm-default"` →
  `idp_realm_id` becomes **required** (`validate_required(changeset, [:idp_realm_id])`).
  A `TenantFixture`-generated slug can never equal `"bpm-default"` exactly: `slug` is always
  `Letflow.TenantSlugFixture.unique_slug(slug_prefix)`, which unconditionally appends
  `"-#{Ecto.UUID.generate()}"` regardless of what `slug_prefix` is passed
  (`test/support/tenant_slug.ex:21–23`) — so this branch is the one every
  `TenantFixture`-provisioned tenant with `oidc_mode: :enabled` falls into, unconditionally.

**Consequence, stated as an explicit precondition, not silently handled:**
`provisioned_tenant!(oidc_mode: :enabled)` **without** `idp_realm_id:` will make
`Repo.insert!/1` raise `Ecto.InvalidChangesetError` (the changeset's `validate_required/2`
fails). This is **existing, unchanged `Tenant.create_changeset/3` behaviour** — not new
behaviour this design introduces — but it is a real interaction the four consuming files
must satisfy: every one of them already supplies both `oidc_mode: :enabled` and a
(dynamic-or-literal) `idp_realm_id` value at every call site, so no consuming file needs a
workaround here; this section exists so ELIXIR-DEV and TEST-DESIGNER do not have to
rediscover the constraint by hitting the raise.

### 2.3 What the fixture does *not* do

`TenantFixture` performs **no new validation** of its own on `idp_realm_id` — no shape
check, no "is this `\"bpm-default\"`?" branch, no collision pre-check. It passes the value
through to `Tenant.create_changeset/3` exactly as `oidc_mode` is passed through today, and
lets that changeset's own (already-decided, `lib/letflow/identity/tenant.ex`-owned)
validation and the database's own partial unique index be the sole authorities on whether a
given value is acceptable. Adding fixture-side validation would be new behaviour beyond
what ISS-0112b asks for, and would duplicate logic that already exists correctly one layer
down — precisely the "do not add behavior beyond design update" discipline this module's
own moduledoc states.

---

## 3. Threading — the exact call site touched

`provisioned_tenant!/1`'s body (`test/support/tenant_fixture.ex:234–263`) builds a map
literal and passes it as `create_changeset/3`'s `attrs` argument:

```
tenant =
  %Tenant{}
  |> Tenant.create_changeset(
    %{
      slug: Letflow.TenantSlugFixture.unique_slug(slug_prefix),
      display_name: display_name
    },
    oidc_mode
  )
  |> Repo.insert!()
```

The change is a **one-key addition to that same map literal**: add
`idp_realm_id: idp_realm_id` where `idp_realm_id = Keyword.get(opts, :idp_realm_id, nil)` is
read alongside the function's existing `slug_prefix`/`display_name`/`oidc_mode`/`expected`/
`template` local-variable reads (`tenant_fixture.ex:237–241`), in the same style (one
`Keyword.get/3` per opt, at the top of the function body, before `owning_test()`).

No other line in `provisioned_tenant!/1` changes. `create_changeset/3` already casts
`:idp_realm_id` (`tenant.ex:104`, `[:slug, :display_name, :status, :idp_realm_id]`), so this
is a **caller-side-only change**: `lib/letflow/identity/tenant.ex` needs **zero** edits
(confirms INV-F-2 below is preserved, not merely "not violated by accident").

**Behaviour-preservation for every existing caller.** Every current call site of
`provisioned_tenant!/1` — both ISS-0109-adopted modules and any other caller that predates
this opt — omits `idp_realm_id:` entirely, so `Keyword.get(opts, :idp_realm_id, nil)`
evaluates to `nil`. Casting an explicit `idp_realm_id: nil` into `attrs` is behaviourally
identical to the key being entirely absent from `attrs` (today's exact behaviour): the field
is nullable at the column level with no schema `default:`, so `Ecto.Changeset.cast/3` leaves
it at the struct's own default (`nil`) either way, and no validation this design touches
distinguishes "key absent" from "key present with value `nil`". This is the same
behaviour-preservation argument §3.2 of the iss0109 design already made for `oidc_mode`
gaining a default; it is restated here for the new key specifically because it is the
concrete claim CODE-DESIGN-VALIDATOR needs to check.

---

## 4. Collision risk — determined precisely, not assumed

**Determination: the fixture's per-test schema isolation does *not* cover this. The
collision risk is real, structurally identical to the ISS-0766/ISS-0108 class, and the
fixture leaves it entirely to the caller to manage — by design, not by oversight.**

Reasoning, traced through the actual mechanism rather than assumed by analogy:

1. `provisioned_tenant!/1`'s "per-test isolation" property (the property that lets 39 other
   call sites safely coexist) comes from two places: (a) each call generates a **globally
   unique `slug`** via `unique_slug/1`'s UUID suffix, and (b) each call provisions a
   **dedicated, uniquely-named Postgres schema** (`tenant_<32-hex-tenant-id>`) that only
   that test's rows live in. Both of those are scoped to the *tenant row's own identity*
   and to *tenant-scoped tables inside that tenant's schema*.
2. `idp_realm_id` is neither. It is a plain column on the single, shared, `public.tenants`
   table (`lib/letflow/identity/tenant.ex:71`), the same row-level namespace `slug` lives in
   — but unlike `slug`, `TenantFixture` does **not** generate a unique value for it; a caller
   who passes a literal (`"bpm-default"`, or any other fixed string reused across tests)
   gets that literal verbatim in `public.tenants.idp_realm_id`.
3. `tenants_idp_realm_id_partial_index` (a real Postgres partial unique index, confirmed by
   `unique_constraint(:idp_realm_id, name: :tenants_idp_realm_id_partial_index)` at
   `tenant.ex:109`) enforces **at most one row per distinct non-null `idp_realm_id` value,
   database-wide** — across every schema, every test module, and (per
   `bpm_default_realm_displacement.ex`'s own moduledoc, confirmed live) **across multiple
   concurrently-running `mix test`/`scripts/test_parallel.sh` OS processes sharing the same
   test database**. Per-test schema provisioning does nothing to partition this index,
   because the index is not schema-scoped — it is one index on one shared table.
4. Consequently: two `TenantFixture.provisioned_tenant!(idp_realm_id: "bpm-default", ...)`
   calls racing concurrently (or one racing the migration-seeded row, or one racing
   `identity_test.exs`'s or another module's own hand-rolled insert against the same value)
   collide on that unique index exactly the way ISS-0766/ISS-0108 already documented for
   hand-rolled inserts — this is **the same hazard class**, not a new one, now reachable
   through the shared fixture instead of only through copy-pasted code.

**Design decision: the fixture does not solve this.** Three options were considered:

- **(Rejected) Fixture auto-detects `idp_realm_id == "bpm-default"` and calls
  `BpmDefaultRealmDisplacement.displace!()` internally.** Rejected: it would silently import
  a specific literal's special-case handling into a general-purpose fixture, contradicting
  §2.3's "no new behaviour beyond passthrough" scoping, and would make the fixture depend on
  `test/support/bpm_default_realm_displacement.ex` for a case only 2 of ~41 call sites need.
  It would also be wrong for a hypothetical future caller who pins some *other* singleton
  realm this module knows nothing about — the real fix in that case is the same as today's:
  the caller displaces/coordinates, not the fixture.
- **(Rejected) Fixture rejects `idp_realm_id: "bpm-default"` outright (`raise ArgumentError`)**
  Rejected: it would make the fixture unusable for exactly the two files that legitimately
  need it (with displacement already handled correctly by their own existing code), for no
  safety gain — the unique index itself is the actual backstop; a caller who forgets
  `displace!()` gets a loud `Ecto.InvalidChangesetError`/constraint violation immediately at
  insert time, not silent corruption.
- **(Adopted) Fixture stays a thin passthrough; the precondition is documented, not enforced
  in code.** A caller pinning any singleton-class `idp_realm_id` value (`"bpm-default"`
  today; any future equivalent) remains responsible for its own coordination — via
  `Letflow.Support.BpmDefaultRealmDisplacement.displace!()` for `"bpm-default"` specifically
  — called **before** `provisioned_tenant!/1`, exactly mirroring the order every existing
  `insert_bpm_default_tenant!/0` helper already uses
  (`auth_pipeline_test.exs:130` / `iss0736_oidc_live_revocation_test.exs:99`, both call
  `displace!()` as the first statement, before `insert_tenant!/1`). This keeps
  `TenantFixture` consistent with its own stated shape (a thin, general-purpose sequencer,
  INV-F-2/§3.1 of the base design) and requires **zero** new fixture code beyond §3's
  one-key threading.

This is recorded as a new invariant (§5, INV-F-11) rather than left as prose only, so
CODE-DESIGN-VALIDATOR and a future reader do not have to re-derive it.

---

## 5. New invariant

| Id | Invariant |
|---|---|
| **INV-F-11** | `provisioned_tenant!/1` performs no `idp_realm_id`-specific validation, displacement, or collision handling of any kind. A caller passing a singleton-class `idp_realm_id` value (in particular the literal `"bpm-default"`, governed by `tenants_idp_realm_id_partial_index`) is solely responsible for its own coordination — e.g. calling `Letflow.Support.BpmDefaultRealmDisplacement.displace!()` before the `provisioned_tenant!/1` call, in an `async: false` module — exactly as today's hand-rolled `insert_bpm_default_tenant!/0` helpers already do. This mirrors INV-F-2/§3.1's "thin passthrough, not a validation layer" shape for every other opt. |

All ten `INV-F-1`..`INV-F-10` invariants from the base iss0109 design are unaffected and
remain binding: in particular **INV-F-2** (no edit to `lib/letflow/tenant_provisioning.ex` or
`lib/letflow/identity/tenant.ex` — confirmed in §3, this is a caller-side-only change) and
**INV-F-1** (still test-only, still not supervised, still never referenced from `lib/`).

---

## 6. SECURITY-REVIEWER determination

**Determination: not needed. Reasoned explicitly below, not reflexively.**

Arguments for requiring it, considered and rejected:

- *"`idp_realm_id` is an identity/auth-realm value, and this touches auth-pipeline tests."*
  True that the *value* is identity-shaped, but this change does not touch how that value is
  **produced, verified, or trusted** anywhere in `lib/`. `AuthPipeline`'s realm-resolution
  and `verify_realm_ownership/2` logic (`lib/letflow/plugs/auth_pipeline.ex`,
  `lib/letflow/identity.ex`) are unmodified; this design touches only which literal string a
  **test** puts into a **test-created** row before exercising that unmodified production
  code. The realm value was already fully caller-controlled test data before this change
  (all four consuming files already construct arbitrary `idp_realm_id` values by hand); this
  design only relocates *where* that literal is written (into `opts`, threaded through one
  more `Keyword.get/3`) — it does not change *what* can be written, *who* can write it, or
  *which* production code path consumes it.
- *"This could be the mechanism that lets a test wrongly claim the `\"bpm-default\"` realm."*
  Already possible today, unconditionally, by any test that hand-rolls
  `Tenant.create_changeset(%{idp_realm_id: "bpm-default", ...}, :enabled)` — exactly what
  2 of the 4 files already do. This design adds no new capability; it gives an *existing*
  capability (already exercised by real, merged test code) a shared, opt-based call surface
  instead of four copies. §4's collision-risk analysis is the security-relevant question
  here, and it resolves to "identical existing hazard, explicitly left to the caller"
  (INV-F-11), not to a new hazard this design introduces.

Arguments for *not* requiring it, matching the base design's own precedent exactly:

- Same conclusion as `lib/letflow/design/iss0109-provisioning-completeness-and-fixture-instrumentation.md`
  §2.3: nothing under `lib/` changes (§3 confirms `create_changeset/3` needs zero edits —
  it already casts `:idp_realm_id`); everything lands under `test/support/`, compiled only
  under `elixirc_paths(:test)`, never part of the shipped application, never on a request
  path a real tenant's traffic crosses.
  every new/changed line is either (a) a `Keyword.get/3` read of an opt, or (b) one map key
  added to an `attrs` literal passed to an *already-existing, already-gated* production
  changeset function. No new query, no new route, no new migration, no secrets handling.
- The iss0109 design's own SECURITY-REVIEWER-scoping rationale ("SECURITY-REVIEWER's
  tenant-data-path trigger is therefore not armed by this design") applies here for the
  identical reason: this is not a tenant-data-path change in the sense
  `docs/agents/instructions/security-invariants.md` gates on (an API route, a migration, a
  response shape, or secrets handling) — it is a test-fixture opt.

**Conclusion: SECURITY-REVIEWER is not required for this change.** If ORCH's own routing
disagrees (e.g. because it classifies any `idp_realm_id`-touching diff as identity-adjacent
regardless of layer), that is ORCH's prerogative to invoke as an extra gate — nothing in this
design depends on skipping it, and REVIEWER's normal idiom/scope-creep pass still applies
either way.

---

## 7. Test-designer notes

### 7.1 Tests needed for the fixture extension itself (new, this design's scope)

Add to the existing `test/letflow/support/tenant_fixture_test.exs`
(`use Letflow.DataCase, async: false`, matching its current C1–C6 `describe` convention — a
new `describe "idp_realm_id opt"` block fits directly after C6):

1. **Positive threading test.** Call
   `provisioned_tenant!(oidc_mode: :enabled, idp_realm_id: <a fresh, test-generated realm
   string never reused elsewhere — e.g. `"iss0112b-" <> Ecto.UUID.generate()`, not a
   hard-coded literal, so this test itself introduces no new collision risk>)` and assert the
   returned `tenant.idp_realm_id` equals the value passed. This is the direct proof that §3's
   threading works.
2. **Backward-compatibility / no-regression test.** Call `provisioned_tenant!/1` with no
   `idp_realm_id:` key at all (today's exact call shape) and assert the returned
   `tenant.idp_realm_id` is `nil` — proving §3's "absent key ≡ explicit `nil`" behaviour-
   preservation claim is actually true, not merely argued.
3. **Characterization test for the §2.2 interaction (pins existing `Tenant` behaviour, not
   new fixture behaviour).** Call `provisioned_tenant!(oidc_mode: :enabled)` — `:enabled`
   with no `idp_realm_id:` — and assert it raises `Ecto.InvalidChangesetError`. This is
   deliberately a **characterization** test, not a fail-first regression test for a bug: it
   pins today's `Tenant.create_changeset/3` validation (§2.2) through the new opt surface, so
   a future change to either module that silently drops the requirement is caught here.
   Label it as such in the test's own doc, mirroring the base design's own
   fail-first-vs-characterization discipline (iss0109 design §7.2's note on the same
   distinction).

**Not needed, and explicitly out of scope for this fixture-level test file:**

- **No `"bpm-default"`-literal test here.** Exercising the actual collision/displacement
  mechanism against the fixture would mean either (a) hard-coding `"bpm-default"` into this
  shared test file — reintroducing exactly the cross-file singleton hazard §4 describes, now
  inside the fixture's *own* test suite — or (b) calling
  `BpmDefaultRealmDisplacement.displace!()` from a module that has no other reason to depend
  on it. Per §4/INV-F-11, that coordination is the *caller's* concern, and the caller-level
  proof already exists: `auth_pipeline_test.exs`'s and
  `iss0736_oidc_live_revocation_test.exs`'s own `insert_bpm_default_tenant!/0`-pattern tests,
  today, prove displacement + literal-realm insertion works correctly. Nothing here needs to
  re-prove that.
- **No new oracle-rot-style test.** `idp_realm_id` is a plain nullable string column with no
  enumerable "expected set" the way `expected_tenant_tables/0` has; §3.3's oracle-rot
  discipline doesn't apply to this opt.

### 7.2 The real-world proof — later batch, not this design

Per the task's framing: the actual migration of `auth_pipeline_test.exs`,
`auth_pipeline_configurable_verifier_test.exs`, `iss0736_oidc_live_revocation_test.exs`, and
`authorization_ac9_test.exs` onto `provisioned_tenant!/1` (replacing their private
`insert_tenant!/1`/`insert_tenant_for_realm!/1`/`insert_bpm_default_tenant!/0` helpers) is a
**separate, later ISS-0112 batch**, out of scope for this design (mirrors the base iss0109
design's own §5 adoption-boundary discipline: this run only extends the shared fixture's
`opts`, it does not adopt it into new call sites). When that batch runs, TEST-RUNNER quoting
full, unmodified-behaviour passes for all four files **is** the real-world proof the opt
threads correctly end to end — §7.1's fixture-level tests exist so that migration can be
attempted with the opt already independently verified, not so it can skip verification.

---

## 8. Acceptance-criteria traceability

| Task item | Where satisfied |
|---|---|
| 1. Exact `opts` key to add | §2.1 |
| 2. Threading to `Tenant.create_changeset/2` (actually `/3`) call site | §3 |
| 3. Collision-risk determination across concurrent test runs, precise not assumed | §4, INV-F-11 (§5) |
| 4. SECURITY-REVIEWER determination, explicit and careful | §6 — not required, reasoned both ways |
| 5. Test-designer notes: fixture-level vs. later-batch real-world proof | §7.1, §7.2 |
| Design-doc-tracks-implementation discipline (base module's own moduledoc) | This file itself, filed alongside `iss0109-*.md` as the extension's own record |
| No implementation code | This file contains `@type`/prose only — no `.ex` function bodies |
