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
which equals the launcher. Windows developers export `UAT_PF_BASH` to git-bash (Q2).

WSL-stub detection (mechanism): all tests call one shared helper `run_preflight/2` that, right after
`System.cmd` returns, asserts the combined output contains the report header `UAT PREFLIGHT  environment=qa`
(printed by the script's report section, always reached on a working launcher regardless of GAPs). If it is
absent (WSL stub, missing python3, usage error), the helper fails with a message that includes the launcher
used, the first 500 characters of the output, and the hint "set UAT_PF_BASH to a real bash (git-bash on
Windows)". No separate probing of the launcher is done.

### 6.2 Invocation and fixtures (all created per test in `@tag :tmp_dir`; no new repo fixtures)

Command line (flags verified against scripts/uat_preflight.sh lines 112-114):

    <launcher> scripts/uat_preflight.sh --base-url <URL> --environment qa
        --credential-source <tmp>/cred.sh --credential-protocol qa-uat-env
        --scenarios <tmp>/scenarios --sha deadbeef --idp-url <URL> --out <tmp>/out.json

`--sha deadbeef` keeps git/origin/main out of the run. `--idp-url <URL>` is set to the SAME URL as
`--base-url` in every test (hermetic): without it the script derives `https://auth.<host>` (line 132), i.e.
`https://auth.127.0.0.1`, and the realm discovery GETs (script lines ~384-386) would attempt real DNS/HTTPS. The whole run exits 1 (ENV_NOT_READY) in T1-T6
because the unreachable base URL makes `/health` a GAP; tests therefore assert on output text, NOT on
exit code, except T7 (see below). `System.cmd` is called with `stderr_to_stdout: true` (it cannot capture the two streams separately), so
all assertions, including T6, run against the combined output; the fake source's own stderr is consumed
inside the script's subprocess and never reaches it.

- Fake credential source `<tmp>/cred.sh`: written by the test, invoked by the script as
  `bash cred.sh token <user>`. It writes a per-test noise line to stderr and the per-test payload of
  section 6.3 to stdout (payload embedded via a quoted heredoc so no shell expansion occurs). Any
  other first argument prints nothing.
- Scenario fixture: ONE file `<tmp>/scenarios/swiftroute/t.yaml` (the script globs `**/*.yaml`
  under `--scenarios`, skipping `_throwaway`; `parse_scenario` uses PyYAML when installed, else a
  regex fallback that reads top-level `id`, `company_id`, and an `actors:` block of indented
  `label: actor-...` lines). Exact content (three keys, nothing else, so both parser paths agree):

      id: t
      company_id: swiftroute
      actors:
        dispatcher: actor-swiftroute-lena

  No `process_id` (definitions check is then OK/n-a), no `pipeline_test` (spec check OK), label
  `dispatcher` is not a "candidate" label so the app_roles check uses `GET /api/v1/tasks/inbox`.
  Derived realm for the actor is `swiftroute`.
- Fake JWT constant `@jwt`: `eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJl` (49 chars: 20 + 1 + 15 +
  1 + 12; passes the >= 40 floor).
- Base URL and IdP URL, T1-T6: both `http://127.0.0.1:9` (nothing listens; every HTTP call returns status 0, so a
  parsed token ends as BAD_CRED, which is how "reached verification" shows up).
- Base URL, T7 (decision: IN): a stub HTTP server started inside the test with `:gen_tcp.listen(0,
  [:binary, active: false, reuseaddr: true])` (port 0, real port read back with `:inet.port/1`), served
  by a `Task` accept loop that reads one request and answers EVERY GET, whatever the path, with
  `HTTP/1.1 200 OK`, `Content-Length: 2`, `Connection: close`, body `{}`; closed in `on_exit`. The script
  issues GETs (verified against the script) to `/health` (twice: global check and SHA probe), exactly two
  realm paths `/realms/swiftroute/.well-known/openid-configuration` and
  `/realms/bpm-default/.well-known/openid-configuration` (served by the stub because `--idp-url` equals the
  base URL), `/api/v1/me/modules` (token check) and `/api/v1/tasks/inbox` (app_roles); a catch-all 200
  covers all of them, and since no seeded `admin-user` exists, `/api/v1/tenants` and `/api/v1/version`
  are not requested. Because `{}` carries no tenant list the tenant check is UNKNOWN, so T7 asserts on
  text, not on exit code. The loop accepts connections repeatedly (one request per connection) until
  closed in `on_exit`.
  No new dependency; the script's `urllib` talks plain HTTP/1.1 with
  `Connection: close` so a one-request-per-connection loop suffices.

### 6.3 Test cases and exact assertions

Let A = `actor-swiftroute-lena`. All assertions are substring checks on captured stdout.
Script-verified message forms: actors detail `login failed: <A>(<STATE>)`; credential-validity line
`<A>@swiftroute=<STATE>` (present only after a login attempt reached verification; with no attempt the
line reads `credential validity   : none checked`).

| # | Fake source stdout (stderr always gets a `noise on stderr` line) | Required substrings | Forbidden substrings |
|---|---|---|---|
| T1 | `WARN something` line, then `@jwt` line | `login failed: A(BAD_CRED)` and `A@swiftroute=BAD_CRED` | `NO_PASSWORD` |
| T2 | `Token: @jwt` | `A@swiftroute=BAD_CRED` | `NO_PASSWORD` |
| T3 | `WARN something` and `Logged in as lena.x.y` (noise only) | `login failed: A(NO_PASSWORD)` and `credential validity   : none checked` | `BAD_CRED` |
| T4 | only `auth.qa.bizdala.com`; second sub-case only `qa.bizdala.com` | `login failed: A(NO_PASSWORD)` | `BAD_CRED` |
| T5 | `@jwt` followed by a CR LF line ending (written \r\n, emitted by the fake source with `printf '%s\r\n' "$JWT"`) | `A@swiftroute=BAD_CRED` | `NO_PASSWORD` |
| T6 | same as T1, run with `--out` | `@jwt` (the full literal and its first segment `eyJhbGciOiJSUzI1NiJ9`) absent from the combined output and the `--out` JSON file | the JWT literal |
| T7 | `@jwt` line, base URL = stub | `credential validity   : A@swiftroute=OK`; and actors cell not a GAP, i.e. stdout has no `login failed` | `NO_PASSWORD`, `BAD_CRED` |

"OK" for T7 means exactly: the token check `GET /api/v1/me/modules` returned 200 so `try_login` returned
OK, evidenced by the `A@swiftroute=OK` validity entry and absence of `login failed`.

T5 note: the script reads the source with `subprocess.run(..., text=True)` (script line ~264), whose universal-newline
mode turns CR LF into LF before `parse_token_line` sees the line, so T5 is an end-to-end guard that a
CRLF-emitting source works; it does not by itself exercise rule R1's strip (R1 stays as defence in depth).

Pre-fix: T1, T5, T7 fail (NO_PASSWORD); T2, T3, T4, T6 pass (T6 passes trivially pre-fix, it is a
guard). Post-fix: all pass.

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

## 9. Open questions

- Q1: the silent `except Exception: pass` hides source failures (timeouts, non-zero exit). Explicitly
  out of scope for ISS-0936; a follow-up issue may add a distinct `CRED_SOURCE_ERROR` status.
- Q2: a Windows developer running `mix test` without `UAT_PF_BASH` hits the WSL stub bash. Decision:
  the shared helper's header assertion fails with the hint above (section 6.1); Linux CI is the
  authority. No further implementer decision is left.
