# 0005 — Pin a canonical Elixir/Mix toolchain version for `mix format`

Status: decided, application deferred. Owner: ORCH → REVIEWER.

## Question

`mix format --check-formatted` has now failed twice for the same underlying
reason, on files nobody touched in the run that discovered the failure:

- **ISS-0008** (GH#12, closed 2026-08-15): 5 files failed under a sandbox
  running Elixir 1.20.3/OTP 29, formatted clean under whatever toolchain
  last committed them.
- **ISS-0068** (GH#229, closed 2026-08-19): 14 different files failed under
  this host's Elixir 1.18.3/Mix 1.18.3 (OTP 27), for the identical reason.

Root cause (established by both incidents' diagnosis, most recently
`lib/letflow/design/iss0068-format-drift-fix.md` §3): this project runs
several concurrently-active hosts (per `CLAUDE.md`/session briefs — as of
2026-08-19, four: this host, `~/letflow-wt2`, and two checkouts on the
project owner's machine), each free to run whatever local Elixir/Mix
install it has. `mix.exs` declares `elixir: "~> 1.14"` — a floor, not a
pin — and `README.md` only "recommends 1.17+". Mix's formatter changes its
paren-insertion/line-wrap heuristics across versions, so whichever host's
`mix format` runs last on a given file "wins," and the next host to check
that file out sees a spurious failure on content it never touched.

Both prior incidents were resolved the same way: reformat the flagged
files under the diagnosing host's own toolchain and move on. That fix is
correct for closing the individual incident but does not address the
recurring cause — it just moves which toolchain's output is "current"
until the next host reformats something under a third version. A third
occurrence should be expected under the status quo.

## Options

**(a) Pin one canonical Elixir/Mix version repo-wide via a version file
(e.g. `.tool-versions` for asdf, or the `mise`/`rtx` equivalent), and
require every host to run that exact version for anything that writes
formatted output (`mix format`) before committing.**

- Pro: closes the root cause directly — if every host's formatter agrees,
  drift stops recurring regardless of how many hosts run concurrently.
- Con: requires every host to actually have that exact version installed
  (or install it via the version manager) rather than "whatever 1.17+ is
  already on the machine" per the current README note; a host that can't
  install the pinned version is blocked from ever producing a
  format-clean commit until it does.
- Con: this repo has no CI (`.github/workflows` does not exist, confirmed
  2026-08-19) to enforce the pin mechanically — it would rely on every
  host's own `mix letflow.check` run to catch a drifted local toolchain,
  same as today, just with a documented target to drift back toward.

**(b) State the target version in `mix.exs`'s `elixir:` requirement (e.g.
tighten from `~> 1.14` to an exact `== 1.18.3`) plus a documented
convention in `docs/guides/backend_developer_guide.md`, without a
separate version-manager file.**

- Pro: no new tooling dependency (no asdf/mise required), the version
  requirement already lives in a file every host reads (`mix.exs` itself
  refuses to compile under a disallowed version if written strictly
  enough).
- Con: `mix.exs`'s `elixir:` requirement is a compile-time gate on the
  *language* version, not the *formatter's* version — Mix's formatter
  ships as part of the Elixir installation, so pinning the `elixir:`
  requirement is effectively equivalent to (a) in outcome but weaker in
  enforcement (a version-manager file actively selects the right toolchain
  when you `cd` into the repo; a `mix.exs` requirement only complains
  after you've already installed the wrong one and tried to compile).

**(c) Keep resolving drift incident-by-incident, as both ISS-0008 and
ISS-0068 already did.**

- Pro: zero setup cost, no host has to change anything.
- Con: this is the status quo that produced two incidents in four days of
  active multi-host development; nothing about the underlying condition
  (N concurrently-active hosts, no shared toolchain reference) changes
  between now and the third occurrence.

## Recommendation (non-binding — REVIEWER decides)

(a) is the only option that actually closes the root cause rather than
documenting it. (c) has already been tried twice with the same result
each time, so it is not "no decision" — it is implicitly re-choosing the
option that already failed to prevent recurrence. Between (a) and (b), (a)
is the stronger enforcement mechanism at a small one-time setup cost per
host (a version manager most Elixir hosts already have available), and it
degrades gracefully to (b)'s effect on a host that has no version manager
installed (the `mix.exs` requirement still catches a language-version
mismatch even without `.tool-versions` present).

## What this record does not decide

- The exact version string to pin. If (a) or (b) is adopted, REVIEWER's
  sign-off should also state which currently-in-use version to standardize
  on (a natural default: whichever version the most recent successful
  `mix letflow.check` run used, currently Elixir 1.18.3/Mix 1.18.3/OTP 27
  per ISS-0068's diagnosis) — not decided here to avoid this record
  going stale if a newer host toolchain supersedes that pick before
  REVIEWER reviews it.
- Whether to add CI (`.github/workflows`) as a second enforcement layer.
  This repo currently has none; adding one is a larger, separate scope
  than this record's question and is not assumed by any option above.

## Follow-on

Once REVIEWER signs off on an option (or explicitly defers to (c) with a
stated reason), the actual toolchain-pin file (if (a) or (b) is chosen)
is a small, single/two-file ELIXIR-DEV change — queue task 125 / GH#232
tracks this record; a second, small follow-on task should be filed for
the application step once a decision is made here, since this record
itself is the decision artefact, not the applied fix.

## REVIEWER sign-off

Date: 2026-08-19T05:39:44Z (corrected by ORCH from a fabricated
date-only placeholder the REVIEWER sub-agent wrote instead of running
`date -u` — same anti-pattern class documented in
`docs/anti-patterns.md`'s "Extrapolating handoff timestamps instead of
reading the clock" entry; flagging the correction here per that entry's
own guidance rather than silently overwriting it).

**Decision: option (a).** Pin the toolchain repo-wide via `.tool-versions`
(asdf-style), targeting **Elixir 1.18.3 / OTP 27**.

Verification performed independently before deciding:
- `ls .github` → no such directory; confirms the draft's "no CI exists"
  claim.
- `mix.exs` line 8 → `elixir: "~> 1.14"`; confirms the draft's "floor,
  not a pin" characterization.
- This host's actual toolchain (`elixir --version` / `mix --version`) →
  Elixir 1.18.3, Mix 1.18.3, OTP 27 — matches the draft's cited figures
  for ISS-0068 exactly, so 1.18.3/OTP 27 is not just "most recent
  successful run" per the record, it's also what is live on at least
  this host today, making it the lowest-friction pin target.
- Grepped `docs/migration/decisions/` for toolchain/CI/formatting
  topics — no hits besides this record itself. No existing decision is
  reopened or contradicted by pinning a toolchain here.

Reasoning: (b) only tightens a compile-time language-version gate,
which the draft itself notes is weaker than (a) for the actual failure
mode — the *formatter's* heuristics drift with the Elixir install, not
with language-version compatibility, and a version-manager file
actively selects the right toolchain on `cd`, catching drift before a
host ever runs `mix format`, rather than after. (c) is ruled out per
the draft's own argument: it has already been tried twice and produced
two incidents in four days: continuing it is not neutral, it's
re-choosing the option with a demonstrated failure rate. The one-time
setup cost of (a) (installing an asdf/mise-managed Elixir per host) is
small relative to a third recurrence.

Status changed to "decided, application deferred" — this record does
not itself add `.tool-versions` or edit `mix.exs`; that is ELIXIR-DEV's
follow-on task per queue task 125 / GH#232, which should also update
`README.md`'s "recommends 1.17+" language to point at the pinned
version and tighten `mix.exs`'s `elixir:` requirement to match (folding
in (b)'s mechanism as the compile-time backstop (a)'s own pro/con
already anticipates).

## REVIEWER sign-off — amendment (supersedes the version target above)

Date: 2026-08-21T01:25:50Z (read from `date -u`, not from memory — the
2026-08-19 sign-off above records that it had to be corrected once for a
fabricated date, so this one states its provenance too).

Run: `WF03-ISS0106-20260821`, step 1.5. Trigger: ISS-0106. Evidence base:
`handoffs/WF03-ISS0106-20260821/step-01-diagnose.json` (ISSUE-FIXER), whose
load-bearing claims were re-derived independently before deciding — see
"Verification performed independently" below.

**The 2026-08-19 decision to pin (option (a), via `.tool-versions`) STANDS.
The version target it named does not.** This amendment changes the target
and adds the enforcement mechanism the original sign-off left out. Nothing
above this heading is altered; read the two sections in order.

### Decision, stated so it can be implemented without inference

1. **`.tool-versions` names Elixir 1.20.3 / OTP 29.** Exact file contents
   after this run:

   ```
   elixir 1.20.3-otp-29
   erlang 29.0.5
   ```

   (`29.0.5` measured on this host via the Erlang installation's
   `OTP_VERSION` file; `erlang:system_info(otp_release)` returns only the
   major `"29"`, and asdf wants the full version, so the full one is
   pinned. `erts` is 17.0.5, recorded for identification, not pinned.)

2. **`mix.exs`'s `elixir:` requirement is UNCHANGED: `elixir: "~> 1.18"`.**
   This is a deliberate no-op, called out explicitly so that a later run
   does not "tidy" it into agreement with the pin. Its semantics are
   `>= 1.18.0 and < 2.0.0` (measured, below) — a *floor* that spans both
   the old pin and the new one. It is deliberately wider than
   `.tool-versions` so that no host is locked out of compiling by the pin
   moving. Option (d)'s proposal to tighten it to `~> 1.18.0` is
   **REJECTED** — see constraint 2 below.

3. **Option (c) is ADOPTED, as a WARNING, not a hard exit-code failure.**
   `mix letflow.check` gains a first step that parses `.tool-versions`,
   compares it against `System.version()` and
   `:erlang.system_info(:otp_release)`, and on mismatch prints a warning
   naming *both* the expected and the running version, then continues.
   Requirements on it, each load-bearing:
   - It runs **first** in the alias, so the warning is on screen before
     any format diff an agent might misattribute.
   - It prints on mismatch **regardless** of whether the later checks pass,
     and is not suppressible by a flag or env var.
   - It **never** changes any other check's exit code, and it must not be
     made to pass by relaxing what it reads.
   - Promotion to a hard exit-code failure is deferred, with a stated
     trigger: once the active-host fleet can be established *in the present
     tense* as all on-pin. Filing that as a follow-on is left to ORCH.

### Verification performed independently before deciding

Re-derived rather than inherited, per `docs/anti-patterns.md`'s "Inheriting
a claim from a record instead of re-deriving it from the source":

- `mix.exs:8` → `elixir: "~> 1.18"`. Semantics measured, not assumed, by
  running the resolver itself: `Version.match?("1.20.3", "~> 1.18")` →
  `true`; `Version.match?("2.0.0", "~> 1.18")` → `false`;
  `Version.match?("1.20.3", "~> 1.18.0")` → `false`;
  `Version.match?("1.18.9", "~> 1.18.0")` → `true`. The two-component form
  admits 1.19/1.20/1.21. **`README.md:154-156`'s claim that it "accepts any
  1.18.x patch" is therefore measurably false** and must not survive this
  run.
- `.tool-versions` is inert on this host: `command -v asdf mise rtx` → all
  three not found; a repo-wide grep over `*.ex`/`*.exs`/`*.y{a,}ml`/
  `Makefile`/`*.sh`/`*.ps1` outside `docs/` and `handoffs/` for
  `tool-versions` → **zero hits**. Nothing in this repo reads the file.
  This is the sharpest fact in the record: the artefact the 2026-08-19
  sign-off produced is, on a host without a version manager, a comment.
- Nothing in the gate inspects a toolchain version:
  `mix.exs:56-60` defines `letflow.check` as exactly
  `["format --check-formatted", "compile --warnings-as-errors",
  "letflow.check.test"]`; `lib/mix/tasks/letflow.check.test.ex` (120 lines)
  contains no `version`/`otp` reference other than one prose mention of a
  `stream_data` bump; grepping `lib/ mix.exs config/` for
  `System.version|otp_release|:erlang.system_info` returns only two prose
  lines inside a design markdown file.
- `ls -d .github` → *No such file or directory*. No CI enforcement point.
- This host, measured now: Elixir 1.20.3 (compiled with Erlang/OTP 29),
  OTP 29.0.5, erts 17.0.5.

**Spot-check of the overturn** (ISSUE-FIXER's central claim: the four
flagged files are unformatted under the *old pin* too, so the reformat is
not a cost of moving the pin). Two independent methods, neither of which
re-runs the container:

- *Line length.* `.formatter.exs` sets no `line_length`, so the default 98
  applies — under every Elixir version that has had a formatter. Measured
  lengths of the flagged lines: `test/letflow/engine/pin_resolver_test.exs`
  239 → 102, 322 → 102; `test/letflow/engine/pin_rebind_test.exs` 516 →
  100; `lib/letflow/engine/pin_resolver.ex` 541 → 99. All four exceed 98.
  **Corroborates.** One refinement to the diagnosis: it describes these as
  "101-102 character" wraps; the actual figures are 99-102, and
  `pin_resolver.ex:541` is only one character over. This does not change
  the conclusion — 99 > 98 under any version — but the record should carry
  the measured numbers, not the approximated ones.
- *Introducing-commit blob check*, `git show <rev>:<path> | mix format
  --check-formatted -`, which never writes the working tree:
  `variable_merge.ex` at `91d7e25^` → exit 0, at `91d7e25` → exit 1;
  `pin_resolver.ex` at `cb43cc2^` → exit 0, at `cb43cc2` → exit 1;
  `pin_resolver_test.exs` at `a7fa87b^` → exit 0, at `a7fa87b` → exit 1.
  **Corroborates**: each file was format-clean at its parent and
  unformatted at the commit that merged on 2026-08-20.

I attempted a third method for the `variable_merge.ex` heredoc-escape case
specifically — looking for a pre-existing `\"""` elsewhere in `lib/`/`test/`
that predates 1.20 and would show the escaping rule is not new. `grep -rln`
found none, so that method is **inconclusive** and is reported as such. The
1.18.3 side of that one diff rests on ISSUE-FIXER's container run, which I
did not reproduce. It is not load-bearing for this decision: the other
three files are over-length under every version, so the reformat is
required regardless of how the heredoc case is attributed.

### Why the target moved, and why the decision itself did not

The 2026-08-19 sign-off gave two reasons for 1.18.3: it was "most recent
successful run," and it was "what is live on at least this host today,
making it the lowest-friction pin target." **Both were true when written
and neither is true now.** The repo's records show no host on 1.18.3 since
2026-08-19; every toolchain observation dated 2026-08-20 or later is
1.20.3/OTP 29, on two independent Windows checkouts. Pinning to 1.18.3
today would mean pinning to a version no record shows any host running —
the exact opposite of the property that was used to choose it. Holding the
old target would be preserving the sign-off's *letter* while discarding its
*reasoning*.

The generalizable lesson, recorded so the next amendment is cheaper:
**"lowest-friction, it is what is live today" is a premise with an expiry
date.** A pin chosen on that basis is not a permanent fact and must be
re-derived whenever the host fleet changes. That is not a flaw in the
2026-08-19 sign-off — it is why an amendment mechanism exists — but the
record should say so out loud rather than letting the next reader mistake a
dated observation for a standing one.

What did *not* change, and why option (a) survives intact: the underlying
condition — several concurrently-active hosts, each free to run whatever
Elixir it has — is unchanged. A pin is still the right shape. One honest
qualification, since it cuts against the original record's diagnosis: this
run measured that 1.18.3 and 1.20.3 agree byte-for-byte about *this*
codebase's formatting, in both directions. The formatter-heuristic drift
that 0005 was filed to stop is not what produced ISS-0106's four files;
unformatted code merged past a red gate did. The pin is retained anyway,
because "these two particular versions happen to agree about this
particular tree today" is not a property that survives the next Elixir
release, and because the pin is what gives the new version check something
to compare against.

A second, affirmative reason to move forward rather than back, which the
options as framed do not capture: 1.20's set-theoretic type checker is the
only reason the fourteen `struct for X is expected on struct update` sites
are visible at all — 1.18.3 emits zero warnings on the identical tree.
Pinning to 1.20.3 therefore buys a standing type-safety gate that pinning
to 1.18.3 forfeits. The fix for those sites (an explicit struct pattern
match, the idiom ISS-0046 already merged) is ordinary Elixir, clean and
format-clean under both versions — so this gain costs nothing in
compatibility.

### The four constraints, by number

**Constraint 1 — option (a) is not executable by this pipeline.** Weighed
and rendered moot: (a) is rejected on its merits, not on its cost. Asking
the workstation owner to install 1.18.3 would move the only
confirmed-live host onto a version no record shows any host running, to
satisfy a pin whose own justification was "it is what is live" — and it
would still leave Symptom 1 failing, since the four files are unformatted
under 1.18.3 too. Rejecting (a) is also what lets this WF-03 run close
ISS-0106 without a human in the loop.

**Constraint 2 — a hard version gate can lock a host out entirely.** This
is the constraint that shapes the decision, and it is why two of the three
tempting tightenings are refused. Tightening `mix.exs` to `~> 1.18.0`
(option (d)'s second half) would make *this* host — the only host confirmed
live — unable to compile Letflow at all. Making the new version check a
hard exit-code failure would lock any surviving 1.18.3 host out of running
its own test gate: not merely blocked from committing, but unable to *see*
whether its tests pass, which is a worse outcome than the drift being
guarded against. Both are bets against a host population the records cannot
describe in the present tense.

So: **under this decision, an off-pin host is warned, never blocked.** It
compiles (`~> 1.18` admits 1.18.x through 1.x), it runs the full gate, and
it gets an exit code that reflects the actual state of the code. The
acceptable failure mode is a loud, unsuppressible, correctly-attributed
warning; the unacceptable one is a host that cannot work at all. This is
the right trade specifically because the residual risk is small and
self-announcing: the only real hazard from an off-pin host is that a
*future* `mix format` there might disagree with the pin, and the warning is
printed exactly where whoever is about to commit will read it.

**Constraint 3 — do not satisfy a gate by editing what it measures.**
Honoured, and worth being precise about, because adopting (c) could
superficially look like the forbidden move. It is the reverse. Today the
gate inspects *no* toolchain version, so there is no signal to quieten; the
change adds information that does not exist. No existing check is relaxed:
`format --check-formatted` and `compile --warnings-as-errors` keep their
exact current strictness and their exit codes, and the four files and
fourteen warning sites are fixed on their merits rather than tolerated. The
new check's only power is to *say more*. Two guards are written into the
decision above so it cannot drift into the forbidden shape later: it is not
suppressible, and it may never lower another check's exit code.

**Constraint 4 — the superseded premise.** Addressed at length under "Why
the target moved" above; summarized: it changes the target, not the
decision.

### Cross-host safety: what happens to a host still on 1.18.3

Such a host cannot be ruled out — the records establish nothing about
`~/letflow-wt2` or the hetzner host in the present tense. Under this
decision it remains **able to work, with a visible warning**. Point by
point, each resting on a measured result rather than an expectation:

- *Compiles.* `mix.exs` is unchanged at `~> 1.18`, which admits 1.18.3.
- *Passes the format check.* Output formatted by 1.20.3 is accepted by
  1.18.3's checker (measured, exit 0). The four reformatted files do not
  fail there.
- *Passes the compile check.* The struct-update fix is an explicit struct
  pattern match — clean and format-clean under both versions (measured);
  and 1.18.3 emits none of those warnings to begin with.
- *Runs the gate.* The new check warns and continues; the exit code still
  reflects the code, not the toolchain.

Degraded, not blocked, in exactly one respect: that host will see a warning
on every `mix letflow.check` run until it moves to the pin. That is the
intended pressure, and it is the informative kind.

### Scope for the implementation (ordered; for CODE-DESIGNER)

Three parts. Only Part A was blocked on this sign-off; B and C were always
independent and may proceed in parallel.

**Part A — pin and enforcement:**

1. `.tool-versions` → `elixir 1.20.3-otp-29` / `erlang 29.0.5`.
2. `mix.exs` line 8 — **no change.** Listed so the no-op is deliberate and
   auditable, not an oversight.
3. `lib/mix/tasks/letflow.check_toolchain.ex` (new) — parses
   `.tool-versions`, compares `System.version()` and
   `:erlang.system_info(:otp_release)`, warns on mismatch naming expected
   and running versions. Must degrade gracefully (warn, never crash) if
   `.tool-versions` is absent or unparseable.
4. `mix.exs` — prepend `"letflow.check_toolchain"` as the **first** entry of
   the `letflow.check` alias.
5. `README.md` Notes (lines ~149-157) — update the pinned version *and*
   delete the false "accepts any 1.18.x patch" claim, replacing it with the
   measured semantics and the reason the requirement is deliberately wider
   than the pin.
6. `docs/guides/backend_developer_guide.md:17` — replace "Elixir 1.17+ /
   OTP 26+ (the project was scaffolded on 1.14/OTP 25 via apt…)" with the
   pin; 0005's option (b) named this guide explicitly and commit `68edfbc`
   updated only `README.md`.
7. This record — done in this step; no further edit needed.

**Part B — Symptom 1, reformat (4 files, mechanical, zero conflict with
in-flight branches):** `lib/letflow/engine/pin_resolver.ex`,
`lib/letflow/engine/variable_merge.ex`,
`test/letflow/engine/pin_rebind_test.exs`,
`test/letflow/engine/pin_resolver_test.exs`.

**Part C — Symptom 2, 14 struct-update sites via ISS-0046's idiom:**
`lib/letflow/engine/transition.ex` (6), `lib/letflow/engine/reconstruction.ex`
(6), `lib/letflow/engine/sub_process.ex` (1), `lib/letflow/engine.ex` (1).

Bookkeeping outside the code change, for ORCH/DOC-UPDATER rather than
ELIXIR-DEV: `docs/issues/ISS-0106.yaml`'s stated root cause is wrong for
Symptom 1 and should be superseded (not overwritten); `docs/issues/
ISS-0046.yaml`'s UNCONFIRMED version attribution is now settled and should
get an addendum.

### One finding this decision does not fix

Three commits merged to `main` on 2026-08-20 each made a previously
format-clean file unformatted, past a format gate that was already present
and already correct. No pin, no version check, and no reformat addresses
that; it is a gate-discipline failure, and it is a more serious finding
than the drift ISS-0106 was filed for. It is out of scope for this record
and is flagged to ORCH for a separate issue.
