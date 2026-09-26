# ISS-0848 — queue/yaml reconciliation check (design)

Queue task 848 (`Q-848`), GH-1846, S11, BLOCKER. This design covers **AC2** only
(step 1/AC1 and AC4 are already done directly by ORCH — see the issue's own
`progress_2026_09_26:` note and `docs/anti-patterns.md`'s two ISS-0848 entries).
AC3 (a live run reporting no mismatches) is ELIXIR-DEV's job once the check
exists, not designed here.

## 0. Traceability

| AC | Covered by |
|---|---|
| AC2a — "the reconciliation check exists" | §2, §3: `Mix.Tasks.Letflow.CheckQueueReconciliation`, a standalone mix task (§1 explains why it is *not* wired into `mix letflow.check`). |
| AC2b — "a test proves it flags (i) a status mismatch ... using fixtures, not the live service" | §3.2 `reconcile/2`, a pure function of `(yaml_entries, issue_entries, queue_tasks)` — no I/O, no network, fixture-friendly by construction. §5 test plan. |
| AC2c — "... and (ii) a queue_ref to a non-existent task, using fixtures" | §3.2's `:dangling_queue_ref` finding kind, produced by the same pure function. §5 test plan. |
| AC3 (not this design's job, but the tool must support it) | §4 `run/1`'s human-readable report is what ELIXIR-DEV quotes as "output" when running it live post-step-1. |

## 1. Where it runs

**Decision: a new standalone mix task, `mix letflow.check_queue_reconciliation`,
is NOT added to the `letflow.check` alias in `mix.exs`.** It is run directly —
by ORCH at session start, or on demand — never as part of the CI/local gate
sequence.

### Reasoning

- Every existing `letflow.check_*` task is a pure, hermetic, no-network scan.
  `Mix.Tasks.Letflow.CheckRequirementsRegistration`'s own moduledoc states this
  as a discipline, not an incidental fact: *"It never writes to
  `docs/requirements.yaml`, never assigns or suggests an `impl_order` value,
  and makes no network call — in particular none to letflow-queue."* Adding a
  task to the `letflow.check` alias that reaches an external HTTP service over
  the network breaks that discipline for the whole alias: `mix letflow.check`
  is the project's only CI gate (no separate CI config exists — same
  moduledoc), and CI is not a host `docs/agents/protocols/TASK_QUEUE.md`
  guarantees carries `$QUEUE_AUTH_TOKEN` — the token is documented as *"a
  sanctioned local-dev convenience"* on specific workstations' `.env` files,
  explicitly not a thing every host has. An unconditional network dependency
  in the CI gate would make `mix letflow.check` flaky (or permanently red) on
  any host/CI runner without that token or without egress to
  `queue-test.ai-dala.com`.
- `docs/migration/decisions/0017-task-queue-selection-model.md`'s own
  Consequences section anticipates exactly this fork: *"`mix
  letflow.check_requirements_registration` and `mix
  letflow.check_deferral_staleness` ... *may* now verify against the live
  queue. Not required by this record, and deliberately not scoped here."* This
  design treats ISS-0848 as the follow-up that *does* scope it, but as an
  independent task rather than folding it into either existing one — neither
  of those tasks' own hermetic contract should be broken to add a network
  call, and this check's concerns (queue liveness, not requirements-file
  shape) are a different axis from either.
- The fix_direction text itself frames this as a real choice ("CODE-DESIGNER
  decides ... a mix task ORCH runs at session start, or inside mix
  letflow.check when QUEUE_AUTH_TOKEN is present"). Making it conditional
  *inside* the alias (skip the step silently when no token) was considered and
  rejected: a step that is sometimes present and sometimes absent from the
  same named gate, depending on an environment variable no other alias step
  depends on, is a harder thing for a future reader to reason about than a
  separate task with its own name and its own "run me when you have queue
  access" contract. A standalone task is also easier to invoke ad hoc — this
  is explicitly a "run before trusting `get_next_task`" tool (per the
  adjacent anti-patterns.md entry's closing line), not a per-commit gate.

### What the task does when the token is unavailable

Per `TASK_QUEUE.md`'s own "Before concluding the token is unavailable" section,
the task's token-resolution step (§4 `resolve_queue_auth_token/0`) checks, in
order:

1. `System.get_env("QUEUE_AUTH_TOKEN")`.
2. A `QUEUE_AUTH_TOKEN=` line in a `.env` file at the repo root (read directly
   off disk — this task must not assume `.env` has been loaded into the OS
   environment by anything else).

If neither yields a token, the task prints a clear, unambiguous
`SKIPPED — no $QUEUE_AUTH_TOKEN (checked shell env and ./.env)` line and exits
**0**, not 1 — an unreachable/uncredentialed queue is a known, expected state
on many hosts (this mirrors `TASK_QUEUE.md`'s own "genuine unreachable case"
framing), and this being a standalone task never wired into any gate makes a
soft-skip safe: nothing downstream silently treats "skipped" as "passed the
gate," because there is no gate here to begin with. It is not a hard failure,
in contrast to e.g. `check_toolchain`'s `bash`-not-found case, because a
missing dev-only credential is not itself evidence of a code defect the way a
missing toolchain binary is.

## 2. Module: `Mix.Tasks.Letflow.CheckQueueReconciliation`

`lib/mix/tasks/letflow.check_queue_reconciliation.ex` (new file). Follows the
established shape of the sibling `letflow.check_*` tasks: one `Mix.Task`
module, pure logic exposed as public functions (fixture-testable, no
`Mix.shell()`/network inside them), I/O and CLI/report concerns kept in
`run/1` and its immediate helpers.

### 2.1 Reused parsing (per instructions: don't reinvent)

- **Requirements-file parsing**: reuses
  `Mix.Tasks.Letflow.CheckRequirementsRegistration.scan/1` (already public,
  already returns `%{entries: [entry()], ...}` with `id`, `status`,
  `impl_order`, `state` per entry — exactly the `{id, status, impl_order}`
  triples this check needs for every `:registered` entry). This check does
  **not** re-parse `docs/requirements.yaml` itself; it calls that module's
  `scan/1` and filters to `state == :registered` entries (a `:deferred` or
  `:neither` entry has no `impl_order` to reconcile against, by construction —
  that absence is `check_requirements_registration`'s own concern, not this
  one's).
- **Issues-directory parsing**: `Mix.Tasks.Letflow.CheckIssueRefs` exposes
  `issue_files/1` (directory listing) and `audit/2` (ref-format lints) but
  **no function that returns `{id, status, queue_ref}` triples** — its `audit/2`
  returns violations only, not parsed field values, and its `capture/2`
  helper for reading a field's value is private. This check therefore adds
  its own small line-oriented extractor, `parse_issue_file/1` (§2.2), reusing
  `CheckIssueRefs`'s established *conventions* (column-0 `key: value` lines
  only, `strip_comment/1`-equivalent quote/comment stripping, `Q-<n>`
  well-formedness via the same `~r/^Q-[1-9]\d*$/` shape) rather than its code,
  since the actual return shape needed doesn't exist yet in that module.
  (Open question §6.1: whether `CheckIssueRefs` should later be extended with
  a public `parse/1` that both tasks share — not done here, to keep this
  design's diff scoped to ISS-0848.)

### 2.2 Types

```
@type yaml_status :: String.t()   # requirements.yaml's own status: vocabulary
                                    # (done | in_progress | pending | blocked | cancelled, unvalidated beyond being a string)
@type queue_status :: String.t()   # queue's own status: vocabulary (open | blocked | done), per decision 0017 §B
@type source_kind  :: :requirement | :issue

@type source_ref :: %{
  kind: source_kind(),
  id: String.t(),               # "REQ-405" | "ISS-0848"
  yaml_status: yaml_status(),
  queue_task_id: pos_integer()  # from impl_order: (requirement) or queue_ref: "Q-<n>" (issue)
}

@type queue_task :: %{
  id: pos_integer(),
  status: queue_status(),
  title: String.t()
}
# ^ the subset of decision 0017 §B's documented GET /tasks fields this check
#   actually needs (id, status). Extra fields (locked_by, depends_on,
#   blocked_by, eligible, ...) are accepted and ignored -- see §3.1.

@type finding ::
  %{kind: :status_mismatch, source: source_ref(), queue_status: queue_status(), reason: String.t()}
  | %{kind: :dangling_queue_ref, source: source_ref()}

@type report :: %{
  sources_checked: non_neg_integer(),
  queue_tasks_seen: non_neg_integer(),
  findings: [finding()]
}
```

`source_ref` deliberately carries both `kind` and `id` (never conflates a
requirement and an issue by numeric id alone) — a requirement's `impl_order`
and an issue's `queue_ref` both resolve to the same queue-task-id space, but
`REQ-405` and `ISS-0405` are unrelated records that happen to reference
different queue tasks; findings must always be traceable back to which yaml
file/entry produced them.

## 3. Pure core (fixture-testable, no I/O)

### 3.1 `parse_issue_file/1`

```
@spec parse_issue_file(content :: String.t(), path :: String.t()) ::
        source_ref() | :unregistered | {:error, String.t()}
```

Extracts `id:`, `status:`, `queue_ref:` (column-0 fields, same convention as
`CheckIssueRefs`). Returns:

- `{:error, reason}` if `id:` is missing/malformed, or `status:` is missing.
- `:unregistered` if `queue_ref:` is `null` (an issue never registered in the
  queue — not a finding, just out of scope for this check, same as
  `check_requirements_registration`'s `:deferred` state being out of scope for
  requirements. A `null` `queue_ref` is not itself a defect;
  `check_issue_refs` R4 already gates that it carries an explaining comment).
- Otherwise a `source_ref` with `kind: :issue`, `queue_task_id` parsed from
  `Q-<n>` (strip prefix, `String.to_integer/1`).

### 3.2 `reconcile/2` — the core comparison, and the whole reason this is
testable against fixtures

```
@spec reconcile(sources :: [source_ref()], queue_tasks :: [queue_task()]) :: report()
```

Pure. Takes already-parsed data on both sides — no file reads, no HTTP. This
is the function AC2's test targets directly, per the requirement that "the
check's core logic must be testable against FAKE/fixture queue data."

Algorithm, per `source_ref`:

1. Look up `queue_task_id` in `queue_tasks` (by `id`).
2. Not found → `{:dangling_queue_ref, source: source_ref}`. This is
   `check_queue_reconciliation`'s reading of the fix_direction's "must also
   flag a queue_ref whose task does not exist" clause, generalized to both
   requirements (`impl_order`) and issues (`queue_ref`) — ISS-0848's own
   description shows both directions of drift (issues with fabricated
   `queue_ref`s *and* requirements whose `impl_order` task silently vanished
   would be equally invisible otherwise), so this finding kind is not
   issue-only despite the fix_direction wording naming only `queue_ref`.
3. Found → compare `yaml_status` against the found task's `status` via
   `status_compatible?/2` (§3.3). Incompatible → `{:status_mismatch, source:
   ..., queue_status: ..., reason: ...}` with a human-readable `reason`
   string naming which mapping rule was violated (e.g. `"yaml status \"done\"
   maps to queue {done, blocked}; queue task 796 reports \"open\""`).
4. Compatible → no finding for that source.

`report.findings` is the concatenation across all sources; `sources_checked`
and `queue_tasks_seen` are plain counts, printed unconditionally by `run/1`
even on a clean pass (same "always printed, never silent" discipline as
`check_requirements_registration`'s totality line).

### 3.3 `status_compatible?/2` — the mapping table

```
@spec status_compatible?(yaml_status :: yaml_status(), queue_status :: queue_status()) :: boolean()
```

| yaml `status:` | compatible queue `status:` values | rationale |
|---|---|---|
| `done` | `done`, `blocked` | **ISS-0836/REQ-406/REQ-407 precedent**: a requirement's yaml status was flipped to `done` before its actual completion was validated; the queue side was corrected to `blocked` (not re-opened to `open`) specifically to record "this is disputed, not simply unfinished," while the yaml itself still reads `done` pending a separate correction. A strict `done ⟺ done`-only mapping would make this check fail permanently on exactly the two records ISS-0848's own resolution intentionally left in this state, which is not a defect to keep re-reporting — it is the documented outcome. `open` is NOT compatible with yaml `done`: that is the undetected-drift shape ISS-0848 was filed over in the first place (14 tasks silently left `open` while yaml already said `done`), and must keep failing loudly. |
| `in_progress` | `open`, `blocked` | Work claimed/in flight is legitimately `open` (unclaimed-but-not-yet-picked-up is a narrower case this check doesn't distinguish — see §6.2) or `blocked` (blocked on a dependency, or blocked pending review per the ISS-0836 pattern generalized to non-done states). `done` is NOT compatible: a requirement the queue already considers finished but the yaml still calls "in progress" is worth surfacing (either the yaml is stale, or the release was premature). |
| `pending` | `open` | The queue's own "not yet started, not blocked" state. `done`/`blocked` both indicate real queue-side activity a `pending` yaml entry doesn't yet reflect — worth surfacing. |
| `blocked` | `blocked`, `open` | A yaml-side `blocked` (dependency unmet, or a human/process block) is compatible with a queue `blocked` (the direct match) and also with `open` — decision 0017 §B's own `blocked_by` field means a dependency-blocked task can still show queue `status: open` with a non-empty `blocked_by`, since `status` and eligibility are tracked separately in the queue's model; this check does not fetch/compare `blocked_by` (§6.3), so it treats yaml `blocked` loosely rather than risk a false mismatch it cannot actually resolve without that extra field. `done` is NOT compatible: a genuinely-completed queue task under a yaml entry still marked `blocked` is stale in the yaml, worth surfacing. |
| `cancelled` | `open`, `blocked`, `done` | Cancelled work has no reliable queue-side counterpart in this project's current registration flow (queue tasks are never registered as "cancelled" — `letflow-queue`'s status vocabulary per decision 0017 §B is `open`/`blocked`/`done` only). Any queue status is accepted for a cancelled yaml entry rather than inventing a rule this check can't actually verify; effectively a no-op comparison, documented as such rather than silently matching by accident. Flagged as an open question (§6.4) rather than resolved further, since ORCH/REVIEWER may want a stricter rule once cancelled-with-a-real-queue-task becomes a real, observed case. |

Every mapping direction not listed above (i.e. anything not explicitly
compatible) is a `:status_mismatch`. The table is total over the five yaml
statuses observed in `docs/requirements.yaml`/`docs/issues/*.yaml` today
(`done`, `in_progress`, `pending`, `blocked`, `cancelled` — confirmed via a
live grep of both corpora during this design session); an unrecognized
**yaml** status value is treated as its own hard-fail case (`status_mismatch`
with `queue_status: "n/a"` and a reason naming the unrecognized yaml status),
never silently passed — same "no everything-else-is-fine branch" discipline
`check_requirements_registration`'s moduledoc calls out for its own
classifier.

## 4. I/O wrapper: `run/1`

```
@impl Mix.Task
@spec run([String.t()]) :: :ok
```

1. `resolve_queue_auth_token/0` (§1) — on `:none`, print the SKIPPED line and
   return `:ok` (exit 0).
2. On a token: read `docs/requirements.yaml` via
   `CheckRequirementsRegistration.scan/1`, filter to `:registered` entries,
   map each to a `source_ref` (`kind: :requirement`).
3. Read every `docs/issues/*.yaml` file (reusing
   `CheckIssueRefs.issue_files/1` for the directory listing), run
   `parse_issue_file/1` on each, keep only the real `source_ref`s (drop
   `:unregistered` silently — expected state, not a finding; hard-fail
   immediately on any `{:error, reason}`, printing which file and why, same
   as the sibling tasks' R6-style "can't even read the input" failure mode).
4. `fetch_queue_tasks/1` (the only network call in this module): `GET
   https://queue-test.ai-dala.com/tasks` via `:httpc` (mirrors
   `Letflow.Webhooks.do_dispatch_http/3`'s own use of `:httpc` — no new HTTP
   client dependency), `Authorization: Bearer <token>` header, decode with
   `Jason.decode!/1` (already a project dependency), reading the task list
   from the **`"tasks"`** key — per REQ-222's own acceptance criterion
   (`docs/requirements.yaml`: "GET /tasks with a valid bearer token returns
   200 and a JSON body with a `\"tasks\"` key whose value is a list covering
   every task in the database"), and independently confirmed empirically:
   ORCH's own live `GET /tasks` call earlier in this same session parsed the
   response as `%{"tasks" => [...]}`, not `%{"data" => [...]}`. **This is a
   DIFFERENT envelope shape from `register_task`'s POST response**
   (`{"error": ..., "data": {...}}`, a single created-task object) — do not
   assume the two endpoints share a shape; `docs/anti-patterns.md`'s
   "Retrying a `register_task` POST after misreading its success response"
   entry is about that other, `data`-keyed endpoint and does not apply here
   directly, though the general lesson (read the actual documented/observed
   key, don't assume) is the same one this correction re-applies. A non-2xx
   response, a JSON-decode failure, or a response missing the `"tasks"` key
   entirely is a hard `Mix.raise` (network/service failure or an unexpected
   response shape is not a clean "no mismatches" pass).
5. `reconcile/2` on the combined `sources` and the fetched `queue_tasks`.
6. Print the report (counts + full finding list, same "always printed"
   discipline as the sibling checks) and exit `0` iff `findings == []`,
   `Mix.raise/1` otherwise, naming every finding (kind, source id, queue task
   id, reason) so the raised message alone is enough to act on without
   re-running.

### 4.1 `resolve_queue_auth_token/0`

```
@spec resolve_queue_auth_token() :: {:ok, String.t()} | :none
```

Checks `System.get_env("QUEUE_AUTH_TOKEN")` first, then a `QUEUE_AUTH_TOKEN=`
line in `./.env` (plain line-oriented read, matching this project's existing
"no YAML/dotenv dependency for a lint-adjacent tool" discipline — see
`check_requirements_registration`'s own "Parsing model" section reasoning
applied here to `.env` instead of YAML).

## 5. Test design pointers (for TEST-DESIGNER, not written here)

AC2's own wording ("using fixtures, not the live service") is satisfied
entirely through `reconcile/2` (§3.2), which never touches the network or the
filesystem:

- **Fixture (i) — status mismatch**: a `source_ref` with `kind: :requirement,
  yaml_status: "done", queue_task_id: 999` against a `queue_tasks` fixture
  list containing `%{id: 999, status: "open", ...}` (mirrors the ISS-0848
  finding shape verbatim: yaml says done, queue says open). Assert
  `reconcile/2`'s result contains exactly one `:status_mismatch` finding for
  that source. A companion fixture using `status: "blocked"` instead of
  `"open"` for the same `yaml_status: "done"` source must assert **zero**
  findings — this is the ISS-0836/REQ-406/REQ-407 precedent case, and a test
  suite that only exercises the mismatch direction would not actually prove
  the mapping table's most load-bearing exception is implemented correctly.
- **Fixture (ii) — dangling queue_ref**: a `source_ref` with `queue_task_id:
  99999` against a `queue_tasks` fixture list that does not contain id
  `99999`. Assert exactly one `:dangling_queue_ref` finding.
- Both fixtures constructed as plain `source_ref()`/`queue_task()` maps
  in-test — no `docs/issues/` or `docs/requirements.yaml` fixture files needed
  for these two cases, since `reconcile/2`'s inputs are already the parsed
  shape.
- Separately (still fixture-based, not live-service): `parse_issue_file/1`
  against small in-memory YAML-ish strings, mirroring
  `CheckAsyncSandboxReachability.async_true_file?/1`'s own "pass a synthetic
  string, not a file" pattern — covering a well-formed `queue_ref: "Q-N"`
  line, a `queue_ref: null` line (→ `:unregistered`), and a missing/malformed
  `id:` line (→ `{:error, _}`).
- `fetch_queue_tasks/1` and `resolve_queue_auth_token/0` (the two I/O-touching
  functions) are deliberately **not** unit-tested against the live service
  from `mix test` — consistent with this project's established
  discipline against network calls inside the test suite. If TEST-DESIGNER
  wants coverage of the JSON-envelope-unwrapping logic specifically, it
  should be factored as its own pure function (e.g. `decode_tasks_response/1`
  taking a raw JSON string) so it can be fixture-tested the same way — flagged
  here as a recommendation, not mandated, since AC2 only requires the two
  named scenarios.

## 6. Open questions (deliberately not resolved here)

1. **`CheckIssueRefs` reuse gap** (§2.1): should it later grow a shared
   `parse/1` returning structured fields, so this check and any future one
   don't each hand-roll a column-0 extractor? Not done here to keep this
   change scoped to ISS-0848; flagging so ELIXIR-DEV doesn't assume it was
   considered and rejected.
2. **`in_progress` vs. `open`-but-unclaimed**: this check's mapping table
   (§3.3) does not distinguish a queue task that is `open` and genuinely
   unclaimed from one that's `open` but a stale lock was force-cleared — both
   read as plain `status: "open"` from `GET /tasks` per decision 0017 §B's
   field list (which separately exposes `locked_by`/`locked_at`, not folded
   into `status`). This check does not fetch or reason about `locked_by`; a
   task locked by a long-dead session still reads as a clean `open`/`done`
   compatibility match. Left as a real gap, not a silent assumption.
3. **`blocked_by` not fetched**: §3.3's `blocked` row's looseness (accepting
   `open` for yaml `blocked`) is a direct consequence of not reading
   `blocked_by`. A future revision could fetch it and require it be
   non-empty for `open` to count as compatible with yaml `blocked` —
   tightening the rule — but that's out of scope for this pass.
4. **`cancelled` mapping is a no-op** (§3.3's last row): revisit if a
   genuinely cancelled requirement/issue is ever found still holding a live,
   non-`done` queue task — this design has no case to learn from yet.
5. **Filtering `GET /tasks` server-side**: decision 0017 §B says the endpoint
   is "filterable by `status`, `task_type`, `stage`, `eligible`." This design
   fetches the full unfiltered list once per run (simpler, and the corpus is
   currently ~850 tasks — cheap for a single GET) rather than filtering
   server-side or paginating; revisit if task volume makes an unfiltered pull
   noticeably slow.
