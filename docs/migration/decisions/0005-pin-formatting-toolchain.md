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
