# REQ-373 — service_catalog version/status lifecycle + real PinResolver.Lookup

Test-design spec for REQ-373. Design authority:
`lib/letflow/design/req373-service-catalog-version-lifecycle.md`. Implementation
authority: `lib/letflow/service_catalog.ex`, `lib/letflow/service_catalog/entry.ex`,
`lib/letflow/service_catalog/version.ex`, `lib/letflow/service_catalog/pin_lookup.ex`,
`lib/letflow/engine.ex` (`pin_lookup/2`), `lib/letflow/routers/admin_services.ex`,
`priv/repo/migrations/20260921000003_add_service_catalog_versioning.exs`.

## Requirement text (restated from the handoff, not re-derived)

REQ-373 adds a version identity + ACTIVE/RETIRED lifecycle status to
`service_catalog`, wires `Letflow.Engine.create/2`'s pin resolution to a real,
catalog-backed `PinResolver.Lookup` in place of the permanent
`PinResolver.default_lookup/0` stub, and exposes `publish`/`retire` as two new
admin-gated HTTP actions. See the design doc for full rationale; this spec covers
only the acceptance-criteria -> test-case mapping.

## File layout

| File | Covers |
|---|---|
| `test/letflow/service_catalog_test.exs` (extended, pre-existing file) | AC1 (schema/migration), `publish/3`/`retire/1` core behavior |
| `test/letflow/engine_pin_resolver_catalog_test.exs` (new) | AC2, AC3, AC4 (two-sided), AC5 |
| `test/letflow/routers/admin_services_publish_retire_test.exs` (new) | AC6 |
| AC7 | Moduledoc-citation check, not a test-code check per the task's own instruction — verified by reading, not asserted in ExUnit (see "AC7" section below) |
| AC8 | `mix letflow.check` output, quoted in the TEST-DESIGNER handoff, not an ExUnit test |

**Deviation from the handoff's `owned_modules` naming, noted explicitly:** the
handoff lists `test/letflow_web/admin_services*` as the expected router-test
location. No `test/letflow_web/` directory exists anywhere in this codebase — every
router test (including the pre-existing `test/letflow/routers/admin_services_test.exs`
this file's own module doc cites as its established idiom) lives under
`test/letflow/routers/`. This spec follows the codebase's actual, established
convention (`test/letflow/routers/admin_services_publish_retire_test.exs`) rather
than a path that would be the only file of its kind in the suite.

## AC1 — version identity + ACTIVE/RETIRED status, schema stated with reasoning

**Criterion:** `service_catalog` entries carry a version identity and an
ACTIVE/RETIRED status, with the chosen schema (composite key vs. status+sibling
table) stated explicitly in the moduledoc along with the reasoning, proven by a
migration and a schema test.

**Test cases** (`service_catalog_test.exs`, new `describe "AC1: ..."` blocks):

1. `register/1` stamps a fresh row with `version: "1"`, `status: :ACTIVE`, a
   non-nil `version_id`, a non-nil `published_at`, and `retired_at: nil` — proves
   the version identity + status columns exist and are populated by the one
   existing write path this design must not disturb (design §1 point 3/4).
2. A raw SQL `INSERT` with `status = 'BOGUS'` is rejected by the database
   (`Postgrex.Error{postgres: %{code: :check_violation}}`), naming
   `chk_service_catalog_status` — proves the migration's `CHECK` constraint is
   real and DB-level, not merely a changeset-side illusion (mirrors this file's
   own AC1/AC2 idiom from REQ-191).
3. A raw SQL `INSERT` with a 256-character `version` string is rejected the same
   way, naming `chk_service_catalog_version_length`.

**Why each exists:** (1) is the one thing every other test in this file
transitively depends on — if `register/1` didn't stamp these four fields, every
later publish/retire/pin test would be building on a false premise. (2)/(3) exist
because `Entry.publish_changeset/2`'s own `validate_required`/`validate_length`
checks are explicitly "advisory only" (this file's moduledoc, repeated verbatim
from REQ-191's own convention) — the acceptance criterion's actual authority is the
database constraint, so only a raw-SQL bypass of the changeset can prove the DB
itself enforces it, not merely that friendly Elixir-side validation happens to
agree.

## `publish/3` / `retire/1` core behavior (not individually numbered, but load-bearing
## infrastructure every AC2-5 test builds on)

**Test cases** (`service_catalog_test.exs`):

1. `publish/3` against a nonexistent `service_id` -> `{:error, :not_found}`.
2. `publish/3` with `version` equal to the row's own current version ->
   `{:error, :duplicate_version}`.
3. `publish/3` with `version` equal to an already-archived version (publish v2,
   then attempt to re-publish v1) -> `{:error, :duplicate_version}` — proves the
   duplicate check also consults `service_catalog_versions`, not only the live
   row.
4. A successful `publish/3` archives the *previous* live row's full
   version-specific field snapshot into `service_catalog_versions` (same
   `version_id` as the row had before publish, `retired_at` newly stamped) and
   updates the live row in place: a fresh `version_id`, the new `version`,
   `status: :ACTIVE`, new `published_at`, `retired_at: nil`.
5. `retire/1` against a nonexistent `service_id` -> `{:error, :not_found}`.
6. `retire/1` against an already-`RETIRED` row -> `{:error, :already_retired}`
   (not a silent idempotent `:ok`).
7. A successful `retire/1` sets `status: :RETIRED`, stamps `retired_at`, and
   leaves every version-specific technical field (`endpoint_url` etc.) exactly as
   it was — no `service_catalog_versions` insert.

**Why:** every AC2-5 test needs `publish/3`/`retire/1` to behave correctly as
preconditions; a bug in either function's own error/state-transition contract
would otherwise surface as a confusing failure in a higher-level pin-resolution
test instead of here, at the layer that actually owns the bug.

## AC2 — publish doesn't disturb an already-resolved pin

**Criterion:** publishing a new version of an existing `service_id` does not
alter or invalidate any already-resolved `pinned_version` entry recorded in a
prior `INSTANCE_STARTED` event, proven by a test that resolves a pin, publishes a
new version, and re-derives the same instance's effective pin set unchanged.

**Test case** (`engine_pin_resolver_catalog_test.exs`): register a service
(version `"1"`, ACTIVE), start a real instance via `Engine.create/2` (no
`pin_lookup` override — real wiring) referencing that `service_id` from a
`SERVICE_TASK` node placed *after* a `HUMAN_TASK` stop (so the instance parks
without ever attempting to dispatch the service task — REQ-215's dispatch layer
is out of this requirement's scope, and `resolve/4` walks every `SERVICE_TASK`
node in the whole graph regardless of reachability, so the pin is resolved and
recorded either way). Assert the `INSTANCE_STARTED` event's `pinned_versions`
carries `version: "1"`, `resolved_id: <original version_id>`. Then call
`ServiceCatalog.publish/3` for the same `service_id` with `version: "2"`. Then
call `PinResolver.reconstruct_effective_pins/2` for the same instance and assert
the `catalog_entry` pin is still `version: "1"` / the *original* `resolved_id` —
proving publish left the already-recorded pin completely untouched.

**Why this exists:** this is the direct behavioral proof of the design's central
"pins are frozen, never re-read live" invariant (design §3.1's "Explicit
invariant" paragraph) — the one place a bug (e.g. an accidental live catalog
re-read on replay) would be most dangerous, since it would silently and
invisibly change already-running instances' behavior underneath them.

## AC3 — a new case after a publish resolves the newly published version

**Criterion:** a new case created after a publish resolves the newly published
version via `Letflow.Engine.PinResolver.resolve/4`'s real (non-default) Lookup,
proven by a test.

**Test case** (`engine_pin_resolver_catalog_test.exs`): register a service
(version `"1"`), publish `"2"`, then call `PinResolver.resolve/4` directly
against a hand-built `Graph`/`ProcessDefinition` referencing the `service_id`,
using `Letflow.ServiceCatalog.PinLookup.build/0` as the `Lookup` (the real
implementation, not a hand-rolled `const_lookup` stub as `pin_resolver_test.exs`
uses elsewhere). Assert the resulting pin's `version == "2"`, `resolved_id` equal
to the *post-publish* `version_id`, `source == :resolved`.

**Why this exists:** proves the real `Lookup` implementation genuinely reads
live/current catalog state at resolve time (unlike a pin already recorded, which
never does) — the necessary complement to AC2's "already-resolved pins don't
move," confirming instead that *unresolved* references correctly *do* pick up the
latest publish.

## AC4 — retire: two-sided (the most important test in this run)

**Criterion:** retiring a version prevents any NEW resolution from choosing it (a
fresh `resolve/4` call against the retired ref fails, per this requirement's own
design decision — no fall-through, stated explicitly) while an instance already
pinned to the retired version continues to resolve via `pin_for/3` with no error,
proven by a test covering both sides.

**Test case** (`engine_pin_resolver_catalog_test.exs`, single test function,
deliberately not split across two tests): register a service, resolve a pin for
it via `PinResolver.resolve/4` + `PinLookup.build/0` *before* retiring (capturing
the exact `pinned_version` map an `INSTANCE_STARTED` event would have recorded),
then call `ServiceCatalog.retire/1`. Then, in the same test:

* **Side A (fresh resolution fails):** a second `PinResolver.resolve/4` call
  against the identical `Graph`/`Lookup` now returns
  `{:error, {:unresolved_catalog_ref, ref}}` — the existing error variant, no new
  one.
* **Side B (already-pinned read is unaffected):** `PinResolver.pin_for/3` called
  with `[pin]` (the pin captured *before* retirement in this same test) and the
  same `{:catalog_entry, ref}` key still returns `{:ok, pin}` — byte-identical to
  what it returned before retirement, unaffected by the retire that happened in
  between.

**Why this exists (and why it must be one test, not two):** a two-sided contract
is only genuinely proven when both halves are demonstrated against the *same*
`service_id`, in a single causal chain (resolve -> retire -> re-resolve fails +
pin_for still works) — two separate tests could each pass independently while a
regression that coupled the two code paths (e.g. `pin_for/3` accidentally gaining
a live lookup call) would only be caught by having both assertions share one
`retire/1` call and one `service_id` in one test body. This is also the design's
own single most load-bearing claim (design §3.2's "Why pin_for/3 reads... are
entirely unaffected by retire" paragraph, called out as "the same 'by
construction, not by care taken' argument" as AC2) — a false claim here would mean
a running instance's pinned service call breaks the moment an admin retires a
newer/different version of the same service, silently disrupting production
traffic.

## AC5 — `Engine.create/2` wired to the real Lookup (integration)

**Criterion:** `Engine.create/2`'s `pin_lookup/2` helper is wired to the real
catalog-backed `Lookup` for `catalog_entry` references in place of
`PinResolver.default_lookup/0`, proven by an integration test that starts a real
instance referencing a `SERVICE_TASK`'s `service_id` and confirms a `:resolved`
(not `:unresolved_catalog_ref`-failing) pin is recorded.

**Test case** (`engine_pin_resolver_catalog_test.exs`): register a real
`service_catalog` entry, build a real, activated `ProcessDefinition` (via
`Definitions.create/2` + `Definitions.activate/2`, matching `engine_test.exs`'s
own established fixture discipline) whose graph references that `service_id` from
a `SERVICE_TASK` node reached only *after* a `HUMAN_TASK` stop. Call
`Engine.create/2` with **no `attrs[:pin_lookup]` override at all** — this is the
load-bearing detail: it exercises exactly the fallback `Map.get(attrs,
:pin_lookup, PinLookup.build())` call site the design changed (§6), not a test
double standing in for it. Assert `{:ok, result}` (proving the definition's
`SERVICE_TASK` reference did NOT hit `{:unresolved_catalog_ref, ref}}`, which is
what `PinResolver.default_lookup/0` would still produce today for any registered
`service_id`, since that stub never reads any catalog at all), then read the
persisted `INSTANCE_STARTED` event's `pinned_versions` and assert the
`catalog_entry` pin has `source: "resolved"` and `resolved_id` equal to the real
entry's `version_id`.

**Why this exists:** every other test in this file calls `PinLookup.build/0`
directly — none of them, by itself, proves `Engine.create/2` actually *uses* that
function at its own real call site rather than still calling
`PinResolver.default_lookup/0` (a call-site wiring bug that no unit test of
`PinLookup` in isolation could ever catch). This is the one test in the file that
would fail if `lib/letflow/engine.ex`'s `pin_lookup/2` private function were
reverted to its pre-REQ-373 body while every other file in this design's scope
was left untouched.

## AC6 — publish/retire gated by the existing `:AdminServicesManage` permission

**Criterion:** publish/retire operations are gated behind the already-shipped
`:AdminServicesManage` permission (`Letflow.Api.Authorization`), not a newly
invented permission name, proven by a test.

**Test cases** (`admin_services_publish_retire_test.exs`), for **both**
`POST /:service_id/versions` and `POST /:service_id/retire`:

1. A caller with no `:AdminServicesManage`-granting role (e.g.
   `PROCESS_DESIGNER`) gets `403`, and the response body carries no service data
   — mirrors `admin_services_test.exs`'s own established 403 assertion shape for
   `GET /`.
2. A caller with `PLATFORM_ADMIN` (the only role holding
   `:UsersGroupsRolesManage`, which `:AdminServicesManage` maps to) succeeds: `201`
   for publish, `200` for retire, with the expected `service_record_json/1` shape
   in the body.

**Why this exists:** directly proves the acceptance criterion's two-sided claim
("a caller without that permission is rejected and a caller with it succeeds") —
a permission-gate test that only checked the 403 half could pass even if the
route were miswired to reject *everyone*, including a legitimate admin.

## AC7 — PLC-01/module_ref stays out of scope (not a test-code check)

Per the task's own explicit instruction: "AC7 is a moduledoc-citation check, not a
test-code check — do not invent a test for it." Verified by reading (not
asserting in ExUnit): `Letflow.ServiceCatalog.PinLookup`'s moduledoc states
verbatim that `module_lookup` "stays a permanent `{:error, :not_found}` stub"
and cites `pin_resolver.ex`'s own "SCOPE GAP — service_catalog (S6) and PLC-01
(unscoped) are not built" section by name (confirmed by reading
`lib/letflow/service_catalog/pin_lookup.ex` lines 8-14 in full, during this
handoff). No test in this file's scope references `module_ref`/PLC-01 for this
reason — `pin_resolver_test.exs`'s own pre-existing module-ref coverage (against
`default_lookup/0` and hand-built const lookups) is untouched and sufficient; this
requirement adds nothing there.

## AC8 — `mix letflow.check` passes

Not an ExUnit test — quoted as real command output in the TEST-DESIGNER handoff's
`result` block, and re-verified independently by TEST-RUNNER per WF-02 Step 4.

## Real implementation defect found while writing these tests (not a test-design flaw)

Running this file's own tests (plus `engine_pin_resolver_catalog_test.exs` and
`admin_services_publish_retire_test.exs`) against the shipped implementation
surfaces **one single root-cause bug**, independently reachable through 6 different
tests across 3 files/layers:

`Letflow.ServiceCatalog.Version.archive_changeset/1`
(`lib/letflow/service_catalog/version.ex`) calls
`validate_required(@castable_fields)` against the **full** castable-field list,
which includes `request_schema`, `response_schema`, and `retry_policy` — all three
are legitimately nullable, both on `Letflow.ServiceCatalog.Entry` (never required
by `insert_changeset/2`) and on `service_catalog_versions`' own migration columns
(`add :request_schema, :text` etc., no `null: false`). Any `publish/3` call against
a service registered without setting these three optional fields (the common case —
`register_attrs()` never sets them) fails at the archive-insert step with
`{:error, %Ecto.Changeset{}}` — `"can't be blank"` on all three — even though
nothing about the acceptance criteria or the design doc requires them to be set.

**Tests that fail against the current implementation for this one reason** (correct,
expected behavior — these tests are designed to fail against buggy code and pass
once `archive_changeset/1` is fixed to `validate_required/2` only the genuinely
`NOT NULL` columns):

* `service_catalog_test.exs`: "a version equal to an already-archived version
  returns `{:error, :duplicate_version}`", "a successful publish archives the
  previous row's snapshot...", "publishing following a bare retire archives...".
* `engine_pin_resolver_catalog_test.exs`: AC2's and AC3's own tests (both call
  `publish/3` as a precondition).
* `admin_services_publish_retire_test.exs`: "succeeds (201), bumps the live row...".

Left in place, not weakened or removed — a test asserting `{:error, %Ecto.Changeset{}}`
instead would hide a real, user-facing defect (any admin publishing a new version of
a plainly-configured service, with no `request_schema`/`response_schema`/
`retry_policy` set, gets an unexpected `422` today). Flagged here for whichever
downstream step (TEST-RUNNER's Step 4 report / an ISSUE-FIXER rework cycle) owns
routing this back to ELIXIR-DEV.

## Separate, smaller finding: `chk_service_catalog_version_length` is provably unreachable

See the inline comment on `service_catalog_test.exs`'s own AC1 version-length test:
the `version` column's Ecto migration type (`:string`) renders as `varchar(255)` by
default, so Postgres itself rejects any value over 255 characters at the column-type
level (`:string_data_right_truncation`) before the identically-bounded
`chk_service_catalog_version_length` CHECK constraint could ever fire. Not a
functional bug (an over-length version is still rejected, per AC1), but the CHECK
constraint itself is dead code as written. The test asserts the real observed
behavior rather than the design doc's stated one.
