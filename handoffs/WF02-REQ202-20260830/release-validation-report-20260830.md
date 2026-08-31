# RELEASE-VALIDATOR report — REQ-202 (WF02-REQ202-20260830)

Independent re-verification, not a re-read of prior agents' claims. All 14 acceptance
criteria checked directly against current source and real command output on
`feature/WF02-REQ202-20260830` (clean tree, HEAD matches the branch's final commit).

## Per-AC verification

1. **AC1 (REPO-01 dedup)** — PASS. `test/letflow/repository_test.exs:105-242` ("AC1 --
   REPO-01 deduplication"): byte-identical content across two `artifact_name`s produces
   one `Repository.Artifact` row and two `ArtifactVersion` rows (asserted via
   `Repo.aggregate/3` row counts, not inferred). Read `lib/letflow/repository.ex`'s
   `upsert_content/5` myself: `Repo.insert(..., on_conflict: :nothing, conflict_target:
   :content_hash)` — genuine upsert-by-hash. Ran `mix test test/letflow/repository_test.exs`
   as part of the full suite run below: green.
2. **AC2 (key-order/whitespace insensitivity)** — PASS.
   `test/letflow/repository/canonicaliser_test.exs:24-70` asserts byte-identical
   canonical output (not just equal hash) across differing key order/whitespace,
   including a nested-object case and an array-order negative control.
3. **AC3 (number normalisation)** — PASS. Same file, `describe "AC3"` (lines 80-135):
   asserts canonical **bytes** (not just hash) for `2.0`→`2`, `3.0e2`→`300` (no decimal
   point, no exponent), and a negative control proving `2.5` is not collapsed. Read
   `canonicaliser.ex`'s `canonicalize/1` float clause myself — `trunc(value) == value`
   branch confirms this is the actual mechanism, not a coincidence of test data.
4. **AC4 (binary byte-identity)** — PASS. `describe "AC4"` (lines 143-186): WASM magic
   bytes hashed and compared directly against `:crypto.hash(:sha256, raw_bytes)` — a
   real independent SHA-256, not the module's own output compared to itself. Also
   covers OQ-3 (exact-match-only content-type dispatch) with two negative controls
   (`application/schema+json`, parameterized `application/json; charset=utf-8`).
5. **AC5 (separate module + moduledoc cross-reference)** — PASS, verified by direct
   side-by-side read, not test-trusting alone. `lib/letflow/repository/canonicaliser.ex`'s
   moduledoc names `Letflow.Definitions.PromotionDigest`, states it "does NOT normalize
   numbers," and states the two "must never be merged," citing INV-PRM-5 by name.
   `lib/letflow/definitions/promotion_digest.ex`'s moduledoc reciprocally names
   `Letflow.Repository.Canonicaliser` (REQ-202) and states it "DOES normalize numbers"
   and the two "must not be merged." Genuine substantive cross-reference in both
   directions, not a token mention.
   `git diff main...HEAD -- lib/letflow/definitions/promotion_digest.ex` (run myself):
   a single 9-line hunk, purely additive, inserted into the moduledoc's `"""` block
   only — no change to `canonicalize/1`, `compute_plan_digest/1`, or `verify_digest/2`.
   Confirms the design's own resolution of AC5's "NOT modified" vs "BOTH cross-reference"
   tension: behavior-free, moduledoc-only diff.
6. **AC6 (existing promotion digest unchanged)** — PASS.
   `test/letflow/repository_test.exs:276-311`: `PromotionDigest.compute_plan_digest/1`
   over a fixed fixture asserted equal to a hardcoded, previously-recorded hex digest,
   plus a `2.0` vs `2` differentiation test proving `PromotionDigest` still does not
   normalize numbers (guards against accidental code-sharing). Since `promotion_digest.ex`'s
   only diff is the moduledoc addition confirmed in AC5, this digest is structurally
   guaranteed unchanged, not just observed unchanged in one test run.
7. **AC7 (DB-level immutability)** — PASS. Read the migration's trigger DDL
   (`priv/repo/migrations/20260830030001_create_repository_artifacts.exs` lines
   ~140-200): `repository_artifacts` gets both `BEFORE UPDATE` and `BEFORE DELETE`
   triggers raising a fixed exception; `artifact_versions` gets `BEFORE UPDATE` only
   (DELETE left to the self-FK's `on_delete: :nilify_all`, per design §5.2, a
   deliberate and documented asymmetry, not an oversight). Corresponding tests
   (`repository_test.exs:339-387`) issue raw `Repo.query!/2` UPDATE/DELETE statements
   that go around the context API entirely and assert the Postgrex error message —
   the correct test shape for "rejected by the database, not merely absent from the
   API."
8. **AC8 (version sequencing on changed content)** — PASS.
   `repository_test.exs:395-431`: second `create/2` call for the same `artifact_name`
   with different content asserts `version_number` incremented by exactly 1, a new
   `content_hash`, unchanged `artifact_id` (lineage), and — critically — re-fetches
   the prior version row and prior content row **from the database** (not the
   in-memory struct) to prove they are untouched.
9. **AC9 (version history/pagination)** — PASS. `repository_test.exs:440-` (`describe
   "AC9"`): newest-first ordering, `parent_version_id` linkage across a 3-version
   chain, REQ-067 cursor contract (`page_size` reject-not-clamp at 0/201,
   wrong-endpoint cursor rejection, multi-page cursor advance verified against actual
   returned `version_number` sequences). Read `Letflow.Repository.list_versions/4`
   myself: uses `Pagination.build_raw_cursor_timestamp_key/4`,
   `Pagination.decode_cursor/3`, and a `(version_number, version_id)` tuple comparison
   for the seek predicate — matches design §6 verbatim.
10. **AC10 (placement stated in the migration, with reason)** — PASS. Read the
    migration file's top-of-file comment myself: states PER-TENANT placement
    explicitly, "NOT global," and cites `0003-ecto-schema-strategy.md Decision B`'s
    blast-radius-containment reasoning by name — condensed but substantively matching
    design §1's full reasoning. No REVIEWER sign-off flag needed since the
    per-tenant choice does not diverge from Decision B (the flag is conditioned on
    going global). `repository_test.exs:700-723` pins this comment's exact required
    substrings against the real file, so this is a checked invariant, not merely an
    author's claim.
11. **AC11 (migration-058-vs-045 divergence recorded)** — PASS. Read
    `lib/letflow/repository/artifact.ex`'s moduledoc myself: names both migration 058
    and 045, names 058's conflicting shape (`version_id` PK, `TEXT content_hash`,
    inline `content_json`), and states "Letflow ships exactly one shape: migration
    045's." `repository_test.exs:732-750` pins these exact substrings against the
    real compiled moduledoc via `Code.fetch_docs/1` (not a static grep of the source
    file, which would not catch drift between doc comment and compiled artifact).
12. **AC12 (REQ-041 disambiguation)** — PASS. Read `Letflow.Repository`'s moduledoc
    myself: names `solution_pack_artefact_bases`, cites REQ-041, and states "neither
    reads nor writes it." `repository_test.exs:758-773` pins this via `Code.fetch_docs/1`
    against the compiled module.
13. **AC13 (no route/controller)** — PASS, verified two independent ways. (a) I ran
    `git diff main...HEAD --stat` myself (34 files changed, full list reviewed) — no
    `lib/letflow_web/`, `lib/letflow/routers/`, or `web/` path appears anywhere in the
    diff. (b) `repository_test.exs:787-806` additionally guards against a *future*
    regression by grepping `lib/letflow/routers/**/*.ex` for any reference to
    `Letflow.Repository` and asserting `lib/letflow/router.ex` has no "repository"
    mention — this is a repo-content regression guard, correctly scoped as
    supplementary to (not a replacement for) the git-diff check.
14. **AC14 (mix test / mix compile --warnings-as-errors)** — PASS, re-run from
    scratch by me, not trusted from TEST-RUNNER's reports.
    - `mix compile --warnings-as-errors`: clean, exit 0, no output.
    - `mix format --check-formatted`: clean, exit 0, no output.
    - `bash scripts/test_parallel.sh` (N=8, nproc), run **twice**: the first run
      collided with an earlier auto-backgrounded invocation of the same script
      (both processes contending for the same Postgres connections/ports
      simultaneously), producing a corrupted result (2 partitions crashed with no
      `Result:` line, 28 failures, 2112/2118 tests) — recognized as environmental
      contention, not a code defect, and discarded. Confirmed no leftover
      `mix test`/`test_parallel` processes before rerunning
      (`pgrep -af "mix test"` / `pgrep -af test_parallel`: both empty). The clean,
      single, uncontended rerun: **combined: 2861 tests, 6 properties, 2 failures
      (2865/2867 passed)** — exactly matching TEST-RUNNER's recheck1 figures.
      Grepped the failing partition's log directly
      (`/tmp/letflow_test_parallel.C91icc/partition-3.log`): both failures are
      `Mix.Tasks.Letflow.CheckToolchainTest` ("a mismatched rust pin reports a
      MISMATCH row..." / "a matching rust pin reports OK with no mismatch..."),
      both raising because `System.cmd("rustc", ...)` cannot find the executable —
      independently confirmed via `which rustc` / `which cargo` (both empty/absent
      in this sandbox). This is exactly the documented rustc-absent baseline, and
      nothing else. Zero `TenantSchemaReaperTest` flakes appeared in this run
      (allowed up to 3 under the documented flake class; absence is expected
      variance, not a finding).
    - Independently confirmed the tenant-fixture oracle-rot fix is real, not just
      claimed: `grep -n "repository_artifacts\|artifact_versions"
      test/support/tenant_fixture.ex` shows both table names present (lines 124,
      143); `test/letflow/support/tenant_fixture_test.exs:306` asserts count `== 29`;
      `lib/letflow/tenant_provisioning.ex`'s manifest includes the migration file
      (`"20260830030001_create_repository_artifacts.exs"`, line 471).

## Additional cross-checks

- Read `lib/letflow/design/req202-artifact-repository.md` in full (623 lines) —
  confirmed no literal Elixir/SQL implementation code remains (the two prior design
  reworks' concern), only prose, table specs, and `@spec` signatures as design
  artifacts require.
- Confirmed `docs/migration/decisions/` records are not contradicted: the design and
  shipped migration both correctly apply Decision B (per-tenant, `tenant_id` retained
  as intra-schema discipline) and explicitly do NOT apply Decision C (event-table
  application-layer immutability), instead following req195's DB-trigger precedent —
  a documented, reasoned divergence from the nearest superficially-similar decision,
  not a silent one.
- This is a single-requirement WF-02 run, not a stage-gate (WF-04) run, so no
  `docs/migration/stage-N-*.md` REVIEWER sign-off section applies here.
- `handoffs/WF02-REQ202-20260830/security-review-req202.md` reviewed: SECURITY-REVIEWER
  independently confirmed no raw content column, correct tenant-manifest registration,
  and no route/controller surface — consistent with my own independent findings above.

## Overall verdict: PASS

All 14 acceptance criteria independently re-verified against real source and real
command output. No discrepancy found between any prior agent's claim and the actual
current state of the branch. Routing to DOC-UPDATER (Step 6) to flip REQ-202's status
to `done` and append the status-history event.
