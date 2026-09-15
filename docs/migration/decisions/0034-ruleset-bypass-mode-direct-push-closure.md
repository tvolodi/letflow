# 0034 — Repository rulesets close the direct-push gap classic branch protection couldn't

Status: decided (2026-09-15, `ORCH`, ISS-0678). Owner: `ORCH` (research and this record) /
whoever applies the configuration to the real repo next (explicitly **not** done by this
record — see "What this record does not do").

## Question

ISS-0678, filed as a fast-follow from ISS-0677/0018's "no direct push to `main`, ever"
prose-only fix: `main`'s branch protection (0018) uses classic branch protection, whose
`restrictions` field (who may push) cannot distinguish "this pipeline's PR merges" from
"a bare `git push origin main`" because both authenticate as the same single admin
identity (`tvolodi`) — an allowlist naming that identity accepts the exact bypass it
needs to reject (live-confirmed under 0018, "A real gap found live" section: a bare push
succeeded with only an informational `Bypassed rule violations` line).

GitHub's newer **repository rulesets** (distinct from classic branch protection) support
a `bypass_actors` list on each ruleset. The open question: does bypass-list scoping
genuinely let the same identity bypass "require pull request before merging" for
legitimate PR merges while remaining genuinely blocked from a bare push? This had to be
verified empirically, not assumed from documentation, because the classic-protection
`restrictions` gap it resembles was *also* plausible-sounding until 0018 tested it live
and found the informational-bypass failure mode.

## Method

**Documentation review** (GitHub's rulesets docs, fetched 2026-09-15): rulesets support
rule types including `pull_request` (require PR before merging), `non_fast_forward`
(block force pushes), `deletion` (restrict deletions), and others. Each ruleset carries
one `bypass_actors` array. Per the REST API schema
(`docs/rest/repos/rules`), each bypass-actor entry is `{actor_id, actor_type,
bypass_mode}` — **`bypass_actors` is scoped to the whole ruleset, not to individual rule
types within it.** There is no field that lets one actor bypass `pull_request` but not
`non_fast_forward` inside the same ruleset. This means the issue's own framing —
"the bypass list could be scoped to only the 'require pull request' rule type" — is
**not how rulesets actually work**, and confirming that in the abstract would have wrongly
closed this research as "(b), rulesets don't help."

But `bypass_mode` itself has two values GitHub's docs don't explain in prose: `always`
and `pull_request`. The API schema's own description of `pull_request` mode — "an actor
can only bypass rules on pull requests" — is a *different* axis of scoping than per-rule
scoping: it scopes bypass by **which git operation the actor is performing**, not by
which rule fires. A bare `git push` is not "on a pull request," so a `pull_request`-mode
bypass actor gets no bypass at all for that operation — every rule in the ruleset,
`pull_request` (require-PR) included, applies to them exactly as if they had no bypass
entry. This is the mechanism actually worth testing, and it is different from what
ISS-0678 speculated, so it had to be verified live rather than assumed correct by
analogy.

**Empirical test**, disposable repo `letflow-ruleset-test-0655` (public GitHub repo under
the same `tvolodi` account used only for this test):

1. Created a ruleset on `main` with rules `pull_request`, `non_fast_forward`, `deletion`,
   and one bypass actor: `{actor_type: "User", actor_id: <tvolodi's id>, bypass_mode:
   "pull_request"}`.
2. **Bare push attempt**, as `tvolodi` (the bypass actor): `git push origin main` with a
   direct commit. **Rejected** — real server response:
   ```
   remote: error: GH013: Repository rule violations found for refs/heads/main.
   remote: - Changes must be made through a pull request.
   ! [remote rejected] main -> main (push declined due to repository rule violations)
   ```
3. **Legitimate PR-based change**, same identity: pushed a feature branch, opened PR #1,
   ran `gh pr merge 1 --squash --delete-branch`. **Succeeded** — `gh pr view 1` confirmed
   `"state":"MERGED"`, `"mergedBy":{"login":"tvolodi"}`.
4. **Contrast test** — reconfigured the same ruleset's bypass entry to `bypass_mode:
   "always"` (nothing else changed) and repeated the bare-push attempt. **Succeeded** this
   time, with the exact same informational-only failure mode 0018 already documented for
   classic protection's `restrictions` gap:
   ```
   remote: Bypassed rule violations for refs/heads/main:
   remote: - Changes must be made through a pull request.
      4d5df8f..900c57c  main -> main
   ```

Steps 2–4 are the decisive result: the *only* variable changed between the blocked
attempt and the successful one was `bypass_mode` (`pull_request` vs `always`) on the same
ruleset, same rule set, same identity, same repo. This isolates `bypass_mode:
"pull_request"` as the specific mechanism that closes the gap — not "rulesets" generically
(a ruleset with `bypass_mode: "always"` reproduces 0018's exact gap), and not per-rule
bypass scoping (which does not exist).

**Cleanup**: the test repo was made private immediately after the test concluded. Full
deletion could not be completed by this agent — `gh repo delete` failed with `HTTP 403:
Must have admin rights to Repository... needs the "delete_repo" scope`, and granting that
scope (`gh auth refresh -h github.com -s delete_repo`) requires an interactive
device-code browser authorization this agent cannot complete unattended. **The repo
(`tvolodi/letflow-ruleset-test-0655`, now private) is not yet deleted; this is flagged to
the user directly, not left silent** — either the user grants the `delete_repo` scope (the
device flow was left uncompleted, not carried out on their behalf) or deletes the repo
manually via its Settings → Danger Zone.

## Finding

**Repository rulesets, specifically `bypass_mode: "pull_request"` on the bypass actor,
close the gap 0018 found and ISS-0677 could only patch with prose.** The shared admin
identity can:
- **Not** bypass `main`'s `pull_request` rule for a bare push — GitHub's own rule engine
  rejects it before it reaches the git ref, with a distinct machine-checkable error
  (`GH013`), not an advisory message the agent could fail to notice.
- Still merge legitimate PRs normally, with no `--admin`-equivalent flag needed for the
  ordinary path (0018's required-status-checks override mechanism composes with this
  unchanged — a ruleset's `pull_request` rule only requires *an open PR*, it says
  nothing about required checks, which stay configured separately, classic-protection or
  ruleset-native).

This is a **materially different, and better, mechanism** than what 0018's own
`restrictions: null` decision rejected — 0018 rejected `restrictions` because it can only
gate *who* pushes, not *in what context*, and one identity does both the legitimate
merges and the (undesired) bare pushes. `bypass_mode: "pull_request"` gates *context*
(is this ref update happening as part of a pull-request merge, or not) rather than
*identity*, which is exactly the axis this repo's single-shared-admin-identity constraint
needed and classic branch protection had no field for.

## Recommendation: (a) — adopt rulesets, concrete configuration proposed, NOT applied

Propose replacing `main`'s classic branch protection (0018's configuration) with a
ruleset carrying this shape (sketch — exact `contexts`/status-check names must be
re-verified against `ci.yml` at apply time per 0018 Step 1's own discipline, not assumed
from this sketch):

```json
{
  "name": "main-protection",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/heads/main"], "exclude": [] } },
  "bypass_actors": [
    { "actor_type": "User", "actor_id": "<tvolodi's numeric id>", "bypass_mode": "pull_request" }
  ],
  "rules": [
    { "type": "pull_request", "parameters": { "required_approving_review_count": 0 } },
    { "type": "non_fast_forward" },
    { "type": "deletion" },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [
          { "context": "Backend gate (mix letflow.check)" },
          { "context": "Frontend gate (npm run check)" }
        ]
      }
    }
  ]
}
```

Notes on this sketch, carried over from 0018 rather than re-litigated:
- `required_approving_review_count: 0` mirrors 0018's `required_pull_request_reviews:
  null` reasoning — no human reviewer role exists in this pipeline; inventing a
  GitHub-review requirement would duplicate what WF-02/WF-03 already gate procedurally.
- The `required_status_checks` rule reproduces 0018's two required contexts; 0018's own
  override reasoning (attribute-then-`--admin`) still needs a path under rulesets — this
  sketch's `bypass_mode: "pull_request"` bypass actor covers it, since the override
  happens on a PR merge, never a bare push, so the same bypass actor that unblocks normal
  PR merges also covers the attributed-failure override case. This needs its own live
  re-verification (does `gh pr merge --admin` still work, or does the ruleset use a
  different override affordance?) before being relied on — **not verified by this
  record's test**, which did not exercise a required-status-check rule at all.
- `non_fast_forward` and `deletion` reproduce 0018's `allow_force_pushes: false` /
  `allow_deletions: false`.

**Applying this to the real `tvolodi/letflow` repository is explicitly out of scope for
this record and was not done.** This research task's own instructions require it: a live
change to the production repo's branch protection / ruleset configuration is a
higher-stakes action than researching and proposing one, and requires the user's explicit
authorization before any agent runs the `POST .../rulesets` call against the real repo.
Whoever applies this must re-verify the `required_status_checks` override interaction
(the one gap this record's test did not cover) before treating the sketch above as final.

## What this record does not do

- Does not modify `tvolodi/letflow`'s actual branch protection or create any ruleset on
  it. Confirmed: `gh api repos/tvolodi/letflow/rulesets` and
  `gh api repos/tvolodi/letflow/branches/main/protection` were not called with any
  mutating method during this research; the only mutating calls made were against the
  disposable `letflow-ruleset-test-0655` repository.
- Does not verify the override path for `required_status_checks` under a ruleset ("what
  is the ruleset-native equivalent of `gh pr merge --admin` when a required check is
  red") — flagged above as the one gap left for whoever applies this.
- Does not resolve GIT_MERGE.md's or 0018's own text yet — per this issue's own
  acceptance criteria, that update happens once the configuration is actually adopted,
  which requires the separate authorization named above. GIT_MERGE.md's existing
  prose-only "no direct push, ever" rule (ISS-0677) remains the operative, currently
  enforced rule; this record does not weaken or supersede it — it proposes a mechanical
  reinforcement of the same rule, not yet applied.

## Outstanding: test repo cleanup

`tvolodi/letflow-ruleset-test-0655` was created for this record's empirical test, is now
**private**, and is **not yet deleted** — this agent's GitHub token lacks the
`delete_repo` OAuth scope, and granting it requires an interactive device-code
authorization (`gh auth refresh -h github.com -s delete_repo`) this agent left
uncompleted rather than push through unattended. This is surfaced to the user directly
in this record and in the handoff report; it is not a silent gap.
