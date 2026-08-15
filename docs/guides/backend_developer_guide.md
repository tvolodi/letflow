# Letflow — Backend Developer Guide

**Audience:** `ELIXIR-DEV`, `CODE-DESIGNER` (design must match these conventions),
`REVIEWER` (checks against them).

This guide is written to be followed literally by a small or inexpensive model with no
memory of why each rule exists beyond what's written here — see
`docs/agents/instructions/core-directives.md`'s "Humanless operation" section. When in
doubt, match the style of the existing files cited below rather than introducing a new
pattern.

---

## 1. Environment setup

### Required tools
- Elixir 1.17+ / OTP 26+ (the project was scaffolded on 1.14/OTP 25 via apt; nothing
  depends on that specific version — see `README.md`'s Notes)
- PostgreSQL client tools (`psql`) if connecting outside Docker
- Docker (for the test database, and as the fallback toolchain — see §7)

### Environment variables

| Variable | Where set | Purpose |
|---|---|---|
| Postgres connection | `config/dev.exs`, `config/test.exs` | Port 5462 — deliberately not 5432/5433, which R-Co's own stack already uses |
| `LETFLOW_BOOTSTRAP_TOKEN` (or similar, per REQ-103) | `config/dev.exs` / env | MVP-1 dev-mode auth token — never hardcoded as a literal string in a committed `.ex` file |

### Bootstrap

```bash
docker compose up -d
mix deps.get
mix ecto.setup
mix run --no-halt
```

```bash
mix test
```

---

## 2. Project structure

```
lib/letflow/
├── application.ex          # Supervision tree root
├── repo.ex                 # Ecto.Repo
├── router.ex               # Plug.Router — HTTP entry point (Plug/Bandit, no Phoenix
│                            # yet — see docs/migration/decisions/0001-web-framework.md)
├── process_instance.ex      # :gen_statem — one process per running workflow instance
├── instance_supervisor.ex   # DynamicSupervisor — owns one process per instance
├── parallel_approval.ex     # :gen_statem — dual-approval state machine
├── approval_supervisor.ex   # DynamicSupervisor for parallel_approval instances
├── row_approval.ex          # Plain Ecto context (no process) — see row_approval/approval.ex
├── row_approval/
│   └── approval.ex          # Plain Ecto.Schema
├── events/
│   └── transition_event.ex  # Ecto.Schema — every transition logged here
└── design/                  # CODE-DESIGNER artefacts — one .md per module, written
                              # before implementation, read before you build

priv/repo/migrations/        # Ecto migrations, timestamp-prefixed .exs files

test/letflow/                # ExUnit tests, one file per lib/letflow/ module
test/specs/                  # TEST-DESIGNER's test specs, one .md per REQ-ID
test/reports/                # TEST-RUNNER's structured run reports, .yaml
```

---

## 3. Coding conventions

### 3.1 Naming

| Element | Convention | Example |
|---|---|---|
| Modules | `PascalCase`, namespaced under `Letflow.` | `Letflow.ProcessInstance` |
| Functions | `snake_case` | `start_instance`, `submit` |
| Ecto schema fields / DB columns | `snake_case` | `instance_id`, `from_state` |
| Files | `snake_case.ex` / `.exs` | `process_instance.ex` |

### 3.2 State machines — use `:gen_statem`, not `GenServer` + a state field

If a module models a workflow with named states and legal/illegal transitions between
them, implement it as `:gen_statem` with `callback_mode: :handle_event_function` and
one `handle_event` clause per legal `{action, from_state}` pair, exactly like
`lib/letflow/process_instance.ex`. A `GenServer` holding `%{state: :draft, ...}` and
branching on it with `case` is the crutch this project explicitly avoids — REVIEWER
gates on this distinction (see `.claude/agents/reviewer.md`).

**Do NOT reach for `:gen_statem` when there's no real state machine.** If the "state"
is a single boolean/counter converging to one terminal value with no ordering
constraints between transitions (e.g. two independent approvals both need to happen,
in either order), a plain Ecto schema plus context module — see
`lib/letflow/row_approval.ex` — is simpler and was the deliberately chosen precedent
after `docs/migration/decisions/`-adjacent evaluation. Match the shape of the actual
problem: named-state machine → `:gen_statem`; independent-flags-converging → plain
Ecto.

### 3.3 One supervised process per instance

Every running workflow instance (or parallel-approval instance) gets its own process
under a `DynamicSupervisor` (`Letflow.InstanceSupervisor`,
`Letflow.ApprovalSupervisor`), each with `restart: :transient` in its `child_spec/1`.
Killing one instance's process must never affect a sibling instance — this is tested
directly (see `test/letflow/parallel_approval_test.exs`'s crash-isolation test). Don't
collapse this into a shared process or an ETS table "for simplicity" without flagging
it explicitly to REVIEWER.

### 3.4 Every transition is persisted synchronously

`Letflow.ProcessInstance`'s `transition/5` calls `Repo.insert!` inside the state
machine's own call path, before replying to the caller. This is deliberate — see the
moduledoc's own note — not an oversight to "optimize" by making it async. Don't change
this without flagging it to REVIEWER, since it affects durability guarantees the tests
assume.

### 3.5 Error handling

Public functions that can fail return `:ok | {:error, term()}` (see
`lib/letflow/process_instance.ex`'s `@spec`s) or `{:ok, result} | {:error, reason}`.
Every `@spec` states the error shape — don't leave it implicit. See
`docs/agents/instructions/security-invariants.md` INV-8: don't write a bare pattern
match (`{:ok, x} = external_call()`) on a path reachable from external I/O or
tenant/user input.

### 3.6 SQL — always parameterized

Use `Ecto.Query`'s `from/2` composition, or `Repo.query(sql, params)` with bound `$1`,
`$2`, ... placeholders. Never build a SQL string via `<>` or `"#{}"` interpolation with
tenant- or user-controlled data — see `security-invariants.md` INV-7.

### 3.7 Migrations

Additive and reversible — `change/0` with operations Ecto can automatically reverse
(see `priv/repo/migrations/20260814000001_create_transition_events.exs` for the
established shape: `binary_id` primary key, `null: false` on required columns,
`timestamps/1`, an index on the foreign-key-like column). Timestamp-prefixed filename,
`Letflow.Repo.Migrations.<CamelCaseDescription>` module name.

---

## 4. Self-review checklist before completing a handoff

- [ ] `mix compile --warnings-as-errors` exits 0
- [ ] `mix format --check-formatted` exits 0
- [ ] `mix test` exits 0 (or the Docker fallback below was used and reported real output)
- [ ] No SQL string interpolation of tenant/user data (§3.6)
- [ ] No unresolved `{:ok, _} =` match on external-I/O/tenant-input paths (§3.5)
- [ ] If you touched `process_instance.ex`/`instance_supervisor.ex`: one process per
      instance still holds, crash isolation still holds
- [ ] If you added a migration: reversible, matches the established column-naming/
      index style
- [ ] New public functions have a one-line `@doc`
- [ ] If any function signature changed: every call site still compiles
- [ ] Did you add or change a state transition? Update the ASCII state diagram in
      `README.md` if the workflow's shape changed.

---

## 5. Multi-tenancy — schema-per-tenant (decided)

`docs/migration/decisions/0003-ecto-schema-strategy.md` (REQ-012) decided Decision B:
schema-per-tenant via Ecto `:prefix`/dynamic-repo support, with `tenant_id` retained as
an intra-schema column (not the sole isolation mechanism, and not a tenant-column-only
shared-schema model). Read that decision record in full before writing anything
tenant-scoped — it also covers Decision A (Ecto-idiomatic redesign, not a 1:1 SQL port)
and Decision C (event-store insert-only, composite PK, idempotency sidecar table). S1's
own `users`/`tenant`/tenant-binding tables (`docs/migration/stage-1-identity.md`) follow
Decision B like every other business table.

---

## 6. OIDC / identity — ueberauth_oidcc (partial adoption, decided)

`docs/migration/decisions/0002-oidc-integration.md` (REQ-011) decided a **partial**
library adoption: `ueberauth_oidcc` (`~> 0.4`, pulling in `oidcc ~> 3.7`) for the
token-verification/JWKS-caching layer only. JIT user provisioning, tenant↔realm binding,
the custom role registry, and Keycloak Admin REST API provisioning are all hand-rolled
regardless of library choice — see that decision record's Reasoning section for exactly
which R-Co behaviors are/aren't covered out of the box. This hand-rolled surface is what
S1 (`docs/migration/stage-1-identity.md`, REQ-015 through REQ-021) implements. MVP-1's
static-dev-bearer-token plug (REQ-103) was never built — the whole MVP-1 milestone was
cancelled (see REQ-101's status note in `docs/requirements.yaml`) — so REQ-021's plug is
Letflow's first real auth plug, not an extension of REQ-103.

---

## 7. No local toolchain? Use the Docker fallback

If `mix`/`elixir` aren't on `PATH`, don't stop at "can't verify" — try the Docker
workaround documented in full in `docs/anti-patterns.md`'s "No Elixir/mix toolchain on
PATH in this sandbox" entry: a throwaway `elixir:1.17-otp-27` container plus an isolated
`postgres:16` container on a private Docker network. It has worked cleanly before (12/12
tests including the StreamData property test). Tear both containers down afterward and
restore any temporarily-edited config.
