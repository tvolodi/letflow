# SECURITY-REVIEWER report — REQ-202 (content-addressed artifact store + REPO-04 canonicaliser)

**Run:** WF02-REQ202-20260830, WF-02 Step 2c
**Branch:** feature/WF02-REQ202-20260830
**Reviewed against:** `docs/agents/instructions/security-invariants.md` (INV-1..INV-8)
**Diff reviewed:** `git diff main...HEAD` — new files
`priv/repo/migrations/20260830030001_create_repository_artifacts.exs`,
`lib/letflow/repository.ex`, `lib/letflow/repository/artifact.ex`,
`lib/letflow/repository/artifact_version.ex`,
`lib/letflow/repository/canonicaliser.ex`; modified files
`lib/letflow/definitions/promotion_digest.ex`,
`lib/letflow/tenant_provisioning.ex`.

## Scope test

This diff adds two new tenant-scoped tables (`repository_artifacts`,
`artifact_versions`) via a `priv/repo/migrations/*.exs` migration, and a new context
module (`Letflow.Repository`) reading/writing them. Per the scope test in
`.claude/agents/security-reviewer.md`, this is a tenant-data path. The gate applies.

## INV-1 — Tenant data isolation — APPLIES — PASS

Live per security-invariants.md's 2026-08-17 update (S1 done, S2 migrations exist).
Checked (a)/(b)/(c) as required:

- **(a) `:prefix`-scoping.** Every `Repo` call in `lib/letflow/repository.ex` passes an
  explicit `prefix:` option derived from the caller-supplied `prefix` argument:
  `Repo.insert(prefix: prefix, on_conflict: :nothing, ...)` (upsert_content/5, L189),
  `Repo.insert(prefix: prefix)` (create_with_retries/7, L151), `Repo.one(query,
  prefix: prefix)` (next_version/3, L200), `Repo.all(prefix: prefix)`
  (list_versions/4, L255). No query in this module runs against the default/public
  schema. The migration itself (`20260830030001_create_repository_artifacts.exs`)
  creates both tables and every index/constraint inside `if prefix() do ... end`,
  guarded exactly like `req195`/`req027`'s precedent — nothing is left reachable in
  `public`.
- **(b) Not silently public.** Confirmed: the migration's `change/0` body is entirely
  inside the `if prefix() do` block (lines 65–185); there is no unconditional
  top-level `create table` outside that guard. The migration is a no-op when run
  against the shared/public migration path (`prefix()` returns `nil` there), consistent
  with every other tenant-scoped migration in this codebase.
- **(c) `tenant_id` derivation.** `Letflow.Repository.create/2` and `list_versions/4`
  both call `TenantProvisioning.tenant_id_for_schema_name(prefix)` (repository.ex L106,
  L246) to derive `tenant_id` from the resolved `prefix` argument — a pure parse of the
  `tenant_<hex>` schema-name pattern into a canonical UUID
  (`tenant_provisioning.ex` L193-208), not a database lookup and not a
  separately-trusted field. `create_attrs`'s `@type` (repository.ex L58-66) has **no**
  `tenant_id` key at all — a caller cannot pass a `tenant_id` into `create/2` even if it
  wanted to; the only way `tenant_id` reaches either table is via this derivation.
  `Artifact.changeset/2` and `ArtifactVersion.changeset/2` cast `tenant_id` from attrs
  built exclusively inside `Letflow.Repository` (repository.ex L137-147, L179-185),
  never from an external caller's map. This satisfies the design §1.4 requirement and
  the 0003 addendum directly — confirmed from the actual code, not merely the design
  doc's claim about it.

No caller-supplied, separately-trusted `tenant_id` path exists anywhere in this diff.
PASS.

## INV-2 — Server-side field authorisation — NOT-APPLICABLE

No API response type, controller, or serialisation path is added by this diff (AC13,
confirmed below). S4 has not started. Deferred, per security-invariants.md.

## INV-3 — Untrusted runtime sandboxing — NOT-APPLICABLE

No script/plugin execution path touched. S5 has not started.

## INV-4 — Secrets by reference only — APPLIES — PASS

```
grep -rniE "(password|secret|client_secret|token)\s*(=|:)\s*\"[^\"]{8,}" \
  lib/letflow/repository.ex lib/letflow/repository/ \
  priv/repo/migrations/20260830030001_create_repository_artifacts.exs \
  lib/letflow/tenant_provisioning.ex lib/letflow/definitions/promotion_digest.ex
```
No hits. No secret material is read, logged, or serialized anywhere in this diff — the
new code deals exclusively in content hashes, byte sizes, and content types, not
credentials. The `promotion_digest.ex` and `tenant_provisioning.ex` diffs are a
moduledoc addition and a migration-manifest tuple respectively — neither touches
secret-handling code. PASS.

## INV-5 — Not-found/forbidden indistinguishability — NOT-APPLICABLE

No lookup-by-ID endpoint exists in this diff (no route/controller at all, AC13). S4 has
not started. `list_versions/4` is a context-module function, not an HTTP endpoint, and
per design §6 a cursor minted for one tenant, replayed against a different tenant's
`prefix`, structurally cannot see the first tenant's rows (physically separate schema)
— confirmed as an isolation property in the code (INV-1 above), but the timing/response-
shape invariant itself is only checkable once an HTTP layer exists. Deferred.

## INV-6 — New data-access paths prove their scoping — APPLIES — PASS (this report)

This report is the required proof-of-scoping artifact: INV-1/INV-4/INV-7/INV-8 assessed
above/below, INV-2/INV-3/INV-5 explicitly recorded as NOT-APPLICABLE with reasons, per
this invariant's own "how to verify."

## INV-7 — No SQL string interpolation — APPLIES — PASS

```
grep -rn "Repo.query" lib/ priv/repo/migrations/ --include=*.ex --include=*.exs
```
Hits are all in `lib/letflow/tenant_provisioning.ex`, `lib/letflow/sandbox_pool.ex`,
`lib/letflow/sandbox_pool/fixture_loader.ex` — none of these lines are touched by this
diff (`git diff main...HEAD` confirms `tenant_provisioning.ex`'s only change is the
4-line manifest-tuple addition at the bottom of `@tenant_scoped_migration_manifest`,
nowhere near its existing `Repo.query!` calls). This diff's new files contain **no**
`Repo.query`/`Ecto.Adapters.SQL.query` call at all — `lib/letflow/repository.ex` uses
only `Ecto.Query`-composed queries (`where/3`, `order_by/3`, `limit/2`, `lock/2`) via
`import Ecto.Query`, fully parameterised by Ecto.

The migration file (`20260830030001_create_repository_artifacts.exs`) does use
`execute/2` with string-interpolated SQL (`"#{schema}"` in the trigger/function DDL,
L129-184). This interpolates `schema = prefix()` — the Ecto-migration-framework-
resolved tenant schema name for the current migration run, not tenant- or
user-controlled request data (no HTTP request, no caller input reaches this value; it
is the same trusted value every other tenant-scoped migration in this codebase already
interpolates the identical way, e.g. `req195`'s audit_entries migration). This is
consistent with INV-7's rule (untrusted data is what must never be interpolated) and
the migration's own top-of-file comment explicitly makes this argument. PASS.

## INV-8 — No unhandled crashes on realistic failure paths — APPLIES — PASS

```
grep -rn "^\s*{:ok, .*} = " lib/letflow/repository.ex lib/letflow/repository/
```
One incidental substring hit inside a `case` pattern clause (`{:ok, %Pagination.Cursor{}
= cursor} -> ...`, L279) — not a bare `=` match that can raise; it is one branch of an
exhaustive `case` over `Pagination.decode_cursor/3`'s result, with sibling clauses for
`{:error, :wrong_endpoint}`, `{:error, :expired}`, and a catch-all `{:error, _}`. Not a
violation.

Reviewed the module's actual failure paths by hand:
- `create/2` uses a `with` chain over `Canonicaliser.canonicalize_content/2` and
  `TenantProvisioning.tenant_id_for_schema_name/1`, both of which can fail and both
  failures propagate as tagged errors rather than crashing.
- `create_with_retries/7`'s `Repo.transaction/1` result is matched via `case` with an
  explicit `{:error, %Ecto.Changeset{}}` branch (not a bare `{:ok, _} =`), retrying or
  returning the error tuple.
- `list_versions/4` is a `with` chain over three fallible calls
  (`tenant_id_for_schema_name/1`, `validate_page_size/1`, cursor decoding), each with
  its own `{:error, _}` branch surfaced to the caller rather than raised.
- No externally-reachable path in this diff pattern-matches a fallible external call
  with a bare `{:ok, x} =` that could raise on realistic tenant-controlled input. PASS.

## Additional checks specific to this handoff's brief

**DB-level immutability triggers (AC7).** Read the actual migration DDL
(lines 127-184): `repository_artifacts` gets both `BEFORE UPDATE` (L140-149) and
`BEFORE DELETE` (L151-160) triggers, both calling a single unconditionally-raising
function `"#{schema}".repository_artifacts_immutable()`. `artifact_versions` gets only
`BEFORE UPDATE` (L175-184), via its own distinct function
`"#{schema}".artifact_versions_immutable()` — matching design §5.1/§5.2 exactly (no
blanket DELETE trigger on `artifact_versions`, deliberately, per the design's stated
reasoning about `parent_version_id`'s `on_delete: :nilify_all`). Both trigger functions
are created with `"#{schema}".function_name()` — schema-qualified per-tenant, not a
shared `public`-schema function; each tenant schema gets its own copy of both functions,
consistent with Decision B's physical-isolation model. Confirmed, not merely trusted
from the design doc.

**Cross-tenant leak via FKs.** `artifact_versions.content_hash`'s FK
(`references(:repository_artifacts, column: :content_hash, ..., prefix: schema)`,
migration L90-97) and `parent_version_id`'s self-FK (L99-105) are both declared with
`prefix: schema` — a Postgres foreign key can only reference a table in the same,
explicitly named schema; there is no cross-schema FK here, so neither reference can
resolve into another tenant's schema. Structurally impossible for one tenant's
`artifact_versions` row to point at another tenant's `repository_artifacts`/
`artifact_versions` row. Confirmed no query in `lib/letflow/repository.ex` omits
`prefix:` (see INV-1 above) — no code path was found that queries either table without
scoping.

**Migration manifest registration.** `lib/letflow/tenant_provisioning.ex`'s diff adds
`{20_260_830_030_001, Letflow.Repo.Migrations.CreateRepositoryArtifacts,
"20260830030001_create_repository_artifacts.exs"}` to
`@tenant_scoped_migration_manifest`, immediately after the existing
`CreateAuditEntriesTenantScoped` entry, matching the tuple shape (id, module, filename)
of every other entry in the list. Correct and complete — this is the actual mechanism
by which this migration reaches real tenant schemas per this module's own manifest
comment; without this entry the migration would silently never run against any
provisioned tenant, which is exactly the failure mode this check exists to catch.

**No raw content stored (secrets/PII exposure check).** `repository_artifacts`'s
migration columns (L74-79) are exactly `content_hash` (binary, PK), `tenant_id`,
`content_type`, `byte_size`, `inserted_at` — no raw-content column. `Artifact`'s Ecto
schema (`lib/letflow/repository/artifact.ex` L52-58) declares the same field set, no
more. This matches design §2.1's column list exactly; ELIXIR-DEV did not add a
raw-content column. The artifact body itself is never persisted by this migration's
schema — only its hash, type, and size.

**No route/controller added (AC13).**
```
git diff main...HEAD --stat -- 'lib/letflow_web/*' 'web/*'
```
Empty — no output. Confirmed no HTTP surface was added by this diff.

## Verdict

All applicable invariants (INV-1, INV-4, INV-6, INV-7, INV-8) PASS. INV-2, INV-3, INV-5
correctly NOT-APPLICABLE (S4/S5 not started, no lookup-by-ID endpoint exists). No
BLOCKER found.

**Status: PASS. Routing to REVIEWER (OTP idiom, supervision integrity, scope creep,
decision-record consistency) per WF-02 Step 2c → Step 2d.**
