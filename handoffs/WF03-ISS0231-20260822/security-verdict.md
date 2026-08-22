# SECURITY-REVIEWER verdict — WF03-ISS0231-20260822

- **Agent:** SECURITY-REVIEWER
- **Run:** WF03-ISS0231-20260822 (WF-03 Step 3 gate)
- **Branch:** `fix/WF03-ISS0231-20260822`
- **Diff reviewed:** `git diff main...HEAD` (commits 9504316, 309880a, 282956e, 06db5ea)
- **Verdict:** `OUT_OF_SCOPE` (equivalent to `status: PASS` — non-blocking)

## Diff surface

```
docs/agents/protocols/TASK_QUEUE.md                              |  10 +-
docs/issues/ISS-0221.yaml                                        |  87 +-
lib/letflow/design/iss0231-...-drift-detection.md                | 908 +
lib/mix/tasks/letflow.check_requirements_registration.ex         | 585 +
mix.exs                                                          |   1 +
```

No `priv/repo/migrations/*.exs`. No Ecto schema. No API route or router change.
No `lib/letflow/` *code* (the only `lib/letflow/` path is a design `.md`).

## Scope test (from `.claude/agents/security-reviewer.md`)

| Scope criterion | Result |
|---|---|
| API route reading/writing tenant-scoped data | No — no route, plug, or controller touched |
| `priv/repo/migrations/*.exs` migration | No — none in diff |
| Anything resolving a secret (config, env var, token) | No — verified below, no env/config read added |
| Response shaping for a tenant-scoped entity | No — sole output sink is `IO.write/1` to stdout |
| Lookup-by-ID handler | No — no data-access path introduced |

Resolves to **out of scope: no tenant-data path touched.** The change is pipeline
meta-tooling that reads one repo-local documentation file and prints a report.
The prior ORCH assessment is **independently confirmed**, not accepted on assertion —
the five specific checks below were run against the actual code.

## Requested verifications

**1. Anything beyond `docs/requirements.yaml`?** No.
Single I/O call: `File.read(@requirements_file)` at line 194, with
`@requirements_file "docs/requirements.yaml"` — a module-attribute literal, not
caller- or env-derived. Grep for `File.write|File.rm|File.cp|File.open|File.stream|
File.mkdir|File.ls|File.cd|System.cmd|System.get_env|System.put_env|:os.cmd|:httpc|
HTTPoison|Req.|Finch|Code.eval|String.to_atom` over the module returns **zero hits**.
No directory walking, no write, no network, no shell-out, no env-var read, no atom
creation from file content.

**2. Interpolation into a shell command / query / exfiltrating sink?** No.
The only sinks are `IO.write/1` (line 207) and `Mix.raise/1` (lines 199, 212).
File-derived text reaches a message in exactly two places, both `inspect/1`-escaped
(`inspect(String.trim(line))` in `classify_registration/2`, `inspect(reason)` in the
R6 read-failure raise). No `System.cmd`, no `:os.cmd`, no SQL, no HTTP. stdout is the
only sink — confirmed.

**3. `TASK_QUEUE.md` auth/token guidance altered?** No.
The edit is a single hunk at lines 261-271, replacing one sentence about how to record
an unregistered `impl_order` deferral. It touches no `QUEUE_AUTH_TOKEN` example, no
bearer/header guidance, no auth section. A grep for `QUEUE_AUTH_TOKEN|Bearer` across the
**entire** `main...HEAD` diff returns zero hits, so no token name and no token value
appears anywhere in the change. The INV-4 hardcoded-secret heuristic
(`(password|secret|client_secret|token)\s*(=|:)\s*["'][^"']{8,}`) run over the whole
diff also returns zero hits.

**4. Can the added `letflow.check` alias entry become a denial-of-gate?** No, on
current evidence.
- *Unbounded read:* the file is read whole (`File.read/1`) and split once —
  `docs/requirements.yaml` is a repo-tracked documentation file of bounded size, not
  attacker-supplied input. Single linear pass; no quadratic scan over entries.
- *Pathological backtracking:* all nine regexes (lines 145-153) are line-anchored with
  no nested quantifiers and no alternation inside a repetition — the classic
  `(a+)+`-shaped catastrophic-backtracking construct is absent. Worst case is linear
  in line length.
- *Raise on a legitimately-shaped file:* executed against the real tree —
  `mix letflow.check_requirements_registration` printed its roster and exited **0**
  (`111 entries = 90 registered + 21 deferred + 0 neither + 0 unclassified`). The gate
  does not fire on the repository's current, legitimate `docs/requirements.yaml`.
- *Non-blocking advisory (not a gate failure):* `@requirements_file` is a relative path,
  so R6 raises if the task is invoked with a cwd other than the project root. Mix tasks
  always execute at project root, so this is not reachable in the wired path.

**5. `docs/requirements.yaml` unmodified by this branch?** Confirmed.
`git diff main...HEAD -- docs/requirements.yaml` produces **empty output**. The branch
adds a checker for that file without editing the file it checks.

## Invariant assessment (INV-1 .. INV-8)

| Inv | Verdict | Basis |
|---|---|---|
| **INV-1** Tenant data isolation | NOT-APPLICABLE | INV-1 is live (S1 done, S2 migrations exist) and was tested against the diff rather than skipped by default. The diff contains no migration, no Ecto schema, no tenant-scoped table, and no query of any kind — sub-checks (a)/(b)/(c) have no subject. |
| **INV-2** Server-side field authorisation | NOT-APPLICABLE | No API response type; S4 not started. |
| **INV-3** Untrusted runtime sandboxing | NOT-APPLICABLE | No Lua/WASM; S5 not started. |
| **INV-4** Secrets by reference only | **APPLIES — PASS** | Live invariant. Module reads no env var and no config; adds no secret to any log, message, or serialised payload. Diff-wide hardcoded-secret grep: zero hits. `TASK_QUEUE.md` auth/token guidance untouched; no token value in the diff. `.env` untouched by the branch. |
| **INV-5** Not-found/forbidden indistinguishability | NOT-APPLICABLE | No lookup-by-ID endpoint; S4 not started. |
| **INV-6** New paths prove their scoping | **APPLIES — PASS** | No new data-access path is introduced; this handoff is the required explicit per-invariant statement. |
| **INV-7** No SQL string interpolation | **APPLIES — PASS** | Live invariant. `Repo.query` grep over the diff: zero hits. No SQL, raw or composed, anywhere in the change. |
| **INV-8** No unhandled crashes on realistic failure paths | **APPLIES — PASS** | Live invariant. The one I/O call is handled as `case File.read(...) do {:ok, _} / {:error, reason}`, not a bare match. `^\s*\{:ok, .*\} = ` grep over the new module: zero hits. `scan/1`'s own contract states malformed content yields violations rather than raising, and the raise on violation is the task's intended gate semantics, not an unhandled crash. |

Engaged invariants: **INV-4, INV-6, INV-7, INV-8 — all PASS.**
INV-1, INV-2, INV-3, INV-5: NOT-APPLICABLE, each by an explicit test against the diff.

## Result

`OUT_OF_SCOPE` — no tenant-data path touched. The live invariants were run anyway and
are clean, so this is also a `PASS` on every applicable invariant. **No BLOCKER. Not
routed back to ELIXIR-DEV.** WF-03 may proceed past Step 3.
