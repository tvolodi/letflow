# Design: prod/QA admission headroom — `POOL_SIZE` default + `RESERVED_HEADROOM` env wiring (ISS-0908)

**Status:** design, pending CODE-DESIGN-VALIDATOR.
**Issue:** `docs/issues/ISS-0908.yaml` (queue ref Q-898/ISS-0898 collision, GH-2032,
severity MAJOR, owner ELIXIR-DEV, status open).
**Related:** `docs/issues/ISS-0786.yaml` (same root-cause class, `config/dev.exs`-only
precedent — resolution and reasoning mirrored here for the prod/QA path it explicitly
left untouched), `lib/letflow/admission.ex` (`Letflow.Admission`, REQ-216),
`lib/letflow/design/iss0437-admission-tenant-eviction.md` §3/§9 OQ-2 (fair-share
divisor gap — out of scope here, see §4 below), `docs/anti-patterns.md` ISS-0219/
ISS-0222 (Postgres connection-count sizing caution — checked in §3).

## 1. Problem, confirmed against the code (per ISSUE-FIXER's diagnosis — not
re-diagnosed here)

`Letflow.Admission.start_link/1` (`lib/letflow/admission.ex`) derives `global_cap`
once, at process start, as `pool_size - reserved_headroom`:

- `pool_size` falls back to `Application.fetch_env!(:letflow, Letflow.Repo)[:pool_size]`
  — under `config_env() == :prod` (which QA boots under; QA has no
  `config_env() == :qa` distinction anywhere in this repo) this is set by
  `config/runtime.exs:113`: `pool_size: String.to_integer(System.get_env("POOL_SIZE")
  || "10")`. `deploy/.env.example:17` documents `POOL_SIZE` as optional, defaulting to
  10 — the QA host's out-of-repo `.env` leaves it unset, per ISSUE-FIXER's diagnosis,
  so QA runs the documented-default path, not a QA-specific misconfiguration.
- `reserved_headroom` falls back to `Application.get_env(:letflow, :admission,
  [])[:reserved_headroom] || @default_reserved_headroom` (`@default_reserved_headroom
  2`, compiled into `lib/letflow/admission.ex`). **No config file in this repo — not
  `config/dev.exs`, `config/test.exs`, `config/prod.exs`, nor `config/runtime.exs` —
  ever sets `:letflow, :admission, :reserved_headroom`**, and no env var is read for
  it anywhere. This key is only ever exercised today via `start_link/1`'s own `opts`
  override, used exclusively by tests (`test/support/admission_test_helpers.ex`).

Net effect on QA: `global_cap = 10 - 2 = 8` for the entire node, divided further by
`Letflow.Admission`'s per-tenant fair-share divisor
(`max(div(global_cap, map_size(tenants)), 1)`) across every tenant schema attempted
since the node's last restart — driving `bpm-default`'s real concurrent share to
roughly 4 or fewer, well under the 3-5 concurrent requests one SPA page load needs.
This reproduces `docs/issues/ISS-0786.yaml`'s exact root-cause class
(DB-pool-size-as-concurrency-cap) on the path ISS-0786's own resolution explicitly
left unaddressed: *"No change needed to config/runtime.exs's POOL_SIZE env-override
handling (piece 2 of the suggested_fix was not pursued; the static bump alone closed
the observed 503s)"* — ISS-0786's fix only ever touched `config/dev.exs`.

## 2. Fix — exact config changes

### 2.1 `config/runtime.exs:113` — raise the `POOL_SIZE` fallback default

Current (inside the `if config_env() == :prod do` block, ~L113):

```
config :letflow, Letflow.Repo,
  url: database_url,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
```

Changed default: `"10"` -> `"30"` — this is the SAME numeric value `config/dev.exs`
already settled on for ISS-0786 (`pool_size: 30`, comment: *"Raised to 30 (-> cap 28)
for real headroom"*). Mirroring, not re-deriving, this value is deliberate: ISS-0786
already established 30 as sufficient headroom against `Letflow.Admission`'s default
2-unit reserved headroom for this exact same class of problem, and this fix's own
Postgres-sizing check (§3 below) confirms 30 carries no new risk on the prod/QA path
either. No other line in this `if config_env() == :prod do` block changes.

```
config :letflow, Letflow.Repo,
  url: database_url,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "30")
```

A code comment must be added directly above this line (mirroring `config/dev.exs`'s
own ISS-0786 comment style) stating: this is ISS-0908's fix, the prior default was 10,
why 30 was chosen (mirrors dev.exs/ISS-0786), and that `POOL_SIZE` remains fully
operator-overridable via env var — this line only changes what happens when the var is
**absent**, not the override mechanism itself.

### 2.2 `config/runtime.exs` — wire `:letflow, :admission, :reserved_headroom` to a
new env var, `RESERVED_HEADROOM`

Add a new config stanza inside the same `if config_env() == :prod do` block,
immediately after the `Letflow.Repo` config (§2.1) so both pool-related settings sit
together:

```
config :letflow, :admission,
  reserved_headroom: String.to_integer(System.get_env("RESERVED_HEADROOM") || "2")
```

- Env var name: `RESERVED_HEADROOM` (no `LETFLOW_` prefix — matches this file's own
  existing convention for non-secret, non-namespaced tunables: `POOL_SIZE`, `PORT`,
  `LOG_LEVEL`, `CORS_ALLOWED_ORIGINS` are all unprefixed; only the master-key secret
  uses a `LETFLOW_` prefix. Do not deviate from this file's established naming
  convention for this new var).
- Default: `"2"` — kept identical to `@default_reserved_headroom` in
  `lib/letflow/admission.ex`, per this issue's explicit scope instruction ("keep
  `@default_reserved_headroom = 2` as the fallback unless you find reason to change
  it") — no reason to change it was found; the root cause here is entirely the
  `pool_size` side of the subtraction, not the headroom side.
- Parse failure behavior: `String.to_integer/1` raises `ArgumentError` on a
  non-numeric value (e.g. `RESERVED_HEADROOM=abc`) — this is the SAME fail-fast shape
  `POOL_SIZE`'s existing `String.to_integer(System.get_env("POOL_SIZE") || "10")` line
  already has (an already-accepted pattern in this file; not a new failure mode this
  fix introduces). No additional validation (e.g. rejecting negative values) is added
  — `Letflow.Admission.start_link/1` and `init/1` already only ever consume this value
  arithmetically (`pool_size - reserved_headroom`), and do not require this design to
  add new range-checking that neither `POOL_SIZE` nor any other numeric var in this
  file currently has.
- This key is set ONLY inside the `if config_env() == :prod do` block, matching
  `POOL_SIZE`'s own placement — `config/dev.exs` and `config/test.exs` are untouched
  by this design (§4 confirms dev/test already have their own working values via
  `pool_size: 30` (dev) and `Letflow.Admission`'s test-only `start_link/1` opts
  override (test) — neither needs a `:reserved_headroom` env path).
- **No change to `lib/letflow/admission.ex` itself.** Its existing
  `Application.get_env(:letflow, :admission, [])[:reserved_headroom] ||
  @default_reserved_headroom` read already correctly picks up whatever
  `config/runtime.exs` now sets — this is purely a config-file change, confirming
  ISSUE-FIXER's framing ("wire ... to a real env var in config/runtime.exs") does not
  require touching the admission module's own code.

### 2.3 `deploy/.env.example` — document the new var (repo-owned file, in scope)

Add a new documented-optional entry immediately after the existing `POOL_SIZE` block
(~L17), mirroring its exact comment style:

```
# Optional -- Letflow.Admission's reserved-headroom subtracted from POOL_SIZE to
# derive the global admission concurrency cap (config/runtime.exs), defaults to 2
# if unset.
RESERVED_HEADROOM=
```

This is a documentation-only addition to a template file already checked into the
repo (`deploy/.env.example` itself, not the out-of-repo QA `.env` it templates) — it
does not touch QA host infra, per this design's scope boundary (WF-05 §75).

## 3. Postgres connection-count sizing check (ISS-0219/ISS-0222 caution, per issue
scope instruction)

`docs/anti-patterns.md`'s ISS-0219/ISS-0222 entries caution specifically about
`nproc`-derived test/CI parallelism multiplying against Postgres's own
`max_connections`, and about zombie/orphaned connections from interrupted or
long-lived processes holding a standing pool — both are **test/CI-process-count**
concerns (concurrent `mix test` partitions, or a stray `mix run --no-halt`), not a
concern about one node's own `Ecto.Repo` pool_size in isolation. This fix changes only
the prod/QA release node's own single `Letflow.Repo` pool_size (one release, one pool,
one Postgres connection budget consumed) — it does not add test parallelism, does not
add a second pool, and does not change anything about how many independent OS
processes hold connections at once. ISS-0786's own resolution already confirmed the
identical numeric bump (10 -> 30) for `config/dev.exs` "is not flagged as conflicting
with the CI postgres-sizing concerns raised in ISS-0219/ISS-0222 -- this only affects
config/dev.exs, not config/test.exs's own pool sizing used by CI" — the same
reasoning applies here: this change affects only the prod/QA release's own
`Letflow.Repo` pool, not `config/test.exs`, and QA's Postgres instance is a
provisioned deployment target, not a resource-constrained CI runner, so 30 connections
from a single release node is not a sizing risk this design needs to further qualify.
No `docs/anti-patterns.md` update is needed for this design (the existing ISS-0219/
ISS-0222 entries already scope themselves correctly away from this case).

## 4. Explicitly out of scope (per issue's own scope instructions)

- **Fair-share divisor "counts every tenant ever attempted since restart"
  gap** — confirmed real (`lib/letflow/admission.ex` moduledoc's own "Lazy
  tenant-entry creation" section, and `lib/letflow/design/iss0437-admission-tenant-
  eviction.md` §3/§9 OQ-2's own residual note: "a real cardinality bound for the still-
  open idle-but-never-deactivated case ... remains out of scope"). This design does
  NOT touch that divisor, `state.tenants`, or any eviction logic — ISSUE-FIXER
  explicitly flagged it as already-tracked and out of scope for this pass. Raising
  `global_cap` (§2.1/§2.2) widens the numerator every tenant's share is computed
  from, which is a real, in-scope mitigation of this issue's reported symptom, but
  does not close the underlying divisor-growth gap OQ-2 already tracks separately.
- **`config/dev.exs`, `config/test.exs`** — untouched. Dev already has its own working
  `pool_size: 30` from ISS-0786; test's admission behavior is governed entirely by
  `test/support/admission_test_helpers.ex`'s explicit `start_link/1` opts overrides,
  never by `config/test.exs`'s `Letflow.Repo` pool_size or by any env var — neither
  needs `RESERVED_HEADROOM` wiring.
- **`lib/letflow/admission.ex` itself** — no code change; only its already-existing
  config read is now fed a real value in prod/QA (§2.2).
- **QA host's real, out-of-repo `.env`** — per WF-05 §75, this design cannot touch QA
  host infra. **Followup note for issue closure** (not something this fix can verify
  or control): whoever closes ISS-0908 should independently confirm the QA host's
  actual `.env` does not itself pin `POOL_SIZE` to a value lower than the new default
  (e.g. an old, deliberately-thin `POOL_SIZE=10` left over from before this fix
  existed) — if it does, this in-repo default-raise has no effect on that host until
  the pinned value is also raised or removed, since an explicitly-set `POOL_SIZE` env
  var always wins over `config/runtime.exs`'s fallback default. This is a genuine
  residual risk this design cannot close from inside the repo; it must be flagged
  explicitly at closure, not silently assumed away.

## 5. Test coverage (config-level assertions only — not a concurrency-load test)

Add a new test file, `test/letflow/admission_runtime_config_test.exs`, following
`test/letflow/secrets_runtime_config_test.exs`'s own established pattern for testing
`config/runtime.exs` behavior (a real `mix run` subprocess via `System.cmd/3`, tagged
`@moduletag :slow`, `MIX_ENV` forced appropriately, `MIX_TEST_PARTITION`/
`MIX_BUILD_PATH` explicitly nil'd in `env:` for the same reason
`secrets_runtime_config_test.exs`'s own header comment documents) — `config/
runtime.exs`'s prod-only branch cannot be exercised any other way from an
already-booted test process, same reasoning as that file's own moduledoc. Since the
`if config_env() == :prod do` block requires `MIX_ENV=prod` to evaluate at all (and a
real `prod`-mode boot needs `DATABASE_URL`, a compiled release, etc., which this test
must not assume are available), assert only against the resolved config value itself,
not against a full node boot:

1. **`POOL_SIZE` absent -> resolves to 30, not 10.** Spawn a subprocess that evaluates
   `config/runtime.exs`'s prod branch in isolation (mirroring
   `secrets_runtime_config_test.exs`'s own subprocess-boot technique) with `POOL_SIZE`
   unset and `MIX_ENV=prod`, and assert the resulting `Application.fetch_env!(:letflow,
   Letflow.Repo)[:pool_size] == 30` (not `10`). If a full `prod`-mode `mix run` boot is
   impractical in CI (no compiled release / no `DATABASE_URL`), an acceptable
   equivalent — consistent with "config test, not a full concurrency-load test" per
   this issue's own scope — is a focused `Config.Reader`-based evaluation of
   `config/runtime.exs` alone with `config_env()` stubbed/forced to `:prod` and a
   throwaway `DATABASE_URL`/`LETFLOW_SECRETS_MASTER_KEY` supplied purely so the file
   evaluates without raising; TEST-DESIGNER should pick whichever of these two
   mechanisms this repo's existing test helpers already support most directly (check
   for a `Config.Reader`-based helper before introducing subprocess boot if one
   already exists) rather than this design mandating one over the other.
2. **`POOL_SIZE` explicitly set (e.g. `"15"`) -> resolves to 15, not the new
   default.** Confirms the new default does not shadow or interfere with an operator's
   explicit override — same override mechanism as before, only the fallback changed.
3. **`RESERVED_HEADROOM` absent -> `Application.get_env(:letflow, :admission,
   [])[:reserved_headroom] == 2`.** Confirms the new wiring's default matches
   `Letflow.Admission.@default_reserved_headroom` exactly (both must independently
   read `2` — this test protects against the two defaults drifting apart in a future
   edit, since nothing else in the codebase currently cross-checks them against each
   other).
4. **`RESERVED_HEADROOM` explicitly set (e.g. `"5"`) -> resolves to 5.** Confirms the
   new var actually takes effect, end to end from env var to resolved config value —
   this is the core "QA can tune it without a redeploy" acceptance criterion.
5. **`RESERVED_HEADROOM` set to a non-numeric value -> subprocess/evaluation exits
   non-zero** (mirrors `POOL_SIZE`'s own pre-existing, unguarded `String.to_integer/1`
   failure mode — not a new assertion pattern, just confirming the new line fails the
   same fail-fast way as the line it sits beside).

None of the above requires starting `Letflow.Admission`, generating concurrent
requests, or exercising `try_acquire/2` — `Letflow.Admission`'s own existing test
suite (`test/letflow/admission_test.exs`) already covers the arithmetic
(`global_cap = pool_size - reserved_headroom`, per-tenant fair-share division) given
whatever values it's started with; this issue's gap was entirely that prod/QA never
fed it real values, not that the arithmetic itself was untested.

## 6. Decision-record check

Searched `docs/migration/decisions/` for any record governing `Letflow.Repo`
pool-sizing or `Letflow.Admission` config defaults — none exists (REQ-216's own design
doc, `lib/letflow/design/req216-admission-control-core.md`, governs the admission
algorithm itself, not deployment-time tuning values). No decision record is
implicated and none needs updating.

## 7. SECURITY-REVIEWER — not required

This change touches no tenant-data path, no API route, no migration, no secret, and no
response shaping — it changes two numeric config defaults and adds one new
non-secret, operator-facing env var (`RESERVED_HEADROOM`) alongside an
already-existing one (`POOL_SIZE`) of the identical class. Per
`docs/agents/instructions/security-invariants.md`'s INV-1..INV-8 categories, none
apply. Standard REVIEWER pass (idiom, decision-record consistency, scope creep) is
sufficient.

## 8. Acceptance criteria (for CODE-DESIGN-VALIDATOR / ELIXIR-DEV / TEST-DESIGNER)

- **AC1:** `config/runtime.exs`'s `if config_env() == :prod do` block's `Letflow.Repo`
  `pool_size` line's fallback default changes from `"10"` to `"30"`, with an
  ISS-0908-attributed comment above it explaining the change and mirroring
  `config/dev.exs`'s own ISS-0786 comment. `POOL_SIZE` remains fully operator-settable
  via env var (no override mechanism removed).
- **AC2:** `config/runtime.exs`'s same `if config_env() == :prod do` block gains a new
  `config :letflow, :admission, reserved_headroom: ...` stanza reading a new
  `RESERVED_HEADROOM` env var, falling back to `"2"` when unset — matching
  `lib/letflow/admission.ex`'s `@default_reserved_headroom`. No other environment's
  config file (`config/dev.exs`, `config/test.exs`) gains this stanza.
- **AC3:** `lib/letflow/admission.ex` is unchanged — this fix is config-only.
- **AC4:** `deploy/.env.example` documents the new `RESERVED_HEADROOM` var, in the same
  comment style as the existing `POOL_SIZE` entry, immediately following it.
- **AC5:** A new test file (or an extension of an existing runtime-config test file)
  asserts, without booting a full concurrency scenario: (a) the new `pool_size`
  default is 30 when `POOL_SIZE` is unset; (b) an explicit `POOL_SIZE` override still
  works; (c) the new `reserved_headroom` default is 2 when `RESERVED_HEADROOM` is
  unset; (d) an explicit `RESERVED_HEADROOM` override resolves correctly end to end.
- **AC6:** No change anywhere to `Letflow.Admission`'s per-tenant fair-share divisor
  behavior (`max(div(global_cap, map_size(tenants)), 1)`) or its tenant-entry
  lifecycle — confirmed by `lib/letflow/admission.ex`'s diff being empty (AC3) and no
  new test asserting different divisor behavior.
- **AC7:** The design's writeup (this file) states the out-of-repo-QA-`.env`
  `POOL_SIZE`-pin risk explicitly as a followup note for whoever closes ISS-0908 —
  present in §4 above; ELIXIR-DEV/DOC-UPDATER should carry this note into the issue's
  own `resolution` text at closure, mirroring how ISS-0786's own resolution recorded
  what it did and did not pursue.
- **AC8:** No `docs/anti-patterns.md` entry is required or added by this fix (§3
  concludes the existing ISS-0219/ISS-0222 entries already scope themselves away from
  this single-node pool_size change).

## 9. Open questions

None outstanding for this fix's own scope. One residual, explicitly-flagged (not
silently resolved) risk exists outside this design's ability to close: the possibility
that QA's real `.env` pins `POOL_SIZE` below the new in-repo default, discussed in §4
and carried into AC7 as a mandatory closure-time followup note, not a code change this
pass can make.
