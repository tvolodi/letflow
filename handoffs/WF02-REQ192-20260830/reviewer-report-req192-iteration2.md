# REQ-192 REVIEWER report — Step 2d, rework iteration 2

**Run:** WF02-REQ192-20260830 · **Step:** 2d · **Verdict: PASS**

Scope: idiom/scope/decision-record gate on `lib/letflow/routers/admin_services.ex`
(full rewrite) and `lib/letflow/service_catalog.ex`'s new `list_all/1` plus the
`split_list_page`/`build_list_next_cursor` arity refactor. Compile,
format, and the two named test files are independently confirmed clean by
ORCH; SECURITY-REVIEWER already PASSed INV-1..INV-8/INV-RT-1 (see
`handoffs/WF02-REQ192-20260830/req192-security-review-iteration2.md`). This
report covers only what falls under REVIEWER's own remit.

## Flagged decision 1 — scope expansion (`list_all/1` added to REQ-191's context module)

**AGREE — defensible, minimal, additive.** Read the design doc's §5
(`lib/letflow/design/req192-service-catalog-routes.md`) and the real
`list_all/1` implementation (`lib/letflow/service_catalog.ex:339-405`)
directly, not just the handoff's characterization.

Reasoning:

- The conflict is real and was discovered, not invented after the fact: the
  original iteration-1 design specified a router-local `Ecto.Query` against
  `Entry`, and that literally cannot coexist with `INV-RT-1`
  (`test/letflow/routers/req078_supporting_routes_test.exs`'s T-19, a static
  `Path.wildcard`-based scan with `assert offenders == []` and no allowlist
  mechanism). There is no third option that satisfies both "no
  context-module change" and "no `Repo.` call under `lib/letflow/routers/`"
  simultaneously for a genuinely tenant-agnostic list. One of the two has to
  give.
- Between the two, `INV-RT-1` is the one that should hold: it's a
  repo-wide, REVIEWER-approved, test-enforced invariant established by a
  *different* requirement (REQ-078) for the entire router layer, not a
  scope note local to REQ-192. REQ-192's own "no context-module change"
  line was a sizing choice to keep this diff small, not a structural
  constraint on `Letflow.ServiceCatalog` — the module's own moduledoc
  ("Function arity" section) already anticipates future growth.
- The change itself is genuinely minimal and additive, verified directly:
  - `list_for_tenant/2`'s public name, arity (`/2`), and `where` clause
    (`e.scope == :global or e.owner_tenant_id == ^tenant_id`, line 274) are
    byte-for-byte unchanged — confirmed by reading the function body.
  - `list_all/1` is a new, separate public function. No existing function's
    signature, behavior, or return-type contract changed.
  - No migration, no `Entry` schema field, no changeset change.
  - The new function's own `@doc` is explicit and honest about what it is:
    "no tenant or scope filtering whatsoever... the caller is entirely
    responsible for ensuring only an authorized admin path ever calls this
    function" — this is not a function that could be mistaken for a safe
    default by a future, less-careful caller.
- This is not a bigger divergence needing REQ-191 reopened. Reopening
  REQ-191 would imply revisiting its acceptance criteria, migration, or
  already-signed-off global-table decision (decision 0003 divergence,
  `service_catalog.ex` moduledoc lines 24-60) — none of which this change
  touches. A one-function, read-only, well-documented addition to an
  already-shipped context module, made necessary by a hard invariant
  conflict discovered during implementation of the *next* requirement, is
  exactly the kind of "flag it explicitly, get REVIEWER sign-off, proceed"
  pattern the pipeline is built for — not grounds to reopen the prior
  requirement.

Verdict on decision 1: **AGREE**, no further action required (e.g. no
`docs/migration/decisions/` entry needed — this doesn't establish a new
architectural pattern, it applies an existing one, "context modules own
their own queries," to one more case).

## Flagged decision 2 — `split_list_page`/`build_list_next_cursor` arity change

**AGREE — safe, idiomatic, private-helper-only refactor.**

- `list_for_tenant/2`'s own call site (`service_catalog.ex:280`) passes
  `@list_cursor_prefix` ("SC:") explicitly; behavior is identical to the
  prior hardcoded-inside-the-helper version.
- `grep -rn "split_list_page\|build_list_next_cursor"` across `lib/` and
  `test/` confirms all four other hits are in `lib/letflow/dlq.ex`,
  `lib/letflow/tasks.ex`, and `lib/letflow/instances.ex` — each module
  defines its own same-named private functions with different bodies and
  arities (`/2`/`/1` respectively). These are private functions scoped to
  each defining module; Elixir has no cross-module private-function
  visibility, so there is no possibility of an accidental collision or a
  hidden caller elsewhere in the codebase. No other caller of
  `Letflow.ServiceCatalog`'s two helpers exists or could exist outside this
  one file.
- The refactor itself is idiomatic: threading an explicit `prefix` argument
  through a genuinely shared helper (both `filter_by_list_cursor/2` and
  `split_list_page/3` have bodies with zero `tenant_id` dependency) is the
  correct alternative to either (a) duplicating the pagination logic
  verbatim into `list_all/1`, or (b) a shared helper that silently
  hardcodes one endpoint's prefix and mis-tags the other's cursors. The
  code comment at `service_catalog.ex:314-319` explains this rationale
  in-line, which is good practice.

One documentation nit, not a defect: the design doc's §5 (line 214) still
says "Reuses `filter_by_list_cursor/2` and `split_list_page/2` verbatim,"
but the shipped code correctly uses `split_list_page/3` (three args,
prefix threaded through) — the design text wasn't updated to match the
final arity chosen during implementation. Cosmetic only; the design's
*intent* (share the helper, don't duplicate) was honored, and the doc's
own body text elsewhere (line 215) accurately describes the two-prefix
behavior. Not blocking; noting for the record in case a future reader
diffs the design against the code and is confused by the `/2` vs `/3`
mismatch.

Verdict on decision 2: **AGREE**, refactor is idiomatic and non-leaky.

## Standard REVIEWER checks

1. **Idiomatic vs. crutch — N/A / clean.** No `gen_statem`/`GenServer`
   involved; `Letflow.ServiceCatalog` is a plain Ecto context module (no
   process), same shape as `Letflow.Dlq`/`Letflow.Identity`. No hand-rolled
   state machine anywhere in this diff.

2. **Supervision — no impact.** Nothing in this diff touches process
   structure, `Letflow.InstanceSupervisor`, or any spawn. This is a pure
   HTTP-router-plus-context-function diff.

3. **Type-safety gaps.** None new. `list_all/1` reuses the exact same
   cursor/pagination types `list_for_tenant/2` already uses; no new class
   of invalid state is introduced beyond what REQ-191's own review already
   covered (e.g. `scope`/`required_auth` typed as `atom() | String.t()`
   rather than a narrower type — already filed as a type-safety finding
   under WF02-REQ191-20260830, not duplicated here since nothing about
   this diff changes that surface). Nothing new to file under
   `docs/issues/`.

4. **Scope creep beyond the two flagged items.** None found.
   `Letflow.Routers.AdminServices`'s `service_record_json/1` duplicates
   `Letflow.Routers.Services`'s own private allowlist function rather than
   sharing it — this matches the explicit, already-established
   one-router-per-mount-prefix precedent (`dlq.ex`/`webhooks.ex`, cited in
   the router's own comment), not an abstraction reached for ahead of need.
   No new behaviour module, macro, or generic plumbing appears anywhere in
   this diff. The two new `Letflow.Api.Error` constructors
   (`service_referenced_by_active_definitions/1`,
   `service_scope_narrowing_conflict/1`) are narrowly-scoped, named
   additions modeled directly on the existing `promotion_conflict/2`
   pattern — not new machinery.

5. **`docs/anti-patterns.md`.** Checked; no entry applicable to this diff.

6. **Decision-record consistency.** No new decision-record collision. The
   global-vs-tenant-schema question was already settled and REVIEWER-signed
   for `service_catalog` under REQ-191 (`service_catalog.ex` moduledoc,
   "REVIEWER sign-off: AGREE, 2026-08-30"); this diff adds a read path to
   the same already-approved global table, it doesn't reopen or diverge
   from that decision. No `docs/migration/decisions/*.md` needs creation or
   amendment for this diff.

## `admin_services.ex` code-quality notes

- Router is a clean context-module-delegating router, zero direct
  `Ecto.Query`/`Repo` references — `grep -n "Repo\.\|Ecto.Query" lib/letflow/routers/admin_services.ex` confirms zero hits, satisfying INV-RT-1 by construction as the moduledoc claims.
- Error-branch coverage in `handle_register`/`handle_update_scope`/
  `handle_delete` pattern-matches every documented `{:error, ...}` variant
  from the corresponding `ServiceCatalog` function — no silent catch-all.
- The stale `required_permission/1` comment ("platform-admin enforced in
  handler, per Zig's comment") is correctly *not* silently fixed here —
  flagged in both the design doc and the router's own moduledoc for a
  future, `authorization.ex`-scoped requirement. Agreed this is out of
  scope for REQ-192; no action needed from REVIEWER beyond concurring the
  finding is real and correctly deferred.

## Verdict

**PASS.** Both flagged decisions: **AGREE**. Route to TEST-DESIGNER per
WF-02 Step 3.
