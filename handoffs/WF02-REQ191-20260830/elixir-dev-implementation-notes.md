# REQ-191 implementation notes (ELIXIR-DEV, Step 2a)

## Toolchain

This sandbox has no `mix`/`elixir`/`erl` executable on `PATH` (confirmed:
`command -v mix elixir erl` all fail; `/home/tvolodi/.mix/elixir` exists but
no runnable binary; no usable Docker socket either). **`mix compile
--warnings-as-errors`, `mix format`, and `mix test` could NOT be run in this
environment.** All code below was written and manually cross-checked against
real precedent files (line-by-line), but is NOT independently
toolchain-verified by this agent. ORCH/TEST-RUNNER must run the real
toolchain before this can be trusted as compiling.

Manual checks performed instead: `do`/`end` balance count per changed file,
every `fragment(@attr, ...)` reference confirmed against
`lib/letflow/definitions.ex`'s own `fragment(@rank_case_sql, ...)` precedent
(with the exact same "module attribute inlined as literal before Ecto's
SQL-injection guard runs" mechanism), `create constraint(table, name,
check: ...)` DSL confirmed against
`20260817181240_create_event_retention_policies.exs`'s identical usage, and
default Postgres constraint-naming conventions (`<table>_pkey`,
`<table>_<column>_fkey`) confirmed against
`lib/letflow/design/req033-snapshot-store.md`'s documented equivalent.

## Files changed

- `priv/repo/migrations/20260830000001_create_service_catalog.exs` (new) —
  global migration, no `if prefix()` guard, not registered in
  `tenant_scoped_migrations/0`.
- `lib/letflow/service_catalog/entry.ex` (new) — `Ecto.Schema`, string PK.
- `lib/letflow/service_catalog.ex` (new) — context module: `register/1`,
  `get_for_tenant/2`, `list_for_tenant/2`, `update_scope/2`, `delete/1`,
  the cross-schema referential guard, `scope_validator_lookup/1`.
- `lib/letflow/tenant_provisioning.ex` (modified) — added
  `list_registrations/0` (read-only, `Repo.all(Registration)`), per design
  §4 step 1 / OQ-3, flagged there for REVIEWER to confirm acceptable scope.
- `lib/letflow/definitions/solution_pack.ex` (modified) — moduledoc +
  one code comment updated per design §6: hard-fail retained unchanged,
  REQ-192 named as the owning follow-up. No behavior change; the same
  `check_unsupported_sections/1` clauses are untouched.

No route or controller file added or modified — confirmed via
`git diff --stat` (shown to ORCH/reviewers): only the four files above.

## Arity deviation from the design's provisional "register/2"/"delete/2" naming

Implemented as `register/1` and `delete/1`, not `register/2`/`delete/2`.
The design's own §7 OQ-1 explicitly left this open and permitted a
documented deviation. Reasoning is stated in full in
`Letflow.ServiceCatalog`'s own moduledoc ("Function arity" section): this
module has no `opts[:prefix]` to carry (global table), and the design's own
second-argument candidate for `register` (an injectable tenant-existence-check
function) was resolved instead via a direct `Letflow.Identity.Tenant` query,
per the design's own permitted alternative — leaving no real second argument
to preserve. `get_for_tenant/2`, `list_for_tenant/2`, `update_scope/2` all
kept their full 2-arity since both arguments in each are genuine business
inputs. Flagging this explicitly for REVIEWER, since it's a deviation from
the requirement text's own literal function names even though the design
doc itself anticipated and permitted it.

## Observation for REVIEWER/SECURITY-REVIEWER: `retry_policy` vs `max_retries`

`web/src/api/services.ts`'s already-shipped `ServiceRecord` interface (cited
in REQ-191's own requirements.yaml entry as the "BINDING CONTRACT") has a
`max_retries: number` field. The approved design
(`lib/letflow/design/req191-service-catalog-core.md` §1) specifies a
`retry_policy` TEXT column instead (ported from R-Co's own
`049_repository_service_catalog.sql`/`GBL-117`), which is what this
implementation built exactly as specified. This requirement has no route
layer (REQ-192 does), so this mismatch does not block REQ-191's own
acceptance criteria — but REQ-192 will need to either translate
`retry_policy`'s JSON-text shape into a `max_retries` number at the wire
boundary, or the design/requirement text and the frontend's already-shipped
type will need explicit reconciliation before REQ-192 ships its route layer.
Not fixed here — the design was already validated and this implementation
built exactly what it specifies, per this agent's own instructions not to
silently re-decide what a validated design already settled.

## Tests

None written by this agent — TEST-DESIGNER's step, per the standard WF-02
pipeline (this agent's role is implementation only; SECURITY-REVIEWER and
REVIEWER gate before TEST-DESIGNER starts).
