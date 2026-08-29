# REQ-181 Release Validation Report

**Agent:** RELEASE-VALIDATOR
**Run:** WF02-REQ181-20260829
**Branch:** feature/WF02-REQ181-20260829
**Commit at validation time:** 53f6c06
**Result:** PASS

## Method

Independently re-derived each acceptance criterion against the actual code and
migration on disk, and re-ran the test suite myself (not a re-read of
TEST-RUNNER's report). No prior report's verdict was taken on trust.

## Acceptance criteria — independent findings

1. **Tenant-scoped migration, `tenant_id` retained (decision 0003 Decision B).**
   Read `priv/repo/migrations/20260829010001_create_webhook_subscriptions.exs`
   directly: the `if prefix() do ... end` guard wraps `create table(:webhook_subscriptions,
   primary_key: false, prefix: prefix())`, with an explicit `add :tenant_id, :binary_id,
   null: false` column retained inside the tenant schema (not used as the isolation
   boundary — the guard/prefix is). Registration confirmed in
   `lib/letflow/tenant_provisioning.ex`'s `@tenant_scoped_migration_manifest`
   (`{20_260_829_010_001, Letflow.Repo.Migrations.CreateWebhookSubscriptions, ...}`).
   Also confirmed by `test/letflow/webhooks_test.exs`'s AC1 test, which queries
   `information_schema.columns`/`.tables` directly and passed. **MET.**

2. **`create/2` generates-or-accepts a secret, stores only a hash, returns
   plaintext once as `hmac_secret_once`; never re-exposed.** Read
   `lib/letflow/webhooks.ex`'s `create/2`: hashes via `:crypto.hash(:sha256, plaintext)
   |> Base.encode16(case: :lower)` before the changeset ever sees it; only
   `secret_hash` is cast (`Letflow.Webhooks.Subscription.insert_changeset/2`'s
   whitelist is `[:target_url, :secret_hash, :description, :event_types, :tenant_id,
   :created_at]` — no `secret`/`hmac_secret_once` key exists on the schema at all,
   confirmed by reading `lib/letflow/webhooks/subscription.ex`'s field list). Two
   explicit tests present and passing: `test/letflow/webhooks_test.exs`'s AC2
   describe blocks ("no secret supplied -- generates one, stores only the SHA-256
   hash, returns hmac_secret_once" and "a subsequent list/1 of the same subscription
   carries no plaintext and no hmac_secret_once key"). **MET.**

3. **`update/3` reconciles `%{status: "PAUSED"}` and `%{is_active: false}` to the
   same stored state.** Read `Letflow.Webhooks.update/3`'s `reconcile_status/1`
   clauses and `apply_status_update/3` clauses: both single-key inputs map to
   `:PAUSED`; a disagreeing pair returns `{:error, :invalid_status}` without
   writing. `test/letflow/webhooks_test.exs`'s AC3 describe block has 7 tests
   covering both single keys, agreeing pairs (both directions), a disagreeing
   pair (verified no write occurs), and idempotent re-pause — all passing.
   **MET.** (Function is named `update/3`, not `update/2` as an earlier draft of
   the criterion text said — `id`, `attrs`, `opts` — this is the correct, final
   signature per the design and is what the real code and tests use.)

4. **`list/1` is tenant-scoped.** Read `Webhooks.list/1`: scoped entirely by
   `Repo.all(query, prefix: prefix)` against the caller's own Postgres schema —
   no `WHERE tenant_id = ...` filter that could be omitted by mistake, consistent
   with the schema-per-tenant model. `test/letflow/webhooks_test.exs`'s AC4 test
   creates a subscription under tenant A and confirms `list/1` scoped to tenant B
   returns `[]`. Passing. **MET.**

5. **`delete/2` removes the row; second delete is not-found.** Read
   `Webhooks.delete/2`: fetches via the private `get/2` (which does the
   `Ecto.UUID.cast/1` + scoped-fetch + `{:error, :not_found}` dance) then
   `Repo.delete/2` — a second call finds no row via `get/2` and short-circuits to
   `{:error, :not_found}` via `with`, structurally incapable of a duplicate
   success. `test/letflow/webhooks_test.exs`'s AC5 test confirms `list/1` excludes
   the deleted row and a second `delete/2` returns `{:error, :not_found}`.
   Passing. **MET.**

6. **No route or controller file added.** `git diff --stat main...HEAD` for this
   branch touches only `lib/letflow/design/req181-webhooks-core.md`,
   `lib/letflow/tenant_provisioning.ex`, `lib/letflow/webhooks.ex`,
   `lib/letflow/webhooks/subscription.ex`, and the migration file — no
   `lib/letflow/routers/`, controller, or Plug file. `test/letflow/webhooks_test.exs`'s
   AC6 tests further assert structurally (`refute source =~ ~r/use\s+Plug\.Router/`,
   etc., and that `lib/letflow/routers/` contains no webhook-named file) — passing.
   **MET.**

7. **`mix test` and `mix compile --warnings-as-errors` both pass.** Re-ran myself,
   not copied from TEST-RUNNER's report:
   - `mix test test/letflow/webhooks_test.exs` → **14 tests, 0 failures.**
   - `mix compile --warnings-as-errors --force` → `Compiling 142 files (.ex)` /
     `Generated letflow app`, exit clean, zero warnings.
   - Full suite via `bash scripts/test_parallel.sh` (N=8 partitions, same
     aggregation mechanism TEST-RUNNER uses) →
     `combined: 2500 tests, 5 properties, 3 failures (2502/2505 passed)`.
     Independently inspected all 3 failures in the partition logs
     (`/tmp/letflow_test_parallel.JHyGCG/partition-{3,5}.log`): 2 are
     `Mix.Tasks.Letflow.CheckToolchainTest` raising `** (ErlangError) Erlang
     error: :enoent` from `System.cmd("rustc", ["--version"], ...)` (no `rustc`
     on this sandbox's PATH), and 1 is
     `Letflow.Engine.Wasm.PluginHandlerTest`'s "AC7: the wasmex NIF is a loaded
     shared library" test, same root cause (wasmex's NIF requires a Rust
     toolchain to produce a compiled artifact). None reference
     `webhook`/`Webhooks`/`Subscription` anywhere in their failure output, and
     none of the touched files appear in this branch's diff. Confirmed same
     class TEST-RUNNER reported, verified independently rather than trusted.
   **MET.**

## Other checks

- No `docs/migration/decisions/` record is contradicted: decision 0003 Decision B
  (schema-per-tenant, `tenant_id` retained) is followed exactly, matching
  REQ-176's `dlq_entries` precedent.
- This is a WF-02 requirement-level run, not a stage-gate check, so no
  `docs/migration/stage-N-*.md` REVIEWER sign-off section applies here.
- Confirmed `docs/requirements.yaml`'s REQ-181 entry's `depends_on` and text are
  consistent with what was actually built (read lines around 9182).
- Confirmed the correct field order for the status-history event
  (`req, event, agent, at, note`) by inspecting existing entries in
  `docs/status/requirement_status.v6.yaml` — this is called out explicitly in
  the Step 6 handoff since this exact field got it wrong twice earlier in this
  run (commits 8ba02f3, e5a03e7).

## Verdict

**PASS.** All 7 acceptance criteria independently verified against real code,
real migration, real tests I ran myself, and a real full-suite run I executed
myself. Routing to DOC-UPDATER via
`handoffs/WF02-REQ181-20260829/step-06-doc-updater.json` to flip REQ-181 to
`done` in `docs/requirements.yaml` and append the status-history event.
