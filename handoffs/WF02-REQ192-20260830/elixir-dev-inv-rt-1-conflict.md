# REQ-192 ELIXIR-DEV note — INV-RT-1 conflict discovered during implementation

Not a "step" handoff file (H6 naming rule) — free-text notes accompanying
`step-02c-security-reviewer.json`.

## What was found

`lib/letflow/design/req192-service-catalog-routes.md` §5 specifies, as a
deliberate, explicitly-flagged-for-REVIEWER-sign-off exception:
`Letflow.Routers.AdminServices`'s `GET /` handler queries
`Letflow.ServiceCatalog.Entry` directly via `Letflow.Repo`/`Ecto.Query`,
bypassing `Letflow.ServiceCatalog` entirely, because that context module has
no tenant-agnostic "list all" function and adding one is out of REQ-192's
scope.

Implementing that exactly as designed (`lib/letflow/routers/admin_services.ex`)
causes an **existing, currently-passing test to fail**:
`test/letflow/routers/req078_supporting_routes_test.exs:720`,
`"T-19: no Repo. call anywhere under lib/letflow/routers/ (INV-RT-1)"` — a
static grep-based assertion (no allowlist mechanism exists in that test) that
zero files under `lib/letflow/routers/` contain a `Repo.` call anywhere.

This is not a coincidental convention: `INV-RT-1` is a **named, documented
invariant from REQ-078's own design**
(`lib/letflow/design/req078-supporting-routes.md` §3.3/§20.3: "No `Repo.`
call appears in any file under `lib/letflow/routers/`. Verified by
`grep -n "Repo\." lib/letflow/routers/*.ex` → zero hits."), which REVIEWER
already signed off on for REQ-078 and which `test/specs/REQ-078.md` still
lists as something "re-verified here rather than only trusted from
REVIEWER's pass." REQ-192's design (§5) independently grepped for the same
thing ("a repo-wide `grep -rln 'Ecto.Query|Repo\.(all|one|get)'
lib/letflow/routers/` turns up no genuine direct-schema-query call anywhere
in the router layer today") and concluded there was "no existing precedent"
to break — true in the sense of no prior *code*, but it did not surface
that this is a formally named, REVIEWER-approved, test-enforced invariant
from another requirement's design, not merely an informal absence of
precedent.

## What ELIXIR-DEV did NOT do

Did not modify `test/letflow/routers/req078_supporting_routes_test.exs`'s
T-19 test (e.g. adding an allowlist exemption for `admin_services.ex`) to
make it pass. That test is not owned by this requirement, encodes a
different requirement's REVIEWER-approved invariant, and deciding whether
to carve out an exception to `INV-RT-1` is exactly the kind of
architectural call this role is not authorized to make unilaterally
(`elixir-dev.md`'s "Forbidden" section: don't silently re-decide something
a decision record/prior REVIEWER sign-off already settled). Did not deviate
from the approved design's §5 resolution either, since ELIXIR-DEV implements
from an approved design rather than re-designing.

## Current `mix test` state (real, unedited output)

Full suite: `2599/2602 passed ... Failed: 3 tests` (824.4s). Of the 3
failures:

* **2 are pre-existing and unrelated to this change** — both in
  `test/mix/tasks/letflow_check_toolchain_test.exs` ("a matching rust pin
  reports OK..." / "a mismatched rust pin reports a MISMATCH row..."),
  failing with `Erlang error: :enoent` from `System.cmd("rustc",
  ["--version"], ...)` — `rustc` is simply not installed in this sandbox.
  Verified unrelated: neither test touches routers, service catalog, or
  authorization.
* **1 is caused directly by this change**: T-19 above, a direct,
  structural consequence of implementing design §5 exactly as specified,
  not a bug in the implementation of that design.

`mix compile --warnings-as-errors` passes clean. `mix format
--check-formatted` passes clean. The targeted enforcement test
(`test/letflow/api/authorization_enforcement_test.exs`, updated per design
§2's required companion fixture change) passes: 14/14.

## What REVIEWER/SECURITY-REVIEWER need to decide

This is now a real fork in the road, surfaced by implementation rather than
resolved by it:

1. **Accept the design's §5 exception as-is** and update
   `req078_supporting_routes_test.exs`'s T-19 to allowlist
   `lib/letflow/routers/admin_services.ex` specifically (mirroring how
   `authorization_enforcement_test.exs`'s own `@allowlist` already
   documents narrower, reasoned exceptions to a different invariant) —
   REVIEWER's call, and arguably also needs to weigh in on whether
   `req078-supporting-routes.md`'s own INV-RT-1 statement needs a
   corresponding update so it doesn't read as unconditionally true anymore.
2. **Reject the exception** and send REQ-192 back to CODE-DESIGNER for a
   different resolution to §5's gap (e.g. actually deciding the design's own
   OQ-1 now, hoisting a real tenant-agnostic list function into
   `Letflow.ServiceCatalog` despite the "no context-module change" scope
   boundary, since that boundary is exactly what produced this conflict).

Either way, this needs an explicit decision recorded (design-doc update or a
`docs/migration/decisions/` entry) — not a silent resolution by whichever
agent next touches either file.
