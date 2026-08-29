# REQ-185 RELEASE-VALIDATOR independent re-verification

Verdict: **PASS**. All 8 acceptance criteria independently re-derived against
the actual design artefact and the actual referenced code (not taken from
TEST-DESIGNER's, REVIEWER's, or SECURITY-REVIEWER's prior reports).

## Criterion-by-criterion

1. **Exactly one recommended firing mechanism.** §2 of
   `lib/letflow/design/req185-scheduler-firing-architecture.md` evaluates
   Oban (§2a), a supervised `GenServer` ticker (§2b), and a per-timer process
   (§2c) against node-restart/multi-node/raising-timer survival properties,
   and §2's "Recommendation" names 2b as the single adopted mechanism with
   stated rejection reasons for 2a and 2c. Confirmed by direct read.

2. **Explicit YES/NO on Oban, REVIEWER sign-off IN the artefact.** §3 states
   "Decision: NO." with four numbered grounds, followed by a fully written
   (non-placeholder) sign-off block: "REVIEWER sign-off: RECORDED,
   2026-08-29, WF02-REQ185-20260829 Step 2d" plus multiple paragraphs of
   substantive agreement/caveat. Verified this is a genuine edit, not just a
   handoff claim, by inspecting `git show 3faef00 -- lib/letflow/design/req185-scheduler-firing-architecture.md`:
   the commit itself replaces the prior PENDING placeholder text with the
   sign-off shown in the file today. Confirmed.

3. **FOR UPDATE SKIP LOCKED + ISS-301 citation.** §4 states "Decision:
   SELECT ... FOR UPDATE SKIP LOCKED is the claim mechanism," explicitly says
   this departs from SCH-02's literal advisory-lock text, cites
   `src/design/scheduler-concurrency-epic3.md`'s ISS-301 section by name, and
   states R-Co removed the per-timer advisory lock on four grounds, with an
   explicit warning that a later reader must not restore it. Confirmed.

4. **Startup-sweep-lock decision.** §5: "Decision: NO," with stated reasoning
   (the ordinary steady-state poll query is already catch-up-safe by
   construction, so there is no separate sweep pass to gate; FOR UPDATE SKIP
   LOCKED alone prevents double-claiming on simultaneous multi-node restart).
   Confirmed as a real decision, not a deferral.

5. **Tenant-iteration strategy with quantified cost.** §6: "Decision: the
   poller iterates tenant schemas per tick," using the existing
   `tenant_schemas` registry, with a quantified cost: "500 queries per tick
   ... 100 queries/second sustained ... 1000 tenants ⇒ ~200 qps." TEST-DESIGNER
   independently re-checked the arithmetic (500/5=100, 1000/5=200) and I
   re-confirm it is correct and matches the stated per-tenant-per-tick query
   assumption. Confirmed as quantified, not qualitative.

6. **Locked/nothing-due/hard-error three-way distinction + ISS-0618
   citation.** §7 states the three outcomes as structurally distinct,
   explicitly cites `src/design/iss0618-scheduler-lock-and-error-signaling.md`,
   and gives the reasoning for why propagating every error out of the fire
   path is wrong: it would stop the tenant-schema poll loop before
   `fire_error_count` can climb to its configured maximum for any timer
   still queued behind the crashing one. Confirmed.

7. **Timer-in-DLQ decision.** §8: "Decision: YES," with `entry_type =
   "timer"`, not deferred to REQ-186. Independently re-verified the
   grounds against the actual files (not trusted from the design doc's own
   text): `priv/repo/migrations/20260829000001_create_dlq_entries.exs`
   declares `add :entry_type, :string, null: false` with no `Ecto.Enum` and
   no CHECK constraint, and its header comment states this is deliberate
   ("extensible ... more later"). `lib/letflow/dlq.ex`'s `enqueue_attrs()`
   types `entry_type` as bare `String.t()` with no allow-list gate anywhere
   in the module. Confirmed: no schema change is needed for `"timer"`.

8. **No migration/engine file/mix.exs change.** Ran directly:
   `git diff --stat main...HEAD` shows exactly: the design markdown file,
   handoff JSONs, and two report markdown files (`reviewer-report.md`,
   `security-review-report.md`) plus `verification-notes.md`. No file under
   `priv/repo/migrations/`, no file under `lib/letflow/engine/`, and
   `mix.exs` does not appear in the diff at all. Confirmed independently
   (not copied from a prior report's claim).

## Cross-checks beyond the 8 criteria

- Re-read `lib/letflow/application.ex` in full: confirms the design's claim
  that no periodic process (no `Process.send_after`-driven `GenServer`, no
  `:timer.send_interval`) exists today.
- Re-read `mix.exs`'s `deps/0`: confirms no Oban, no Quantum, no job-queue
  library.
- `docs/migration/decisions/0003-ecto-schema-strategy.md` Decision B
  (schema-per-tenant, `tenant_id` retained intra-schema) is correctly treated
  as binding table placement only; §6 correctly frames the poller's
  iteration strategy as the separate, still-open question it answers, and
  rejects a global queue specifically because it would conflict with
  Decision B.
- REVIEWER's sign-off commit (3faef00) is a real, substantive edit to the
  artefact, not a rubber stamp copied into a handoff only — checked via
  `git show`.
- §0's honesty about R-Co source being unreachable this session (ISS-301 and
  ISS-0618 citations carried forward as unverified-but-plausible, not
  independently re-confirmed against R-Co) is preserved accurately and does
  not overstate certainty; §11's OQ-3 flags this for a future session with
  R-Co reachable. This is a disclosed limitation, not a gap in this
  requirement's own acceptance criteria (none of the 8 criteria require R-Co
  to be reachable this session).

## Conclusion

No gap found. All 8 acceptance criteria genuinely hold against the actual
artefact and actual referenced code, independently re-derived rather than
taken from any prior agent's report. Routing to DOC-UPDATER (Step 6) to flip
REQ-185 to `done`.
