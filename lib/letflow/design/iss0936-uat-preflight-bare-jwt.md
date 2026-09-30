# ISS-0936 design: uat_preflight.sh accepts a bare JWT from the qa-uat-env credential source

Run: WF03-ISS0936-20261001. Owned file: `scripts/uat_preflight.sh` (embedded Python, heredoc `PYEOF`).
Predecessor: ISS-0909(d) introduced the `qa-uat-env` protocol assuming a `Token: <jwt>` line.

## 1. Problem (from step-01 diagnosis)

`fetch_credential(user)` (qa-uat-env branch, ~line 300-303) only accepts a stdout line starting with
`Token:`. The real `ai-dala-infra` `qa-uat-env.sh token <user>` prints a BARE JWT. No line matches,
the function returns `(None, None)`, and `try_login` maps kind None to `NO_PASSWORD` before any HTTP
call. Every actor login therefore reports NO_PASSWORD.

## 2. Change summary

1. Add one pure module-level helper `parse_token_line` in the embedded Python, placed immediately
   above `fetch_credential`.
2. `fetch_credential`'s qa-uat-env branch calls the helper per stdout line instead of the inline
   `startswith("Token:")` test. The qa-login branch is untouched.
3. Update the header protocol paragraph (lines ~26-38); `scripts/README.md` needs re-grep only (section 5).
4. Add one ExUnit test file (section 6) wired into the normal `mix test` run.

No change to `try_login`, `run_cred`, exit codes, JSON summary shape, or the qa-login protocol.

## 3. Helper signature and parse rules

Signature (illustration only):

    parse_token_line(line: str) -> Optional[str]      # returns the JWT, or None

Pure: no I/O, no globals, no logging, no exceptions for any str input.

Rules, applied to one stdout line at a time:

- R1 (strip): strip surrounding whitespace (including `\r`, since the source may run under
  git-bash/Windows). An empty result returns None.
- R2 (labelled form, unchanged behavior): if the stripped line starts with `Token:`, the candidate is
  the remainder after the first colon, stripped. Return it if non-empty. The labelled form is trusted
  as before and NOT subjected to the JWT shape check (an explicit declaration by the source). Empty
  remainder returns None.
- R3 (bare form): otherwise the WHOLE stripped line must fully match the JWT shape (re.fullmatch):

      ^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$

  All three segments are non-empty (Keycloak access tokens are always signed). Additionally require
  total length >= 40 (a real JWT is hundreds of chars; the floor is a cheap second guard).
- R4: anything else returns None (noise).

Why the `eyJ` prefix: base64url of `{"` is `eyJ`; every JSON-object JWT header begins with it.

Hostname rejection: `auth.qa.bizdala.com`, `qa.bizdala.com` and similar dotted strings do not start
with `eyJ`, so they fail R3; the length floor rejects any short accidental match. Lines containing
spaces (`WARN something`, `Logged in as x.y.z`) fail because the regex is a full-line match with no
whitespace allowed.

Line selection in `fetch_credential`: iterate `r.stdout.splitlines()` in order and return
`("token", value)` for the FIRST line where `parse_token_line` is non-None. Stdout only; stderr is
never scanned. Non-zero exit status handling is unchanged from today (no new gating).

## 4. No secret echo (invariant)

- `parse_token_line` and the modified `fetch_credential` must not print, log, or include the token
  (or any fragment, length, or prefix) in any message, exception text, JSON summary, or report.
- Failure diagnostics are unchanged: failure is still `NO_PASSWORD` (kind None). The existing broad
  `except Exception: pass` stays as is (see open question Q1).
- The `--out` JSON summary continues to contain no secrets; tokens stay in the in-memory `tokens` dict.
- Tests assert the token text appears in neither script stdout, stderr, nor the `--out` JSON file.

## 5. Header documentation

In the `qa-uat-env` paragraph, replace "prints a line `Token: <bearer-token>`" with wording stating:
`<script> token <actor_id>` prints the access token either as a line `Token: <bearer-token>` or as a
BARE JWT on a line by itself (three dot-separated base64url segments starting `eyJ`); other stdout
lines (warnings, hostnames, banners) are ignored; the first line that parses wins; the token is never
echoed. Keep the "verified with a single read-only GET /api/v1/me/modules" sentence and the
ISS-0909(d) pointer; add `ISS-0936`. `scripts/README.md` line 11 describes the script generically and
does not state the `Token:` form, so no change is expected; the implementer re-greps `Token:` in
`scripts/README.md` and updates any hit.

## 6. Test shape and CI wiring

### 6.1 Where and how it runs

`.github/workflows/ci.yml` runs `mix test` (plus web/mobile gates). The existing standalone
`test/scripts/*_test.sh` files are NOT invoked by CI or mix (no reference found in `.github`, `mix.exs`,
or `test/`), so a new `.sh` test would never run. Decision: the test is an ExUnit file, picked up
automatically by `mix test`:

    test/scripts/uat_preflight_bare_jwt_test.exs
    module Letflow.Scripts.UatPreflightBareJwtTest, use ExUnit.Case, async: true

It shells out via `System.cmd` to the real `scripts/uat_preflight.sh` (real code path, no
re-implementation of the parser). It needs `bash` and `python3` (the script already requires python3).
If either is missing the test fails loudly (no skipping, so no silent coverage loss). ubuntu-latest has both.

Bash resolution (host note): on this Windows host the default `bash` is the WSL stub. The test resolves
the launcher as env `UAT_PF_BASH` if set, else `System.find_executable("bash")`, and runs
`<launcher> scripts/uat_preflight.sh ...`. The script sets `UAT_PF_BASH="${BASH:-bash}"` itself (line 96),
which equals the launcher. Windows developers export `UAT_PF_BASH` to git-bash (Q3).

### 6.2 Fixtures (created per test in a tmp dir; no new repo fixtures)

- Fake credential source: a tiny executable shell script written by the test, handling
  `token <user>` by printing a per-test stdout and some stderr noise. Passed via the script's credential
  script flag with `--credential-protocol qa-uat-env` (exact flag name read from the argparse block; Q2).
- Scenario dir: a tmp dir with one minimal scenario declaring one actor `actor-swiftroute-lena`,
  modeled on a file under `test/fixtures/uat/scenarios/`. Passed with `--scenarios`.
- Base URL: required option (a) unreachable `http://127.0.0.1:9` (parse success shows as a
  non-NO_PASSWORD status such as BAD_CRED). Optional (b) a stdlib Python `http.server` stub on port 0
  returning 200 for `GET /api/v1/me/modules`, for T7; drop it if flaky.
- Fake JWT constant: `eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJl` (51 chars, passes length floor).
- Env hygiene: explicit `env` to `System.cmd`; pass a dummy `--sha` so git/origin/main is not consulted.

### 6.3 Test cases

| # | Fake source stdout | Assertion |
|---|---|---|
| T1 | noise line `WARN something`, then bare JWT line | output does NOT contain `NO_PASSWORD`; actor reached verification (e.g. BAD_CRED for unreachable URL) |
| T2 | `Token: <jwt>` | still not NO_PASSWORD (regression guard for the old form) |
| T3 | only noise (`WARN something`, banner text) | output contains `NO_PASSWORD` for the actor |
| T4 | only `auth.qa.bizdala.com` (variant `qa.bizdala.com`) | `NO_PASSWORD` (hostname-like rejected) |
| T5 | bare JWT with CRLF line ending | not NO_PASSWORD (R1) |
| T6 | runs of T1/T2 | token literal absent from script stdout, stderr and the `--out` JSON file |
| T7 (optional) | bare JWT + 200 stub | actor status OK |

Exact asserted substrings are taken from a real run of the script (step-01 reproduction showed
`login failed: <actor>(NO_PASSWORD)` in the actors check and `=BAD_CRED` in the credential validity
line); the test author captures them before writing assertions.

Pre-fix: T1, T5, (T7) fail; T2-T4, T6 pass. Post-fix: all pass.

## 7. Acceptance-criteria mapping

| Criterion | Design element |
|---|---|
| Design doc exists at path | this file |
| Covers parse rules, hostname rejection, no-secret-echo, header docs, test shape, CI wiring | sections 3, 3 (hostname rejection), 4, 5, 6.2-6.3, 6.1 |
| No implementation code beyond signatures/regex | only one signature and one regex appear |
| Handoff result filled, COMPLETED | handoff file |
| Issue: bare JWT accepted, `Token:` still works | R2, R3, T1, T2 |
| Issue: noise ignored | R4, T3 |
| Issue: header docs updated | section 5 |

## 8. Invariants

- I1: `parse_token_line` is pure and total over str.
- I2: a token value never leaves the `tokens` / `fetch_credential` return path.
- I3: qa-login behavior is byte-identical.
- I4: the labelled `Token:` form keeps its pre-fix semantics (no shape check).

## 9. Open questions (none block implementation; defaults stated)

- Q1: the silent `except Exception: pass` hides source failures (timeouts, non-zero exit). Default: out
  of scope; consider a follow-up issue for a distinct `CRED_SOURCE_ERROR` status.
- Q2: exact CLI flag name for the credential script and the minimal scenario shape. Default: read the
  script's argparse block and an existing fixture; this is discovery, not a design choice.
- Q3: a Windows developer running `mix test` without `UAT_PF_BASH` hits the WSL stub. Default: the test
  fails loudly with a message to set `UAT_PF_BASH`; Linux CI is the authority.
