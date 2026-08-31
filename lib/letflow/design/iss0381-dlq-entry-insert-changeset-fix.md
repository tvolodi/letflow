# ISS-0381 fix design — `Letflow.Dlq.Entry.insert_changeset/2` cast list vs. docstring

Status: design for WF-03 (`WF03-ISS0381-20260831`) Step 2, CODE-DESIGNER.
Diagnosis this design implements: `handoffs/WF03-ISS0381-20260831/step-01-issue-fixer-diagnosis.json`.
Issue record: `docs/issues/ISS-0381.yaml` (former id `ISS-0353`).

No implementation code below — signatures, field lists, and pipeline ordering only.
`ELIXIR-DEV` implements this at WF-03 Step 3.

## 1. Problem restated

`lib/letflow/dlq/entry.ex`'s `insert_changeset/2` docstring claims `status`,
`retry_count`, `retry_history`, `tenant_id`, and `created_at` are "deliberately
not castable" — the actual `cast/3` field list casts all five. Today this is
harmless only because the sole caller, `Letflow.Dlq.enqueue/2`
(`lib/letflow/dlq.ex:81-113`), pre-sanitizes `attrs` via `Map.take/2` (an
allowlist of 12 keys, none of the five protected fields) before
`Map.merge/2`-ing its own trusted values on top. The changeset itself is not
the safety boundary its docstring describes — caller discipline is. This
design closes that gap so the changeset enforces its own claim, matching the
two in-repo precedents (`Letflow.Definitions.SolutionPackInstall.insert_changeset/2`,
`Letflow.Definitions.PromotionReview.insert_changeset/2`).

## 2. Field disposition (all five protected fields)

| Field | Schema default | Mechanism after fix |
|---|---|---|
| `:status` | `:pending` (`Ecto.Enum`, entry.ex line 61) | Drop from `cast/3` entirely. Struct default applies on `%Entry{}` construction, unaffected by `cast/3` no longer touching it. |
| `:retry_count` | `0` (entry.ex line 55) | Drop from `cast/3` entirely. Same reasoning. |
| `:retry_history` | `[]` (entry.ex line 54) | Drop from `cast/3` entirely. Same reasoning. Not currently in `validate_required/2`'s list either (confirmed by ISSUE-FIXER) — no `validate_required/2` change needed for this field. |
| `:tenant_id` | none | Drop from `cast/3`'s field list. Add an explicit `put_change/3` call for `:tenant_id`, reading its value out of `attrs`, inside `insert_changeset/2`, before `validate_required/2`. |
| `:created_at` | none | Drop from `cast/3`'s field list. Add an explicit `put_change/3` call for `:created_at`, reading its value out of `attrs`, inside `insert_changeset/2`, before `validate_required/2`. |

This matches `candidate_scope_for_whoever_picks_this_up` in ISS-0381.yaml and
the diagnosis's `acceptance_criteria` verbatim — nothing added, nothing
narrowed.

## 3. `cast/3`'s post-fix field list

The CURRENT `cast/3` call (entry.ex lines 107-125) has exactly 17 elements,
counted field by field directly from the source: `tenant_id`, `entry_type`,
`instance_id`, `reference_id`, `reason`, `full_reason`, `error_detail`,
`error_chain`, `source_payload`, `context_json`, `retry_limit`,
`first_failed_at`, `last_failed_at`, `status`, `retry_count`,
`retry_history`, `created_at` — 17 atoms, not 18. (`next_retry_at` is a
schema field but has never appeared in `cast/3`'s list at all, before or
after this fix; it must not be counted here.)

Disposition of each of the 17, one row per atom:

| # | Field | Post-fix disposition |
|---|---|---|
| 1 | `:tenant_id` | REMOVED — moves to `put_change/3`, see §4 |
| 2 | `:entry_type` | stays in `cast/3` |
| 3 | `:instance_id` | stays in `cast/3` |
| 4 | `:reference_id` | stays in `cast/3` |
| 5 | `:reason` | stays in `cast/3` |
| 6 | `:full_reason` | stays in `cast/3` |
| 7 | `:error_detail` | stays in `cast/3` |
| 8 | `:error_chain` | stays in `cast/3` |
| 9 | `:source_payload` | stays in `cast/3` |
| 10 | `:context_json` | stays in `cast/3` |
| 11 | `:retry_limit` | stays in `cast/3` |
| 12 | `:first_failed_at` | stays in `cast/3` |
| 13 | `:last_failed_at` | stays in `cast/3` |
| 14 | `:status` | REMOVED — schema default applies |
| 15 | `:retry_count` | REMOVED — schema default applies |
| 16 | `:retry_history` | REMOVED — schema default applies |
| 17 | `:created_at` | REMOVED — moves to `put_change/3`, see §4 |

5 rows are REMOVED, 12 rows stay. The resulting post-fix `cast/3` field list
therefore has 12 elements, in the same relative order as today: `entry_type`,
`instance_id`, `reference_id`, `reason`, `full_reason`, `error_detail`,
`error_chain`, `source_payload`, `context_json`, `retry_limit`,
`first_failed_at`, `last_failed_at`. This set is identical, atom for atom, to
the 12-key allowlist `enqueue/2` already passes to `Map.take/2`
(`lib/letflow/dlq.ex:87-100`) — an independent cross-check confirming 12 is
correct for the post-fix list.

The table above is prose/data specification, not a code block to copy
verbatim into a function body — ELIXIR-DEV writes the actual `cast/3` call.

## 4. `put_change/3` placement in the pipeline

Exact pipeline order inside `insert_changeset/2`, stage by stage:

1. **The `cast/3` call, using the 12-field list from §3,** runs first. This is
   mandatory — `cast/3` is what turns `entry` (a bare `%Entry{}` struct) into
   an `%Ecto.Changeset{}` struct in the first place; `put_change/3` requires
   a changeset as its first argument, so it cannot run before `cast/3`.
2. **A `put_change/3` call for `:tenant_id`** — reads the `:tenant_id` entry
   out of the same `attrs` map `cast/3` was given, writes it directly onto
   the changeset's `:changes`, bypassing `cast/3`'s allowed-fields filter
   entirely for this key.
3. **A `put_change/3` call for `:created_at`** — same mechanism, reading the
   `:created_at` entry out of `attrs`.
4. **The existing `validate_required/2` call**, listing the same five field
   names it lists today (`:tenant_id`, `:entry_type`, `:status`,
   `:retry_count`, `:created_at`), unchanged. It must run AFTER both
   `put_change/3` calls, not before — `validate_required/2` inspects the
   changeset's current `:changes`/`:data` state at the point it runs, so if
   it ran before `put_change/3` it would see `:tenant_id`/`:created_at` as
   absent from `:changes` and could reject a legitimate `enqueue/2` call that
   supplies them correctly.

Steps 2 and 3 are independent of each other and may occur in either order
relative to one another; both must occur after step 1 and before step 4.

## 5. Why this doesn't create a silent-nil hole

The task's own concern: since `attrs` is caller-controlled at the
`insert_changeset/2` boundary (not only at `enqueue/2`'s), does the
`put_change/3` call for `:tenant_id` (reading its value out of `attrs`)
silently write `nil` when `attrs` lacks the `:tenant_id` key, and does
`validate_required/2` still catch that?

Answer: yes, `validate_required/2` still catches it, and this is not a new
hole — `cast/3` has the identical behavior today for any field whose value is
`nil` or missing. `Ecto.Changeset.validate_required/2`'s documented contract
treats a field as missing if the changeset's effective value for that field
(from `:changes` if present there, else falling back to `:data`) is `nil` or
not present at all. When `attrs` lacks the `:tenant_id` key, the
`put_change/3` call reads a `nil` and writes `nil` directly into
`changeset.changes` for `:tenant_id`; `validate_required/2` sees that `nil`
and adds the
`"can't be blank"` error for `:tenant_id`, exactly as it would if `cast/3` had
cast a `nil`/missing `:tenant_id` today. So: a call to `insert_changeset/2`
with an `attrs` map lacking `:tenant_id` or `:created_at` still produces an
invalid changeset (`changeset.valid? == false`), not a silently-inserted row
with a `nil` `tenant_id`. This is the same guarantee `validate_required/2`
already gives today for `:tenant_id`/`:created_at` when `cast/3` alone
handled them — the mechanism moves from `cast/3` to `put_change/3` but the
required-field guarantee is preserved because `validate_required/2` doesn't
care which of the two mechanisms populated `:changes`.

What DOES change, and is the entire point of this fix: a caller-supplied
`:tenant_id` value that differs from an intended trusted value is now
IGNORED rather than accepted, because `put_change/3` runs after `cast/3` and
overwrites whatever `cast/3` would have set — but since `cast/3` no longer
even has `:tenant_id` in its field list, `cast/3` never sets it at all;
`put_change/3` is the only writer for that field for any call reaching
`insert_changeset/2` directly. Today, a raw/unfiltered `attrs` map's
`:tenant_id` reaches `cast/3` and is accepted. Post-fix, it is read out of the
SAME `attrs` map by `put_change/3`, so a caller building an `attrs` map with a
key literally named `:tenant_id` still supplies the value that lands on the
changeset — this design does not change WHERE `enqueue/2` gets its trusted
`tenant_id` value from (still `TenantProvisioning.tenant_id_for_schema_name/1`,
merged into `insert_attrs` before the call, per `enqueue/2`'s own unchanged
contract, confirmed in §6). What changes is that a DIFFERENT, untrusted,
UNFILTERED `attrs` map — one that was never routed through `enqueue/2`'s own
`Map.take/2` — can no longer smuggle an extra/different value in for
`:status`/`:retry_count`/`:retry_history` (now unreachable via cast, defaults
win) the way it structurally could before. For `:tenant_id`/`:created_at`
specifically, `put_change/3` still reads them from `attrs`, so the security
property this fix delivers for those two fields is narrower than for the
other three: it makes the changeset's mechanism match its docstring (explicit
`put_change/3`, not implicit `cast/3` inclusion) and closes the specific gap
where a `cast/3`-based mechanism could be additionally influenced by other
`Ecto.Changeset` cast-related behavior (e.g. a future field-list edit
accidentally reintroducing overlap) — see §7's regression test for what is
concretely provable pre/post fix given this nuance.

## 6. Caller contract unchanged — `Letflow.Dlq.enqueue/2`

No change to `lib/letflow/dlq.ex`. `enqueue/2` (lines 81-113) already builds
`insert_attrs` via `Map.take/2` (12-key allowlist, excludes all 5 protected
fields) then `Map.merge/2`s in its own trusted `tenant_id`, `status: :pending`,
`retry_count: 0`, `retry_history: []`, `created_at: DateTime.utc_now() |>
DateTime.truncate(:second)` — this merged map is `insert_changeset/2`'s
`attrs` argument. Post-fix, `insert_changeset/2` reads `:tenant_id` and
`:created_at` out of that same merged map via `put_change/3` instead of
`cast/3`; `enqueue/2` supplies both keys today exactly as it always has, so
its `{:ok, Entry.t()} | {:error, Ecto.Changeset.t()}` return contract and
every acceptance criterion of `enqueue/2` itself (design `req176-dlq-core.md`
§3.1) are unaffected. `retry_changeset/2` and `discard_changeset/2` are out
of scope — this issue is scoped to `insert_changeset/2` only; neither of the
other two changesets casts `tenant_id` or `created_at` today, so neither is
touched.

## 7. Docstring update (accuracy, not new behavior)

Replace the `@doc` above `insert_changeset/2` (currently lines 98-103) with
text stating the actual post-fix mechanism:

- `status`, `retry_count`, and `retry_history` are excluded from `cast/3` and
  rely on their `Ecto.Schema` struct defaults (`:pending`, `0`, `[]`) —
  `enqueue/2` never needs to set them via a cast-reachable path because the
  schema itself supplies the value.
- `tenant_id` and `created_at` are excluded from `cast/3` and are instead set
  via two explicit `put_change/3` calls inside `insert_changeset/2`, reading
  both keys out of the `attrs` map it receives. State plainly: because
  neither key is in `cast/3`'s field list, a caller-supplied `attrs` map
  containing keys with those two names still reaches the changeset (via
  `put_change/3`'s own read of `attrs`) — the guarantee this fix
  adds is that `status`/`retry_count`/`retry_history` can no longer be
  influenced by `cast/3` regardless of what `attrs` contains, and that the
  changeset's structure now matches what the docstring says, rather than
  contradicting it.
- Keep the existing cross-reference to `Letflow.Dlq.enqueue/2` and design
  §3.1 (`lib/letflow/design/req176-dlq-core.md`).

Do not touch `retry_changeset/2` or `discard_changeset/2`'s docstrings — the
issue and this fix do not touch either function.

## 8. `validate_required/2` — unchanged list, confirmed correct

The existing `validate_required/2` call (entry.ex line 126), listing
`:tenant_id`, `:entry_type`, `:status`, `:retry_count`, and `:created_at`,
needs no edit. All five listed fields
still have a value in the changeset's effective state after the fix's
pipeline (§4): `:tenant_id`/`:created_at` via `put_change/3`, `:status`/
`:retry_count` via the struct's own default (present in `changeset.data`
even though `:changes` doesn't carry them — `validate_required/2` checks the
changeset's *current value*, which falls back to `:data` when `:changes` has
no entry for that field), `:entry_type` via `cast/3` unchanged.
`:retry_history` remains absent from `validate_required/2`'s list, as it is
today — no defect, not in scope (ISSUE-FIXER's diagnosis confirms this
explicitly).

## 9. Regression test WF-03 Step 4 must add

**Test location:** `test/letflow/dlq_test.exs` (existing file; ISSUE-FIXER
confirmed no direct `insert_changeset/2` call exists there today).

**Shape — a changeset-level test, NOT an `enqueue/2` test:**

1. Construct a base `%Letflow.Dlq.Entry{}` struct directly (bypassing
   `enqueue/2` entirely — this is the point: prove the CHANGESET's own
   mechanism enforces the invariant, not `enqueue/2`'s `Map.take/2`
   discipline).
2. Build a raw, unfiltered `attrs` map by hand that includes:
   - a `:tenant_id` value chosen to be a DIFFERENT UUID from whatever
     "intended/trusted" tenant_id the test separately supplies via
     `put_change/3`'s actual read path — i.e., the test's `attrs` map's
     `:tenant_id` key is exactly what the fixed `put_change/3` call will
     read, so the test is really asserting that whatever value is at the
     `attrs` map's `:tenant_id` entry is what lands on the changeset, and
     nothing else (e.g. no stale/cached struct field, no double-write) can
     override it — see the more targeted framing below.
   - `:status` set to a value OTHER than `:pending` (e.g. `:resolved` or
     `:discarded`) — a value the caller should never be able to force at
     insert time.
   - `:retry_count` set to a nonzero value (e.g. `7`).
   - `:retry_history` set to a non-empty list.
   - `:created_at` set to an arbitrary/implausible timestamp (e.g. far in the
     past or future) distinguishable from "now".
   - the ordinary required non-protected fields (`:entry_type` at minimum,
     since `validate_required/2` requires it) so the changeset's validity
     turns only on the protected-field assertions, not on an unrelated
     missing-required-field error.
3. Call `Letflow.Dlq.Entry.insert_changeset/2`, passing a freshly-constructed
   `%Entry{}` struct and the `attrs` map built in step 2.
4. Assert on the resulting `%Ecto.Changeset{}`:
   - the `:status` entry is NOT present in the changeset's `:changes` map
     (or, if checked via `Ecto.Changeset.get_field/3`'s fallback-to-default
     behavior, that function returns `:pending`, the schema default, for
     `:status`) — i.e., the caller-supplied `:resolved`/`:discarded` value
     from `attrs` did NOT reach the changeset's effective `:status`.
   - `get_field/3` for `:retry_count` returns `0`, not `7`.
   - `get_field/3` for `:retry_history` returns `[]`, not the non-empty list
     supplied.
   - `get_field/3` for `:tenant_id` returns exactly the value the fixed
     `put_change/3` call reads from the `attrs` map's `:tenant_id` entry
     (this proves the MECHANISM — `put_change/3` — is what's populating it,
     not `cast/3`; see the fail-first framing below for how this specific
     assertion distinguishes pre-fix from post-fix behavior).
   - `get_field/3` for `:created_at` returns exactly the value at `attrs`'s
     `:created_at` entry (same reasoning).

**The fail-first proof (the part that makes this a genuine regression test,
not a restatement of intended behavior):**

The sharpest, unambiguous fail-first assertion is on `:status`/
`:retry_count`/`:retry_history` specifically, NOT on `:tenant_id`/
`:created_at` — because pre-fix, `cast/3` casts all five fields from `attrs`
verbatim, so pre-fix the test's `attrs` value of `:resolved` for `:status`
DOES reach `get_field/3`'s result for `:status` (equal to `:resolved`, not
`:pending`) — the assertion that `get_field/3` returns `:pending` for
`:status` FAILS against pre-fix code and PASSES post-fix (where `:status`
is absent from `cast/3`'s field list, so `cast/3` never touches it, and the
struct default `:pending` is what `get_field/3` returns). Same fail-first
shape for `:retry_count` (pre-fix: `7` reaches the changeset via `cast/3`;
post-fix: `0`, the schema default) and `:retry_history` (pre-fix: the
non-empty list reaches the changeset; post-fix: `[]`, the schema default).

For `:tenant_id`/`:created_at`, note precisely what the fail-first test CAN
and CANNOT show, per §5's nuance: because both fields' values are still read
from the same `attrs` map (via `cast/3` pre-fix, via `put_change/3`
post-fix), a test that only checks that the changeset's `:tenant_id` equals
the value at the `attrs` map's `:tenant_id` entry passes on BOTH sides of
the fix and is not a discriminating regression test for those two fields
specifically. The
discriminating assertion for `:tenant_id`/`:created_at` is a MECHANISM
check, not a value check: assert directly on `changeset.changes` structure —
e.g. that a changeset built from an `attrs` map with `:tenant_id` supplied as
a `String.t()` that is NOT a syntactically valid UUID (`"not-a-uuid"`)
behaves identically whether cast or put_change wrote it (both `cast/3` and
`put_change/3` differ in error-shape on an invalid `Ecto.UUID` — `cast/3`
would add a `"is invalid"` type-cast error to `changeset.errors`, while
`put_change/3` bypasses type casting entirely and stores the raw value,
surfacing only later at `Repo.insert/2` as a DB-level type error, not a
changeset validation error). CODE-DESIGNER flags this as an explicit
DESIGN NOTE for TEST-DESIGNER: assert `changeset.valid?` and
`changeset.errors` differ in exactly this way pre/post-fix for a malformed
`:tenant_id` (pre-fix: `changeset.valid? == false` with a `:tenant_id`
`"is invalid"` cast error; post-fix: `changeset.valid? == true`, no cast
error for `:tenant_id`, because `put_change/3` performs no type
validation) — this is the fail-first-provable, mechanism-level assertion for
`tenant_id`/`created_at` that a mere "value round-trips" assertion cannot
provide. TEST-DESIGNER should include this malformed-UUID sub-case
specifically for `:tenant_id` (and, analogously, a non-`DateTime`-castable
value for `:created_at`, e.g. `"not-a-timestamp"`) alongside the
status/retry_count/retry_history assertions above, and state in the test
spec which of the two fail-first mechanisms (value-divergence for the three
schema-default fields; cast-vs-put_change error-shape divergence for
`tenant_id`/`created_at`) each assertion demonstrates.

**Open question for TEST-DESIGNER, stated rather than silently resolved:**
whether to also add a positive-path unit test asserting `enqueue/2`'s own
existing behavior (sanitized attrs, no direct `insert_changeset/2` call)
still produces a valid changeset with the expected values — this is
regression insurance against a mistake in the `put_change/3` implementation
itself (e.g. a typo reading the wrong key) rather than a proof that the
changeset rejects an untrusted attrs map. Recommended but not mandated by
this design; `enqueue/2`'s existing test coverage in `dlq_test.exs` (not
read in full by this design — TEST-DESIGNER should check whether it already
covers this) may already provide this insurance.
