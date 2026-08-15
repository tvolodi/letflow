# Design: REQ-016 — Add `ueberauth_oidcc` dependency and supervise `Oidcc.ProviderConfiguration.Worker`

**Requirement:** REQ-016 (`docs/requirements.yaml`, stage S1)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** the exact `mix.exs` dep entry, the exact supervised child-spec
shape, the exact config keys/files, and exact verification/logging guidance. No
implementation code — no `.ex`/`.exs` code blocks with real bodies. Snippets below marked
"cited from library docs" are the *shape ELIXIR-DEV must match*, not something this design
authored as Letflow code; ELIXIR-DEV writes the actual files.

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-016 (full entry, `depends_on: []`) — description and all
  four acceptance criteria.
- `docs/migration/decisions/0002-oidc-integration.md` in full, especially its "Deferred to
  S1 execution" closing paragraph (names this exact task) and the Reasoning section's JWKS
  caching row (cites `Oidcc.ProviderConfiguration.Worker` as "a supervised worker process
  per provider configuration").
- `lib/letflow/design/0002-oidc-integration-decision.md` (the S0 research artefact behind
  that decision) — §4's cross-reference confirms the worker is a plain OTP supervision
  concern, orthogonal to the Phoenix/Plug decision; §7 item 3 explicitly flags supervision
  placement as unresolved S1 execution work, not pre-decided.
- `docs/guides/backend_developer_guide.md` §6 (OIDC section — confirms partial-library
  adoption framing, confirms this is the dependency-addition step) and §1 (env-var
  conventions), §3.7 (migration/config conventions — not directly applicable here since
  this requirement adds no migration, but read for consistency).
- `lib/letflow/application.ex` (current state, reproduced in §2 below) — existing children
  list and supervision strategy.
- `config/config.exs`, `config/dev.exs`, `config/test.exs`, `config/prod.exs` (current
  state) — confirmed **no `config/runtime.exs` exists yet** in this repo (only
  `config.exs`, `dev.exs`, `test.exs`, `prod.exs`, wired via `import_config
  "#{config_env()}.exs"` in `config.exs`). This changes where config values land — see §5.
- `docs/agents/instructions/security-invariants.md` INV-4 (secrets by reference only —
  applies now) and INV-7/INV-8 (not applicable to this requirement — no SQL, no new
  external-I/O call site beyond what the library itself performs).
- External verification (hexdocs.pm, current published docs, fetched this session — see
  §3 for exactly what was confirmed vs. inferred).

## 1. Scope boundary (what this requirement is and is NOT)

Per REQ-016's description: **`mix.exs` dependency addition plus supervision-tree wiring in
`application.ex`, configured from `config/dev.exs` (no `config/runtime.exs` exists yet —
see §5 for the resulting decision), and nothing else.**

Explicitly OUT of scope for this requirement (confirmed against `docs/requirements.yaml`'s
later S1 entries, same file read in §0):
- No `Ueberauth.Strategy.Oidcc` provider/strategy configuration (`config :ueberauth,
  Ueberauth, providers: [...]`) — that is claim-mapping/verification wiring, REQ-017's
  territory (pure claim-mapping function) and REQ-021's territory (the Plug pipeline that
  actually calls into Ueberauth). This requirement only starts the provider-configuration
  worker; it does not wire anything to call it yet.
- No realm provisioning, no Keycloak Admin REST API adapter (explicitly deferred per the
  S1 section comment in `docs/requirements.yaml` lines 499-504, cited in REQ-016's own
  description).
- No `tenants`/`users`/`groups`/`tenant_role` schema interaction (REQ-015's territory —
  REQ-016 shares no module or config table with it, confirmed no `depends_on`).
- No real Keycloak instance stood up. Exactly one realm/issuer, from config, using a
  documented placeholder value (§5).

## 2. Current `lib/letflow/application.ex` (baseline this design edits)

```
children = [
  Letflow.Repo,
  {Registry, keys: :unique, name: Letflow.Registry},
  Letflow.InstanceSupervisor,
  Letflow.ApprovalSupervisor,
  {Bandit, plug: Letflow.Router, port: 4000}
]
```

Passed to `Supervisor.start_link(children, opts)` with `strategy: :one_for_one, name:
Letflow.Supervisor`.

No child in this list currently performs network I/O at start (Repo connects to Postgres,
which is local infra, not a remote HTTP call). The new child is the first children-list
entry that reaches out over HTTP on startup.

## 3. `Oidcc.ProviderConfiguration.Worker` — API shape: confirmed vs. inferred

Per Core Directives' No Speculation rule, this section states plainly what was verified
this session against current library documentation (`oidcc` v3.7.2/3.8.0,
`ueberauth_oidcc` current docs on hexdocs.pm, fetched directly, not recalled from
pretraining) versus what remains an inference.

**Confirmed directly from `Oidcc.ProviderConfiguration.Worker`'s own hexdocs page and the
`oidcc`/`ueberauth_oidcc` READMEs (three independent fetches this session, consistent
across all three):**

- The worker is started as a **supervised child** via a `{Oidcc.ProviderConfiguration.Worker, opts}`
  tuple, `opts` being a **map**, not a keyword list.
- `opts` fields:
  - `:issuer` — **required**. A URI string for the OIDC provider's issuer
    (e.g. `"https://accounts.google.com"` in the library's own doc example).
  - `:name` — **optional but required in practice for multi-issuer setups**: a GenServer
    registration name (an atom, typically a module-qualified name like
    `MyApp.GoogleOpenIdConfigurationProvider`) used later to address this specific
    provider-configuration process from calling code (e.g. `Oidcc.retrieve_token/5`'s
    second argument takes this registered name). Without a distinct `:name` per worker,
    multiple workers cannot be told apart or referenced.
  - `:provider_configuration_opts` — optional, additional provider-configuration-fetch
    options (not enumerated in the fetched docs beyond the field's existence — treat as
    unneeded for REQ-016's single-realm, default-options case; do not invent values for
    it).
  - `:backoff_min`, `:backoff_max`, `:backoff_type` — optional, retry/backoff tuning for
    the provider-metadata fetch. Not required for this requirement; leave unset (library
    defaults apply) unless a later requirement needs to tune them.
  - **`:backoff_type` default and process-survival consequence — CONFIRMED directly from
    `oidcc`'s own source this session** (`src/oidcc_provider_configuration_worker.erl`,
    `erlef/oidcc`, read directly, not inferred from docs): `init/1` sets
    `backoff_type = maps:get(backoff_type, Opts, stop)` — **the default is `stop`**, not
    "retry forever" or any other more forgiving default. Confirmed consequence, also read
    directly from source: when a provider-metadata fetch fails and `backoff_type` is
    `stop`, `handle_backoff_retry/3` calls `oidcc_backoff:handle_retry/4`, which returns
    `stop`, and the worker's `gen_server` callback returns `{stop, ErrorDetails, State}` —
    **this terminates the worker process.** With the library default left unset (as this
    design currently specifies), a persistently-unreachable issuer does **not** leave the
    worker "alive with a failed fetch" — it stops the process outright. This changes the
    shape of §7's verification procedure (see below) and is carried into §11 as an
    explicit open question about whether REQ-016 should override this default.
- The library's own documented supervisor example (verbatim shape, from the worker's own
  hexdocs page):
  ```
  Supervisor.init([
    {Oidcc.ProviderConfiguration.Worker, %{issuer: "https://accounts.google.com"}}
  ], strategy: :one_for_one)
  ```
  and, for the named/multi-issuer case (verbatim shape, from the same page):
  ```
  {:ok, _pid} =
    Oidcc.ProviderConfiguration.Worker.start_link(%{
      issuer: "https://accounts.google.com",
      name: __MODULE__.GoogleConfigProvider
    })
  ```
  A third, independent search-result confirmation (not hexdocs.pm directly, but citing the
  same shape) showed the identical pattern embedded directly in an `Application.start/2`
  children list, which is the exact call site REQ-016 targets:
  ```
  children = [
    {Oidcc.ProviderConfiguration.Worker, %{
      issuer: "https://accounts.google.com",
      name: SampleApp.GoogleOpenIdConfigurationProvider
    }},
    SampleAppWeb.Endpoint
  ]
  ```
  This is consistent with §2's existing `application.ex` shape (a flat list of module
  names and `{Module, opts}` tuples passed to `Supervisor.start_link/2`) — the new child
  is added as one more list entry, no wrapping supervisor needed.

- **Confirmed: `ueberauth_oidcc` does NOT auto-start this worker from
  `config :ueberauth_oidcc, :issuers`.** That config block (documented shape:
  `config :ueberauth_oidcc, :issuers, [%{name: :oidcc_issuer, issuer: "<uri>"}]`) is
  consumed by `Ueberauth.Strategy.Oidcc` at *request-verification* time (REQ-021's
  territory), not by any `ueberauth_oidcc`-owned `Application` module that would start
  provider-configuration workers on its own. Checked directly for an `Application`
  behaviour implementation in `ueberauth_oidcc`'s own source tree; no such
  auto-supervision module was found, and no documentation describes one. **This confirms
  REQ-016's premise is correct**: the host application (Letflow) must add this child spec
  to its own supervision tree explicitly — it is not redundant with library-internal
  behavior, and skipping it would leave no provider-configuration process running at all.

**Confirmed (upgraded from "open question" this rework pass): `init/1` does NOT block
synchronously on the first metadata fetch.** Read directly from
`src/oidcc_provider_configuration_worker.erl` this session (cited from `oidcc` source,
Erlang, not Letflow code — evidence for the finding, not a shape ELIXIR-DEV implements):

```
init(Opts) ->
    EtsTable = register_ets_table(Opts),
    maybe
        {ok, Issuer} ?= get_issuer(Opts),
        ProviderConfigurationOpts = maps:get(provider_configuration_opts, Opts, #{}),
        {ok,
            #state{...},
            {continue, load_configuration}}
    end.
```

`init/1` returns `{ok, State, {continue, load_configuration}}` — the actual metadata
fetch happens in a `handle_continue/2` callback, dispatched *after* `init/1` returns and
*after* `start_link` has already reported success to its caller (the supervisor). This
means: an unreachable/invalid issuer does **not** fail `Letflow.Application.start/2` or
`Letflow.Supervisor.start_link/2` — the worker's `start_link` always returns `{:ok, pid}`
regardless of issuer reachability, and the fetch (success or failure) happens
asynchronously afterward. This closes the item that was previously listed as this
design's top open inference (see §11, item 1, updated accordingly). **What happens next,
once that async fetch fails, is the separate and still-load-bearing question below —
do not conflate the two.**

**What remains inference or requires empirical confirmation (flagged per No Speculation,
not silently assumed):**
- **Whether the worker process stays alive or exits, some interval after boot, once the
  async fetch has had time to fail.** §3 above confirms `backoff_type` defaults to `stop`
  and that `oidcc`'s own source shows this causes `{stop, ErrorDetails, State}` on fetch
  failure — i.e. the worker is very likely to exit, not persist "alive with a failed
  fetch" as one might otherwise assume. This is now the design's primary flagged
  empirical unknown, carried into a rewritten §7 procedure below: ELIXIR-DEV must observe
  the actual behavior directly rather than trust either this design's or the source
  reading's prediction, because the exact `oidcc_backoff:handle_retry/4` control flow
  (timing, whether it retries at all before stopping, exact error shape) was read from
  source but not exercised live against this application's actual supervision tree.
- **Whether repeated worker restart-and-fail destabilizes `Letflow.Supervisor` itself.**
  If the worker process does exit on fetch failure, `Letflow.Supervisor`'s `:one_for_one`
  strategy restarts it (standard `:permanent` restart type is OTP's/Elixir Supervisor's
  default child spec value, and `application.ex` does not override it — confirmed by
  reading `lib/letflow/application.ex` directly this session, no `restart:` option is set
  on any child). If the fetch fails again immediately on restart (which it will, against
  a permanently-unreachable `.invalid` placeholder host), this repeats. Elixir's
  `Supervisor.init/2` defaults `max_restarts: 3, max_seconds: 5` when not explicitly
  passed (confirmed from Elixir's own `Supervisor` hexdocs this session) — and
  `application.ex`'s `opts = [strategy: :one_for_one, name: Letflow.Supervisor]` sets
  neither `:max_restarts` nor `:max_seconds`, so these defaults apply. If the OIDC
  worker's stop-and-restart cycle happens faster than 3 times per 5 seconds, exceeding
  this intensity causes **`Letflow.Supervisor` itself to terminate**, which — because
  `Letflow.Supervisor` is the application's top-level supervisor — brings down the entire
  `Letflow` application. ELIXIR-DEV must determine this empirically (see rewritten §7).
- Whether `provider_configuration_opts` needs anything for a bare metadata-fetch-only use
  case (e.g. TLS options for a self-signed dev Keycloak cert). Left unset per the point
  above; if ELIXIR-DEV's empirical run against a real or containerized Keycloak surfaces a
  need (e.g. `:ssl` verification failure against a self-signed cert), that is a new,
  separate finding to document in the handoff, not something to silently add without
  noting it.

## 4. Exact `mix.exs` dependency entry

Add to the `deps/0` list in `mix.exs`, in the existing style (list of `{:app, requirement}`
/ `{:app, requirement, opts}` tuples, currently ordered roughly by when each was added —
append this as a new entry rather than reordering existing ones):

```
{:ueberauth_oidcc, "~> 0.4"}
```

This transitively resolves `{:oidcc, "~> 3.7"}` — do not add `:oidcc` as a direct/explicit
dependency; it is not called directly by anything in this requirement's scope (the
supervised child is `Oidcc.ProviderConfiguration.Worker`, a module `oidcc` itself exposes
as a transitive dep of `ueberauth_oidcc`, addressed by its full module name — no `alias`,
no direct `{:oidcc, ...}` line needed). No `:ueberauth` base package needs to be added as
a *separate* explicit dep for REQ-016's scope specifically (`ueberauth_oidcc` itself
depends on `ueberauth`; REQ-016 does not configure any `Ueberauth.Strategy`, so nothing in
this requirement's own code references `Ueberauth` directly) — but confirm via `mix deps.tree`
after `mix deps.get` that `:ueberauth` did resolve transitively, since REQ-017/REQ-021 will
need it and a resolution gap here should be caught now rather than later.

**Verification step (acceptance criterion 1):** run `mix deps.get` (or the Docker fallback
per `docs/anti-patterns.md` if no local toolchain) and quote its actual output — including
confirmation that `ueberauth_oidcc` and `oidcc` both appear as locked/fetched dependencies
(check `mix.lock` for both entries after the fetch).

## 5. Exact config keys and files

**Decision: use `config/dev.exs`, not `config/runtime.exs`.** REQ-016's description names
"`config/dev.exs` (or `config/runtime.exs`)" as the acceptable locations, but this repo
currently has **no `config/runtime.exs` file at all** (confirmed in §0 — only `config.exs`,
`dev.exs`, `test.exs`, `prod.exs` exist, and `config.exs` does not `import_config
"runtime.exs"` anywhere). Creating a new `runtime.exs` is a larger structural change
(release-time vs. compile-time config semantics, `System.get_env/2` availability
differences) than this requirement's scope calls for, and nothing in REQ-016's acceptance
criteria requires release-time (as opposed to compile-time) config resolution — this is
dev-environment wiring for a worker that has no reachable real issuer yet regardless.
**ELIXIR-DEV adds the new config to `config/dev.exs`**, matching the existing pattern in
that file (a `config :letflow, ...` block with literal/placeholder values, same file that
already holds `Letflow.Repo`'s dev connection settings). If a later requirement needs
release-time env-var resolution (e.g. S6/S7 deployment), introducing `runtime.exs` then is
that requirement's own scope decision, not retrofitted here.

**New config key, added to `config/dev.exs`:**

```
config :letflow, :oidc,
  issuer: "https://placeholder-keycloak.invalid/realms/bpm-default",
  provider_name: Letflow.Oidc.DefaultProvider
```

Naming rationale:
- `config :letflow, :oidc` (not `config :ueberauth_oidcc, ...`) — the issuer URL and
  provider name are **Letflow's own** config, read by `Letflow.Application` to build the
  child spec. This is distinct from `config :ueberauth_oidcc, :issuers`, which is
  `ueberauth_oidcc`'s own config key for the Strategy-layer wiring REQ-017/REQ-021 will
  add later — conflating the two would make REQ-016's child spec implicitly depend on
  REQ-021-scoped config existing, which it must not (REQ-016 has `depends_on: []`).
- `issuer` — a placeholder, documented as such, not a live Keycloak URL. Use the
  `.invalid` TLD (reserved by RFC 2606 for exactly this purpose — guaranteed
  non-resolving, unlike using a real domain that happens to be unreachable today) so it is
  unambiguous to any reader that this is not a real endpoint. A code comment directly
  above this config block must state: `# Placeholder — no real Keycloak instance exists
  yet. Replace with a real per-environment issuer URL once realm provisioning (deferred
  past S1, see the S1 section note in docs/requirements.yaml) exists.`
- `provider_name` — an atom (module-style name, `Letflow.Oidc.DefaultProvider`) used as
  the worker's `:name` option (§3) and as the value `application.ex` reads to build the
  child spec's `name:` field. Naming it `DefaultProvider` (not e.g. `BpmDefaultProvider`)
  keeps it generic since only one realm/issuer is configured in this requirement's scope —
  this is a placeholder module name for the *registered process*, not a real module that
  needs its own file; it never gets `defmodule`'d, only referenced as an atom, exactly the
  way `SampleApp.GoogleOpenIdConfigurationProvider` in §3's cited library example is used.

**`config/test.exs` and `config/prod.exs`:** no change needed for this requirement.
`config/test.exs` inherits `config/dev.exs`'s value unless overridden (Elixir config files
are merged per-environment, `dev.exs` only loads for `:dev`) — but since `test.exs` does
**not** currently `import_config` from `dev.exs` (confirmed in §0: each env file is loaded
independently via `config.exs`'s `import_config "#{config_env()}.exs"`), the `:oidc` key
will be **absent** under `MIX_ENV=test` unless added there too. Since the test suite for
this requirement (see §6) only needs to confirm the child spec is present and
correctly-shaped — not that the worker successfully fetches metadata — **add the identical
`config :letflow, :oidc, issuer: ..., provider_name: ...` block to `config/test.exs`** as
well, using the same placeholder issuer value, so `mix test` doesn't crash on a missing
config key when `Letflow.Application` (or a test that inspects the supervision tree) reads
it. This is the one piece of config duplication across files this design calls for
explicitly — do not read it from `dev.exs` at runtime from within `test.exs` (no such
cross-env config-loading mechanism exists in standard `Config`).

## 6. Exact `application.ex` child-spec placement

**New child added to the `children` list, placed immediately after `Letflow.Repo` and
before `{Registry, ...}`.**

**`backoff_type: :random` is now REQUIRED in the opts map — this is the SETTLED design,
not the library default, and not left unset. See §11 item 2 for the full resolution and
why the value is `:random`, not `:retry`.** ORCH's rework instruction that triggered this
update named the desired value as `:retry` — **that atom does not exist in `oidcc`**.
Confirmed directly from `deps/oidcc/src/oidcc_backoff.erl`'s own type spec this session:
`-type type() :: stop | exponential | random | random_exponential.` There is no `retry`
member. Passing `backoff_type: :retry` would not raise at compile time (the opts map has
no static Dialyzer enforcement at the call site as written), but at runtime
`oidcc_backoff:handle_retry/4`'s `priv_handle_retry/4` has no clause matching `retry` as
`Type`, so the first fetch failure would raise a `function_clause` error inside the
worker's `handle_continue/2` — i.e. it would crash immediately on the very first failure,
which is a **worse** outcome than the `:stop` behavior this change is meant to fix, not a
fix. **This design substitutes `:random`** — confirmed as the correct, intended
non-`:stop` value both from `oidcc_backoff.erl`'s type spec and from directly-applicable
precedent: `deps/ueberauth_oidcc/lib/ueberauth_oidcc/application.ex` line 11, where
`ueberauth_oidcc`'s own `Application` module (when it auto-starts these same worker
processes from `config :ueberauth_oidcc, :issuers`) does `Map.put_new(child_opts,
:backoff_type, :random)` — the library maintainers' own choice of safe default for this
exact "don't let a worker crash the supervision tree over an unreachable issuer" case.

Resulting list shape (existing entries unchanged, new entry marked):

```
children = [
  Letflow.Repo,
  {Oidcc.ProviderConfiguration.Worker, %{
    issuer: <read from Application.get_env(:letflow, :oidc)[:issuer]>,
    name: <read from Application.get_env(:letflow, :oidc)[:provider_name]>,
    backoff_type: :random
  }},                                                    # <-- new (backoff_type added
                                                           #     this rework pass)
  {Registry, keys: :unique, name: Letflow.Registry},
  Letflow.InstanceSupervisor,
  Letflow.ApprovalSupervisor,
  {Bandit, plug: Letflow.Router, port: 4000}
]
```

`backoff_type: :random` is a literal atom (not config-sourced) — unlike `issuer` and
`name`, this is a fixed operational-tuning choice, not an environment-varying value, so
it does not need to come from `Application.get_env(:letflow, :oidc)`. If a later
requirement finds a need to tune it per-environment, that is that requirement's own
scope decision (consistent with §11 item 5's treatment of `:backoff_min`/`:backoff_max`).

**Operational note (not a defect, stated explicitly per this rework pass's instruction):**
with `backoff_type: :random`, an issuer that stays unreachable indefinitely means the
worker retries **indefinitely** (see §11 item 2 for the confirmed retry-interval and
give-up behavior) — this produces an ongoing `logger:error` line (from
`oidcc_provider_configuration_worker.erl`'s `handle_backoff_retry/3`, quoted in §11 item
2) every retry interval, indefinitely, for as long as the issuer remains unreachable.
This is background log noise, not a crash risk, and no volume/rate cap exists in the
library for it. **Judgment call: acceptable for S1's scope, not worth a blocking
follow-up requirement right now** — S1 has no real Keycloak instance and no production
deployment or on-call surface yet (pre-S8, per Core Directives' "Humanless operation"
section: no real user traffic at stake), so unbounded retry logging against a
placeholder issuer has no operational audience to burden. **This should be revisited
before any real deployment** (S6 secrets / S7-S8 deployment stages, per §11 item 3's
existing `runtime.exs` flag for the same stage range) — capping retry-failure log
visibility/alerting (e.g. log-once-then-throttle, or surfacing worker health via a
telemetry event) is reasonable scope for a future requirement once Letflow has an actual
operator/alerting surface to serve. Filing a new requirement for that now would be
speculative (YAGNI, consistent with §9's existing reasoning for not generalizing to
multi-realm config ahead of need) — noted here so it isn't forgotten, not filed as an
issue today.

**Placement rationale (why here, not elsewhere in the list):**
- **After `Letflow.Repo`:** no functional dependency exists between the two (the OIDC
  worker does no DB I/O), but keeping infra-level children (DB connection pool, external
  service clients) grouped ahead of app-level supervisors (`Registry`,
  `InstanceSupervisor`, `ApprovalSupervisor`) matches this file's existing ordering
  convention of "shared infra first, then app-specific supervision structures, then the
  HTTP listener last." `Bandit` staying last is the one existing invariant worth
  preserving explicitly: nothing should start accepting HTTP connections before the rest
  of the tree is up, and this new child does not change that — it's still inserted before
  `Bandit`.
- **Before `Registry`/`InstanceSupervisor`/`ApprovalSupervisor`:** no dependency either
  direction — none of those three reference OIDC/identity state today (S1's identity
  tables and S3's engine are unrelated trees at this point in the migration). Order
  relative to these three is **irrelevant to correctness**; placing it right after `Repo`
  is a readability choice (groups "things that talk to the outside world or hold shared
  state" near the top), not a load-bearing dependency ordering. State this explicitly to
  ELIXIR-DEV so no one invents a false dependency justification later.
- **`:one_for_one` strategy is unchanged and sufficient:** this child's failure mode (an
  unreachable issuer) does not need to restart any sibling — `one_for_one` already means a
  crash in this one child does not tear down `Repo`/`Registry`/the supervisors/`Bandit`.
  No new supervisor layer (e.g. wrapping this in its own one-child supervisor) is needed
  for REQ-016's scope; if a future requirement needs different restart semantics (e.g.
  `:transient` with custom backoff beyond what `oidcc`'s own `:backoff_*` opts give), that
  is that requirement's decision to make, not pre-built here.

**Reading config, not hardcoding (acceptance criterion 2):** the child-spec's `issuer` and
`name` values must come from `Application.get_env(:letflow, :oidc)` (or equivalently
`Application.fetch_env!/2` — ELIXIR-DEV's choice between the two, but `fetch_env!` is
preferable since a missing `:oidc` config key should fail loudly at boot rather than
passing `nil` into `Oidcc.ProviderConfiguration.Worker`'s required `:issuer` field), never
a literal string typed directly into `application.ex`. This satisfies INV-4 in spirit
(config/env-sourced, not a hardcoded literal) even though INV-4 is about secrets
specifically and an issuer URL is not itself secret — the mechanism (config-sourced, not
hardcoded) is the same discipline REQ-016's acceptance criteria ask for independent of
INV-4's applicability.

## 7. What ELIXIR-DEV must verify and report explicitly (acceptance criterion 4)

**Second rework pass, superseding the procedure below where they conflict:** the crash
under `backoff_type: :stop` (library default, left unset) is now **confirmed, historical
evidence** — ELIXIR-DEV already ran the procedure below against the unset-`backoff_type`
child spec and reported: the worker exited within ~90ms with reason
`{:configuration_load_failed, {:failed_connect, ...}}`, restarted 4 times in under
150ms (exceeding `Letflow.Supervisor`'s default `max_restarts: 3, max_seconds: 5`), and
the entire `Letflow` application crashed and did not recover within a 30-second
observation window. **This finding does not need to be re-run** — it is cited as-is in
§11 item 2 as the empirical basis for this rework pass's `backoff_type: :random`
decision. What ELIXIR-DEV must now do is a **fresh, second verification pass** against
the corrected child spec (§6, `backoff_type: :random` now present):

1. Update the child spec in `lib/letflow/application.ex` to match §6 exactly
   (`backoff_type: :random` added to the opts map).
2. Re-run application boot against the same unreachable `.invalid` placeholder issuer
   from §5, and confirm — this is the acceptance bar, both halves required, not just the
   first:
   - The application **boots** (`{:ok, pid}` from `Letflow.Application.start/2`), same as
     before (this part was never in question — §3's async-`init/1` finding still holds
     regardless of `backoff_type`, since `backoff_type` only affects what happens after
     the first fetch failure, not `init/1` itself).
   - The application **stays up** — observe for at least 30 seconds (same window as the
     original `:stop` finding, so the two results are directly comparable), confirming
     `Letflow.Supervisor` does NOT exceed its restart-intensity limit and the `Letflow`
     application does NOT crash/exit. This is the part that failed under `:stop` and is
     the actual thing this rework pass exists to fix — booting alone is not sufficient
     evidence, since the previous run also booted successfully before crashing 150ms
     later.
   - The OIDC worker process itself: confirm it **keeps retrying** rather than exiting —
     i.e. `Process.whereis(<provider_name atom>)` (or equivalent) continues to resolve to
     a live (possibly different, if the process itself restarts under normal supervision
     rather than looping) pid across the observation window, and/or the expected
     `logger:error` "Metadata load failed... Retrying in ~w ms" line (per
     `oidcc_provider_configuration_worker.erl`'s `handle_backoff_retry/3`, quoted in §11
     item 2) appears in output repeatedly rather than a single crash-and-stop.
   - Capture and quote the actual log lines observed (the retry log message includes the
     computed wait interval — quote at least two consecutive occurrences if visible, to
     show the process is genuinely retrying on a loop rather than having stopped after
     one retry).
3. State the result explicitly in the handoff's `result.summary`, updating (not
   duplicating) the equivalent bullets from the original procedure below:
   - "Verified: with `backoff_type: :random` in place, the application boots AND remains
     up (observed Xs, no crash) against the unreachable placeholder issuer — the OIDC
     worker retries the metadata fetch on a random backoff interval rather than exiting
     the process." (State the actual observed duration/behavior; do not just restate this
     template sentence.)
   - If the 30-second observation shows anything other than "stays up, worker keeps
     retrying" — e.g. the worker still exits, or the supervisor still destabilizes for
     some other reason — **do not silently patch further; stop and escalate back to
     CODE-DESIGNER/REVIEWER exactly as §11 item 2's prior escalation instruction required
     for the `:stop` finding.** A second contradicted prediction in the same design would
     mean something about this design's understanding of the library is still wrong, not
     that a third silent patch is the right move.

**Original first-pass procedure below is kept for record/audit purposes (it is what
produced the `:stop` crash evidence now cited in §11 item 2) — it does not need to be
re-run a third time; only the corrected-child-spec pass above is pending.**

1. **Start the application** (`mix run --no-halt`, or via `mix test` triggering
   `Application.start/2` through the normal test-boot path) with the placeholder
   `.invalid` issuer URL from §5 in place, and observe/report:
   - Confirm `Letflow.Application.start/2` returns `{:ok, pid}` — §3 confirms (from
     `oidcc` source) that `init/1` never blocks on the fetch, so application boot itself
     should succeed regardless of issuer reachability. Report the actual observed result
     rather than asserting it, in case something about this application's actual
     supervision tree behaves differently from the isolated source reading.
   - **Empirically determine whether the worker process is still alive some interval
     after boot** (e.g. wait at least one `backoff_min`-scale interval — check the
     resolved default, or simply wait several seconds — then check), using
     `Process.whereis(<provider_name atom>)` or `Supervisor.which_children(Letflow.Supervisor)`.
     Do NOT presuppose the answer. Report exactly what is observed: process alive and
     registered, or process absent/exited. If exited, capture the exit reason.
   - **Empirically determine whether the worker process repeatedly restarts and exits.**
     Watch (via `Supervisor.count_children/1`, repeated `Process.whereis/1` polling, or
     observed log output showing repeated start/stop) whether the worker is stuck in a
     restart loop against the unreachable `.invalid` host.
   - **Empirically determine whether this destabilizes `Letflow.Supervisor` itself.**
     Confirm whether `Letflow.Supervisor` (and thus the whole `Letflow` application)
     stays up, or whether it crashes/exits once the OIDC worker's restart rate exceeds
     the supervisor's actual configured intensity. §3 confirms `application.ex` sets
     neither `:max_restarts` nor `:max_seconds` on `Letflow.Supervisor`, so Elixir's
     `Supervisor.init/2` default (`max_restarts: 3, max_seconds: 5`) applies — re-confirm
     this against `lib/letflow/application.ex` as it exists at implementation time in
     case it has changed since this design was written, don't assume this design's
     reading is still current. Let the application run long enough (tens of seconds) to
     observe whether repeated fast restart-and-fail actually trips this intensity limit
     in practice, and report the actual observed outcome — including the case where it
     does NOT trip (e.g. if `oidcc`'s internal backoff/retry timing, prior to the final
     `stop`, is slow enough that restarts stay under the 3-per-5-seconds threshold).
   - Capture and quote the actual log output / error the worker (or the supervisor, if it
     terminates) produces when the metadata fetch fails and when/if the worker or
     `Letflow.Supervisor` exits (expected: an HTTP/DNS resolution failure against the
     `.invalid` host, logged by `oidcc`'s own internal retry/backoff logging, and
     possibly a supervisor `:shutdown` or crash report if intensity is exceeded — quote
     whatever actually appears, do not paraphrase it as "an error occurred").
2. **State explicitly in the handoff's `result.summary`** (not left to be inferred from
   test output alone):
   - "Verified: child spec is present in `Letflow.Application`'s children list, sourced
     from `config :letflow, :oidc` (not hardcoded), and `mix compile
     --warnings-as-errors` passes with the new dependency in the tree."
   - "Verified: application boots successfully (`{:ok, pid}`) even when the configured
     issuer is unreachable" (per §3's confirmed async-init finding — report if this
     differs from what was observed).
   - "Verified: the OIDC worker process [stays alive / exits] after its async
     provider-metadata fetch fails against the unreachable placeholder issuer, and
     [does / does not] enter a restart loop under `Letflow.Supervisor`" (state the actual
     observed answer — do not omit this; it is the primary empirical finding this rework
     pass exists to force).
   - "Verified: `Letflow.Supervisor` [remains up / crashes] under the observed
     restart-and-fail behavior" (state the actual observed answer; if it crashes, this is
     a significant finding that should be escalated, not quietly noted — see §11 item 3
     for the recommended follow-up).
   - "NOT verified: the worker completing a real metadata fetch / JWKS retrieval against
     a genuine Keycloak issuer, because no Keycloak instance is deployed in this
     environment (per REQ-016's own scope — realm provisioning is out of this S1 batch).
     This will first become verifiable once a real or containerized Keycloak instance
     exists to point the `issuer` config at."
3. This split (what was verified vs. what structurally cannot be verified yet) is the
   literal content REQ-016's fourth acceptance criterion is asking for — do not write a
   handoff that only reports the positive half. **If empirical testing shows
   `Letflow.Supervisor` crashes/destabilizes**, do not treat that as merely a fact to
   report in `result.summary` and move on — flag it back to CODE-DESIGNER/REVIEWER before
   proceeding further, since it means this design's §11 open question (below) needs to be
   resolved (likely by setting `backoff_type: :retry` or similar) rather than shipped as
   REQ-016 currently specifies the child-spec opts. **[Historical text, kept as originally
   written — this is exactly what happened; ELIXIR-DEV correctly escalated the crash
   rather than silently patching it. Note for any reader: the actual resolved value is
   `backoff_type: :random`, not `:retry` — `:retry` is not a valid value in this library,
   see §11 item 2's "Value correction" for why. This paragraph's "`:retry` or similar" was
   this design's own first-pass guess at the fix shape, phrased loosely before the
   library's actual type set was re-checked against the specific atom; §11 item 2 is the
   normative, corrected source of truth, not this line.]**

## 8. Cross-module dependencies

- **Depends on:** `mix.exs` (new dep entry), `config/dev.exs` + `config/test.exs` (new
  `:oidc` config key), `lib/letflow/application.ex` (new child-spec entry). No dependency
  on REQ-015's schema work (confirmed §1) or any existing `lib/letflow/*.ex` module beyond
  `application.ex` itself.
- **Depended on by (future requirements, not built here):** REQ-017 (claim mapping —
  will read verified-token output, not this worker directly), REQ-018 (JIT provisioning),
  REQ-019 (tenant↔realm binding), REQ-020 (role registry), REQ-021 (the Plug pipeline that
  will actually call `Ueberauth`/`Oidcc` functions referencing the `provider_name` atom
  this requirement registers — REQ-021 must reuse `Application.get_env(:letflow,
  :oidc)[:provider_name]` rather than re-inventing or hardcoding the same atom, so name
  this atom exactly once, here, as the source of truth).

## 9. Invariants

- Exactly one `Oidcc.ProviderConfiguration.Worker` child exists after this requirement
  (one realm/issuer, per REQ-016's explicit scope limitation) — the design supports N
  workers later (one per configured realm, per 0002's Reasoning section) by making
  `config :letflow, :oidc` a single map now; generalizing to a list-of-maps plus a
  `children` list built via `Enum.map/2` is a follow-up requirement's shape change, not
  built speculatively here (YAGNI — REQ-016 has no second realm to configure against).
- The `issuer`/`provider_name` values are never hardcoded string/atom literals inside
  `application.ex` itself — always read from `Application.get_env/fetch_env!`.
- `Bandit` (the HTTP listener) remains the last child in the list — nothing about this
  change reorders it earlier.
- No secret material is introduced by this requirement (an issuer URL is not a secret;
  client ID/secret belong to REQ-021's Ueberauth strategy config, out of scope here) — so
  INV-4's "never logged/serialized" clause has nothing new to violate yet, but the
  config-sourced-not-hardcoded discipline is still followed as a matter of consistency.

## 10. Acceptance-criteria traceability

| REQ-016 acceptance criterion | Concrete design element addressing it |
|---|---|
| "`mix.exs` lists `{:ueberauth_oidcc, \"~> 0.4\"}`, and `mix deps.get` resolves it (or the Docker-fallback equivalent, actual output quoted)" | §4 gives the exact dep entry and ordering guidance; the last paragraph of §4 tells ELIXIR-DEV exactly what command to run and what to quote |
| "`lib/letflow/application.ex`'s children list includes a supervised `Oidcc.ProviderConfiguration.Worker` child spec, sourced from config rather than a literal hardcoded issuer URL" | §6 gives the exact list position, the exact tuple shape (with `Application.get_env`/`fetch_env!` reads, not literals), and the placement rationale; §5 gives the exact config key/file the values are sourced from |
| "`mix compile --warnings-as-errors` passes with the new dependency in the tree" | §7 item 2's first bullet names this as one of the explicit handoff statements ELIXIR-DEV must make |
| "if the worker cannot reach a real issuer in this environment, that is stated explicitly (what was and wasn't verified)" | §7 gives the full empirical-verification procedure (boot with the `.invalid` placeholder, observe/report boot success-or-failure, capture actual log output) and the exact three-part `result.summary` statement (verified / verified / explicitly-not-verified) ELIXIR-DEV must write, not left to be inferred |

## 11. Open questions (not silently resolved)

1. **~~Synchronous vs. lazy metadata fetch on `init/1`~~ — CONFIRMED, no longer open** (§3).
   Resolved this rework pass by reading `oidcc_provider_configuration_worker.erl` directly:
   `init/1` returns `{ok, State, {continue, load_configuration}}` — the fetch is
   asynchronous, dispatched via `handle_continue/2` after `start_link` has already
   returned success. An unreachable issuer does not fail application boot. This item is
   kept here (rather than deleted) only so the traceability of "this used to be an open
   question, here is how and when it was closed" is visible; §3 is the normative source of
   truth going forward, not this line.
2. **`backoff_type` default (`:stop`) — RESOLVED this rework pass (second pass). No
   longer open.**

   **Empirical evidence (from ELIXIR-DEV's implementation-and-verification run against
   this design's original unset-`backoff_type` child spec, per the first-pass §7
   procedure):** with the placeholder unreachable `.invalid` issuer in place, the
   `Oidcc.ProviderConfiguration.Worker` process exited within ~90ms of boot with reason
   `{:configuration_load_failed, {:failed_connect, ...}}`, restarted 4 times in under
   150ms total — exceeding `Letflow.Supervisor`'s default `max_restarts: 3, max_seconds:
   5` (confirmed unset/default in `application.ex`, §3) — and the entire `Letflow`
   application then crashed with `"Application letflow exited: shutdown"` and did **not**
   recover within a 30-second observation window. This confirms, empirically and not just
   from source-reading, exactly the risk this section anticipated when it was still
   "genuinely open": leaving `backoff_type` unset (`:stop`) is not survivable for
   REQ-016's scope, because the placeholder `.invalid` issuer used for verification is
   permanently unreachable by construction (§5), so the worker enters exactly the
   fast-crash-loop case that trips the supervisor's default intensity limit.

   **Decision (ORCH, informed by this evidence): set a non-`:stop` `backoff_type` on the
   child spec, so a temporarily- or permanently-unreachable OIDC issuer degrades to
   "auth temporarily unavailable" rather than taking down the entire application,
   including unrelated business-process functionality with nothing to do with OIDC.**

   **Value correction made during this design update:** the value actually implemented
   is **`backoff_type: :random`**, not `:retry`. ORCH's rework instruction described the
   desired value as `:retry`, but `:retry` is not a member of `oidcc`'s `backoff_type()`
   type — confirmed directly from `deps/oidcc/src/oidcc_backoff.erl`'s type spec this
   session: `-type type() :: stop | exponential | random | random_exponential.` Passing
   an atom outside this set would not fail to compile (the opts map is not
   statically enforced at the `application.ex` call site) but would crash
   `priv_handle_retry/4` with a `function_clause` error on the very first fetch failure —
   a strictly worse outcome than `:stop`, not the intended fix. `:random` was chosen, not
   `:exponential` or `:random_exponential`, on direct precedent: `ueberauth_oidcc`'s own
   `Application` module
   (`deps/ueberauth_oidcc/lib/ueberauth_oidcc/application.ex` line 11) auto-starts these
   same worker processes (when configured via `config :ueberauth_oidcc, :issuers`) with
   `Map.put_new(child_opts, :backoff_type, :random)` — i.e. the library's own maintainers'
   chosen safe default for "don't let this worker's failure mode be `:stop`." No design
   reason exists to diverge from that precedent for REQ-016's scope. See §6 for the
   corrected child-spec shape and §7 for the required re-verification.

   **Confirmed `:random` retry behavior, read directly from
   `deps/oidcc/src/oidcc_backoff.erl`'s `priv_handle_retry/4` clause for `random`:**
   ```
   priv_handle_retry(random, Min, Max, State) ->
       {rand(Min, Max), State};
   ```
   where `rand(Min, Max) -> rand:uniform(Max - Min + 1) + Min - 1.` — a uniformly random
   wait interval between `backoff_min` and `backoff_max` (defaults `1_000`ms /
   `30_000`ms respectively per `oidcc_provider_configuration_worker.erl`'s own
   `@moduledoc`, left at library defaults per §11 item 5, unchanged by this decision).
   Unlike `stop`, `random`'s clause has no `State =:= undefined -> stop` branch and no
   give-up condition of any kind — **it retries indefinitely**, forever, at a fresh random
   interval in `[backoff_min, backoff_max]` each time, for as long as the fetch keeps
   failing. There is no maximum retry count and no circuit-breaker in this library. This
   is confirmed directly from source, not inferred. Each retry attempt that fails logs via
   `handle_backoff_retry/3` (`oidcc_provider_configuration_worker.erl` lines 429-441):
   ```
   logger:error(
       "Metadata load failed for issuer ~s. Retrying in ~w ms. Error Details: ~w",
       [Issuer, Wait, ErrorDetails],
       #{error => ErrorDetails}
   ),
   erlang:send_after(Wait, self(), backoff_retry),
   {noreply, State#state{backoff_state = NewBackoffState}}
   ```
   i.e. the worker process itself never exits on repeated failure under `:random` — it
   stays alive, logs an error, schedules its own retry via `erlang:send_after/3`, and
   returns `{noreply, State}` — no supervisor restart is even triggered on the failure
   path itself (the process never crashes; `Letflow.Supervisor` only ever sees this child
   as "up"). This structurally cannot exceed `max_restarts`/`max_seconds` the way the
   `:stop` case did, because no restart cycle occurs at all in the failure path — the
   same process keeps retrying itself indefinitely.

   **Operational consequence flagged explicitly (per this rework pass's instruction):**
   see §6's "Operational note" for the indefinite-retry-log-noise judgment call
   (assessed there as acceptable for S1's scope, revisit before real deployment).
3. **`config/runtime.exs` introduction** — this design deliberately chose `config/dev.exs`
   over creating a new `runtime.exs` (§5). If a later stage (S6 secrets, S7/S8 deployment)
   needs release-time config resolution for the OIDC issuer (e.g. reading it from an
   actual env var at release-boot time rather than compile time), that is a separate,
   later requirement's decision — flagging so it isn't assumed to already be handled by
   this requirement's config choice.
4. **Whether `provider_configuration_opts` needs TLS/cert overrides** for a real
   containerized Keycloak with a self-signed cert, once one exists — left unset per §3;
   revisit only if empirical testing against a real instance surfaces a need.
5. **Exact retry/backoff tuning** (`:backoff_min`/`:backoff_max`) — left at library
   defaults; no requirement read this session calls for tuning these further, so this
   design does not invent values. (`:backoff_type` specifically is item 2 above, not
   bundled into this generic item, since it is the one with a confirmed
   process-survival consequence.)
