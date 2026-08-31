# RELEASE-VALIDATOR report — REQ-203 (WF02-REQ203-20260831)

Independent re-verification, not a re-read of prior agents' claims. All commands
below were run by me, in this session, against real Postgres, on branch
`feature/WF02-REQ203-20260831` (clean tree throughout except for one deliberate,
reverted mutation-test edit — see AC8).

## Global gates

- `mix compile --warnings-as-errors` — clean, exit 0, no output.
- `mix format --check-formatted` — clean, exit 0, no output.
- `scripts/test_parallel.sh` (full suite, 8 partitions, real Postgres) —
  `combined: 2889 tests, 6 properties, 2 failures (2893/2895 passed)`. Inspected
  both failures directly in the partition logs: both are
  `Mix.Tasks.Letflow.CheckToolchainTest`'s rust-pin tests, failing with
  `Erlang error: :enoent` from `System.cmd("rustc", ["--version"], ...)` —
  the documented rustc-absent sandbox baseline, unrelated to REQ-203. No other
  failures anywhere in the suite.
- `git diff main...HEAD --stat` (36 files) — reviewed in full: only
  `lib/letflow/{repository.ex,repository/*,design/*,tenant_provisioning.ex}`,
  `priv/repo/migrations/20260831000001_create_artifact_activations.exs`,
  `test/**`, `config/test.exs`, `docs`-adjacent handoff/report files. No
  `lib/letflow_web/`, router, or controller file anywhere in the diff.

## Per-acceptance-criterion verification

- **AC1 (atomic group activation, all-succeed + forced-failure rollback)** —
  MET. Read `activate_group/4`'s `Ecto.Multi` pipeline
  (`lib/letflow/repository/activation.ex`) in full: one `Repo.transaction/1`
  call over the group's envelope insert + N per-artifact upsert/history/audit
  steps. Ran `test/letflow/repository/activation_test.exs`'s "AC1" describes
  directly (all-succeed: 3/3 new versions, 3 history rows; forced-failure: a
  bogus `version_id` triggers a real FK violation, and I confirmed all three
  artifacts remain at prior versions, zero new history rows, group-envelope
  count unchanged) — both tests pass in a standalone run I performed.
- **AC2 (REPO-08 observability, no mixed state)** — MET, verified as the
  hardest criterion per instruction. Read the full test
  (`describe "AC2 ..."`, lines 310-383) and confirmed genuinely non-vacuous:
  `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` is set in
  `provisioned_tenant/0` (not `Letflow.DataCase`'s default shared-connection
  mode), `activate_group/4` is spawned via `Task.async` with
  `test_pause_after: 1, test_pause_fun: pause_fun`, the pause function blocks
  on `receive do :continue -> :ok end`, and the main test process issues real
  `Activation.resolve/3` reads (on the separate main connection) during the
  pause, asserting all three artifacts show OLD versions (including artifact 1,
  whose row is already updated inside the still-open transaction) — this is a
  real test of Postgres's MVCC visibility floor, not a commit-then-read check.
  Passed in my own run of `test/letflow/repository/activation_test.exs`.
- **AC3 (per-tenant isolation)** — MET. Read and ran both tests
  (lines 389-465): activating in tenant B leaves tenant A `:not_activated`
  and vice versa; the same `version_id` (from REQ-202's global content store)
  is active in tenant A while tenant B has never activated that name. Both
  pass.
- **AC4 (UNIQUE constraint DB-enforced)** — MET. Migration
  (`priv/repo/migrations/20260831000001_create_artifact_activations.exs`)
  declares `unique_index(:artifact_activations, [:tenant_id, :artifact_kind,
  :artifact_name], name: :artifact_activations_tenant_kind_name_idx, ...)`.
  Test builds a raw, changeset-valid second row for the same triple and
  asserts `Ecto.ConstraintError` on `Repo.insert!/2` — a real DB-level
  rejection, not an application check. Passed.
- **AC5 (previous_version_id null-then-populated)** — MET. Read and ran the
  field-by-field test (lines 517-557): first activation's history row has
  `previous_version_id == nil`; second activation's has it populated with the
  first version's id, with every other field (new_version_id,
  new_version_number, activator_user_id, rationale, tenant/kind/name)
  asserted individually across both rows. Passed.
- **AC6 (blank rationale rejected)** — MET. Read and ran all four tests
  (nil, `""`, whitespace-only `"   \t  "`, and a changeset-bypassing
  `insert_all/3` with `rationale: ""`). Independently confirmed from
  `Ecto.Type.trim/2`'s behavior (leading-whitespace trim feeding
  `validate_required/2`'s empty-value check) that this design's claim — that
  `cast/4`'s pipeline also catches whitespace-only strings, not just `nil`/`""`
  — matches the actual mechanism the test exercises; the whitespace-only test
  passed for real, not merely by construction. DB-level `CHECK (rationale <>
  '')` on both `artifact_activation_groups` and `artifact_activation_history`
  confirmed present in the migration; the changeset-bypass test asserts
  `Postgrex.Error` matching the constraint name. All four tests pass.
- **AC7 (chronological + REQ-067 cursor pagination)** — MET. Read and ran all
  seven `list_history/4` tests: per-artifact order, tenant-wide order (nil
  kind/name), page-size-bounded pagination advancing across 3 pages,
  `page_size_too_large` for 0 and 201, `wrong_endpoint` for a foreign `"RV:"`
  cursor, `expired` for an ancient mint-time cursor, `invalid_cursor` for
  non-base64 input. All pass.
- **AC8 (resolve/3 not-found, never arbitrary)** — MET, independently
  mutation-tested by me (not just trusting the on-record TEST-DESIGN-VALIDATOR
  mutation evidence, though it matches). I edited `resolve/3` myself to fall
  back to the latest `artifact_versions` row by `version_number` instead of
  returning `{:error, :not_activated}`, ran the two targeted tests
  (`activation_test.exs:781` AC8, `:389` AC3's isolation test) — both failed
  (exit 2) under the mutant, exactly the two tests the design and prior
  reports predicted. Reverted with `git checkout -- lib/letflow/repository/
  activation.ex`, confirmed `git status --porcelain lib/ test/` empty, and
  re-ran `test/letflow/repository/activation_test.exs test/letflow/
  repository_test.exs` together: `Result: 56 passed`, confirming a clean
  revert and no regression to REQ-202's own suite.
- **AC9 (ON DELETE RESTRICT)** — MET. Migration declares `on_delete: :restrict`
  on `active_version_id`, `previous_version_id`, and `new_version_id`, all FKs
  to `artifact_versions.version_id`. Both tests (deleting the active version;
  deleting a version referenced only as a history `new_version_id`/
  `previous_version_id` after a newer version is active) assert
  `Ecto.ConstraintError` on `Repo.delete!/1`. Both pass.
- **AC10 (moduledoc disambiguation vs. audit_entries)** — MET. Read
  `Letflow.Repository.Activation`'s actual shipped moduledoc: it states the
  scope/shape/mandatory-field/tamper-evidence/consumer distinction accurately
  (activation history = subsystem-specific, denormalized, mandatory
  `rationale`, no hash chain; `audit_entries` = tenant-wide, generic jsonb
  shape, hash-chained with `chain_hash`/`prev_chain_hash`), and explicitly
  states neither table is ever deleted as redundant with the other. The
  moduledoc-substring test (`Code.fetch_docs/1`-based) passes.
- **AC11 (no route/controller)** — MET, confirmed both by the dedicated test
  and independently via `git diff main...HEAD --stat` (36 files, none under
  `lib/letflow_web/`).
- **AC12 (mix test / mix compile --warnings-as-errors pass)** — MET. See
  "Global gates" above — both re-run by me directly, with real quoted output.

## Two specifically-flagged contentious fixes, re-verified

- **FK-constraint fix on both insert and update branches**: confirmed
  `Letflow.Repository.Activation.changeset/2` (the single shared changeset
  function) carries `foreign_key_constraint(:active_version_id, name:
  :artifact_activations_active_version_id_fkey)`, and `upsert_activation_pointer/8`
  calls this same `changeset/2` on both its `nil ->` (insert) branch and its
  `%__MODULE__{} = existing ->` (update) branch — one function, both branches,
  confirmed by reading the source directly, not inferred from a doc comment.
- **Test-only pause seam compile-time gate**: `grep`-confirmed
  `activation_test_hooks_enabled?` appears only in `config/test.exs` (`config
  :letflow, activation_test_hooks_enabled?: true`) and nowhere in `config/
  dev.exs` or `config/prod.exs`, so `Application.compile_env(:letflow,
  :activation_test_hooks_enabled?, false)` resolves to `false` in those builds.
  `maybe_add_test_pause_step/3`'s `if @activation_test_hooks_enabled? and
  index == pause_after and is_function(pause_fun, 0)` is therefore a
  compile-time no-op outside `MIX_ENV=test`.

## Verdict

**PASS.** All 12 acceptance criteria independently re-derived and confirmed
against actual source, actual migration DDL, and real command output — not
against status-history narration. No discrepancy found between what the long
rework chain's final commits claim and what is actually shipped. Routing to
DOC-UPDATER (Step 6) to flip REQ-203's status to `done` and append the
status-history event.
