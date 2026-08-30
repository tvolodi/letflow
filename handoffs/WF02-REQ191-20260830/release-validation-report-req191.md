# RELEASE-VALIDATOR report — REQ-191 service catalog core

Run: WF02-REQ191-20260830, Step 5. Verdict: **PASS**.

Independent re-derivation, not a re-read of prior reports. Toolchain was
available in this sandbox via `~/.asdf/shims` on `PATH` (elixir 1.20.3-otp-29);
`rustc`/`cargo` genuinely absent, consistent with the documented pre-existing
environmental gap. Postgres reachable via the workspace's already-running
`letflow-1-postgres-1` container on port 5463 (`.env`'s `LETFLOW_DB_PORT`).

## Commands actually run, with results

- `mix compile --warnings-as-errors --force`: clean, exit 0 (148 files
  compiled, `Generated letflow app`).
- `bash scripts/test_parallel.sh` (full suite, 8 partitions):
  `combined: 2592 tests, 5 properties, 2 failures (2595/2597 passed)` —
  identical aggregate to TEST-RUNNER's own report. Both failures traced by
  grepping partition logs: `Mix.Tasks.Letflow.CheckToolchainTest` "rust pin"
  tests, failing on `running_rust_raw/0`/`running_rust_version/0` because
  `rustc`/`cargo` are absent from this sandbox — confirmed environmental, not
  caused by this diff (`git diff --stat main...HEAD` does not touch that test
  file or anything it exercises).
- `mix test test/letflow/service_catalog_test.exs --trace`: `Result: 26
  passed`, 0 failures.
- `mix letflow.lint_handoffs`: `OK -- 0 new violations across 1460 handoff
  files (25 pre-existing grandfathered, traced to ISS-0190)`.
- `mix format --check-formatted`: clean, exit 0.

## Acceptance criteria, re-derived against real code and a real test run

1. **DB-level scope/owner CHECK** — confirmed in
   `priv/repo/migrations/20260830000001_create_service_catalog.exs`
   (`chk_service_catalog_scope_owner_consistency`, a table-level `create
   constraint/2 check:`, not a changeset validation).
   `test/letflow/service_catalog_test.exs:174,190` insert directly with
   `Repo.insert_all`/raw changeset paths that bypass changeset validation and
   assert the DB itself rejects both invalid combinations. Both pass.
2. **required_auth/timeout_ms DB CHECK** — `chk_service_catalog_required_auth`
   and `chk_service_catalog_timeout_ms` in the same migration; tests at
   lines 211, 226, 241 all pass.
3. **get_for_tenant/2 three-way visibility** — read `lib/letflow/service_catalog.ex`
   lines 207-242: single `Repo.get/2` plus a pure pattern match, so the
   "genuinely missing" and "real but invisible" branches return the
   identical `{:error, :not_found}` tuple, not merely equal-looking atoms
   from different code paths. Tests at lines 265, 275, 285, plus an explicit
   264-tuple-identity test at line 293, all pass.
4. **Global uniqueness** — `service_id` is the table's own primary key
   (migration line 55, `Entry`'s `@primary_key {:service_id, :string,
   autogenerate: false}`), so a duplicate insert is a PK violation regardless
   of tenant/scope. Test at line 316 passes, and confirms the first row is
   untouched (no silent overwrite).
5. **register/1 rejects nonexistent tenant** — `check_tenant_exists/1`
   (service_catalog.ex:166-188) runs a `Repo.get(Tenant, uuid)` before any
   insert is attempted, inside a `with` pipeline that short-circuits on
   `{:error, :tenant_not_found}`. Test at line 352 passes, confirms no row
   created.
6. **delete/1 referential guard, structural** — `referencing_active_definitions/2`
   (service_catalog.ex:462-495) uses a parameterized `jsonb_array_elements`/
   `EXISTS` SQL fragment matching `node->>'node_type' = 'SERVICE_TASK'` AND
   `node->'attributes'->>'service_id' = ?` — a structural attribute match,
   not `LIKE '%...%'` against serialized graph text. Tests at lines 375
   (blocked, names the definition id), 390 (unreferenced succeeds), and 398
   (substring-only occurrence inside an unrelated string does NOT block
   delete) all pass. A bonus regression test at line 425 covers a real
   concurrent-delete race (forced via an actual Postgres row lock, not a
   hypothetical) and confirms `Ecto.StaleEntryError` is rescued to
   `{:error, :not_found}` rather than crashing — this was SECURITY-REVIEWER's
   rework-1 finding, now covered.
7. **update_scope/2 narrow/widen** — `narrowing?/2` (service_catalog.ex:378-381)
   only fires `:global -> :tenant`; `update_scope/2` excludes the assignee
   tenant from the referential check (`Enum.reject` on `exclude_tenant_id`),
   so self-reference doesn't block narrowing but another tenant's reference
   does. Tests at lines 460 (refused, names conflicting tenant), 481
   (self-exemption succeeds), and 495 (widening always succeeds even with
   other tenants' references) all pass.
8. **ServiceScopeValidator unchanged** — `git diff main...HEAD --
   lib/letflow/definitions/service_scope_validator.ex` is empty, confirmed
   directly. `scope_validator_lookup/1` (service_catalog.ex:501-529) builds a
   `Lookup.t()` from two closures without touching that module. Integration
   tests at lines 518 (invisible service rejected at activation) and further
   (visible service activates) pass.
9. **Migration/moduledoc divergence + REVIEWER sign-off** — both the
   migration header and `Letflow.ServiceCatalog`'s moduledoc state the
   GLOBAL-table divergence from decision 0003 Decision B with the R-Co-
   grounded reason (global referenceability + cross-tenant `service_id`
   uniqueness cannot be expressed by a per-tenant-schema copy), and both
   carry `REVIEWER sign-off: AGREE, 2026-08-30 (WF02-REQ191-20260830 Step
   2d)` — a real, dated, run-id-specific sign-off, not a placeholder string.
   Cross-checked against `handoffs/WF02-REQ191-20260830/reviewer-report-req191.md`,
   which independently reasons through the divergence rather than rubber-
   stamping the `solution_pack_installs` precedent. Tests at lines 565, 574
   assert the actual file content, not a mock. Both pass.
10. **solution_pack.ex hard-fail retained, REQ-192 named** — diffed
    `lib/letflow/definitions/solution_pack.ex`: the functional branch
    (`check_unsupported_sections/1`) is byte-identical before and after;
    only the moduledoc and a code comment changed, explicitly naming
    REQ-192 as the requirement that will decide the install-time visibility
    policy. Tests at 589 (moduledoc names REQ-192), 596 (export always `[]`),
    610 (install still hard-fails, all-or-nothing, verified against actual
    `process_definitions` row count) all pass.
11. **No route/controller** — `git diff --stat main...HEAD` (re-run
    directly) touches no file under `lib/letflow/routers/` or any
    controller path; only `handoffs/`, `lib/letflow/definitions/solution_pack.ex`
    (moduledoc only), `lib/letflow/design/`, `lib/letflow/service_catalog.ex`,
    `lib/letflow/service_catalog/entry.ex`, `lib/letflow/tenant_provisioning.ex`,
    the migration, and test/report files. Test at line 647 additionally
    asserts, independent of git history, that `lib/letflow/routers/` itself
    contains no service-catalog-named file. Both checks pass.
12. **mix test / mix compile --warnings-as-errors** — both re-run directly
    in this session (not copied from TEST-RUNNER's report); full output
    quoted above. Pass.

## Other checks performed

- `TenantProvisioning.list_registrations/0` (the one new public function
  outside `lib/letflow/service_catalog*`) is read-only (`Repo.all(Registration)`),
  flagged by the design doc's own OQ-3 and explicitly cleared by REVIEWER's
  scope-creep review — confirmed by reading the diff and the reviewer report,
  not merely trusting the report's verdict.
- `docs/migration/decisions/` was checked for any record this diff could
  contradict: none found — decision 0003 itself is the one on record, and
  this diff states its divergence rather than silently overriding it, with
  REVIEWER sign-off recorded in three places (migration header, moduledoc,
  reviewer report).
- No stage-gate `docs/migration/stage-6-*.md` REVIEWER sign-off section
  applies here — this is a WF-02 single-requirement run, not a stage gate.

## Conclusion

All 12 acceptance criteria hold against the real code and a freshly re-run
test suite, migration, and lint pass. No gap found. Routing to DOC-UPDATER
(Step 6) to flip REQ-191 to `done`.
