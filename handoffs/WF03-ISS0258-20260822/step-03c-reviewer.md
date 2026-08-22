# WF-03 Step 3c — REVIEWER (hard gate)

Run: `WF03-ISS0258-20260822`
Agent: `REVIEWER`
Base: `8b728d7` · HEAD reviewed: `7b88f02`
Branch: `fix/WF03-ISS0258-20260822`

## VERDICT: **PASS**

0 MAJOR. 3 MINOR (all reporting/robustness; none affects a gate decision).
TEST-DESIGNER is unblocked.

Every number below was re-derived in this worktree. Nothing was inherited from
the design doc, the ELIXIR-DEV handoff, or the dispatch brief.

---

## Gate commands — measured

```
$ mix compile --warnings-as-errors
EXIT=0                                        (no output)

$ mix format --check-formatted
FORMAT_EXIT=0

$ mix letflow.check_deferral_staleness
STAGE ACTIVITY (derived, always reported, never gates):
  S0  ACTIVE  [2 cancelled, 5 done]  active via REQ-010, REQ-011, REQ-012 (+2 more)
  S1  ACTIVE  [2 cancelled, 7 done]  active via REQ-015, REQ-016, REQ-017 (+4 more)
  S2  ACTIVE  [21 done]  active via REQ-022, REQ-023, REQ-024 (+18 more)
  S3  ACTIVE  [1 cancelled, 26 done]  active via REQ-043, REQ-044, REQ-045 (+23 more)
  S4  ACTIVE  [2 cancelled, 14 done, 20 pending]  active via REQ-065, REQ-066, REQ-067 (+11 more)
  S8  INACTIVE  [1 cancelled, 10 pending]
  S9  INACTIVE  [4 pending]
DEFERRALS (legitimate ones are reported and never gate): none
0 deferred of 115 entries; 0 stale
DEFERRAL_EXIT=0

$ mix letflow.check_requirements_registration
DEFERRED (visible debt -- always reported, never gates): none
115 entries = 115 registered + 0 deferred + 0 neither + 0 unclassified
```

Stage histogram sums to 7+9+21+27+36+11+4 = 115. Matches the entry count.

---

## (1) Implementation-vs-design fidelity — **PASS**

S1–S6 are each implemented, none dropped, added, or weakened. Verified by
driving `audit/1` on hermetic fixtures rather than by reading the code.

| Rule | Implementation | Fixture result |
|---|---|---|
| S1 stale deferral | `s1/1` on `verdict == :stale` | `[S1] REQ-901 (line 5): STALE deferral -- stage-scoped; stage S4 is ACTIVE -- made active by REQ-900 (done)` |
| S2 deferral without `stage:` | `s2/1` on `stage: nil` | fires; `classify_deferral/3` short-circuits to `:undecidable` before `judge/3` |
| S3 hatch resolves + live | `s3/2` via `hatch_state/3` | all three sub-cases fire — dangling `REQ-999`, self-reference `REQ-901`, expired `REQ-903 is done` |
| S4 `:unknown` hard-fail | `unknown_status_violations/1` over **all** entries | `[S4] REQ-900: unrecognised status "donee" -- known values are blocked \| cancelled \| done \| in_progress \| pending` |
| S5 corpus non-empty/shaped | `shape_violations/2` | fires on both `nothing: here` and a bare `requirements:` section |
| S6 hatch acyclicity | `cycle_violations/1` in `audit/1` | `[S6] REQ-900 (line 2): blocked-by: cycle -- REQ-900 -> REQ-901 -> REQ-900` |

**`:unknown` hard-fails — confirmed, and it is total.** `normalise_status/1`
measured across the full input domain:

```
nil -> :unknown      "done" -> :done          "done  # comment" -> :done
""  -> :unknown      "  blocked " -> :blocked  "donee" -> :unknown
"DONE" -> :unknown
```

There is no branch anywhere that absorbs `:unknown` into a passing bucket.
`@active_statuses` is `[:done, :in_progress, :blocked]` — a closed list;
`:unknown` is not in it, so an unrecognised status cannot confer activity, and
separately `unknown_status_violations/1` gates it. This is the structural
descendant of ISS-0231's `:unclassified` defence, intact. Note it is applied to
**all** entries, not only deferred ones, as OQ-2 ruled.

Design ordering respected: S6 lives in `audit/1`, not `classify_deferral/3`
(design §6 requires this, and cycle detection is inherently multi-entry).

## (2) Scope creep, both directions — **PASS**

`docs/requirements.yaml` changed by **exactly one line**, and it is the status
legend:

```
-# Status values: pending | in_progress | done | blocked
+# Status values: pending | in_progress | done | blocked | cancelled
```

`git diff --stat` confirms `docs/requirements.yaml | 2 +-` — one insertion, one
deletion, same line. No requirement entry touched.

The registration module change is **+17 / −0**, verified additive in fact:

```
$ grep -n "status" lib/mix/tasks/letflow.check_requirements_registration.ex
154,156,158  @status_re + its comment
166          status: String.t() | nil,     (type only)
296          status: extract_status(attributed),   (base map only)
565-569      extract_status/1
```

That is the complete set of references. `status` is read by **no** rule, no
violation function, no `render/1` branch, and no `tally/1` path in that module.
`:deferred` classification is untouched, R1–R6 are untouched, `run/1` is
untouched, and the module still emits its identical roster line and exits 0.
The run's hard constraint — "don't silently redefine what deferred means in that
module" — holds: the field is stored raw and uninterpreted, and the added
comment says so explicitly ("all status semantics live in
`Mix.Tasks.Letflow.CheckDeferralStaleness` (ISS-0258), never here").

No creep in the other direction either. No behaviour, no macro, no generic
plumbing, no config surface, no exception/allowlist mechanism. The new module
reuses `Registration.scan/1` rather than adding a second parser — the right call,
and the one the design mandates. Of 884 lines, 204 are the moduledoc header and
6 more are `@doc` blocks; the executable body is modest for six rules plus two
rendered report blocks.

## (3) Decision-record consistency — **PASS**

- **No new dependency.** `git diff 8b728d7 HEAD -- mix.exs` is one line, inside
  the `aliases` list. `deps/0` is unchanged and `mix diff … mix.lock` is empty.
  The project still has no YAML library; the new module adds no parser.
- **DR-0005** legislates alias **slot 1** only ("prepend `letflow.check_toolchain`
  as the **first** entry"). Slot 1 is still `letflow.check_toolchain`. The new
  task went in at slot 3, immediately after its data source. No conflict.

## (4) The moduledoc hazard — **PASS**

`docs/anti-patterns.md` line 1195 applies squarely: the new moduledoc contains
both the marker form (`# impl_order: UNREGISTERED -- blocked-by: REQ-042 -- …`)
and a literal `status: donee`. Verified the module cannot trip on itself, two
ways:

1. **Structurally.** A single `@requirements_file "docs/requirements.yaml"`
   constant, read at exactly one site (`File.read(@requirements_file)`, line 269).
   `grep -nE "File\.ls|Path\.wildcard|File\.cwd|System\.cmd|:httpc|Req\.|File\.write"`
   over the module returns **NONE-FOUND** — no directory walk, no second read,
   no write, no network.
2. **Empirically.** Both checks run green in the tree that contains the new
   moduledoc — the detector exits 0 and the registration check still reports
   `115 registered + 0 deferred`. The registration module's own scan is likewise
   pinned to the same single path, so the new moduledoc's marker form does not
   register as a deferral there either.

## (5) Correctness traps — **PASS**

**Trailing-comment status parse.** Measured on the real corpus: `8` of `115`
`status:` lines carry a trailing `# …` comment, and all 115 entries have a
status line (so no entry yields a spurious `nil → :unknown`). Both `@status_re`
and `normalise_status/1` take the first whitespace-delimited token only —
`"cancelled  # MVP-1 milestone dropped, …" → :cancelled`. A fixture with two
such lines produces zero violations. The 8 would all have become `:unknown` and
made this gate red on day one under a rest-of-line extractor; they do not.

**Self-exclusion is not gameable.** The decisive fixture is two deferred entries
in one stage, one of them `done`:

```
REQ-900 (done, deferred)    -> LEGITIMATE  (stage S7 inactive after self-exclusion)
REQ-901 (pending, deferred) -> STALE       (stage S7 is ACTIVE -- made active by REQ-900 (done))
```

The exclusion removes *the entry under test from its own computation*
(`facts.witnesses -- [id]`), not deferred entries generally. Two deferrals do
**not** mutually excuse each other — REQ-901 still sees REQ-900 as a witness and
fails. Marking your own deferred entry `done` suppresses nothing while any other
active sibling exists.

The one case that declines to judge — a *lone* deferred entry that is itself
`done` — is design-acknowledged, and I confirmed it is annotated rather than
hidden: the roster prints
`REQ-900  S7  stage-scoped  LEGITIMATE  (NOTE: deferred entry is itself done)`.
Accepted residual, correctly scoped to a registration-shaped anomaly.

**Hatch grammar** (`parse_scope/1`), measured:

```
"-- blocked-by: REQ-042 -- real reason"   -> {:blocked_by, "REQ-042"}
"blocked-by: REQ-042 -- real reason"      -> {:blocked_by, "REQ-042"}
"-- this is blocked-by: REQ-042 in prose" -> :stage_scoped   (anchoring holds)
"-- blocked-by: REQ-042"                  -> :stage_scoped   (free text still required)
"-- blocked-by: REQ-042 --"               -> :stage_scoped
"-- blocked-by: REQ042 -- malformed id"   -> :stage_scoped
```

All four load-bearing properties hold. The optional leading `(?:--\s*)?` is
necessary and correct — `Registration`'s marker capture retains the leading
`--` from `UNREGISTERED -- <rationale>`.

**S6 cycle detection.** `find_cycle/2` is enumerated from every edge source, so
any cycle is found from at least one member; `canonical_cycle/1` rotates to the
minimum id and `Enum.uniq` collapses rotations, so a 2-cycle reports once. The
one-step case is correctly excluded (`length(&1) < 2`) and left to S3. The graph
is confined to deferred entries by construction — a non-deferred entry has no
`UNREGISTERED` marker and therefore cannot carry a hatch.

**Detector fires — re-derived independently.** I reproduced the ELIXIR-DEV
fixture result from scratch, and it matches to the character:

```
[S1] REQ-901 (line 5): STALE deferral -- stage-scoped; stage S4 is ACTIVE -- made active by REQ-900 (done)
REQ-902 (deferred, S8) -> LEGITIMATE, no violation
```

## (6) OQ-1 has gone live — **RULING: the `blocked`-active ruling still holds; it flips nothing**

I did not take this from the brief. Fresh `origin/main` has moved past `b373d08`
during this run — it is now **`6394b8c`** (`fix(ISS-0227): drop the removed
fields from ISS-0226's fabricated in_flight fixtures (#506)`). I measured that
head directly:

- **116 entries** (`grep -c "^  - id: REQ-"`).
- **Exactly one `blocked`**: line 4346, `REQ-077`, `status: blocked`,
  `stage: S4`, `impl_order: 144`. Confirmed by reading the entry.
- **Zero deferral markers** (`grep -c "^\s+# impl_order: UNREGISTERED"` → `0`).

I then ran this branch's `audit/1` against that live corpus:

```
entries=116 deferrals=0 stale=0 violations=0
S4 active %{blocked: 1, pending: 20, done: 14, cancelled: 2} nwit=15
blocked ids: ["REQ-077"]
S4 witnesses minus blocked: 14
S4 active without :blocked? true
```

**The ruling is confirmed, and your analysis is correct.** S4 carries 14 `done`
witnesses independently of REQ-077, so removing `blocked` from `@active_statuses`
leaves S4 `:active` regardless. The live instance changes no stage verdict, no
deferral verdict, and no violation. The `blocked`-active decision remains
unexercised in outcome — it is currently a ruling about a case that does not yet
discriminate.

Two consequences worth recording, both favourable:

1. **The Step-Final rebase onto `origin/main` will not turn this gate red.** I
   measured `violations=0` against the post-rebase corpus, not just the branch
   corpus. That is the risk the stale measurement actually created, and it is
   closed.
2. The design's *justification* prose for `blocked` ("measured: zero
   requirements are currently `blocked`") is now factually stale even though its
   *conclusion* is unaffected. See MINOR-3.

**OTP idiom and supervision:** not applicable in substance. This is a `Mix.Task`
with a pure core (`audit/1`, `stage_activity/1`, `classify_deferral/3`,
`parse_scope/1`, `normalise_status/1`, `render/1` all pure and public for
fixture testing) and IO confined to `run/1`. No processes, no supervision tree,
no state machine — nothing for the supervision-integrity or `:gen_statem`
criteria to bite on. The pure-core/IO-shell split is idiomatic and is exactly
what makes Step 4's hermetic fixtures possible.

---

## Findings

### MAJOR — none.

### MINOR-1 — roster prints `LEGITIMATE` for an entry that fails the run (S3)

When a hatch is *invalid* (dangling id or self-reference) **and** the stage is
inactive, `judge/3` falls through `{:invalid, detail}` to `by_stage/4`, which
assigns `verdict: :legitimate`. `s3/2` independently emits the violation, so
**there is no gate hole** — measured:

```
REQ-900  S8  blocked-by: REQ-999  LEGITIMATE
    its `blocked-by:` scope is unusable (names REQ-999, which is not present in the corpus); stage S8 is inactive -- …
VIOLATIONS (each one fails the run):
  [S3] REQ-900 (line 2): `blocked-by:` scope does not resolve -- …
violations=1 stale=0
```

Exit is non-zero and the reason string does say "unusable". But the roster's
one-word verdict column contradicts the run outcome, which is the column a
reader scans first. Suggest a third rendered verdict label (or reusing
`:undecidable`) for the invalid-hatch branch. Reporting only — not a gate defect,
and not worth blocking on.

### MINOR-2 — `audit/1` depends on the sibling module for duplicate-id safety

`statuses` is `Map.new(entries, …)` keyed by id, so duplicate ids silently
collapse, and `map_size(result.statuses)` is the denominator in the
`"N deferred of M entries"` line — it would under-report against
`report.entry_count`. Duplicates are gated upstream by
`CheckRequirementsRegistration`'s `duplicate_id_violations/1`, which runs first
in the alias, so the live path is safe (and the live corpus has none: 115
statuses for 115 entries, 116 for 116 on `origin/main`).

Flagging it because S5's own stated rationale is that this module "must be
correct on its own, not correct only because another task ran first" — this is
the one place that principle is not met. Cheap fix if TEST-DESIGNER wants a
fixture for it; not blocking.

### MINOR-3 — the design's `blocked` justification prose is now stale

Design §3 / the moduledoc justify `blocked`-as-active partly on "measured: zero
requirements are currently `blocked`". As of `origin/main` `6394b8c` that is
false — REQ-077 is `blocked` in S4. The *conclusion* is unaffected (ruled above),
but the supporting measurement should be refreshed at Step Final so the record
does not carry a false fact forward. Documentation only.

---

## Note for TEST-DESIGNER

The live corpus has **zero** deferrals and **zero** unknown statuses, so every
live-corpus assertion about S1/S2/S3/S6 passes vacuously and would keep passing
under almost any mutation of the staleness rules. The regression value is
entirely in hermetic fixtures against the pure functions. `audit/1`,
`classify_deferral/3`, `parse_scope/1`, `normalise_status/1` and `render/1` are
all public and content-taking for exactly this reason.

Practical note that cost me a cycle: plain `mix run` trips a shared-dev-DB guard.
Use `mix run --no-start` for the pure functions.

---

## Gate record

| Item | Ruling |
|---|---|
| (1) Design fidelity, S1–S6, `:unknown` hard-fail | PASS |
| (2) Scope creep, both directions | PASS |
| (3) Decision-record consistency (deps, DR-0005) | PASS |
| (4) Moduledoc hazard | PASS |
| (5) Correctness traps | PASS |
| (6) OQ-1 live `blocked` instance | PASS — ruling holds, flips nothing |

**REVIEWER: PASS.** Proceed to WF-03 Step 4 (TEST-DESIGNER).
