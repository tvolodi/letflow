# Queue triage report -- 2026-09-30 (ORCH, tvolo-win11-orch)

Observed, decided, why. Standing rule: deciding about sibling-session state is ORCH discretion; this is the after-the-fact report.

| Task | Observed | Decision | Why |
|---|---|---|---|
| Q-890 (ISS-0890) | open, locked `ai-dala-orch` since 2026-09-29T23:56Z (~7h). Last ISS-0890 activity: triage + split PRs #2018/#2019 (00:0xZ) and DOC-UPDATER notes to 02:40Z. No open PR/branch, no handoff dir, no other locks by that holder. Umbrella; children ISS-0898..0903 worked as separate tasks. | `force` release, left `open` | Holder dead; blocked is irreversible (no blocked->open API), so kept open. Umbrella sorts last under issue LIFO. |
| Q-886 | blocked, duplicate double-registration of ISS-0886 (documented in its yaml `duplicates_closed`) | released `done` | Duplicate of a resolved issue (fix PR #2007). |
| Q-884 | blocked, ISS-0886 canonical task; released blocked 2026-09-30 only because QA backfill could not be run | released `done` | Code merged; QA was remediated manually on 2026-09-30 (see ISS-0910); remaining gap tracked by ISS-0910 / Q-899. |
| Q-887 (ISS-0892) | blocked; four code blockers merged; seeds never executed on QA | left blocked; new task Q-904 / ISS-0912 / GH-2039 | Queue cannot unblock. Remaining step is well defined, so registered as successor. |
| Q-888 (ISS-0888) | blocked; remainder is promo-proposer host secrets and master-realm admin credential (ai-dala-infra-owned) | left blocked | No letflow-side work item; infra-owned. |
| Q-897..903 | 897-902 open+eligible; Q-903 (ISS-0911) locked `tvolo-win11-orch` 06:58Z, live branch `feature/WF03-ISS0911-20260930` | left as is | Q-903 is live sibling work. |

## Claim order caveat
`get_next_task` drains issues LIFO (highest id first): expected order 904, 902, 901, 900, 899, 898, then 897. Q-897 (BLOCKER, ISS-0905) is claimed LAST by `get_next_task`; priority cannot be changed via the API. Scanners must pick it via `GET /tasks` + `set_lock` on id 897 to get it first.

## Scanner loop
No cron/scheduled trigger or loop is documented in the repo. Claimers are interactive/operator-started ORCH sessions: agent ids `ai-dala-orch` (other host) and `tvolo-win11-orch` (this workstation). Started by prompting an ORCH session (`.claude/agents/orchestrator.md`) with unscoped work ("what's next"), which calls `get_next_task` per TASK_QUEUE.md. Nothing indicates an automated loop exists.
