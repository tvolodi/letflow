# WF03-ISS0258-20260822 — Step 3b — SECURITY-REVIEWER scope test

**Verdict:** OUT_OF_SCOPE (recorded explicitly, not skipped)
**Applied by:** ISSUE-FIXER as run driver, per `.claude/agents/security-reviewer.md` §"Scope
test — does this handoff apply to you?", which directs that a diff touching none of the
listed paths be recorded explicitly as out of scope rather than routed.

The run brief required this be stated with the test actually applied — "an agent skipping
the scope test is exactly how a genuinely in-scope change slips through unreviewed."

## The test, applied to the real diff (not to the change's description)

Diff measured as `git diff --stat 8b728d7 HEAD`:

    docs/agents/protocols/TASK_QUEUE.md                |  27 +
    docs/issues/ISS-0258.yaml                          |  68 +
    docs/requirements.yaml                             |   2 +-
    handoffs/WF03-ISS0258-20260822/*.md                | 714 +
    lib/letflow/design/iss0258-...md                   | 991 +
    lib/mix/tasks/letflow.check_deferral_staleness.ex  | 884 +
    lib/mix/tasks/letflow.check_requirements_registration.ex |  17 +
    mix.exs                                            |   1 +

| criterion | result |
|---|---|
| Adds/modifies an API route reading or writing tenant-scoped data | **NO** — `git diff --name-only 8b728d7 HEAD \| grep -cE 'routers/\|router\.ex'` → `0` |
| Adds/modifies a `priv/repo/migrations/*.exs` migration | **NO** — `grep -c 'priv/repo/migrations'` → `0` |
| Adds/modifies anything resolving a secret (config, env var, token) | **NO** — `grep -cE 'secret\|config/'` → `0` |
| Adds/modifies response-shaping code for a tenant-scoped entity | **NO** — no web/serialisation code in the diff |
| Adds/modifies a lookup-by-ID handler | **NO** — no data-access code in the diff |

**Out of scope — no tenant-data path touched.**

The only two `lib/` files in the diff are Mix tasks. Both are build-time developer tooling:
they `File.read/1` exactly one path (`docs/requirements.yaml`), write nothing, open no
socket, make no network call — in particular none to letflow-queue — and touch no `Repo`,
no schema, no tenant id, and no credential. There is no runtime code path from the
application to either module; they are reachable only from `mix`.

Note the change reaches *no further* than the design allowed: the change to the existing
`letflow.check_requirements_registration.ex` is **+17 lines, 0 deletions** — additive
only, consistent with the design's bounded "raw status token" addition.

**Not a judgement that security does not matter here — a measured finding that no
invariant in `security-invariants.md` has a surface in this diff to apply to.**
