# Design: REQ-078 — Supporting routes (audit, definition validation, tenant config, solution packs, pin rebind, metrics)

**Requirement:** REQ-078, stage S4, `depends_on: [REQ-072, REQ-030, REQ-109]`
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ078-20260822`, WF-02 Step 1
**This document produces:** mount-point decisions, per-route method/path/delegate/response/error
mapping, the shared `variable_schemas` registration contract, the new context functions each
route needs, moduledoc content obligations, changed-file list, traceability, open questions.
**No implementation code** — no function bodies, no `.ex`/`.exs` files.

---

## 0. Sizing finding — RAISED, and RULED ON by ORCH: **do not split**

> **RULING (ORCH, WF02-REQ078-20260822): OQ-1 = option (a). Accept the added scope inside
> REQ-078. Do not split.** Splitting would strand AC3 and AC8, and AC8 exists precisely because
> an earlier requirement dropped the `variable_schemas` insert path and shipped the table empty
> (ISS-0063 / GH#212) — splitting to tidy the port would re-create the exact failure mode the
> criterion was added to prevent. **Implementation condition ORCH will enforce:** solution
> packs (§8) + the registration function (§9) are committed as **their own commit, before** the
> five thin routes, so the load-bearing half is landed first. Full ruling: §20.
>
> §0.1–§0.3 below are retained **as the raised finding and its reasoning**, not as a live
> recommendation. §0.4 is now the operative instruction.

The finding as raised follows. This was a considered judgement made *after* doing the full
design below, not an estimate made instead of it. Both halves are designed here in full, so
either decision was executable immediately — which is why ORCH could rule in one pass.

**REQ-078 as written is arguably two requirements.** This is a
considered judgement made *after* doing the full design below, not an estimate made instead
of it. Both halves are designed here in full, so either decision is executable immediately.

### 0.1 What is actually thin, and what is not

REQ-078's description asserts that all six modules are "a one-to-three-handler surface over
existing context functions". Grep-verified against this worktree, that is true of five of them
and **false of the sixth**:

| Module | Backing context in Letflow today | Verdict |
|---|---|---|
| `audit.zig` | `Letflow.EventStore.read_global/1` (`event_store.ex:761`) — exists; needs four additive filter opts | thin ✅ |
| `validation.zig` | `Graph.validate_graph/1` / `validate_node_attributes/1` / `validate_edge_conditions/1` (`graph.ex:289/317/343`) — exist; needs one small composing function | thin ✅ |
| `tenant_config.zig` | `Identity.get_tenant_by_slug/1` (`identity.ex:627`), `resolve_tenant_by_realm/1` (`identity.ex:128`) — exist | thin ✅ *(after §12's scope correction)* |
| `pin_rebind.zig` | `Letflow.Engine.PinRebind.rebind_pins/3` (`pin_rebind.ex:162`) — **exists, complete, no new context function at all** | thin ✅ |
| `metrics.zig` | nothing exists; needs three `COUNT(*)`-shaped context functions | thin ✅ |
| **`solution_packs.zig`** | **NOTHING.** `grep -rn "export_pack\|install_pack\|SolutionPackDocument" lib/` → **zero hits.** `Letflow.Definitions.SolutionPackInstall`'s entire public surface is `insert_changeset/2` (`solution_pack_install.ex:83`) — it is an Ecto schema, not an engine. REQ-041 delivered the *three-way diff* (`compute_pack_update_plan/5`, `definitions.ex:250`) plus three tables, **not** export/install. `Letflow.Definitions.ExportImport.export/2`/`import/3` (`export_import.ex:87/120`) are **single-definition**, not multi-definition pack documents. | **NOT thin ❌** |

R-Co's two solution-pack handlers are thin **only because** they delegate to
`src/solution/store.zig`'s `exportPack` (L46) and `installPack` (L284) — roughly 700 lines that
Letflow has ported none of. Porting the routes means **building that context module**
(§8.3): a multi-definition pack-document export, and an install that inserts definitions,
writes `solution_pack_installs`, runs a conflict pre-check, and performs the
`variable_schemas` registration AC8 demands — all transactionally.

### 0.2 The `variable_schemas` registration function is a third distinct unit

§9 designs `Letflow.Definitions.register_variable_schemas/3`, plus
`well_formed_json_schema?/1`, plus a change to `Letflow.Engine.VariableSchema.changeset/2` and
its moduledoc, plus the resolution of a `done`-stage open question (`req109-variable-schemas.md`
§11.3 OQ-3) and the closure of GH#306. That is not route work at all. It is a cross-cutting
storage-contract decision on a **done** S3 module, which happens to be triggered by the pack
install being the first writer.

### 0.3 The split that was proposed — **NOT TAKEN** (ORCH ruled against it; kept for the record)

| | Keeps | Acceptance criteria |
|---|---|---|
| **REQ-078 (unchanged id)** | audit, definition validation, tenant config, pin rebind, metrics — five route modules over context that exists or needs only small additions | **AC1** (narrowed to five modules), **AC2**, **AC4**, **AC5**, **AC6**, **AC7** |
| **REQ-078b (new)** | `Letflow.Definitions.SolutionPack` (`export/3`, `install/3`), `Letflow.Routers.SolutionPacks`, `Letflow.Definitions.register_variable_schemas/3`, `well_formed_json_schema?/1`, the `VariableSchema.changeset/2` change, the OQ-3 closing moduledoc, GH#306 | **AC3**, **AC8**, plus AC1's two solution-pack rows |

The split is clean because the two halves share **no** file: the solution-pack half touches
`lib/letflow/routers/solution_packs.ex`, `lib/letflow/definitions/solution_pack.ex`,
`lib/letflow/definitions.ex` (registration functions) and
`lib/letflow/engine/variable_schema.ex`; the five-route half touches the four reserved route
stubs, `definitions.ex`/`instances.ex`, `event_store.ex`, `engine.ex`, `router.ex` and
`api_pipeline.ex`. The only overlap is `lib/letflow/definitions.ex`, where the two halves add
disjoint functions (`validate_definition_graph/2` + `count_definitions_by_status/1` versus
`register_variable_schemas/3` + `well_formed_json_schema?/1`).

**The `variable_schemas` obligation must travel WITH the solution-pack half — it must not be
dropped.** That obligation exists precisely because a previous requirement dropped it and
shipped an empty table (ISS-0063 / GH#212). If REQ-078b is deferred rather than scheduled,
REQ-082 inherits the obligation to build `register_variable_schemas/3` — and REQ-082's own
text already says so ("whichever of the two lands FIRST builds that function").

### 0.4 OPERATIVE — execute the whole document as one requirement

Everything needed is in this document; nothing is under-designed to make it fit. §8 specifies
the full solution-pack context module, §9 the full registration contract. **What must not
happen is a partial build** — shipping `Letflow.Routers.SolutionPacks` over a stubbed or
half-built `install/3` would produce exactly the half-built write path AC8 exists to prevent.

**Commit order (ORCH's condition):**

1. **Commit 1 — the load-bearing half.** `Letflow.Definitions.JsonSchemaShape` (§9.3),
   `Letflow.Definitions.register_variable_schemas/3` (§9.2), the
   `Letflow.Engine.VariableSchema.changeset/2` + moduledoc changes (§9.3/§9.4),
   `Letflow.Definitions.SolutionPack` (§8.3), `Letflow.Routers.SolutionPacks` (§8.5) and its
   forward.
2. **Commit 2 — the five thin routes.** Audit (§6), definition validation (§7), tenant config
   (§12), pin rebind (§10), metrics (§11), plus the `event_store.ex` / `engine.ex` /
   `definitions.ex` counter and filter additions and the `router.ex` / `api_pipeline.ex`
   mount changes.

**Sizing finding stands as a recorded correction to the requirement text** — see §20 item C-2.

---

## 0.5 Sources read for this design

### Letflow (this worktree)

| File | Lines cited | Used for |
|---|---|---|
| `docs/requirements.yaml` | REQ-078 entry in full (description + all **eight** acceptance criteria + `depends_on`) | §1, §12 |
| `lib/letflow/routers/tenants.ex` | 1–117 (moduledoc), **181–194** (`with_authorization/4`), 356–381 (response allowlist) | §3.1 exemplar, §4 |
| `lib/letflow/routers/identity.ex` | 1–108 (moduledoc), **187–213** (`with_authorized_scope/4`), 586–637 (map builders) | §3.1 exemplar, §4 |
| `lib/letflow/routers/{audit,metrics,tenant_config,validation}.ex` | 1–12 each (the four reserved stubs) | §2 |
| `lib/letflow/routers/{instances,definitions}.ex` | 1–12 each (empty stubs, "Routes added by REQ-079/080" and "REQ-081/082") | §2.3, §2.5 |
| `lib/letflow/plugs/api_pipeline.ex` | 16–26 (deferred-plug table), 32–37 (chain), **39–49** (the eleven forwards) | §2, §11 |
| `lib/letflow/router.ex` | 61–115 (route table, `/health` at 106, `/api/v1` forward at 110, deferred table 83–97) | §2.4, §11 |
| `lib/letflow/plugs/auth_pipeline.ex` | 1–32 (moduledoc), 56–80 (`call/2`) — **confirmed: no public-path bypass exists anywhere in this plug** | §2.4 |
| `lib/letflow/api/context.ex` | 116–347; esp. **298–339** (`scoped_repo_opts/1`), 181–205 (INV-5 section), 165–176 (AC6 no-tenant-arg rule) | §3.2, §5 |
| `lib/letflow/api/response.ex` | 348–535 (every helper's `@spec`) | §6 error maps |
| `lib/letflow/api/error.ex` | 64–65 (`defstruct`), 85–92 (`@type t`), **103–116** (`serialise/1`, incl. the `errors: [_\|_]` clause), 213–221 (`unprocessable/1`) | §6.2 |
| `lib/letflow/api/pagination.ex` | 43–56 (`Cursor`), 59–78 (`Page`), 111–113, 133–135, 153–154, 164–165, **188–194** (`decode_cursor/4`), 268–269 (`build_raw_cursor/3`) | §6.1 |
| `lib/letflow/api/validation.ex` | 1–56 (`FieldConstraint`/`FieldError`), 189 (`validate/2`), 224 (`problem/1`) | §6, §7, §8 |
| `lib/letflow/api/authorization.ex` | **227** (`endpoint_policy_key("GET", "/audit") -> :AuditRead`), **232** (`("GET","/metrics") -> :MetricsRead`), **265** (`_,_ -> :Unknown`), **272–300** (`evaluate_access/2`, incl. the `:MetricsRead` unconditional-Allow short-circuit at 281–282 and the `:Unknown` PLATFORM_ADMIN-only branch at 274–279), 336 (`required_permission(:AuditRead) -> :AuditRead`), 366–397 (`role_allows?/2` matrix; `:PROCESS_OPERATOR` holds `:AuditRead` at 388) | §4, §5 |
| `lib/letflow/event_store.ex` | **726–741** (`read_global_opts`/`read_global_result`/`read_global_error`), **759–761** (`read_global/1` `@spec`), 903–907 (`clamp_read_global_limit/1`) | §6.1 |
| `lib/letflow/event_store/event.ex` | **79–90** (the `events` schema field list) | §6.1 field mapping |
| `lib/letflow/definitions.ex` | 400 (`create/2`), 424 (`get_by_id/2`), 466 (`list/2`), 250/254 (`compute_pack_update_plan/5`), 107–210 (types). **Zero occurrences of `variable_schema` in this file** | §7, §8, §9 |
| `lib/letflow/definitions/graph.ex` | 73–108 (`Node`/`Edge`), **110–140** (`Violation`, incl. the 26-value `code()` union), 161–168 (`Graph` struct + `result()`), 190/201 (`from_map/1`), **289** (`validate_graph/1`), **317** (`validate_node_attributes/1`), **343** (`validate_edge_conditions/1`) | §7 |
| `lib/letflow/definitions/service_scope_validator.ex` | 162 (`build/1`), **184** (`validate/3`) | §7 (deliberate non-call) |
| `lib/letflow/definitions/solution_pack_install.ex` | 60–72 (schema), **83** (`insert_changeset/2`) — **the only public function; no export/install engine here** | §8, OQ-1 |
| `lib/letflow/definitions/solution_pack_artefact_base.ex` | 50 (schema), 100 (unique constraint) | §8 |
| `lib/letflow/definitions/pack_update_resolution.ex` | 56–71 (schema), 84 (`insert_changeset/2`) | §8 |
| `lib/letflow/definitions/export_import.ex` | 33 (`@export_schema_version "bpm/definition/v1"`), 35–62 (`ExportDocument`), 65–72 (error types), **87** (`export/2`), **120** (`import/3`) | §8 |
| `lib/letflow/engine/pin_rebind.ex` | 90–136 (all types, incl. `rebind_attrs` requiring `:idempotency_key`, and the full `rebind_error()` union), **162** (`rebind_pins/3`, the module's only public function) | §10 |
| `lib/letflow/engine/pin_resolver.ex` | 179 (`kind()`), 199–205 (`override_entry()`), 284–290 (`default_lookup/0` + the `json_schema: nil` stub) | §10 |
| `lib/letflow/engine/variable_schema.ex` | **120–128** (schema), 130–143 (`t()`, `schema_map()`, `error_reason()`), **145–164** (`changeset/2` + its OQ-3 `@doc`), 207–215 (`variable_validations/5`), **257–274** (`fetch_schemas/3` — the ISS-0089 site), **327–351** (`validations_for/3` + its `{:ok, _not_a_map}` clause), 56–82 (the "registration path is deferred" moduledoc section) | §9 |
| `lib/letflow/event_store/registry/json_schema.ex` | 32 (`validate/2`, the only public fn), **146–173** (`properties_violations/3` — **already carries the ISS-0088 `is_map(subschema)` guard**) | §9 |
| `lib/letflow/event_store/instance_projection.ex` | **124–128** (`instance_projections` schema, `status` enum `[:active, :completed, :cancelled, :error]`), 132 (`definition_id`) | §11 |
| `lib/letflow/engine/task.ex` | 53–70 (`tasks` schema), **57–62** (`status` enum `[:pending, :completed, :cancelled]`) | §11 |
| `lib/letflow/definitions/process_definition.ex` | **91–94** (`status` enum `[:draft, :active, :deprecated, :archived]`) | §11 |
| `lib/letflow/identity.ex` | 128 (`resolve_tenant_by_realm/1`), 145 (`resolve_realm_by_tenant/1`), **627** (`get_tenant_by_slug/1`), 582/609/641/661/668 | §12 |
| `lib/letflow/tenant_provisioning.ex` | **166** (`schema_name_for_tenant/1`), **195/208** (`tenant_id_for_schema_name/1`), 426–427 (variable_schemas migration manifest entry) | §5, §9 |
| `lib/letflow/oidc/claim_mapping_config.ex` | 20–54 (struct), 57 (`for_realm/1`), 88 (`default/1`) | §12 (deliberate non-use) |
| `lib/letflow/design/req070-router-decomposition.md` | 100–140 (sub-router roster + module template), 202–205 (the four forwards) | §2 |
| `lib/letflow/design/req109-variable-schemas.md` | 78–184 (migration/schema/changeset), §11.3 OQ-3 | §9 |
| `docs/issues/ISS-0089.yaml` | full (`status: open`, GH#306, both candidate resolutions) | §9.4 |
| `docs/issues/ISS-0088.yaml` | header + `status: resolved` (GH#305) | §9.4 — **contradicts the requirement text; see §14 C-1** |
| `docs/migration/stage-4-api-surface.md` | 82–100 (group (a) table), 101–120 (group (b) table incl. the `sandbox_access.zig` row), 121–137 (middleware) | §2, §13 |
| `docs/agents/instructions/security-invariants.md` | INV-1, INV-2, INV-4, INV-5, INV-6, INV-7, INV-8 in full | §5 |
| `docs/anti-patterns.md` | full | — |
| `web/src/api/audit.ts` | 1–70 (`RawAuditEntry`, `RawAuditPage`, the `/api/v1/audit` call + its six query params) | §6.1 |
| `web/src/auth/tenantConfig.ts` | 40–52 (the `/api/tenant-config` call with `realm`-or-`host` params) | §12 |
| `web/src/api/metrics.ts` | 126–128 (`client.getText('/metrics')`, Prometheus text) | §11, OQ-6 |

### R-Co (`C:\Users\tvolo\dev\ai-dala\R-Co\`)

| File | Lines cited | Used for |
|---|---|---|
| `src/api/routes/audit.zig` | 10–19 (`ListAuditParams`), **21–52** (`handleList` + the whole error map), 54–77 (`serializeList` — the `{items,next_cursor,count}` body), 79–126 (`appendItem` — the nine per-entry keys) | §6.1 |
| `src/obs/audit.zig` | 26–50 (`AuditEntry`), 51–61 (`ListFilters`), 63–72 (`ListResult`), **74–107** (`list/3`, `FROM audit_entries`) | §6.1 |
| `src/api/routes/validation.zig` | **1–31** (header: path, auth, tenant-scoping, "cross-tenant reads fall through as `DefinitionNotFound` (HTTP 404)"), 60–74 (the documented status map), **75–139** (`handleValidate`) | §7 |
| `src/api/validation.zig` | 1–16 (header: "Input validation module … API-07 … validates incoming request payloads"), 28–52 (`FieldError`) | §7.4 (the AC6 distinction) |
| `src/api/routes/tenant_config.zig` | **1–6** (header: "Public endpoint (no auth required)", OIDC-F-05), 20–27 (`TenantConfigResponse`), **44–115** (`handleTenantConfig` — realm-then-host precedence and the never-error fallback), 117–155 (`resolveTenantBySlug`), 157–207 (`queryRealmByHostname`) | §12 |
| `src/api/routes/solution_packs.zig` | 1–5 (the two SOL-01/02 paths), **29–92** (`handleExport` + its error map), **110–145** (`handleInstall` + its error map), 146–345 (`parseDocument`), **287–318** (the `variable_schemas` array: `definition_id`/`schema_name`/`schema_content`), 351–424 (`serializeDocument`), **426–463** (`serializeInstallResult`) | §8 |
| `src/solution/store.zig` | 11–21 (re-exported types), **46** (`exportPack`), 126–145 (per-definition `SELECT variable_key, json_schema FROM variable_schemas`), **284–289** (`installPack`), **415–441** (the `VariableSchemaConflict` pre-check), **480–493** (`INSERT INTO variable_schemas … ON CONFLICT (definition_id, variable_key) DO NOTHING`), 589 (`checkRoleGate`) | §8, §9 |
| `src/api/routes/pin_rebind.zig` | **1–3** (`POST /api/v1/instances/:id/rebind-pins`), **24–44** (the documented request body, success body, and nine error codes), 45–163 (`handleRebindPins`), 165–170 (`parsePinKind`) | §10 |
| `src/api/routes/metrics.zig` | **1–59**; esp. 8 (`collectGlobalPrometheusText`), **20** (`// /metrics is intentionally unauthenticated (OBS-02).`), 21–25 (`content_type = PROMETHEUS_CONTENT_TYPE`), 32/48 (`bpm_active_instances_total`, `bpm_task_completions_total{definition_id=…}`) | §11 |
| `src/main.zig` | 17–18, 54–55, 92–93, 100 (module registrations); **457** (`/metrics`), **462–464** (`/api/tenant-config`, commented "public — no auth required"), **777–784** (`POST …/definitions/:id/validate`), **847–849** (`POST …/instances/:id/rebind-pins`), **1189–1214** (`GET /api/v1/audit`, incl. the hardcoded `actor.role = .PLATFORM_ADMIN` at 1190–1196 and the consequently-dead `!= PLATFORM_ADMIN -> 403` branch at 1198), **1541–1553** (`POST /api/v1/tenants/{tenant_id}/solution-packs/{export,install}`) | §2, §4 |

**Not read, and why:** `src/api/routes/sandbox_access.zig` — deliberately out of scope, see §13.

---

## 1. What this requirement is, restated

Six R-Co route modules (1,356 lines total) are ported onto backing Letflow subsystems.
Five of the six are genuinely thin. **One is not** — solution packs has no backing context
in Letflow at all (§8, OQ-1). Plus one cross-cutting obligation that is not a route at all:
the single shared `variable_schemas` registration function (§9), which this requirement
builds because REQ-082 has not (verified: `lib/letflow/definitions.ex` and
`lib/letflow/definitions/solution_pack_install.ex` contain **zero** occurrences of
`variable_schema`, and REQ-082 is `status: pending`).

---

## 2. Mount-point decisions — the single table (§2.7 is the summary)

REQ-070's roster (`lib/letflow/design/req070-router-decomposition.md:126-136`) assigned four
of these six a mount point **by Elixir module name, not by R-Co URL**. Checked against
`src/main.zig`, three of those four assignments are wrong about the URL, and one is wrong
about the authentication boundary. `docs/migration/stage-4-api-surface.md:82-100` assigns no
mount point to any of the six, so these are genuinely open and are decided here.

### 2.1 Audit — `Letflow.Routers.Audit` at `/audit` — **stub kept as-is** ✅

R-Co: `GET /api/v1/audit` (`main.zig:1189-1214`). Letflow: `GET /api/v1/audit`. Identical.
`Letflow.Api.Authorization.endpoint_policy_key("GET", "/audit")` already returns `:AuditRead`
(`authorization.ex:227`), and `web/src/api/audit.ts:59` already calls exactly this path.
Nothing changes about the mount.

### 2.2 Metrics — `Letflow.Routers.Metrics` at `/metrics` — **stub kept, with two named divergences**

R-Co: top-level `GET /metrics`, **unauthenticated** (`main.zig:457`; `metrics.zig:20` says so
verbatim), Prometheus exposition text, platform-global in-memory registry.
Letflow: `GET /api/v1/metrics`, **authenticated** (it sits behind `Letflow.Plugs.AuthPipeline`,
which has no bypass), JSON, per-tenant. Full reasoning and the moduledoc obligation: §11.

**Why not move it to the top level to match R-Co.** Letflow has no `MetricsRegistry` and no
observability subsystem, so there are no in-memory platform counters to serve. Every figure
Letflow can produce today comes out of a **tenant schema**, and reaching a tenant schema
requires `Letflow.Api.Context.scoped_repo_opts/1`, which requires
`conn.assigns[:auth_context]`, which requires authentication. An unauthenticated `/metrics`
in Letflow would therefore have to be either empty or cross-tenant. It stays authenticated.

### 2.3 Definition validation — **moves to `Letflow.Routers.Definitions`; `Letflow.Routers.Validation` is deleted**

R-Co: `POST /api/v1/definitions/:id/validate` (`main.zig:777-784`, `validation.zig:6`).
R-Co has **no `/validation` URL prefix anywhere.** The `Letflow.Routers.Validation` stub at
`/validation` is an artefact of REQ-070 grouping by Zig **filename** (`routes/validation.zig`)
rather than by URL.

**Decision:** declare `post "/:id/validate"` on `Letflow.Routers.Definitions` (already mounted
at `/definitions`, currently an empty stub), giving `POST /api/v1/definitions/:id/validate` —
byte-identical to R-Co. **Delete** `lib/letflow/routers/validation.ex` and its forward at
`api_pipeline.ex:48`.

**Rejected alternative:** keep `/validation` and serve `POST /validation/definitions/:id`.
Rejected because it invents a URL that exists in neither R-Co nor `web/`, and because
`Plug.Router`'s `forward/2` is prefix-exclusive — two sub-routers cannot both own
`/definitions`, so a `/validation`-mounted module could never carry R-Co's real path.
Leaving the stub in place unused is also rejected: its own moduledoc promises "Routes added
by REQ-078", so after this requirement it would be a module that documents a promise it did
not keep.

**Co-ownership note for ORCH.** `Letflow.Routers.Definitions` is reserved for REQ-081/082
(both `pending`). This requirement adds exactly one route to it and does not touch its
`match _` catch-all. REQ-081/082 must be sequenced after this requirement, or must rebase.
The same note applies to `Letflow.Routers.Instances` (§2.5) and REQ-079/080.

### 2.4 Tenant config — **moves out of the authenticated pipeline to the top-level router**

R-Co: `GET /api/tenant-config?host=…` (or `?realm=…`), **explicitly public**
(`tenant_config.zig:1-4`: "Public endpoint (no auth required)"; `main.zig:462` carries the
same comment). Its purpose is login-page bootstrap: the SPA calls it to learn which OIDC
authority to redirect to. `web/src/auth/tenantConfig.ts:46` calls exactly `/api/tenant-config`.

The stub is mounted at `/tenant-config` **inside** `Letflow.Plugs.ApiPipeline`, i.e. behind
`Letflow.Plugs.AuthPipeline`. Confirmed by reading `auth_pipeline.ex` in full: there is **no**
public-path allowlist, no bypass, no `skip` option — every request reaching that plug without
a valid bearer token gets 401. A login-bootstrap endpoint behind auth is unreachable by the
only caller that needs it. This is not a preference; it is a functional defect in the reserved
mount point.

**Decision:** `Letflow.Routers.TenantConfig` is forwarded from **`Letflow.Router`**, not from
`Letflow.Plugs.ApiPipeline` — `forward("/api/tenant-config", to: Letflow.Routers.TenantConfig)`,
declared **before** the `/api/v1` forward at `router.ex:110`, exactly as `GET /health` is
(`router.ex:106`). The `/tenant-config` forward at `api_pipeline.ex:47` is **removed**. The
module file stays where it is; only its mount moves.

Disclosure analysis (INV-5) is in §12.2 — the "fall through to the default config on any
miss or any error" behaviour is what keeps it from being a tenant-existence oracle, and it
is therefore a **load-bearing behaviour to port, not an R-Co quirk to tidy up.**

### 2.5 Pin rebind — **routes onto `Letflow.Routers.Instances`; no new sub-router**

R-Co: `POST /api/v1/instances/:id/rebind-pins` (`pin_rebind.zig:1-3`, `main.zig:847-849`).
This is an instances route. `Plug.Router`'s `forward/2` is prefix-exclusive, so a separate
`Letflow.Routers.PinRebind` **cannot** be mounted at `/instances`; it would force an invented
URL. Declare `post "/:id/rebind-pins"` on `Letflow.Routers.Instances` (currently an empty
stub). Ordering inside that module matters — it must precede any future `post "/:id"`,
matching R-Co's own comment at `main.zig:848` ("must precede plain /:id"); this requirement
declares no other instances route, so the constraint is recorded for REQ-079.

### 2.6 Solution packs — **new `Letflow.Routers.SolutionPacks` at `/solution-packs`; the path `tenant_id` is dropped**

R-Co: `POST /api/v1/tenants/{tenant_id}/solution-packs/export` and `.../install`
(`solution_packs.zig:1-5`, `main.zig:1541-1553`). The `{tenant_id}` is **caller-supplied in
the path**.

**Decision: drop the path segment entirely.** Letflow paths are
`POST /api/v1/solution-packs/export` and `POST /api/v1/solution-packs/install`, served by a
new `Letflow.Routers.SolutionPacks`, forwarded from `Letflow.Plugs.ApiPipeline`.

> **The tenant a solution-pack request reads from and writes into is derived solely from
> `Letflow.Api.Context.scoped_repo_opts/1`, i.e. solely from
> `conn.assigns[:auth_context][:tenant_id]`. No tenant identifier appears anywhere in these
> two URLs, so no caller-supplied tenant value can reach a `:prefix` — not by precedence,
> not by fallback, not by a future refactor.** (INV-1, and `Letflow.Api.Context`'s own AC6
> rule at `context.ex:165-176` that no function in that module may take a tenant argument.)

**Rejected alternative:** keep `/tenants/:slug/solution-packs/…` for path fidelity and 404 on
a mismatch against the token's tenant. Rejected because a path segment that is authoritative
for nothing is a standing invitation for a later reader to "wire it up", which would be a
cross-tenant write. Rejected also because `/tenants` is already forwarded to
`Letflow.Routers.Tenants` (`api_pipeline.ex:40`), so this shape would put pack export/install
inside the PLATFORM_ADMIN-only tenant-administration router — the wrong permission neighbourhood.

### 2.7 The single mount table

| # | R-Co source | R-Co path | Letflow method + path | Sub-router module | Mounted from | Authenticated? | Permission key | Divergence justification |
|---|---|---|---|---|---|---|---|---|
| 1 | `routes/audit.zig` `handleList` (L21) | `GET /api/v1/audit` | `GET /api/v1/audit` | `Letflow.Routers.Audit` | `ApiPipeline` (existing forward, `api_pipeline.ex:46`) | yes | **`:AuditRead`** (route-local call, §4) | none |
| 2 | `routes/validation.zig` `handleValidate` (L75) | `POST /api/v1/definitions/:id/validate` | `POST /api/v1/definitions/:id/validate` | `Letflow.Routers.Definitions` | `ApiPipeline` (existing forward, `api_pipeline.ex:42`) | yes | none (§4.3) | none on path; the `/validation` stub is deleted (§2.3) |
| 3 | `routes/tenant_config.zig` `handleTenantConfig` (L44) | `GET /api/tenant-config` (public) | `GET /api/tenant-config` (public) | `Letflow.Routers.TenantConfig` | **`Letflow.Router`** (new top-level forward) | **no** | none | Mount **moves out of `ApiPipeline`**: `AuthPipeline` has no bypass, and a login-bootstrap endpoint behind auth cannot serve its only caller (§2.4) |
| 4 | `routes/solution_packs.zig` `handleExport` (L29) | `POST /api/v1/tenants/{tenant_id}/solution-packs/export` | `POST /api/v1/solution-packs/export` | `Letflow.Routers.SolutionPacks` (**new**) | `ApiPipeline` (**new forward**) | yes | none (§4.3) | Path `{tenant_id}` **dropped** — INV-1 (§2.6) |
| 5 | `routes/solution_packs.zig` `handleInstall` (L110) | `POST /api/v1/tenants/{tenant_id}/solution-packs/install` | `POST /api/v1/solution-packs/install` | `Letflow.Routers.SolutionPacks` (**new**) | `ApiPipeline` (**new forward**) | yes | none (§4.3) | same as row 4 |
| 6 | `routes/pin_rebind.zig` `handleRebindPins` (L45) | `POST /api/v1/instances/:id/rebind-pins` | `POST /api/v1/instances/:id/rebind-pins` | `Letflow.Routers.Instances` | `ApiPipeline` (existing forward, `api_pipeline.ex:41`) | yes | none (§4.3) | none on path; no new `PinRebind` sub-router (forward is prefix-exclusive, §2.5) |
| 7 | `routes/metrics.zig` `handleMetrics` (L8) | `GET /metrics` (public, Prometheus text, platform-global) | `GET /api/v1/metrics` (JSON, **per-tenant**) | `Letflow.Routers.Metrics` | `ApiPipeline` (existing forward, `api_pipeline.ex:49`) | **yes** (R-Co: no) | `:MetricsRead` **not evaluated** (§4.3, §11.3) | Three divergences — auth, scope, format — all named in §11.2 and required verbatim in the moduledoc |

---

## 3. Shared structure every new handler follows

### 3.1 Handler shape — copied from the two exemplars, not reinvented

Every route module in this requirement matches `Letflow.Routers.Tenants` /
`Letflow.Routers.Identity` exactly:

* `use Plug.Router`, then `plug(:match)`, `plug(:dispatch)` — **no plug chain declared in a
  sub-router** (`req070-router-decomposition.md:141-144`).
* One `get`/`post` macro per route whose body does nothing but call a private
  `handle_*/N` through the preamble helper (§4), passing the path param explicitly, e.g.
  `conn.params["id"]` — never re-deriving the path template from `conn.request_path`.
* A terminal `match _ do Response.not_found(conn) end`.
* Request bodies validated through `Letflow.Api.Validation.validate/2` against a
  module-attribute `[%FieldConstraint{}]` schema, with `{:errors, field_errors}` rendered by
  `Response.send_problem(conn, Validation.problem(field_errors))`.
* Response bodies built by a **hand-written private map builder with an explicit key list**,
  never a `Jason.Encoder` derivation over an Ecto struct (INV-2; `tenants.ex:356-372` is the
  precedent, including its `@doc false` + `@spec` on the private builder).
* Timestamps rendered by a private `iso8601/1` matching `tenants.ex:377-381`
  (`NaiveDateTime` → `DateTime.from_naive!("Etc/UTC")` → `DateTime.to_iso8601/1`). For
  `:utc_datetime_usec` fields (`events.created_at`, `tasks.completed_at`) a second clause
  taking `%DateTime{}` and calling `DateTime.to_iso8601/1` directly is added — same function,
  one extra clause, not a second helper.

### 3.2 Ordering guarantee — inherited, not re-invented

> `Letflow.Routers.Tenants`'s moduledoc section **"Ordering guarantee (design §6.1)"**
> (`tenants.ex:74-81`) is the ordering contract every route module in this requirement also
> honours: **no `Repo` call of any kind — including a pre-fetch read — happens before the
> preamble has resolved the scoped prefix and, where a permission gate applies, before
> `evaluate_access/2` has returned a non-`:Deny403` decision.**

Each new/extended route module's moduledoc must contain an "Ordering guarantee" section
stating this and citing `lib/letflow/routers/tenants.ex`'s section by name.

### 3.3 No `Repo.` call in any route module

Hard rule for this requirement. Every handler delegates to a context module. Where the needed
context function does not exist, §7/§8/§9/§10/§11 name the module it lands on, its full
`@spec`, and its error tuples. **`ELIXIR-DEV` must be able to run
`grep -n "Repo\." lib/letflow/routers/*.ex` after implementation and get zero hits.** That
grep is a stated verification step, not a suggestion.

---

## 4. Authorization — the temporary route-local call

### 4.1 The gap, and the decision

REQ-130 (authorization-plug design) and REQ-131 (its implementation) are **both `status:
pending`** (verified in `docs/requirements.yaml` this run). There is therefore no
authorization plug. `Letflow.Api.Authorization` is nonetheless already called from two route
modules, each with its own private helper:

* `lib/letflow/routers/tenants.ex:181-194` — `defp with_authorization(conn, method, path_template, fun)`
* `lib/letflow/routers/identity.ex:187-213` — `defp with_authorized_scope(conn, method, path_template, fun)`
  (same shape, plus a `Context.scoped_repo_opts/1` step 1)

**Decision: option (i) — a third private copy in `Letflow.Routers.Audit`, not an extraction.**

Rationale, recorded as instructed:

1. Extraction would be a refactor of two already-merged, already-security-reviewed modules,
   inside a requirement whose scope is six route ports plus a registration function. That is
   scope creep into other requirements' files.
2. A single shared `Letflow.Api.Authorization`-adjacent helper that every router calls to gate
   every request **is the plug REQ-131 is chartered to build.** Building it here under a
   different name pre-empts REQ-131's design (REQ-130) and would make REQ-131 a deletion
   exercise rather than a build.
3. Three copies of a 13-line helper is a small, visible, greppable debt with a named owner.
   One copy in a shared module is an invisible architectural commitment.
4. The copy is deliberately **narrow**: it appears in `Letflow.Routers.Audit` only. It is not
   added to the definitions, instances, solution-packs, tenant-config, or metrics routes
   (§4.3).

Consolidation point: REQ-131 replaces all three copies at once with a real plug.

### 4.2 The exact shape (`Letflow.Routers.Audit`, private)

Structurally identical to `tenants.ex:181-194`:

```
@spec with_authorization(
        Plug.Conn.t(),
        method :: String.t(),
        path_template :: String.t(),
        (Plug.Conn.t() -> Plug.Conn.t())
      ) :: Plug.Conn.t()
defp with_authorization(conn, method, path_template, fun)
```

Behaviour contract (no body here — this is a design document):

1. Build `%Letflow.Api.Authorization.AccessContext{user_id: conn.assigns.auth_context.user_id,
   roles: Letflow.Api.Authorization.roles_from_strings(conn.assigns.auth_context.roles)}`.
   `roles_from_strings/1` (`authorization.ex:161-171`) is the mandatory conversion — it drops
   unrecognised strings and never reaches the atom table.
2. `decision = Authorization.evaluate_access(ctx, Authorization.endpoint_policy_key(method, path_template))`.
   `method` and `path_template` are **string literals at the call site** (`"GET"`, `"/audit"`),
   never derived from `conn`.
3. `decision.kind`: `:Deny403` → `Response.forbidden(conn, "insufficient permissions")` and
   return immediately, no `Repo` call on that path. Anything else (`:Allow`,
   `:AllowWithRowFilter`) → `fun.(conn)`.

For `GET /audit`, `endpoint_policy_key("GET", "/audit")` returns `:AuditRead`
(`authorization.ex:227`) and `required_permission(:AuditRead)` returns `:AuditRead`
(`authorization.ex:336`). Per `role_allows?/2`: `PLATFORM_ADMIN` (L366, catch-all) and
`PROCESS_OPERATOR` (L388) hold it; `PROCESS_DESIGNER`, `TASK_WORKER`, `AGENT_RUNNER` do not.
So a `PROCESS_DESIGNER`-only or `TASK_WORKER`-only caller gets **403**, which is AC2's second
clause.

**Required moduledoc sentence in `Letflow.Routers.Audit`** (wording is an obligation; exact
phrasing is ELIXIR-DEV's):

> This module calls `Letflow.Api.Authorization.evaluate_access/2` **from inside its own
> handler**, through a private `with_authorization/4` that is a third copy of the helper
> already in `lib/letflow/routers/tenants.ex:181` and `lib/letflow/routers/identity.ex:187`.
> **This is temporary.** REQ-131 builds the authorization plug that supersedes all three
> copies at once; when it lands, this helper is deleted, not adapted. Do not extract it into
> a shared module in the meantime — a shared always-called gate *is* REQ-131's plug under
> another name, and building it here would pre-empt REQ-130's design.

### 4.3 Why the other five routes get no permission gate here

`Letflow.Api.Authorization.endpoint_policy_key/2` (`authorization.ex:186-265`) has **no**
clause for `POST /definitions/:id/validate`, `POST /solution-packs/*`, or
`POST /instances/:id/rebind-pins`. All three fall to the catch-all at L265 and return
`:Unknown`, and `evaluate_access/2`'s `:Unknown` branch (L274-279) allows **PLATFORM_ADMIN
only**.

Adding `endpoint_policy_key/2` clauses for them would be **inventing new authorization
policy** — R-Co's own `authorization.zig` has no entries for these paths either, so there is
nothing to port. Deciding what permission a pack install or a pin rebind requires is a policy
question that belongs to REQ-130/REQ-131, not to a route-port requirement.

**Decision:** these routes call `evaluate_access/2` **not at all** in this requirement. They
are authenticated (via `AuthPipeline`) and tenant-scoped (via `scoped_repo_opts/1`), and their
permission gate arrives with REQ-131. Each of the three modules' moduledocs must say so
explicitly, naming REQ-131, so the gap is visible rather than silent. Recorded as **OQ-3**.

`GET /metrics` is the special case — see §11.3.

### 4.4 404 vs 403 — the per-endpoint rule (Decision 5)

| Situation | Status | Mechanism |
|---|---|---|
| Caller lacks `:AuditRead` on `GET /audit` | **403** | `evaluate_access/2` → `:Deny403` → `Response.forbidden/2`. A *permission* answer about a resource class, not a question about a specific row's existence. |
| `GET /audit` — another tenant's events | **absent from the response body** | `read_global/1` runs with `prefix: <caller's schema>`. Tenant B's rows are not in that schema. There is no filter to bypass and no 403 involved. |
| `POST /definitions/:id/validate` — `:id` belongs to another tenant | **404** | `Definitions.get_by_id/2` with the caller's `:prefix` returns `{:error, :not_found}` → `Response.not_found/1`. Byte-identical to a genuinely absent id (`Error.not_found/0` takes no detail). Matches `validation.zig:31`'s own documented behaviour. |
| `POST /definitions/:id/validate` — `:id` genuinely absent | **404** | same call, same code path, same bytes, same query count. |
| `POST /instances/:id/rebind-pins` — instance in another tenant | **404** | `PinRebind.rebind_pins/3` with the caller's `:prefix` returns `{:error, :instance_not_found}` → `Response.not_found/1`. |
| `POST /solution-packs/export` — a `definition_id` in another tenant | **422 `DEFINITION_NOT_FOUND`** | The prefix-scoped read finds nothing; the export reports it as a not-found definition id, exactly as R-Co does (`solution_packs.zig:80`). This is the *body-parameter* not-found case, not a resource-URL 404. |
| Any of the above with a caller whose `auth_context` is missing/invalid | **500** | `scoped_repo_opts/1` returns `{:error, _}` → `Response.internal_error/1`, matching `identity.ex:189-190`. Never falls through to an unscoped query. |

**No handler may add a cross-tenant existence check to produce a nicer message.** This is
discharged structurally at `Letflow.Api.Context`'s boundary — see its moduledoc section
"Why no cross-tenant existence check is added anywhere (AC7, INV-5)" (`context.ex:181-205`).

---

## 5. Tenant scoping — one mechanism, five consumers

Every authenticated route in this requirement obtains its prefix from **one** call:

```
Letflow.Api.Context.scoped_repo_opts(conn)
  :: {:ok, prefix: String.t()} | {:error, :missing_auth_context | :invalid_tenant_id}
```
(`lib/letflow/api/context.ex:326-328`)

`{:error, _}` → `Response.internal_error/1`, never a query. The returned keyword fragment is
spread into the context function's `opts`. No route in this requirement calls
`TenantProvisioning.schema_name_for_tenant/1` directly.

`GET /api/tenant-config` is the one route that does **not** call it — it is unauthenticated by
design and reads only the **global** `tenants` table (§12).

---

## 6. Route 1 — Audit (`Letflow.Routers.Audit`)

### 6.1 Contract

| Item | Value |
|---|---|
| R-Co source | `src/api/routes/audit.zig:21-52` (`handleList`), body shape at L54-126; backing store `src/obs/audit.zig:74-107` |
| Method + path | `GET /api/v1/audit` |
| Mount | `Letflow.Routers.Audit`, existing forward `api_pipeline.ex:46` |
| Permission | `:AuditRead`, via the route-local `with_authorization/4` (§4.2) — **403** on `:Deny403` |
| Delegate | `Letflow.EventStore.read_global/1` (**extended**, §6.3) |

**The backing store is different from R-Co's, and this must be stated.** R-Co reads a dedicated
`audit_entries` table (`obs/audit.zig:107`). Letflow has **no such table** — verified:
`grep -rn "audit_entries\|audit_log" priv/repo/ lib/` returns only a comment in
`priv/repo/migrations/20260816193002_create_instance_definition_snapshots.exs:71`. REQ-078's own
description redirects this route onto REQ-026's event read paths, so the audit list is served
from the tenant-scoped `events` table via `read_global/1`.

### 6.2 Field mapping, R-Co `AuditEntry` → Letflow `events` row

`events` fields: `event_id`, `created_at`, `instance_id`, `event_type`, `payload`, `actor_id`,
`sequence_number`, `idempotency_key`, `metadata`, `global_seq`
(`lib/letflow/event_store/event.ex:79-90`).

| R-Co key (`audit.zig:79-126`) | Letflow value | Note |
|---|---|---|
| `audit_id` | `event.event_id` | |
| `actor_id` | `event.actor_id` (nullable) | |
| `action` | `event.event_type` | |
| `resource_type` | the constant string `"instance"` | Every Letflow event is instance-scoped; there is no second resource kind in `events`. |
| `resource_id` | `event.instance_id` | |
| `pipeline_run_id` | `event.metadata["pipeline_run_id"]`, else `null` | `Letflow.Api.Context` reserves `:pipeline_run_id` as a documented-but-unwritten key (`context.ex:136-142`), so nothing writes it today; the key is emitted as `null` rather than omitted, so the response shape is stable. |
| `timestamp` | `event.created_at`, ISO 8601 UTC | |
| `before_state` | **always `null`** | Letflow's event model has no before/after capture. Emitting a fabricated value would be worse than `null`. |
| `after_state` | **always `null`** | same |
| — (**Letflow addition**) | `payload` — `event.payload` verbatim | The tenant's own event payload, returned to a caller inside that tenant holding `:AuditRead`. Without it the response carries no information about *what* changed, which would make the endpoint useless. Named as an addition so it is not mistaken for R-Co's `after_state`. |

Response body (matching `audit.zig:54-77` and `web/src/api/audit.ts:36-40`):

```
%{
  "items"       => [ <the ten keys above>, ... ],   # ascending global_seq
  "next_cursor" => String.t() | nil,
  "count"       => non_neg_integer()                # length(items), not a total
}
```

### 6.3 Filters — what has backing, and what does not (do not silently drop)

R-Co's `ListAuditParams` (`audit.zig:10-19`) carries eight params. Disposition:

| Param | Letflow | How |
|---|---|---|
| `cursor` | **supported** | opaque cursor over `global_seq`, §6.4 |
| `page_size` | **supported** | `Pagination.parse_page_size_param/1` → `Pagination.validate_page_size/1` → `read_global/1`'s `:limit` |
| `from` / `to` | **supported** | new `:from`/`:to` opts on `read_global/1` (§6.5), filtering `events.created_at` |
| `actor_id` | **supported** | new `:actor_id` opt, filtering `events.actor_id` |
| `resource_id` | **supported** | new `:instance_id` opt, filtering `events.instance_id` (R-Co's `resource_id` is this column) |
| `resource_type` | **NOT SUPPORTED — accepted and ignored unless it is `"instance"`** | Letflow's `events` table has exactly one resource type. A value other than `"instance"` returns an **empty page** (`items: []`, `next_cursor: null`, `count: 0`) — a truthful answer, not a silent filter drop. A missing param, or `"instance"`, is unfiltered. **This must be named in the moduledoc.** |
| `pipeline_run_id` | **NOT SUPPORTED — 422 `invalid_filter` if supplied non-empty** | Nothing writes `metadata["pipeline_run_id"]` yet (`context.ex:136-142`), so filtering on it could only ever return an empty page while looking like it worked. An explicit 422 is honest; a silent empty page is not. **Named in the moduledoc as unsupported-until-something-populates-the-key.** |

### 6.4 Cursor

`Letflow.Api.Pagination` is the codebase's cursor convention (`pagination.ex:164-194`):
`build_raw_cursor/3` (prefix, timestamp_us, key) → `encode_cursor/1`; `decode_cursor/4` with
an endpoint prefix and an expiry-timestamp offset.

* Endpoint prefix constant: **`@audit_cursor_prefix "A:"`** — a new value, distinct from
  `"T:"` (`tenants.ex:130`) and `"U:"` (`identity.ex:107`); `decode_cursor/4`'s
  `{:error, :wrong_endpoint}` is what makes a cursor from another endpoint fail.
* Cursor `key` = the last returned row's `global_seq`, rendered as a decimal string.
* Decoding: `Pagination.decode_cursor(raw, "A:", byte_size("A:"))`, then
  `Pagination.parse_int_from_cursor/3` to recover `global_seq`, passed as `read_global/1`'s
  `:after_global_seq`.
* `next_cursor` is `nil` when `has_more` is `false`, else a freshly built cursor over the last
  row's `global_seq`. `read_global/1`'s own `@doc` (`event_store.ex:754-757`) documents
  `has_more` as a heuristic; that boundary case is inherited unchanged and named in the
  moduledoc.

Cursor error mapping mirrors `tenants.ex:280-290`: every `decode_cursor/4` failure
(`:invalid_base64` / `:wrong_endpoint` / `:expired` / `:invalid_cursor`) collapses to one
route-level `{:error, :invalid_cursor}`. **Divergence from R-Co, stated deliberately:** R-Co
distinguishes `422 invalid_cursor` from `410 cursor_expired` (`audit.zig:42-43`). Letflow
collapses both to **422 `invalid cursor`**, because `Pagination.decode_cursor/4`'s expiry
result is already folded into the same failure family everywhere else in this codebase
(`tenants.ex:287`), and adding a 410 here would be the only endpoint in Letflow that does it.
Recorded as **OQ-4**.

### 6.5 New context function — `Letflow.EventStore.read_global/1` gains filter opts

**One read path, not two.** Rather than add a second `list_audit/1` alongside `read_global/1`,
`read_global_opts()` is widened **additively**; every existing caller is unaffected because
every new key defaults to `nil`.

Changed type (`lib/letflow/event_store.ex:726-730`):

```
@type read_global_opts :: [
        prefix: String.t(),
        after_global_seq: pos_integer() | nil,
        limit: non_neg_integer() | nil,
        actor_id: Ecto.UUID.t() | nil,
        instance_id: Ecto.UUID.t() | nil,
        from: DateTime.t() | nil,
        to: DateTime.t() | nil
      ]
```

Changed error type (`event_store.ex:738-741`), widened by two:

```
@type read_global_error ::
        {:error, :invalid_schema_name}
        | {:error, :invalid_actor_id}
        | {:error, :invalid_instance_id}
        | {:error, {:payload_resolution_failed, event_id :: Ecto.UUID.t()}}
        | {:error, term()}
```

`read_global/1`'s `@spec` is unchanged in shape (`event_store.ex:759-760`). Semantics of the
new opts:

* All four are `AND`-composed with each other and with `:after_global_seq`.
* `:from` / `:to` are **inclusive** bounds on `events.created_at`.
* `:actor_id` / `:instance_id` are validated with `Ecto.UUID.cast/1` **before any query is
  constructed**; a malformed value returns `{:error, :invalid_actor_id}` /
  `{:error, :invalid_instance_id}` with zero queries issued — the same
  validate-then-query ordering `variable_schema.ex:262-274` establishes.
* Composed with `Ecto.Query` and bound parameters only; no SQL string interpolation (INV-7).
* Ordering (`asc: global_seq`), `:prefix` scoping and `$ref` payload resolution are unchanged.

**The `from > to` case is the route's, not the store's.** R-Co checks it in the handler
(`audit.zig:26-30`) and returns 422 `invalid_time_range`. Letflow does the same: the route
compares the two parsed `DateTime`s with `DateTime.compare/2` before calling the store, and
returns 422 on `:gt` — no query issued.

### 6.6 Error → status map

| Condition | Status | Helper |
|---|---|---|
| `:Deny403` from `evaluate_access/2` | 403 | `Response.forbidden(conn, "insufficient permissions")` |
| `scoped_repo_opts/1` → `{:error, _}` | 500 | `Response.internal_error/1` |
| `from` or `to` not ISO 8601 | 422 | `Response.unprocessable(conn, "invalid time range")` |
| `from > to` | 422 | `Response.unprocessable(conn, "invalid time range")` (R-Co `invalid_time_range`) |
| cursor fails `decode_cursor/4` (any reason, incl. expiry) | 422 | `Response.unprocessable(conn, "invalid cursor")` — see OQ-4 |
| `page_size` non-integer / `{:error, :invalid_page_size}` | 400 | `Response.bad_request(conn, "invalid page_size")` |
| `{:error, :page_size_too_large}` | 400 | `Response.bad_request(conn, "page_size out of range")` |
| `pipeline_run_id` supplied non-empty | 422 | `Response.unprocessable(conn, "invalid filter")` (R-Co `invalid_filter`) |
| `{:error, :invalid_actor_id}` / `{:error, :invalid_instance_id}` | 422 | `Response.unprocessable(conn, "invalid filter")` |
| `{:error, :invalid_schema_name}` | 500 | `Response.internal_error/1` |
| `{:error, {:payload_resolution_failed, _}}` / any other `{:error, term()}` | 500 | `Response.internal_error/1` (INV-4 — no detail slot) |
| success | 200 | `Response.ok/2` |

**No 503 branch.** R-Co maps `PoolExhausted` → 503 (`audit.zig:45`). Ecto/DBConnection surfaces
pool exhaustion as a raised `DBConnection.ConnectionError`, not an `{:error, :pool_exhausted}`
tuple, so there is no tuple to match. Porting a 503 clause would create a branch nothing can
reach. **Stated in the moduledoc as a deliberate non-port, not an omission.** Same reasoning
applies to every other 503 in this requirement (§8.5, §10.3).

### 6.7 Moduledoc obligations — `Letflow.Routers.Audit`

1. Route table row (method, path, delegate, permission, response), matching `tenants.ex:18-25`.
2. The temporary route-local authorization paragraph, verbatim intent from §4.2.
3. **"Served from the event store, not an audit-entry table"** — naming
   `src/obs/audit.zig`'s `audit_entries` as R-Co's backing table and stating Letflow has none.
4. The full filter-disposition table from §6.3, including the two unsupported params and why
   each is unsupported rather than silently ignored.
5. `before_state`/`after_state` are always `null`, and `payload` is a Letflow addition.
6. The 410-collapse divergence (OQ-4) and the no-503 non-port (§6.6).
7. "Ordering guarantee" section per §3.2.
8. **INV-1 statement:** the only tenant input is `scoped_repo_opts/1`'s prefix; there is no
   query parameter, header, or body field through which another tenant's events could be
   selected. An audit list that escaped scoping would disclose another tenant's entire
   activity history in one response — this is the sharpest INV-1 case in this requirement.

---

## 7. Route 2 — Definition validation (`Letflow.Routers.Definitions`)

### 7.1 Contract

| Item | Value |
|---|---|
| R-Co source | `src/api/routes/validation.zig:75-139` (`handleValidate`); header L1-31 |
| Method + path | `POST /api/v1/definitions/:id/validate` |
| Mount | `Letflow.Routers.Definitions` (§2.3) |
| Permission | none in this requirement (§4.3, OQ-3) |
| Delegate | `Letflow.Definitions.validate_definition_graph/2` (**new**, §7.2) |
| Request body | **ignored** — bodyless, like `tenants.ex`'s deactivate/reactivate (OQ-3 there). R-Co's `handleValidate` takes no body either (`validation.zig:75-80`). |

### 7.2 New context function — `Letflow.Definitions.validate_definition_graph/2`

AC4 requires the route to produce **the same outcome as calling REQ-028/029's validators
directly**. That is only structurally guaranteed if the route contains no validation logic at
all. So the composition lives in `Letflow.Definitions`:

```
@typedoc "The merged outcome of REQ-028/029's three graph validators over one stored definition."
@type graph_validation_result :: %{
        definition_id: Ecto.UUID.t(),
        valid: boolean(),
        violations: [Letflow.Definitions.Graph.Violation.t()]
      }

@spec validate_definition_graph(id :: Ecto.UUID.t(), opts :: opts()) ::
        {:ok, graph_validation_result()}
        | {:error, :not_found}
        | {:error, :graph_structure_invalid}
        | common_error()
def validate_definition_graph(id, opts)
```

Behaviour contract:

1. `Definitions.get_by_id(id, opts)` (`definitions.ex:424`) — prefix-scoped.
   `{:error, :not_found}` propagates unchanged (this is the INV-5 cross-tenant path).
2. `Graph.from_map(definition.graph)` (`graph.ex:190/201`). `:error` →
   `{:error, :graph_structure_invalid}` — a stored graph that will not even parse.
3. Run **exactly these three**, in this order, on the resulting `%Graph{}`:
   * `Graph.validate_graph/1` (`graph.ex:289`) — REQ-028 structural
   * `Graph.validate_node_attributes/1` (`graph.ex:317`) — REQ-029 node attributes
   * `Graph.validate_edge_conditions/1` (`graph.ex:343`) — REQ-029 edge conditions
4. Concatenate the three `result()` maps' `:violations` lists in that order (duplicates are
   not deduplicated — the three validators produce disjoint `Violation.code()` sets, see
   `graph.ex:112-138`). `valid` is `violations == []`.
5. **Adds no rule of its own, and calls no other validator.** In particular it does **not**
   call `Letflow.Definitions.ServiceScopeValidator.validate/3` (`service_scope_validator.ex:184`),
   which `Definitions.activate/2` does call (`definitions.ex:502-509`). Service-scope
   validation needs an injected `Lookup.t()` this endpoint has no source for, and including it
   would break AC4's equality with "REQ-028/029's validator directly". **Named in the moduledoc
   as a deliberate exclusion with its owning path (`activate/2`).**
6. Issues exactly one query (`get_by_id/2`); everything after step 1 is pure.

### 7.3 Responses

**200 — valid** (`Response.ok/2`):

```
%{
  "status"       => "valid",
  "findings"     => [],
  "definition_id" => <uuid>,
  "validated_at" => <ISO 8601 UTC, DateTime.utc_now/0 at response time>
}
```

**Divergence from R-Co, deliberate.** R-Co emits `"status":"semantically_valid"` plus
`"compiler_version"` (`validation.zig:115-118`, `src/validation/wire.zig:200-214`), because its
VLD-01/02/03 pipeline performs expression type-checking and its VLD-04 gate persists a verdict
with a compiler version. Letflow has ported neither. Claiming `"semantically_valid"` would
overclaim what was actually checked, and `compiler_version` has no value to report. Letflow
emits `"valid"` and omits `compiler_version`. **Must be named in the moduledoc.**

**422 — findings present** (`Response.send_problem/2` with a hand-built
`%Letflow.Api.Error{}`): `Letflow.Api.Error`'s `errors` extension member already serialises a
non-empty list (`error.ex:110-116`), so the problem document is:

```
%Letflow.Api.Error{
  type:   <problems_base> <> "unprocessable-entity",
  title:  "Unprocessable Entity",
  status: 422,
  detail: "definition graph failed validation",
  errors: [ %{"code" => "<Violation.code() as string>", "message" => "<Violation.message>"}, ... ]
}
```

The `errors` list is built by a private map builder over `[Graph.Violation.t()]` with exactly
those two keys — `Violation` has exactly two fields (`graph.ex:113`), so this is a total
mapping, not a redaction. **Note for ELIXIR-DEV:** `Error.serialise/1`'s
`errors: [_ | _]` clause passes the list straight to `Jason.encode!/1`, so the elements must
already be plain maps with string keys — do not pass `%Violation{}` structs.

### 7.4 Moduledoc obligation (AC6) — the `validation.zig` distinction

`Letflow.Routers.Definitions`'s moduledoc must carry a section that reads, in substance:

> **Two different R-Co files are called `validation.zig`. They are unrelated.**
>
> * `src/api/routes/validation.zig` (173 lines) is the **definition-graph validation
>   endpoint** — `POST /api/v1/definitions/:id/validate`, VLD-01/02/03, which runs validators
>   over a *stored process-definition graph*. **That is what is ported here, by REQ-078.**
> * `src/api/validation.zig` (592 lines) is the **request-body validator** — API-07, which
>   checks an *incoming JSON request payload* against a field-constraint schema and returns
>   RFC 9457 field errors. It has nothing to do with process definitions. **That is ported by
>   REQ-068, as `Letflow.Api.Validation` (`lib/letflow/api/validation.ex`).**
>
> Both appear in this module — the second as the `Letflow.Api.Validation` calls that check
> request bodies, the first as this endpoint's own delegate. Do not conflate them, and do not
> "consolidate" them: they validate different things at different layers.

The same paragraph (or a one-line pointer to it) must also appear in `Letflow.Api.Validation`'s
own moduledoc, so a reader arriving from either side finds the distinction.

Additional moduledoc obligations for this module: the deleted `/validation` stub and why
(§2.3); the deliberate exclusion of `ServiceScopeValidator` (§7.2 step 5); the `"valid"` vs
`"semantically_valid"` divergence (§7.3); the INV-5 404 rule, citing `validation.zig:31`'s own
"cross-tenant reads fall through as `DefinitionNotFound` (HTTP 404)"; the REQ-131 authorization
gap (§4.3); an "Ordering guarantee" section (§3.2); and a note that REQ-081/082 co-own this
file.

### 7.5 Error → status map

| Condition | Status | Helper |
|---|---|---|
| `:id` not UUID-shaped (`Ecto.UUID.cast/1` fails, checked in the route before any call) | 422 | `Response.unprocessable(conn, "invalid id format")` (R-Co `validation.zig:83-85`) |
| `scoped_repo_opts/1` → `{:error, _}` | 500 | `Response.internal_error/1` |
| `{:error, :not_found}` (absent **or** another tenant's) | 404 | `Response.not_found/1` — no detail (INV-5) |
| `{:ok, %{valid: true}}` | 200 | `Response.ok/2` |
| `{:ok, %{valid: false, violations: vs}}` | 422 | `Response.send_problem/2`, §7.3 |
| `{:error, :graph_structure_invalid}` | 422 | `Response.unprocessable(conn, "definition graph is not well-formed")` |
| `{:error, {:transaction_failed, _}}` / `{:error, :invalid_schema_name}` | 500 | `Response.internal_error/1` |

No 503 branch — §6.6's reasoning.

---

## 8. Routes 3 & 4 — Solution packs (`Letflow.Routers.SolutionPacks`, new)

### 8.1 ⚠ Scope finding — the backing subsystem does not exist (OQ-1, BLOCKING)

REQ-078's description says all six modules are "a one-to-three-handler surface over existing
context functions". **For solution packs that is not true, and ORCH must see this before
ELIXIR-DEV starts.**

Verified this run:

* R-Co's handlers are thin because they delegate to `src/solution/store.zig`'s
  `SolutionPackStore.exportPack` (L46) and `installPack` (L284) — roughly 700 lines.
* Letflow ported **none** of that. REQ-041 ported the *pack-update three-way diff*
  (`Definitions.compute_pack_update_plan/5`, `definitions.ex:250`) plus three **global**
  Ecto schemas: `SolutionPackInstall`, `SolutionPackArtefactBase`, `PackUpdateResolution`.
  `Letflow.Definitions.SolutionPackInstall`'s only public function is `insert_changeset/2`
  (`solution_pack_install.ex:83`). `grep -rn "export_pack\|install_pack\|SolutionPackDocument" lib/`
  returns zero hits outside `lib/letflow/design/`.

So this requirement must **build a new context module**, not merely route to one. That is
larger than "port a route", and it is the shape `stage-4-api-surface.md:101-108` warns about.

**Two mitigating facts, which is why this design proceeds rather than blocking outright:**

1. Letflow's pack scope is far narrower than R-Co's. R-Co's pack document carries four arrays;
   Letflow can support only two of them today (§8.2), so the port is a fraction of 700 lines.
2. Both `export/2` and `install/3` compose **existing** Letflow functions
   (`Definitions.get_by_id/2`, `Definitions.create/2`, `VariableSchema.fetch_schemas/3`,
   `SolutionPackInstall.insert_changeset/2`) plus the one new registration function §9 builds
   anyway.

**OQ-1 is BLOCKING and is for ORCH/REVIEWER to answer before Step 2a:** accept the added scope
inside REQ-078, or split solution packs into their own requirement — in which case AC3 and AC8
cannot be satisfied by REQ-078 and the requirement text needs amending. **Do not let
ELIXIR-DEV decide this by starting to type.**

### 8.2 Pack document — what Letflow supports, and what it drops

R-Co's `SolutionPackDocument` (`solution_packs.zig:146-345`) has four content arrays:

| R-Co array | Letflow | Reason |
|---|---|---|
| `definitions` | **supported** | `process_definitions` exists (REQ-027/030) |
| `variable_schemas` | **supported** | `variable_schemas` exists (REQ-109); this is AC8 |
| `service_catalog_entries` | **NOT supported** | Letflow has no service catalog — `services.zig` is group (b), owning stage **S6** (`stage-4-api-surface.md:104`). Export emits `[]`; install **rejects a non-empty array with 422 `UNSUPPORTED_PACK_SECTION`** rather than silently discarding tenant-supplied content. |
| `manifest.required_roles` | **supported, read-only** | Checked against the closed role set `Letflow.Api.Authorization.roles/0` (`authorization.ex:124-125`); produces the `role_mapping_checklist` (§8.4). No role is created. |

Consequence: R-Co's `409 CATALOG_CONFLICT` (`solution_packs.zig:135`) is **not ported** — there
is no catalog to conflict with, so the branch would be unreachable. **Stated in the moduledoc
as a deliberate non-port.**

Likewise R-Co's `409 TenantInactive` (`solution_packs.zig:127-134`) is **not ported**:
`Letflow.Plugs.TenantStatus` runs at `api_pipeline.ex:35`, before any sub-router, and rejects an
inactive tenant's request with `403 tenant_inactive` for every method
(`tenants.ex:62-72`). A 409 branch here could never fire. **Also stated as a deliberate
non-port with its upstream owner named.**

### 8.3 New context module — `Letflow.Definitions.SolutionPack`

New file `lib/letflow/definitions/solution_pack.ex`. Two public functions.

```
@typedoc "One definition inside a pack document."
@type packed_definition :: %{
        definition_id: String.t(),   # the SOURCE tenant's id; opaque correlation key on install
        process_key:   String.t(),   # maps to ProcessDefinition.name
        name:          String.t(),
        version:       String.t(),
        graph:         map()
      }

@typedoc "One variable-schema row inside a pack document. `schema_content` is a JSON *string* in R-Co's wire format."
@type packed_variable_schema :: %{
        definition_id:  String.t(),
        schema_name:    String.t(),   # -> variable_schemas.variable_key
        schema_content: String.t()    # JSON text -> variable_schemas.json_schema (decoded)
      }

@type pack_document :: %{
        pack_id:                    String.t(),
        version:                    String.t(),
        bpm_export_schema_version:  String.t(),
        exported_at:                String.t(),
        definitions:                [packed_definition()],
        service_catalog_entries:    [],
        variable_schemas:           [packed_variable_schema()],
        manifest:                   %{required_roles: [String.t()]}
      }

@type installed_definition :: %{
        source_definition_id: String.t(),
        new_definition_id:    Ecto.UUID.t(),
        process_key:          String.t(),
        status:               String.t()          # "installed" | "skipped"
      }

@type role_checklist_entry :: %{role_name: String.t(), bound: boolean()}

@type install_result :: %{
        pack_id:                 String.t(),
        version:                 String.t(),
        install_id:              Ecto.UUID.t(),
        installed_definitions:   [installed_definition()],
        variable_schemas_written: non_neg_integer(),
        role_mapping_checklist:  [role_checklist_entry()],
        warnings:                [String.t()]
      }

@type export_error ::
        {:error, {:definition_not_found, definition_id :: String.t()}}
        | {:error, :empty_definition_ids}
        | Letflow.Definitions.common_error()

@type install_error ::
        {:error, :invalid_pack_document}
        | {:error, {:unknown_schema_version, actual :: String.t()}}
        | {:error, :unsupported_pack_section}
        | {:error, {:variable_schema_conflict, definition_id :: String.t(), variable_key :: String.t()}}
        | {:error, {:malformed_variable_schema, variable_key :: String.t(), reason :: Letflow.Definitions.variable_schema_error()}}
        | {:error, :duplicate_pack_install}
        | Letflow.Definitions.create_error()
        | Letflow.Definitions.common_error()
```

```
@spec export(
        definition_ids :: [String.t(), ...],
        version :: String.t(),
        opts :: Letflow.Definitions.opts()
      ) :: {:ok, pack_document()} | export_error()
def export(definition_ids, version, opts)
```

Behaviour: for each id in order — `Definitions.get_by_id(id, opts)`; `{:error, :not_found}` →
`{:error, {:definition_not_found, id}}` (this is the cross-tenant case, §4.4). Then
`Letflow.Engine.VariableSchema.fetch_schemas(Letflow.Repo, definition.id, opts)`
(`variable_schema.ex:262`) for that definition's rows, flattened into the document's
`variable_schemas` array with `definition_id = definition.id`, `schema_name = variable_key`,
`schema_content = Jason.encode!(json_schema)`. `pack_id` is a fresh `Ecto.UUID.generate/0`;
`exported_at` is `DateTime.utc_now/0` ISO 8601; `bpm_export_schema_version` reuses
`Letflow.Definitions.ExportImport`'s `@export_schema_version "bpm/definition/v1"`
(`export_import.ex:33`) rather than inventing a second version string —
**one version constant, not two.** `service_catalog_entries` is always `[]`.
`manifest.required_roles` is `[]` (nothing in Letflow declares per-definition roles yet;
named as a known gap in the moduledoc).

**INV-1 for export:** every read runs with `opts[:prefix]` from `scoped_repo_opts/1`. A
definition id belonging to tenant B is invisible in tenant A's schema, so it can only produce
`{:error, {:definition_not_found, id}}` — never a tenant B artefact in the document. This is
AC3's first clause.

```
@spec install(
        document :: pack_document(),
        actor_id :: Ecto.UUID.t(),
        opts :: Letflow.Definitions.opts()
      ) :: {:ok, install_result()} | install_error()
def install(document, actor_id, opts)
```

Behaviour, in one `Ecto.Multi` executed by `Letflow.Repo.transaction/2`:

1. Reject `document.service_catalog_entries != []` → `{:error, :unsupported_pack_section}`.
2. Reject `document.bpm_export_schema_version != @export_schema_version` →
   `{:error, {:unknown_schema_version, actual}}` (R-Co: `INVALID_PACK_DOCUMENT`,
   `solution_packs.zig:170-172`).
3. **Well-formedness pre-check on every `variable_schemas` entry, before any insert** — §9.3.
   `schema_content` is decoded with `Jason.decode/1` and checked by
   `Letflow.Definitions.JsonSchemaShape.check/1`. Any failure aborts the whole transaction
   with `{:error, {:malformed_variable_schema, variable_key, reason}}`. **Nothing is written.**
4. Conflict pre-check, porting `store.zig:415-441`: for each entry, if a row already exists in
   the caller's schema for the same `(definition name, variable_key)` with a **different**
   `json_schema`, abort with
   `{:error, {:variable_schema_conflict, definition_id, variable_key}}`. Identical content is
   not a conflict.
5. Insert `SolutionPackInstall.insert_changeset/2` (`solution_pack_install.ex:83`) with
   `tenant_id` derived from the prefix via
   `Letflow.TenantProvisioning.tenant_id_for_schema_name(opts[:prefix])`
   (`tenant_provisioning.ex:195`) — **derived from the resolved prefix, never accepted as a
   caller-supplied field** (INV-1 verification item (c)). The table is **global** by REQ-041's
   own design (`priv/repo/migrations/20260817083801_create_solution_pack_installs.exs:12-13`),
   so this insert carries **no** `:prefix`. Its `uq_solution_pack_install_active` partial
   unique index → `{:error, :duplicate_pack_install}`.
6. For each `packed_definition`, `Definitions.create/2` (`definitions.ex:400`) with
   `name: process_key`, `version`, `graph`, `created_by: actor_id`, and `opts` — so every
   definition lands in the caller's schema and nowhere else. Record the mapping
   `source_definition_id -> new_definition_id`.
7. For each `packed_variable_schema`, resolve its `definition_id` through that mapping (an
   entry whose `definition_id` matches no packed definition is **skipped and reported in
   `warnings`**, matching R-Co's `continue` at `store.zig:482`), then call
   **`Letflow.Definitions.register_variable_schemas/3` — the single shared registration
   function (§9)**. `variable_schemas_written` is that function's returned count summed over
   all definitions.
8. Build `role_mapping_checklist` (§8.4). Commit.

**INV-1 for install:** every write is `:prefix`-scoped to the caller's own schema except the
one global `solution_pack_installs` row, whose `tenant_id` is derived from that same prefix.
This is AC3's second clause and AC8's "none into any other tenant's schema".

### 8.4 Role checklist

`role_mapping_checklist` is `Enum.map(document.manifest.required_roles, fn name ->
%{role_name: name, bound: name in Enum.map(Letflow.Api.Authorization.roles(), &Atom.to_string/1)} end)`.
Read-only; no role is created, nothing is bound. This is a narrowed port of
`store.zig:589`'s `checkRoleGate` and must be named as narrowed in the moduledoc.

### 8.5 Route contracts and error maps

**`POST /api/v1/solution-packs/export`**

Request schema (`[%FieldConstraint{}]`, `Letflow.Api.Validation.validate/2`):

| Field | Required | Type | Constraints |
|---|---|---|---|
| `definition_ids` | yes | `:array` | `min_items: 1` |
| `version` | no | `:string` | `reject_empty_string: true`, `max_length: 64`; default `"1.0.0"` (R-Co `solution_packs.zig:59-65`) |

Element-level "every id is a string" is checked in the route after `validate/2` (the
`FieldConstraint` vocabulary has no per-element type rule) and maps to R-Co's
`definition_id_must_be_string`.

| Condition | Status | Helper | R-Co code |
|---|---|---|---|
| body not a JSON object | 400 | `Response.bad_request(conn, "invalid body")` | `invalid_body` |
| `validate/2` `{:errors, _}` (missing/empty/not-array `definition_ids`) | 422 | `Response.send_problem(conn, Validation.problem(errs))` | `missing_definition_ids` / `definition_ids_must_be_array` / `definition_ids_empty` |
| an element is not a string | 422 | `Response.unprocessable(conn, "definition_id must be a string")` | `definition_id_must_be_string` |
| `{:error, {:definition_not_found, _}}` | 422 | `Response.unprocessable(conn, "definition not found")` — **detail carries no id** (INV-5: it must not confirm that some id exists elsewhere) | `DEFINITION_NOT_FOUND` |
| `scoped_repo_opts/1` `{:error, _}` / `common_error()` | 500 | `Response.internal_error/1` | `internal_error` |
| success | 200 | `Response.ok/2` (the pack document) | — |

`MODULE_NON_EXPORTABLE` (`solution_packs.zig:81`) is **not ported** — Letflow has no
process-module packaging (`process_modules.zig` is group (b), S5). Named as a non-port.

**`POST /api/v1/solution-packs/install`**

Request body is the pack document itself.

| Condition | Status | Helper | R-Co code |
|---|---|---|---|
| empty body | 400 | `Response.bad_request(conn, "empty body")` | `empty_body` |
| body not a JSON object / required top-level keys absent | 422 | `Response.unprocessable(conn, "invalid pack document")` | `INVALID_PACK_DOCUMENT` |
| `{:error, {:unknown_schema_version, _}}` | 422 | `Response.unprocessable(conn, "invalid pack document")` | `INVALID_PACK_DOCUMENT` |
| `{:error, :unsupported_pack_section}` | 422 | `Response.unprocessable(conn, "pack contains an unsupported section")` | *(Letflow-only, §8.2)* |
| `{:error, {:malformed_variable_schema, key, _reason}}` | 422 | `Response.unprocessable(conn, "variable schema is not a well-formed JSON Schema document")` — **`key` is echoed, `reason` is not** (`key` is the caller's own submitted value; `reason` is internal) | *(Letflow-only, §9.3)* |
| `{:error, {:variable_schema_conflict, _, _}}` | 409 | `Response.conflict(conn, "variable schema conflict")` | `VARIABLE_SCHEMA_CONFLICT` |
| `{:error, :duplicate_pack_install}` | 409 | `Response.conflict(conn, "pack already installed")` | *(Letflow-only, from `uq_solution_pack_install_active`)* |
| `create_error()` e.g. `{:error, :duplicate_name_version}` | 409 | `Response.conflict(conn, "definition already exists")` | — |
| other `create_error()` / `%Ecto.Changeset{}` | 422 | `Response.unprocessable(conn, "validation failed")` | — |
| `common_error()` / `{:error, term()}` | 500 | `Response.internal_error/1` | `internal_error` |
| success | 200 | `Response.ok/2` (`install_result()`) | — |

No 503 (§6.6). No 409 `CATALOG_CONFLICT`, no 409 `TenantInactive` (§8.2).

### 8.6 Moduledoc obligations — `Letflow.Routers.SolutionPacks`

1. Route table for the two endpoints.
2. **The dropped path `tenant_id`**, with the verbatim-intent sentence from §2.6 that no
   caller-supplied tenant value can reach a `:prefix`.
3. The four non-ports and their owners: `service_catalog_entries`/`CATALOG_CONFLICT` (S6),
   `MODULE_NON_EXPORTABLE` (S5), `TenantInactive` (upstream in `Letflow.Plugs.TenantStatus`),
   503 (§6.6).
4. The AC8 statement: install writes `variable_schemas` rows **only** through
   `Letflow.Definitions.register_variable_schemas/3`, and no other insert path into that table
   exists in the route layer.
5. INV-1 statement covering both directions (export reads, install writes).
6. REQ-131 authorization gap (§4.3). "Ordering guarantee" section (§3.2).

---

## 9. The shared `variable_schemas` registration function (AC8)

### 9.1 Where it lives, and why one

REQ-078's own text: *"the registration logic lives in a SINGLE function on REQ-030's
`Letflow.Definitions`, called by both this requirement's install and REQ-082's import.
Whichever of the two lands FIRST builds that function."* Verified: REQ-082 is `pending` and
`lib/letflow/definitions.ex` contains zero occurrences of `variable_schema`. **REQ-078 builds
it.**

### 9.2 The contract

Added to `lib/letflow/definitions.ex`.

```
@typedoc """
One variable-schema registration input. `json_schema` is the ALREADY-DECODED
document (a `map()` if well formed). Callers that hold JSON text — the
solution-pack install path, whose wire format carries `schema_content` as a
string (`R-Co src/api/routes/solution_packs.zig:299-315`) — decode it before
calling and map a decode failure onto `{:invalid_json, key}`.
"""
@type variable_schema_input :: %{
        required(:variable_key) => String.t(),
        required(:json_schema)  => term(),
        optional(:description)  => String.t() | nil
      }

@typedoc "Every distinct, pattern-matchable failure of the registration path."
@type variable_schema_error ::
        :missing_prefix
        | :invalid_definition_id
        | {:duplicate_variable_key, String.t()}
        | {:blank_variable_key, non_neg_integer()}
        | {:not_well_formed, variable_key :: String.t(), path :: [String.t()]}
        | {:schema_too_deep, variable_key :: String.t()}

@doc """
The SINGLE insert path into the tenant-scoped `variable_schemas` table
(`Letflow.Engine.VariableSchema`, REQ-109). REQ-078's solution-pack install and
REQ-082's definition import both call THIS function; neither adds a second
insert path. `grep -rn "VariableSchema" lib/letflow/routers/` must return zero
hits, and the only `Repo` insert against that schema anywhere in lib/ must be
the one inside this function.
"""
@spec register_variable_schemas(
        definition_id :: Ecto.UUID.t(),
        entries :: [variable_schema_input()],
        opts :: opts()
      ) :: {:ok, non_neg_integer()} | {:error, variable_schema_error()}
def register_variable_schemas(definition_id, entries, opts)
```

Behaviour contract:

1. **Validate first, query never-before-validated.** `opts[:prefix]` absent →
   `{:error, :missing_prefix}`; `Ecto.UUID.cast(definition_id)` fails →
   `{:error, :invalid_definition_id}`. Zero queries issued in either case — the same ordering
   `variable_schema.ex:262-274` establishes and documents.
2. `entries == []` → `{:ok, 0}`, no query. (A pack with no `variable_schemas` array is normal.)
3. A blank/whitespace-only `variable_key` at index `i` → `{:error, {:blank_variable_key, i}}`.
4. Duplicate `variable_key` **within `entries`** → `{:error, {:duplicate_variable_key, key}}`,
   checked before any insert (the DB's `uq_variable_schema_definition_key` would otherwise
   surface it as an opaque changeset error mid-transaction).
5. **Well-formedness check on every entry** — §9.3. First failure aborts; nothing is written.
6. Insert via `Letflow.Engine.VariableSchema.changeset/2` (`variable_schema.ex:164`) —
   **reusing REQ-109's changeset, not inventing a second one**, exactly as its `@doc`
   (`variable_schema.ex:145-162`) anticipates — with
   `%{definition_id: definition_id, variable_key: ..., json_schema: ..., description: ...}`,
   `Repo.insert/2` with `prefix: opts[:prefix]` and
   `on_conflict: :nothing, conflict_target: [:definition_id, :variable_key]` — porting
   R-Co's `ON CONFLICT (definition_id, variable_key) DO NOTHING` (`store.zig:485-491`) exactly.
7. All inserts run inside one `Ecto.Multi`, so the function is all-or-nothing. **It does not
   open its own transaction** — it returns a shape the caller can run inside its own
   `Ecto.Multi` (the install path already has one, §8.3), so the pack install and the schema
   registration commit or roll back together. If called outside a transaction it wraps itself
   in one. *(Composition detail flagged as **OQ-5** — see §14.)*
8. Returns `{:ok, count}` where `count` is the number of rows actually inserted (rows skipped
   by `ON CONFLICT DO NOTHING` are not counted).

**Row scoping.** Rows are keyed to the `definition_id` argument. A pack carrying N definitions
calls this function N times with N distinct ids, so the row sets are disjoint and cannot
collide with REQ-082 importing a different definition — REQ-078's own stated invariant.

### 9.3 WELL-FORMEDNESS — the decision (closes GH#306 / ISS-0089)

**Chosen: option (a) from REQ-078's text — validate the submitted `json_schema` document is
well formed at EVERY level BEFORE insert, and reject a malformed one with a typed error at
install/import time.**

**Home module — ruled by ORCH (OQ-2): a dedicated module, `Letflow.Definitions.JsonSchemaShape`,
in `lib/letflow/definitions/json_schema_shape.ex`.** Both `Letflow.Definitions` (the
registration path) and `Letflow.Engine.VariableSchema` (the changeset) call it. An Engine
module calling into `Letflow.Definitions` would be the wrong dependency direction; a leaf
module both may depend on has no such problem. The module is pure — no `Repo`, no clock, no
`Plug.Conn` — and has exactly one public function.

```
defmodule Letflow.Definitions.JsonSchemaShape

@max_depth 32

@doc """
True iff `document` is a well-formed JSON Schema document AT EVERY LEVEL:
it is a map, every value of a `"properties"` map is itself well formed, and an
`"items"` value, when present, is itself well formed. Bounded by `@max_depth`
(32) — a deeper document returns `{:error, :too_deep}` rather than recursing
without limit on caller-supplied input (INV-8).

Returns the JSON-pointer-style segment path to the FIRST offending level, so a
caller can tell the submitter where the document went wrong. `[]` means the
top level itself is not a map.
"""
@spec check(document :: term()) ::
        :ok | {:error, {:not_well_formed, path :: [String.t()]}} | {:error, :too_deep}
def check(document)
```

`register_variable_schemas/3` maps `JsonSchemaShape.check/1`'s
`{:error, {:not_well_formed, path}}` to `{:error, {:not_well_formed, variable_key, path}}`, and
its `{:error, :too_deep}` to `{:error, {:schema_too_deep, variable_key}}` — two distinct
reasons so the two failure modes stay distinguishable in a log.

**Why (a) and not (b).**

1. **It makes both defects genuinely unreachable rather than merely handled.** ISS-0089's own
   scoping note says (b) "is cleaner if registration validation is going to exist anyway, but
   it does not protect rows written before it lands." Here there **are no rows written before
   it lands**: `grep -rn "VariableSchema" lib/` finds *zero* insert paths anywhere in `lib/`
   (verified this run — the only writers are test seeds and `test/support/tenant_fixture.ex`),
   and this requirement is the first insert path in the codebase's history. The usual
   objection to (a) — legacy rows — is empirically absent.
2. **Option (b) would require re-opening `fetch_schemas/3`'s query shape.** Selecting
   `json_schema` untyped means every consumer of `schema_map()` — including
   `variable_validations/5` on the task-completion hot path (`engine.ex:1680`,
   `sub_process.ex:834`) — inherits a widened `error_reason()`. That is a change to a `done`
   S3 hot path, made from an S4 route requirement, to accommodate data this requirement can
   simply refuse to store.
3. **The error is far more useful at the boundary.** A malformed schema rejected at install
   time names the offending `variable_key` to the caller who submitted it. The same document
   rejected at merge time surfaces as an `ArgumentError` inside an open transaction on a task
   completion, hours later, to a different user.
4. **`Letflow.Api.Validation` already establishes reject-at-the-boundary as this API's
   contract** (REQ-068). This is the same discipline applied to a nested document.

**Placement — a strengthening beyond the minimum, and NOT negotiable.** The check is *also*
wired into `Letflow.Engine.VariableSchema.changeset/2` (`variable_schema.ex:164`) as a
`validate_change(:json_schema, ...)` calling `JsonSchemaShape.check/1`, adding a
`:json_schema` changeset error on `{:error, _}`. That makes the changeset — which REQ-109's
`@doc` explicitly warns "does not validate that `json_schema` is itself a well-formed JSON
Schema document" — the real choke point for **every** writer, including REQ-109's own test
seeds and any future path that bypasses `register_variable_schemas/3`. Without this, (a) would
guarantee well-formedness only for callers that remember to use the registration function.

*(OQ-2, ruled: the predicate's home is the dedicated `Letflow.Definitions.JsonSchemaShape`
module above, so no Engine→Definitions dependency is created. The placement inside
`changeset/2` was never in question.)*

**What happens to the two read-side defensive branches.**

* `Letflow.EventStore.Registry.JsonSchema.properties_violations/3`'s `is_map(subschema)` guard
  (`json_schema.ex:159-172`) — **KEEP.** *(And note: ISS-0088/GH#305 is **already
  `status: resolved`** — see §14 C-1.)*
* `Letflow.Engine.VariableSchema.validations_for/3`'s `{:ok, _not_a_map}` clause
  (`variable_schema.ex:344-350`) — **KEEP, but its comment must be rewritten.** ISS-0089's
  scoping note is right that "unreachable defensive code that looks live is worse than no
  defence", and the fix for that is to stop it *looking* live: the comment must say it is now
  unreachable by construction and name what would have to break for it to fire.
* **This requirement deletes neither branch.** A follow-up may. Deleting live-looking defensive
  code in the same change that makes it unreachable removes the safety net at exactly the
  moment the new guarantee is least proven.

### 9.4 Required moduledoc text — `Letflow.Engine.VariableSchema` (closes design §11.3 OQ-3)

Added to that module's moduledoc, replacing/extending the "The registration (INSERT) path is
deferred — REQ-078 and REQ-082 carry it" section (`variable_schema.ex:56-82`). Substance
required (exact phrasing ELIXIR-DEV's):

> **OQ-3 (`req109-variable-schemas.md` §11.3) is CLOSED by REQ-078, in favour of
> validate-before-insert.**
>
> A `variable_schemas` row is written by exactly one function —
> `Letflow.Definitions.register_variable_schemas/3` — and that function rejects any
> `json_schema` that is not a well-formed JSON Schema document *at every level* with
> `{:error, {:not_well_formed, variable_key, path}}` before issuing any insert. The
> well-formedness predicate is additionally wired into `changeset/2` below, so **every** writer
> is covered, not only callers that go through the registration function.
>
> Consequence for the read path: a top-level non-object `json_schema` can no longer be stored,
> so `fetch_schemas/3`'s typed `:map` select can no longer raise `ArgumentError` at Ecto load
> time (**ISS-0089 / GH#306 — closed by construction**), and a nested non-map subschema can no
> longer be stored either (**ISS-0088 / GH#305 — already resolved separately by the
> `is_map(subschema)` guard now in `JsonSchema.properties_violations/3`; this requirement makes
> that guard unreachable as well**).
>
> `validations_for/3`'s `{:ok, _not_a_map}` clause and
> `JsonSchema.properties_violations/3`'s `is_map(subschema)` guard are **deliberately
> retained** as last-resort guards against a future writer that bypasses `changeset/2` — for
> example raw SQL inside a migration, or a hand-built `Repo.insert_all/3`. They are unreachable
> through every path that exists today. Do not read them as live defences, and do not add a new
> write path that would make them live again.

`changeset/2`'s own `@doc` (`variable_schema.ex:145-162`) must be updated in the same edit: its
current text says the changeset "does not validate that `json_schema` is itself a well-formed
JSON Schema document" and warns REQ-078/REQ-082 not to assume it does. After this requirement
that sentence is **false** and must be replaced.

GitHub: close **GH#306 (ISS-0089)**, referencing this design. **GH#305 (ISS-0088) is already
closed** — do not reopen it; reference it in the closing note instead.

---

## 10. Route 5 — Pin rebind (`Letflow.Routers.Instances`)

### 10.1 Contract

| Item | Value |
|---|---|
| R-Co source | `src/api/routes/pin_rebind.zig:45-163`; documented contract at L24-44; registration `main.zig:847-849` |
| Method + path | `POST /api/v1/instances/:id/rebind-pins` |
| Mount | `Letflow.Routers.Instances`, existing forward `api_pipeline.ex:41` (§2.5) |
| Permission | none in this requirement (§4.3, OQ-3) |
| Delegate | `Letflow.Engine.PinRebind.rebind_pins/3` (`pin_rebind.ex:162`) — **exists, no new context function needed** |

```
@spec rebind_pins(
        instance_id :: Ecto.UUID.t() | String.t(),
        attrs :: rebind_attrs(),
        opts :: rebind_opts()
      ) :: {:ok, rebind_result()} | rebind_error()
```
with (`pin_rebind.ex:99-136`)
```
@type rebind_attrs :: %{
        required(:entries) => [rebind_entry()],
        required(:reason) => String.t(),
        required(:actor_id) => Ecto.UUID.t(),
        required(:idempotency_key) => String.t()
      }
@type rebind_entry :: %{kind: entry_kind() | String.t(), ref: String.t(), version: String.t()}
@type rebind_opts :: [prefix: String.t()]
@type changed_entry :: %{kind: entry_kind(), ref: String.t(), prior_version: String.t(), new_version: String.t()}
@type rebind_result :: %{instance_id: Ecto.UUID.t(), changed: [changed_entry()], rebound_at: DateTime.t()}
```

`entry_kind()` is `Letflow.Engine.PinResolver.kind()` = `:catalog_entry | :variable_schema | :module`
(`pin_resolver.ex:179`) — the same three strings R-Co's `parsePinKind` accepts
(`pin_rebind.zig:165-170`). The route passes `kind` through as the **raw string**;
`rebind_attrs()` explicitly permits `String.t()`, so no atom conversion happens in the route
(and therefore no attacker-controlled atom creation).

### 10.2 The `idempotency_key` gap

`rebind_attrs()` **requires** `:idempotency_key`. R-Co's request body has none
(`pin_rebind.zig:26-30`). So the route must source one. No other Letflow router reads an
idempotency header — `grep -rn "Idempotency-Key\|idempotency_key" lib/letflow/api/ lib/letflow/routers/`
returns **zero** hits, so there is no existing convention to follow.

**Decision:** read the `idempotency-key` request header; if present and non-empty, use it
truncated to 255 bytes; otherwise generate `Ecto.UUID.generate/0`. Stated in the moduledoc as
the first HTTP-layer idempotency convention in this codebase, and recorded as **OQ-6** so
REQ-079/080 adopt the same convention rather than inventing a second one.

### 10.3 Request validation and error map

Request schema (`Letflow.Api.Validation.validate/2`):

| Field | Required | Type | Constraints |
|---|---|---|---|
| `reason` | yes | `:string` | `reject_empty_string: true`, `min_length: 1`, `max_length: 1024` |
| `entries` | yes | `:array` | `min_items: 1` |

Per-element shape (`kind`/`ref`/`version` all present, all strings; `kind` one of the three) is
checked in the route after `validate/2`, mapping any failure to R-Co's `422 INVALID_INPUT`.

| Condition | Status | Helper | R-Co code (`pin_rebind.zig:35-43`) |
|---|---|---|---|
| body not a JSON object | 400 | `Response.bad_request(conn, "request body must be a JSON object")` | `400 MALFORMED_JSON` |
| `:id` not UUID-shaped (checked in-route before any call) | 422 | `Response.unprocessable(conn, "instance_id is not a valid UUID")` | `422 INVALID_INSTANCE_ID` |
| `{:error, :invalid_instance_id}` from the context | 422 | same | `422 INVALID_INSTANCE_ID` |
| `validate/2` `{:errors, _}` | 422 | `Response.send_problem(conn, Validation.problem(errs))` | `422 INVALID_INPUT` |
| malformed element / `{:error, {:malformed_entry, _i, _r}}` | 422 | `Response.unprocessable(conn, "request body failed validation")` | `422 INVALID_INPUT` |
| `{:error, :invalid_reason}` / `{:error, :empty_entries}` | 422 | same | `422 INVALID_INPUT` |
| `{:error, :instance_not_found}` (absent **or** another tenant's) | 404 | `Response.not_found/1` — no detail (INV-5) | `404 INSTANCE_NOT_FOUND` |
| `{:error, {:instance_not_rebindable, _status}}` | 409 | `Response.conflict(conn, "instance is in a terminal state and cannot be rebound")` — **`_status` is NOT echoed** (it is a property of a resource whose existence the caller has already been told about, so echoing it leaks nothing, but the constant detail keeps the body stable) | `409 INSTANCE_NOT_REBINDABLE` |
| `{:error, {:concurrent_modification, _}}` | 409 | `Response.conflict(conn, "instance is locked by another transaction")` | `409 CONCURRENT_MODIFICATION` |
| `{:error, {:unknown_pin_ref, kind, ref}}` | 422 | `Response.unprocessable(conn, "a requested entry is not present in the instance's current effective pin set")` — **neither `kind` nor `ref` echoed**; both are caller-supplied, so echoing is safe, but a constant detail matches `tenants.ex`'s established constant-detail style | `422 UNKNOWN_PIN_REF` |
| `{:error, :missing_actor_id}` / `{:error, :missing_idempotency_key}` / `{:error, :invalid_schema_name}` | 500 | `Response.internal_error/1` (all three are route-construction bugs, not caller errors) | `500 INTERNAL_ERROR` |
| `{:error, {:event_append_failed, _}}` / `%Ecto.Changeset{}` / `{:error, term()}` | 500 | `Response.internal_error/1` (INV-4) | `500 INTERNAL_ERROR` |
| `scoped_repo_opts/1` `{:error, _}` | 500 | `Response.internal_error/1` | — |
| success | 200 | `Response.ok/2` | — |

No 503 (§6.6).

### 10.4 Response shape

Porting `pin_rebind.zig:33` plus one Letflow addition:

```
%{
  "instance_id" => <uuid>,
  "changes"     => [ %{"kind" => "catalog_entry"|"variable_schema"|"module",
                       "ref" => String.t(),
                       "prior_version" => String.t(),
                       "new_version" => String.t()}, ... ],
  "rebound_at"  => <ISO 8601 UTC>
}
```

`rebound_at` has no R-Co counterpart; it is carried because `rebind_result()` already returns it
(`pin_rebind.ex:129-133`) and it is useful. Named in the moduledoc as an addition.
`changes` maps `rebind_result().changed` element-wise, with `kind` rendered via
`Atom.to_string/1` — a hand-built map with exactly four keys (INV-2).

### 10.5 Moduledoc obligations — `Letflow.Routers.Instances`

Route table row; the idempotency-key convention (§10.2, OQ-6); the note that this route must
precede any future `post "/:id"` (`main.zig:848`); the INV-5 404 rule; the REQ-131 gap; an
"Ordering guarantee" section; and a note that REQ-079/080 co-own this file.

---

## 11. Route 6 — Metrics (`Letflow.Routers.Metrics`)

### 11.1 What exists today — measured, not assumed

* **No metrics registry, no telemetry.** `grep -rln "telemetry\|Telemetry" lib/` matches only
  five files under `lib/letflow/design/` (design prose), never `.ex` code.
* **No counting functions.** `grep -rn "def count_\|@spec count_" lib/letflow/` returns **zero**
  hits.

So "expose whatever counters exist today" has the literal answer **none**. The honest counters
available are `COUNT(*)`-style aggregates over tables that already exist inside a tenant schema.
Producing them requires **three new context functions** (§11.4) — not a metrics subsystem.

### 11.2 The three divergences from `metrics.zig`, all deliberate

Required as a moduledoc section headed **"Divergences from R-Co's `metrics.zig` — all three are
deliberate"**, immediately followed by the AC7 statement (§11.5):

| Dimension | R-Co (`metrics.zig`) | Letflow | Why |
|---|---|---|---|
| **Auth** | unauthenticated — `metrics.zig:20` says so verbatim; mounted top-level at `main.zig:457` | **authenticated** — `/api/v1/metrics`, behind `Letflow.Plugs.AuthPipeline` | Every Letflow figure comes from a tenant schema; reaching one requires `scoped_repo_opts/1`, which requires `conn.assigns[:auth_context]`. An unauthenticated endpoint could only be empty or cross-tenant. |
| **Scope** | platform-global, in-memory `MetricsRegistry` | **per-tenant** — every figure computed inside the caller's own schema | See §11.3. |
| **Format** | Prometheus exposition text (`content_type = PROMETHEUS_CONTENT_TYPE`) | **JSON**, via `Letflow.Api.Response.ok/2` | `Letflow.Api.Response` has no Prometheus-text helper (`response.ex:403-404` defines only `application/json` and `application/problem+json`); adding one is scope. JSON is this codebase's universal response convention. |

> **Do not "correct" any of the three back toward R-Co.** Reverting the scope divergence in
> particular would reintroduce a cross-tenant disclosure — see §11.3.

### 11.3 The tenant-exposure rule (AC5) — required verbatim in the moduledoc

> **Tenant-exposure rule: PER-TENANT-SCOPED.**
>
> Every counter this endpoint returns is computed **within the calling tenant's own schema**,
> via `Letflow.Api.Context.scoped_repo_opts/1`. **No platform-wide figure, and no figure
> derived from more than one tenant, appears in the response body at all.**
>
> This is not a stylistic choice. `Letflow.Api.Authorization.evaluate_access/2` short-circuits
> `:MetricsRead` to `%AccessDecision{kind: :Allow}` **unconditionally**, before the permission
> check ever runs (`lib/letflow/api/authorization.ex:281-282` — a faithful port of
> `authorization.zig`). Every authenticated caller of every tenant therefore holds
> `:MetricsRead` in practice. "Aggregate platform counters to `:MetricsRead` holders" would
> mean "platform-wide figures to every authenticated caller of every tenant" — a cross-tenant
> disclosure (INV-1). Per-tenant scoping is the only option compatible with that
> short-circuit.

Consequence, stated in the same section: **this route does not call `evaluate_access/2` at
all.** A call whose result is a compile-time constant `:Allow` is not a gate; it is
decoration that would read as a gate to the next maintainer. Tenant scoping is the real
protection here, and it is structural. Recorded under OQ-3 for REQ-131.

### 11.4 Three new context functions

Each lands in the context that owns its table. **No `Repo.` call in the route.**

`lib/letflow/engine.ex` (owns `instance_projections` and `tasks`):

```
@typedoc "status atom -> row count, within one tenant schema. Every status is present, zero-valued if unseen."
@type status_counts :: %{atom() => non_neg_integer()}

@doc "Counts `instance_projections` rows by `status`, scoped to `opts[:prefix]`. One query."
@spec count_instances_by_status(opts :: [prefix: String.t()]) ::
        {:ok, status_counts()} | {:error, :invalid_schema_name}
def count_instances_by_status(opts)

@doc "Counts `tasks` rows by `status`, scoped to `opts[:prefix]`. One query."
@spec count_tasks_by_status(opts :: [prefix: String.t()]) ::
        {:ok, status_counts()} | {:error, :invalid_schema_name}
def count_tasks_by_status(opts)
```

`lib/letflow/definitions.ex` (owns `process_definitions`):

```
@doc "Counts `process_definitions` rows by `status`, scoped to `opts[:prefix]`. One query."
@spec count_definitions_by_status(opts :: opts()) ::
        {:ok, %{status() => non_neg_integer()}} | common_error()
def count_definitions_by_status(opts)
```

All three: validate `opts[:prefix]` via
`Letflow.TenantProvisioning.tenant_id_for_schema_name/1` (`tenant_provisioning.ex:195`) —
the same guard `read_global/1` uses (`event_store.ex:766`) — **before** constructing a query;
then one `group_by`/`count` query composed with `Ecto.Query` and run with
`prefix: opts[:prefix]` (INV-7: no interpolation). Statuses absent from the result are filled
with `0` so the response shape is stable, from these closed enums:

* instances: `[:active, :completed, :cancelled, :error]` (`instance_projection.ex:125-128`)
* tasks: `[:pending, :completed, :cancelled]` (`task.ex:59-62`)
* definitions: `[:draft, :active, :deprecated, :archived]` (`process_definition.ex:91-94`)

### 11.5 Response and moduledoc

```
%{
  "scope"       => "tenant",
  "generated_at" => <ISO 8601 UTC>,
  "instances"   => %{"active" => n, "completed" => n, "cancelled" => n, "error" => n, "total" => n},
  "tasks"       => %{"pending" => n, "completed" => n, "cancelled" => n, "total" => n},
  "definitions" => %{"draft" => n, "active" => n, "deprecated" => n, "archived" => n, "total" => n}
}
```

`"scope" => "tenant"` is a constant, present specifically so a reader of a captured response
can see at a glance that it is not platform-wide.

Error map: `scoped_repo_opts/1` `{:error, _}` → 500; any of the three
`{:error, :invalid_schema_name}` → 500; otherwise 200. No 503 (§6.6).

**AC7 statement, required verbatim-in-substance, placed immediately after the divergence
table (§11.2):**

> **No metrics subsystem is built here.** This endpoint computes a handful of `COUNT(*)`
> aggregates over tables that already exist in the caller's tenant schema. It builds no
> registry, no collector, no gauge, no histogram, no scrape target and no in-memory counter
> state. **S6 observability is the owning stage for Letflow's metrics subsystem** — see
> `docs/migration/stage-4-api-surface.md`'s group-(b) table and R-Co's own `obs_metrics`
> module (`src/api/routes/metrics.zig:8`, `collectGlobalPrometheusText`), which Letflow has
> not ported. When S6 lands, this endpoint is expected to be superseded or rewritten; it is a
> placeholder shape, not the design.

Plus: the three-divergence table (§11.2), the tenant-exposure rule verbatim (§11.3), the
`evaluate_access/2` non-call and its reason (§11.3), the `web/` contract break (OQ-7), and an
"Ordering guarantee" section.

---

## 12. Route 7 — Tenant config (`Letflow.Routers.TenantConfig`)

### 12.1 Contract

| Item | Value |
|---|---|
| R-Co source | `src/api/routes/tenant_config.zig:44-115` (`handleTenantConfig`); header L1-6; registration `main.zig:462-464` |
| Method + path | `GET /api/tenant-config` — query `?realm=<slug>` or `?host=<hostname>` |
| Mount | `Letflow.Router`, **new top-level forward before the `/api/v1` forward** (§2.4) |
| Auth | **none** — outside `ApiPipeline` entirely, like `GET /health` |
| Delegate | `Letflow.Identity.get_tenant_by_slug/1` (`identity.ex:627`) — **the only delegate; no new context function** (§12.3) |

Precedence, porting `tenant_config.zig:59-95`:

1. If `?realm=<slug>` is present, resolve the tenant by slug; if it resolves and has a non-nil
   `idp_realm_id`, that wins and **the host branch is skipped**.
2. Else, if `?host=<hostname>` is present — **no binding exists in Letflow (§12.3); falls
   through to the default realm**, which is R-Co's own answer for an unbound hostname.
3. Else, or on any miss, or on **any** error: fall through to the default realm.

Response, always **200**, always this exact two-key shape (`tenant_config.zig:20-27`,
`web/src/auth/tenantConfig.ts:10-13`):

```
%{"oidc_authority" => "<idp_base>/realms/<realm_id>", "client_id" => "<client_id>"}
```

`idp_base` from `System.get_env("BPM_IDP_BASE_URL")`, falling back to
`System.get_env("KEYCLOAK_BASE_URL")`, falling back to `"http://localhost:8081"`;
`client_id` from `System.get_env("OIDC_CLIENT_ID")` falling back to `"bpm-platform-api"`;
default realm `"bpm-default"`. All four values ported verbatim from `tenant_config.zig:46-49`
and `L235`. **Read at the point of use via `System.get_env/1`, never threaded through a struct
field or logged** (INV-4). None of the four is secret material — an OIDC authority URL and a
public client id are values the browser must learn in order to log in at all — but the
resolution style follows INV-4 regardless.

### 12.2 The never-error rule is load-bearing (INV-5), not an R-Co quirk

`tenant_config.zig:41-43` states it outright: *"Never returns an error to the caller — DB
failures fall through to the default tenant config so the frontend login page always renders."*

This must be ported **exactly**, and for two independent reasons:

1. **Availability.** The login page cannot render without a config. A 500 here locks every
   tenant out.
2. **INV-5 / anti-oracle.** A miss, an unprovisioned host, a malformed slug and a database
   outage all produce **the same 200 with the same default body**. There is no status code, no
   error body and no absent field from which a prober can learn whether a given hostname or
   slug corresponds to a real tenant. Returning 404 for an unknown host — the "tidier" REST
   answer — would turn this endpoint into a tenant-existence oracle for anyone with a
   wordlist.

A caller **can** still infer that a hostname is bound to *some* realm when it gets back a
non-default realm id — that is unavoidable, since telling the browser which realm to use is
the endpoint's entire purpose, and it is the same information any user of that tenant sees on
their own login page. The disclosure boundary must be stated in the moduledoc:

> **What this endpoint discloses, and what it must never disclose.** It returns exactly two
> values: an OIDC authority URL (which embeds a realm id) and a public client id. Both are
> values the browser must learn *before* authenticating, and both are visible to any user of
> that tenant. It must **never** return a tenant id, slug, display name, status, user count,
> or any other tenant attribute — the response map is hand-built with exactly the two keys and
> is never derived from `%Letflow.Identity.Tenant{}` (INV-2). Adding a third key to this
> response is a security change, not a feature.

### 12.3 The `?host=` branch — NO new table, NO migration, deferred with a named owner

R-Co resolves `?host=` by joining `tenant_hostnames` → `tenant`
(`tenant_config.zig:157-207`, its own helper comment: *"Query tenant_hostnames -> tenant to
resolve idp_realm_id for a given hostname"*). **Letflow has no host→tenant binding of any
kind** — verified: `grep -rn "tenant_hostname\|hostname" lib/ priv/repo/migrations/` returns
**zero** hits. Letflow has only the realm→tenant and slug→tenant directions
(`Identity.resolve_tenant_by_realm/1`, `identity.ex:128`; `Identity.get_tenant_by_slug/1`,
`identity.ex:627`).

Three options were weighed:

| Option | Verdict |
|---|---|
| (i) Add a `tenant_hostnames` table + Ecto schema + migration + context function | **Rejected.** A new global table and migration is a new subsystem surface, not a route port. **No acceptance criterion asks for it**, nothing in this requirement would write to it, and it would silently expand a "thin route port" into a schema change. Adding a migration nobody asked for is exactly the scope creep `stage-4-api-surface.md:101-108` warns against. |
| (ii) Key the endpoint on bindings Letflow already has (`?realm=<slug>`) | **CHOSEN for the served behaviour.** |
| (iii) Declare the host half deferred and name the owner | **CHOSEN for how the gap is recorded.** |

(ii) and (iii) are complements, not alternatives, and this design takes both.

**No new context function is added. No migration is written. No Ecto schema is created.**

**Served behaviour:**

1. `?realm=<slug>` — fully supported, via `Letflow.Identity.get_tenant_by_slug/1`
   (`identity.ex:627`), reading `tenant.idp_realm_id`. This is a faithful port of
   `tenant_config.zig:59-72`'s step 1, which does exactly the same slug lookup
   (`resolveTenantBySlug`, `tenant_config.zig:117-155`, `SELECT idp_realm_id FROM public.tenant
   WHERE slug = $1`). Nothing about this branch diverges from R-Co.
2. `?host=<hostname>` — **accepted and, today, always falls through to the default realm.**
   Not an error, not a 404, not a 400: the parameter is honoured syntactically and produces the
   default config, which is byte-identical to what R-Co produces for an unbound hostname
   (`tenant_config.zig:82-95` — an unmatched hostname leaves `realm_id = "bpm-default"`).
   **So this is not a behavioural divergence for any hostname Letflow could have resolved
   anyway** — Letflow has no bindings at all, so every hostname is unbound, and R-Co's own
   unbound-hostname answer is the one served.
3. Neither parameter present — default realm, same as R-Co.

**This works today for the only caller.** `web/src/auth/tenantConfig.ts:43-45` resolves a realm
slug from `sessionStorage`/the URL **first** and passes `{realm: slug}`, falling back to
`{host: hostname}` only when no slug is known. The supported branch is the preferred branch.

**Deferral, with a named owner (OQ-8).** Host→tenant binding belongs with tenant onboarding —
the point at which a tenant acquires an identity that a hostname could be bound to. **REQ-076
(Identity routes 4/4 — API tokens, role registry, tenant onboarding, `status: pending`) is the
proposed owner.** Until it or a successor lands, `?host=` resolves to the default realm.

**Moduledoc obligation (in addition to §12.5):** state that `?host=` is accepted but currently
always falls through to default; state that Letflow has no `tenant_hostnames` table and that
adding one was deliberately declined as out of scope for a route port; name REQ-076 as the
proposed owner. **A later reader must not "fix" this by adding a migration without an owning
requirement.**

### 12.4 Error map

There is none by design: every path returns **200** with either the resolved config or the
default config. Any `{:error, _}` from either lookup is caught, logged at `:warning` naming the
slug/hostname (both caller-supplied, so safe to log) and **never** the exception, and falls
through to the default — porting `tenant_config.zig:74-80` and `L88-94`.

Because the module is outside `ApiPipeline`, it does **not** get `Plug.Parsers`, `AuthPipeline`,
`TenantStatus`, or `Letflow.Api.Context.assign_trace_id/1`. It is a `GET` with no body, so
`Plug.Parsers` is not needed; but it must call `Plug.Conn.fetch_query_params/1` itself. **The
absence of a trace id must be named in the moduledoc**, since `Response.send_json/3` is still
used and `conn.assigns[:trace_id]` will be absent (harmless — this endpoint emits no problem
document). Recorded as **OQ-9**.

### 12.5 Moduledoc obligations — `Letflow.Routers.TenantConfig`

1. Why it is mounted on `Letflow.Router` and **not** in `ApiPipeline` (§2.4), naming
   `AuthPipeline`'s lack of a bypass as the concrete reason.
2. The never-error rule and **both** justifications (§12.2).
3. The disclosure-boundary paragraph verbatim-in-substance (§12.2).
4. The realm-then-host precedence.
5. That `?host=` is accepted but currently always falls through to the default config; that
   Letflow has **no** `tenant_hostnames` table and adding one here was **considered and
   rejected** as a producerless subsystem (the REQ-056 failure mode, §13); and that **REQ-076
   (tenant onboarding)** is the proposed owner of hostname→tenant binding. **A later reader
   must not "fix" this by adding a migration without an owning requirement** (OQ-8).
6. The missing trace id (OQ-9).

---

## 13. `sandbox_access.zig` — deliberately NOT ported (Decision 3)

Stated in this design, and to be restated in `Letflow.Routers.SolutionPacks`'s moduledoc (the
nearest module in this requirement) or in `stage-4-api-surface.md`'s group-(b) table, which
already carries the row (`stage-4-api-surface.md:115`):

`src/api/routes/sandbox_access.zig` (181 lines) is **not** ported by this requirement, for
three independent reasons, any one of which would be sufficient:

1. **It exports no `handle*` entry point.** Its three public functions are
   `checkPrincipalBound` (L41), `checkProbeRate` (L82) and `writeSentinelAudit` (L152) — guards
   a route calls, not a route. There is no HTTP surface here to port.
2. **Its only consumer is post-S6.** `grep -rln sandbox_access src/` returns exactly one file,
   `routes/agent_sandboxes.zig`, which its own header names as the module it was extracted
   from. `agent_sandboxes.zig` is the runtime-agent subsystem, owning stage **post-S6**
   (`stage-4-api-surface.md:113`). Porting these guards in S4 would ship a guard with no S4
   caller to guard — a partial backing subsystem, the REQ-056 failure mode.
3. **`checkProbeRate` is rate limiting** (`probe_threshold` 20 per `probe_window_secs` 60),
   which needs the per-tenant counter storage REQ-068's SCOPE BOUNDARY paragraph explicitly
   defers. Porting it here would smuggle in the exact mechanism this batch defers elsewhere.

It moves with `agent_sandboxes.zig` to post-S6.

---

## 14. Contradictions found against the inputs to this design

Flagged rather than silently reconciled, as instructed.

**C-1 — ISS-0088 / GH#305 is already closed.** REQ-078's "WELL-FORMEDNESS, NOT JUST PRESENCE"
paragraph describes two *live* read-side defects and instructs closing both GH#306 and GH#305.
But `docs/issues/ISS-0088.yaml` is `status: resolved`, and
`lib/letflow/event_store/registry/json_schema.ex:146-172` already carries the
`is_map(subschema)` guard with a comment naming "ISS-0088 / GH#305 fix". **Only GH#306
(ISS-0089) remains open and is closed by this design (§9.4).** GH#305 must not be reopened.

**C-2 — solution packs are not "a thin surface over existing context functions".** REQ-078's
description asserts that all six modules are. For solution packs it is false: R-Co delegates to
`src/solution/store.zig` (~700 lines), of which Letflow has ported **nothing**. See §8.1 and
**OQ-1** — this needs an ORCH decision before Step 2a.

**C-3 — four of REQ-070's reserved mount points do not match R-Co's URLs.**
`lib/letflow/design/req070-router-decomposition.md:133-136` reserves `/validation`,
`/tenant-config`, `/audit` and `/metrics`. Checked against `src/main.zig`: only `/audit`
survives unchanged; `/validation` corresponds to no R-Co URL at all; `/tenant-config` is
`/api/tenant-config` **and public**; `/metrics` is top-level and public. Resolved per §2;
REQ-070's roster should be annotated by DOC-UPDATER, not silently left inconsistent
(**OQ-10**).

**C-4 — `web/`'s metrics contract breaks.** `web/src/api/metrics.ts:127` calls
`client.getText('/metrics')` and `parsePrometheusText` parses the result. This design serves
**JSON at `/api/v1/metrics`**. `web/src/pages/admin/MetricsPage.tsx` will break. See **OQ-7**.
`web/`'s audit and tenant-config contracts, by contrast, both **match** this design exactly
(`web/src/api/audit.ts:59` → `/api/v1/audit` with the same six params and the same
`{items,next_cursor,count}` shape; `web/src/auth/tenantConfig.ts:46` → `/api/tenant-config`
with `realm`-or-`host`).

---

## 15. Every new and changed file

### New

| Path | What |
|---|---|
| `lib/letflow/routers/solution_packs.ex` | `Letflow.Routers.SolutionPacks` — two routes (§8) |
| `lib/letflow/definitions/solution_pack.ex` | `Letflow.Definitions.SolutionPack` — `export/3`, `install/3` (§8.3) |
| `lib/letflow/definitions/json_schema_shape.ex` | `Letflow.Definitions.JsonSchemaShape` — `check/1`, the pure well-formedness predicate both `Letflow.Definitions` and `Letflow.Engine.VariableSchema` call (§9.3, OQ-2 ruling) |

**No migration is written by this requirement, and no Ecto schema is created.** The
`tenant_hostnames` table R-Co's `?host=` branch needs is deliberately **not** added (§12.3,
OQ-8) — it belongs to REQ-076, not to a route port.

### Changed

| Path | Change |
|---|---|
| `lib/letflow/routers/audit.ex` | `GET /` handler, `with_authorization/4`, cursor helpers, full moduledoc (§6) |
| `lib/letflow/routers/metrics.ex` | `GET /` handler, full moduledoc incl. the verbatim tenant-exposure rule and AC7 statement (§11) |
| `lib/letflow/routers/tenant_config.ex` | `GET /` handler, full moduledoc (§12) |
| `lib/letflow/routers/definitions.ex` | adds `post "/:id/validate"` + moduledoc incl. the AC6 `validation.zig` distinction (§7) |
| `lib/letflow/routers/instances.ex` | adds `post "/:id/rebind-pins"` + moduledoc (§10) |
| **`lib/letflow/routers/validation.ex`** | **DELETED** (§2.3) |
| `lib/letflow/plugs/api_pipeline.ex` | **removes** the `/validation` forward (L48); **removes** the `/tenant-config` forward (L47); **adds** `forward("/solution-packs", to: Letflow.Routers.SolutionPacks)`; moduledoc note on all three |
| `lib/letflow/router.ex` | **adds** `forward("/api/tenant-config", to: Letflow.Routers.TenantConfig)` before the `/api/v1` forward; route-table row; note that the deferred-routes table (L83-97) is unchanged — none of these six modules is in it |
| `lib/letflow/event_store.ex` | widens `read_global_opts()` by four keys and `read_global_error()` by two; extends `read_global/1`'s filtering; `@doc` update (§6.5) |
| `lib/letflow/definitions.ex` | adds `validate_definition_graph/2` (§7.2), `register_variable_schemas/3` (§9.2), `count_definitions_by_status/1` (§11.4) + the new `@type`s (`graph_validation_result`, `variable_schema_input`, `variable_schema_error`) |
| `lib/letflow/engine.ex` | adds `count_instances_by_status/1`, `count_tasks_by_status/1`, `status_counts()` (§11.4) |
| `lib/letflow/engine/variable_schema.ex` | `changeset/2` gains the well-formedness `validate_change`; its `@doc` is rewritten (the OQ-3 warning is now false); moduledoc gains the §9.4 OQ-3 closing section; `validations_for/3`'s `{:ok, _not_a_map}` comment rewritten as unreachable-by-construction (§9.3) |
| `lib/letflow/api/validation.ex` | moduledoc gains the `routes/validation.zig` vs `src/api/validation.zig` pointer (§7.4) |
| `docs/issues/ISS-0089.yaml` | `status: open` → `resolved`, with the §9.3 rationale (DOC-UPDATER) |

`lib/letflow/identity.ex` is **unchanged** — the tenant-config route uses the existing
`get_tenant_by_slug/1` (`identity.ex:627`) and adds nothing.

### Not changed, deliberately

`lib/letflow/api/authorization.ex` — **no new `endpoint_policy_key/2` clause is added by this
requirement.** Inventing policy keys for the pack, rebind and validate paths is REQ-130/131's
job (§4.3). `lib/letflow/event_store/registry/json_schema.ex` — its ISS-0088 guard stays
(§9.3).

---

## 16. Invariants that must hold

| # | Invariant | Where discharged |
|---|---|---|
| INV-RT-1 | No `Repo.` call appears in any file under `lib/letflow/routers/`. Verified by `grep -n "Repo\." lib/letflow/routers/*.ex` → zero hits. | §3.3 |
| INV-RT-2 | Every authenticated route's tenant comes solely from `Letflow.Api.Context.scoped_repo_opts/1`. No path segment, query param, header or body field is ever used to select a tenant, schema or prefix. | §5, §2.6 |
| INV-RT-3 | Authorization (where it applies) and prefix resolution both complete before any `Repo` call, including pre-fetch reads. | §3.2 |
| INV-RT-4 | Every response body is a hand-built map with an explicit key list; no `Jason.Encoder` derivation over an Ecto struct anywhere in this requirement. | §3.1, §12.2 |
| INV-RT-5 | Cross-tenant resource access yields **404** with no detail, on the same code path and same query count as a genuine miss. Missing permission yields **403**. The two are never conflated. | §4.4 |
| INV-VS-1 | **Exactly one** insert path into `variable_schemas` exists in `lib/`: `Letflow.Definitions.register_variable_schemas/3`. Verified by `grep -rn "VariableSchema" lib/letflow/routers/ lib/letflow/definitions/solution_pack.ex` → the route dir returns zero, and `solution_pack.ex` shows only `register_variable_schemas` calls, never a changeset or `Repo` call against the schema. | §9.2, AC8 |
| INV-VS-2 | No `variable_schemas` row that is not a well-formed JSON Schema document at every level can be written through any path in `lib/` or `test/`. | §9.3 |
| INV-VS-3 | Registration rows are keyed to the `definition_id` argument, so concurrent registrations for different definitions write disjoint row sets. | §9.2 |
| INV-MT-1 | The metrics response body contains no platform-wide figure and no figure derived from more than one tenant. | §11.3 |
| INV-TC-1 | `GET /api/tenant-config` returns 200 with the same two-key body for a hit, a miss, a malformed input and a database failure. | §12.2 |

---

## 17. Cross-module dependency map

```
Letflow.Router
  └── (new, public) /api/tenant-config -> Letflow.Routers.TenantConfig
                                              └── Letflow.Identity.get_tenant_by_slug/1   [existing; the ONLY delegate]
                                                  (?host= has no Letflow binding -- default realm; deferred to REQ-076, OQ-8)
  └── /api/v1 -> Letflow.Plugs.ApiPipeline  [Parsers -> assign_trace_id -> AuthPipeline -> TenantStatus]
        ├── /audit          -> Letflow.Routers.Audit
        │                        ├── Letflow.Api.Authorization.{roles_from_strings/1, endpoint_policy_key/2, evaluate_access/2}   [TEMPORARY, REQ-131]
        │                        ├── Letflow.Api.Context.scoped_repo_opts/1
        │                        ├── Letflow.Api.Pagination.{parse_page_size_param/1, validate_page_size/1, build_raw_cursor/3, encode_cursor/1, decode_cursor/4, parse_int_from_cursor/3}
        │                        └── Letflow.EventStore.read_global/1                          [EXTENDED]
        ├── /definitions    -> Letflow.Routers.Definitions
        │                        ├── Letflow.Api.Context.scoped_repo_opts/1
        │                        └── Letflow.Definitions.validate_definition_graph/2           [NEW]
        │                               ├── Letflow.Definitions.get_by_id/2
        │                               └── Letflow.Definitions.Graph.{from_map/1, validate_graph/1, validate_node_attributes/1, validate_edge_conditions/1}
        ├── /instances      -> Letflow.Routers.Instances
        │                        ├── Letflow.Api.Context.scoped_repo_opts/1
        │                        └── Letflow.Engine.PinRebind.rebind_pins/3                    [existing]
        ├── /solution-packs -> Letflow.Routers.SolutionPacks                                   [NEW forward]
        │                        ├── Letflow.Api.Context.scoped_repo_opts/1
        │                        └── Letflow.Definitions.SolutionPack.{export/3, install/3}    [NEW module]
        │                               ├── Letflow.Definitions.{get_by_id/2, create/2}
        │                               ├── Letflow.Engine.VariableSchema.fetch_schemas/3      (export)
        │                               ├── Letflow.Definitions.register_variable_schemas/3    [NEW, the single insert path]
        │                               │      ├── Letflow.Definitions.JsonSchemaShape.check/1 [NEW leaf module]
        │                               │      └── Letflow.Engine.VariableSchema.changeset/2   [gains well-formedness check]
        │                               │             └── Letflow.Definitions.JsonSchemaShape.check/1
        │                               │                (leaf module -- no Engine -> Definitions dependency, OQ-2)
        │                               ├── Letflow.Definitions.SolutionPackInstall.insert_changeset/2
        │                               ├── Letflow.TenantProvisioning.tenant_id_for_schema_name/1
        │                               └── Letflow.Api.Authorization.roles/0                  (role checklist, read-only)
        └── /metrics        -> Letflow.Routers.Metrics
                                 ├── Letflow.Api.Context.scoped_repo_opts/1
                                 ├── Letflow.Engine.{count_instances_by_status/1, count_tasks_by_status/1}   [NEW]
                                 └── Letflow.Definitions.count_definitions_by_status/1                       [NEW]

Every route module also depends on Letflow.Api.Response and, where it takes a body,
Letflow.Api.Validation + Letflow.Api.Validation.FieldConstraint.
REQ-082's future import path depends on Letflow.Definitions.register_variable_schemas/3 and
MUST NOT add a second insert path.
```

---

## 18. Traceability — every acceptance criterion to a concrete element

| # | Acceptance criterion (abbreviated) | Design element(s) | Test that discharges it |
|---|---|---|---|
| **AC1** | each of the six modules has ≥1 end-to-end test through the real router asserting status and response shape | §6 (`GET /api/v1/audit`), §7 (`POST /api/v1/definitions/:id/validate`), §12 (`GET /api/tenant-config`), §8 (`POST /api/v1/solution-packs/export` and `/install`), §10 (`POST /api/v1/instances/:id/rebind-pins`), §11 (`GET /api/v1/metrics`) — response shapes at §6.2, §7.3, §12.1, §8.3, §10.4, §11.5 | **T-01..T-07**: one `Plug.Test.conn/3` request per endpoint through `Letflow.Router` (**not** the sub-router directly — the tenant-config test in particular must go through `Letflow.Router` to prove it is reachable without a token), asserting status and the exact top-level key set |
| **AC2** | audit list returns only the calling tenant's events when both tenants are seeded in the same window; caller without `AuditRead` gets 403 (INV-1) | §5 (`scoped_repo_opts/1` is the only tenant input), §6.1, §6.5 (`:prefix`-scoped `read_global/1`), §4.2 (`:AuditRead` → `:Deny403` → 403), §4.4 | **T-08**: provision tenants A and B, append events to both inside one timestamp window, request as A, assert every returned `resource_id` is an A instance and no B `event_id` appears. **T-09**: request as a `TASK_WORKER`-only caller (no `:AuditRead` per `authorization.ex:394-395`), assert **403** and an RFC 9457 body |
| **AC3** | pack export as tenant A contains no tenant B artefact; install as A writes only into A's schema, verified by querying both schemas after (INV-1) | §8.3 (`export/3` reads with A's prefix only; `install/3` writes with A's prefix only; the one global row's `tenant_id` is derived from that prefix), §2.6 (no path tenant id) | **T-10**: seed definitions in A and B; export as A naming an A id and a B id; assert 422 and that no B artefact appears in any successful export. **T-11**: install as A, then `Repo.all(..., prefix: <B schema>)` over `process_definitions` and `variable_schemas` and assert **zero** rows added in B, and the expected rows in A |
| **AC4** | the validation endpoint returns the same outcome as calling REQ-028/029's validator directly on the same graph — proving the route adds no second rule | §7.2 (the composition lives in `Letflow.Definitions.validate_definition_graph/2`, calls exactly the three `Graph.validate_*` functions, and explicitly does **not** call `ServiceScopeValidator.validate/3`) | **T-12**: for both a valid and an invalid stored graph, call the endpoint and independently call `Graph.validate_graph/1` + `validate_node_attributes/1` + `validate_edge_conditions/1` on the same `%Graph{}`; assert the endpoint's `findings` list equals the concatenated violations, code for code and message for message |
| **AC5** | the metrics tenant-exposure rule is stated in the moduledoc (aggregate-only or per-tenant) and enforced by a test that a tenant A caller sees no tenant B figure | §11.3 (the rule, required verbatim in `Letflow.Routers.Metrics`'s moduledoc), §11.4 (all three counters `:prefix`-scoped), §11.5 (`"scope" => "tenant"`) | **T-13**: seed A with 1 active instance and B with 7; request as A; assert `instances.active == 1` and that **no** value in the body equals 7 or 8 — i.e. neither B's figure nor a platform total is present. **T-14**: a doc test / `Code.fetch_docs/1` assertion that the moduledoc contains the phrase "PER-TENANT-SCOPED" |
| **AC6** | the moduledoc distinguishes `routes/validation.zig` from `src/api/validation.zig` so the two are not conflated | §7.4 (the required section in `Letflow.Routers.Definitions`, plus the pointer added to `Letflow.Api.Validation`) | **T-15**: `Code.fetch_docs/1` on `Letflow.Routers.Definitions` asserting the moduledoc names **both** `routes/validation.zig` and `src/api/validation.zig` and attributes the latter to REQ-068 / `Letflow.Api.Validation` |
| **AC7** | `metrics.zig`'s moduledoc states no metrics subsystem is built here and names S6 observability as its owner | §11.5 (the required AC7 paragraph, placed immediately after §11.2's divergence table) | **T-16**: `Code.fetch_docs/1` on `Letflow.Routers.Metrics` asserting the moduledoc contains both "No metrics subsystem is built here" and "S6 observability" |
| **AC8** | installing a pack whose document carries `variable_schemas` writes those rows into the **calling** tenant's `variable_schemas` and none into any other tenant's, verified by reading both schemas back; and the write goes through the single shared `Letflow.Definitions` registration function REQ-082's import also calls, with grep confirming no second insert path in the route layer | §9.2 (`register_variable_schemas/3` — the single insert path, full `@spec` and error tuples), §8.3 step 7 (install calls it and nothing else), §9.3 (well-formedness), §9.4 (the OQ-3 closing moduledoc text), INV-VS-1 | **T-17**: install a pack carrying `variable_schemas` entries as A; read `variable_schemas` back with `prefix: <A schema>` (rows present, `json_schema` decoded to the expected maps) and with `prefix: <B schema>` (**zero** rows). **T-18**: install a pack whose `schema_content` is `"[1,2]"` (a top-level non-object); assert **422**, and assert **zero** `variable_schemas` rows and **zero** `process_definitions` rows were written in A — the whole transaction rolled back. **T-19 (grep test)**: an ExUnit test that reads every file in `lib/letflow/routers/` and asserts none contains `"VariableSchema"` or `"variable_schemas"`, and reads `lib/letflow/definitions/solution_pack.ex` and asserts it contains no `Repo.insert` against `VariableSchema` — the mechanical form of "grep confirming no second insert path" |

Additional non-AC tests the design implies (for TEST-DESIGNER): cursor round-trip across two
pages on `/audit` (§6.4); `from > to` → 422 (§6.5); `pipeline_run_id` → 422 (§6.3);
`resource_type=definition` → empty page (§6.3); tenant-config returns the **same** default body
for an unknown host, a malformed slug, and a slug with a `nil` `idp_realm_id` (§12.2, INV-TC-1);
tenant-config reachable with **no** `Authorization` header (§2.4); a pack whose
`service_catalog_entries` is non-empty → 422 (§8.2); a rebind against a completed instance →
409 (§10.3); a rebind against another tenant's instance → 404 with a body byte-identical to a
nonexistent instance (§4.4, INV-RT-5).

---

## 19. Open questions — explicitly NOT resolved by guessing

**OQ-1 — BLOCKING. Should solution packs (+ the shared registration function) be split out of
REQ-078?** Full statement, reasoning and proposed split: **§0**. Short form: Letflow has no
backing context for pack export/install (§8.1), so this requirement would have to build
`Letflow.Definitions.SolutionPack` from scratch, plus
`Letflow.Definitions.register_variable_schemas/3` and a change to a `done` S3 module — while
the other five modules are genuinely thin. **My recommendation: split** (§0.3), with AC3 and
AC8 travelling to the new requirement and the `variable_schemas` obligation travelling *with
them*, never dropped. Both paths are fully designed here, so ORCH can decide either way and
Step 2a can start immediately. **ORCH's call, not CODE-DESIGNER's.**

**OQ-2 — Where does the well-formedness predicate live? — RULED: a dedicated module.**
`Letflow.Definitions.JsonSchemaShape.check/1`, in
`lib/letflow/definitions/json_schema_shape.ex`, called by both `Letflow.Definitions` and
`Letflow.Engine.VariableSchema`. *Rationale (ORCH):* placing it on `Letflow.Definitions` would
make an Engine module call into Definitions — the wrong dependency direction and a REVIEWER
finding waiting to happen. A leaf module both may depend on has no such problem. **The
placement of the check inside `changeset/2` was never in question and is unchanged.** Design
updated at §9.3.

**OQ-3 — Five of the seven endpoints ship with no permission gate — RULED: accepted.**
Only `GET /audit` is gated. `POST /definitions/:id/validate`, both `/solution-packs` routes,
and `POST /instances/:id/rebind-pins` have no `endpoint_policy_key/2` clause and are therefore
authenticated-but-unauthorized; `GET /metrics` deliberately does not call `evaluate_access/2`
because that call is a constant `:Allow` (§11.3). *Ruling conditions (ORCH):* (1) every
affected moduledoc names the gap explicitly and names **REQ-131** as the closer; (2) **no local
permission check may be invented to fill it** — REQ-069's whole point is one matrix; (3)
`GET /audit` stays gated via the route-local `evaluate_access/2` call, as a **third private
copy** of the `tenants.ex:181-194` / `identity.ex:187-213` helper, not an extraction (§4.1).

**OQ-4 — 410 `cursor_expired` collapsed into 422 — RULED: accepted, keep the collapse.**
R-Co distinguishes them (`audit.zig:42-43`); Letflow folds expiry into one
`{:error, :invalid_cursor}` because `Pagination.decode_cursor/4`'s expiry result is already
folded that way at every existing call site (`tenants.ex:287`). *Rationale (ORCH):* consistency
with every existing `decode_cursor/4` call site beats R-Co fidelity here; making `/audit` the
only endpoint in the system that can emit 410 is a worse outcome than losing the distinction.
Keep the divergence note in the moduledoc (§6.4, §6.7 item 6).

**OQ-5 — transaction composition of `register_variable_schemas/3` — RULED: as written; ELIXIR-DEV
settles the shape.** §9.2 step 7 wants the
registration to commit atomically with the pack install. Whether that is best expressed as the
function returning an `Ecto.Multi` for the caller to merge, or as the function detecting an
open transaction, is an implementation-shape question ELIXIR-DEV should settle — but the
**guarantee** is fixed: a failed registration must roll back the definitions the same install
created (T-18 asserts exactly this).

**OQ-6 — the `idempotency-key` header convention — RULED: accepted.** §10.2 introduces the
**first HTTP-layer idempotency convention in this codebase**: read the `idempotency-key`
request header if present and non-empty (truncated to 255 bytes), else generate
`Ecto.UUID.generate/0`. Not validated against any R-Co precedent — R-Co's rebind body simply
has no such field. *Ruling condition (ORCH):* `Letflow.Routers.Instances`'s moduledoc must
carry an **explicit sentence stating that REQ-079 and REQ-080 must adopt this same convention
rather than inventing a second one.**

**OQ-7 — `web/`'s metrics page breaks — RULED: accepted as a known, recorded breakage; out of
scope for REQ-078.** `web/src/api/metrics.ts:127` expects Prometheus text
at top-level `/metrics`; this design serves JSON at `/api/v1/metrics`.
`web/src/pages/admin/MetricsPage.tsx` and `parsePrometheusText` will need a FRONTEND-DEV
follow-up. **Out of scope for REQ-078** (which is backend-only), but it is a real, known
breakage and must not be discovered in UAT. ORCH should queue the follow-up.

**OQ-8 — the `?host=` branch has no Letflow binding — RULED: take the smaller option. NO table,
NO Ecto schema, NO migration, NO new context function.** Serve `?realm=<slug>` only, via the
existing `Letflow.Identity.get_tenant_by_slug/1` (`identity.ex:627`); `?host=` parses and always
falls through to the default config. *Rationale (ORCH, overruling this design's first specified
path):* **creating a table that no route in this requirement — and no requirement currently on
the board — ever writes to is a partial backing subsystem shipped with no producer. That is the
REQ-056 failure mode, and REQ-078's own text invokes it twice as the reason `sandbox_access.zig`
is not ported (§13). We cannot decline to port a guard with no caller in one paragraph and add a
table with no writer in the next.** `web/src/auth/tenantConfig.ts:44-45` prefers `realm` when
available, so the endpoint is fully useful on day one, and `?host=` still returns a valid
default config — graceful degradation, not a functional non-port (R-Co returns the same default
for any unbound hostname). Owner of hostname→tenant binding: **REQ-076 (tenant onboarding)**,
named in the moduledoc. Design updated at §12.3; §15 updated. **Consequence, checkable at
review: this requirement adds NO migration at all.**

**OQ-9 — `/api/tenant-config` has no trace id — RULED: accepted as-is; do not mount
`assign_trace_id/1` on `Letflow.Router`.** Mounted outside `ApiPipeline`, it never runs
`Letflow.Api.Context.assign_trace_id/1`, so no `x-trace-id` response header is set. Harmless
today (the endpoint emits no problem document), but it is an inconsistency with every other
Letflow endpoint. Fixable later by mounting `assign_trace_id/1` on `Letflow.Router` itself;
not done here because that would change `GET /health`'s response headers, which
`deploy/redeploy-test.sh` pins (`router.ex:74-76`).

**OQ-10 — REQ-070's roster is now stale — RULED: DOC-UPDATER annotates, does not rewrite.**
`lib/letflow/design/req070-router-decomposition.md:126-136` lists ten sub-routers including
`Letflow.Routers.Validation` at `/validation` and `Letflow.Routers.TenantConfig` under
`ApiPipeline`. After this requirement, one is deleted and one is mounted elsewhere, and
`Letflow.Routers.SolutionPacks` is an eleventh. *Ruling (ORCH):* REQ-070's design is a
**historical artefact** — annotate it, never rewrite it. Same treatment for the group-(a) table
in `docs/migration/stage-4-api-surface.md`. ORCH routes this at closeout.

---

## 20. ORCH rulings — run `WF02-REQ078-20260822`

Every open question and contradiction raised by this design, with the ruling ORCH issued after
reading it. Each is also folded inline at its own OQ (§19) and at the design section it affects.
**These rulings are the operative instruction; where §0–§18 was written before a ruling, the
ruling wins and the affected section has been updated to match.**

| ID | Ruling | Where the design was updated |
|---|---|---|
| **OQ-1** | **(a) — accept the added scope; DO NOT split.** Splitting would strand AC3/AC8, and AC8 exists because an earlier requirement dropped the `variable_schemas` insert path and shipped the table empty (ISS-0063/GH#212) — splitting to tidy the port would re-create that exact failure mode. The two mitigating facts carry it: Letflow supports 2 of R-Co's 4 pack arrays, and both handlers compose functions that already exist plus the registration function §9 builds anyway. Amending the requirement text would need a separate WF-01 pass and would block queue task 145 indefinitely. **Condition: solution packs (§8) + the registration function (§9) are committed as their own commit, BEFORE the five thin routes** (§0.4). | §0 header, §0.3 heading, §0.4 |
| **OQ-2** | **Dedicated module.** `Letflow.Definitions.JsonSchemaShape.check/1`. An Engine→Definitions dependency is the wrong direction. Placement inside `changeset/2` unchanged. | §9.3, §15, §17 |
| **OQ-3** | **Accepted** — five endpoints ship authenticated-but-ungated. Conditions: each moduledoc names the gap and names REQ-131; **no local permission check may be invented**; `GET /audit` stays gated via a **third private helper copy**, not an extraction. | §4.1, §4.3, §19 |
| **OQ-4** | **Accepted** — keep the 422 collapse; consistency with every existing `decode_cursor/4` call site beats R-Co fidelity, and `/audit` must not become the only endpoint emitting 410. | §6.4, §19 |
| **OQ-5** | **As written.** ELIXIR-DEV settles `Ecto.Multi`-vs-open-transaction; the guarantee is fixed and T-18 asserts it. | §9.2, §19 |
| **OQ-6** | **Accepted** — `idempotency-key` header, else generated UUID. Condition: an explicit sentence in `Letflow.Routers.Instances`'s moduledoc that **REQ-079/080 must adopt this same convention**, since it is the first HTTP-layer idempotency convention in the codebase. | §10.2, §10.5, §19 |
| **OQ-7** | **Accepted as a known, recorded breakage; out of scope.** ORCH carries the FRONTEND-DEV follow-up in the run report so it is not discovered in UAT. C-4 stays exactly as written. | §14 C-4, §19 |
| **OQ-8** | **Smaller option, overruling this design's first specified path.** Drop the `tenant_hostnames` table, Ecto schema, migration and `resolve_realm_by_hostname/1`. Serve `?realm=` only; `?host=` falls through to default. A table with no writer is the REQ-056 failure mode this requirement invokes twice against `sandbox_access.zig`. Owner named: **REQ-076**. | §12.1, §12.3, §12.5, §15, §17 |
| **OQ-9** | **Accepted as-is.** Do not mount `assign_trace_id/1` on `Letflow.Router` — it would change `GET /health`'s response headers, which `deploy/redeploy-test.sh` pins (`router.ex:74-76`). | §12.4, §19 |
| **OQ-10** | **DOC-UPDATER annotates, does not rewrite.** REQ-070's design and `stage-4-api-surface.md`'s group-(a) table are historical artefacts. Routed at closeout. | §19 |
| **C-1** | **Design is right; REQ-078's text is wrong.** GH#305/ISS-0088 is already `resolved` and `json_schema.ex:146-172` already carries the `is_map(subschema)` guard. **Do NOT reopen GH#305.** Only GH#306/ISS-0089 is closed by §9.4. **DOC-UPDATER: REQ-078's "WELL-FORMEDNESS, NOT JUST PRESENCE" paragraph is stale on this point and should be corrected.** | §9.3, §9.4, §14 C-1 |
| **C-2** | **Recorded correction to REQ-078's description.** **DOC-UPDATER: amend the "one-to-three-handler surface over existing context functions" sentence to except solution packs**, so the next reader is not misled the way ORCH was. | §0.1, §8.1, §14 C-2 |
| **C-3** | **Resolved per §2; no change needed.** Deleting `lib/letflow/routers/validation.ex` and its forward is correct — a module whose moduledoc promises "Routes added by REQ-078" cannot be left behind unfulfilled. | §2.3, §14 C-3 |
| **C-4** | See OQ-7. Keep as written. | §14 C-4 |

### 20.1 No migration in this requirement — checkable at review

**REQ-078 adds zero files under `priv/repo/migrations/`.** After the OQ-8 ruling, the only
migration this design ever contemplated is gone. Verification at review:
`git diff --name-only origin/main... -- priv/repo/migrations/` must be **empty**.
`Letflow.TenantProvisioning.tenant_scoped_migrations/0` (`tenant_provisioning.ex:499`) is
likewise unchanged.

### 20.2 Sub-router files co-owned with pending requirements — for the queue

| File | Gains from REQ-078 | Reserved for | Action |
|---|---|---|---|
| `lib/letflow/routers/definitions.ex` | **exactly one** route, `post "/:id/validate"` (§2.3, §7) | REQ-081 / REQ-082 (both `pending`) | **Sequence REQ-081/082 after REQ-078, or rebase them.** |
| `lib/letflow/routers/instances.ex` | **exactly one** route, `post "/:id/rebind-pins"` (§2.5, §10) | REQ-079 / REQ-080 (both `pending`) | **Sequence REQ-079/080 after REQ-078, or rebase them.** REQ-079 must additionally keep any future `post "/:id"` **after** this route (`main.zig:848`). |
| `lib/letflow/definitions.ex` | 3 new public functions in disjoint areas (§7.2, §9.2, §11.4) | REQ-082 will add `register_variable_schemas/3` **callers**, never a second implementation | REQ-082 calls it; adds no second insert path (§9.1). |

Neither route module's `match _` catch-all is touched, and no existing route anywhere is
modified — the additions are purely additive.

### 20.3 No `Repo.` call in any route module — checkable at review

**No file under `lib/letflow/routers/` in this design contains a `Repo.` call of any kind.**
Verification at review: `grep -n "Repo\." lib/letflow/routers/*.ex` must return **zero hits**
(INV-RT-1, §3.3). Each of the seven handlers delegates as follows:

| # | Handler | Delegates to | New? |
|---|---|---|---|
| 1 | `GET /api/v1/audit` | `Letflow.EventStore.read_global/1` | existing, **opts widened** (§6.5) |
| 2 | `POST /api/v1/definitions/:id/validate` | `Letflow.Definitions.validate_definition_graph/2` | **new** (§7.2) |
| 3 | `GET /api/tenant-config` | `Letflow.Identity.get_tenant_by_slug/1` | existing, unchanged (§12.3) |
| 4 | `POST /api/v1/solution-packs/export` | `Letflow.Definitions.SolutionPack.export/3` | **new** (§8.3) |
| 5 | `POST /api/v1/solution-packs/install` | `Letflow.Definitions.SolutionPack.install/3` | **new** (§8.3) |
| 6 | `POST /api/v1/instances/:id/rebind-pins` | `Letflow.Engine.PinRebind.rebind_pins/3` | existing, **unchanged** (§10.1) |
| 7 | `GET /api/v1/metrics` | `Letflow.Engine.count_instances_by_status/1`, `Letflow.Engine.count_tasks_by_status/1`, `Letflow.Definitions.count_definitions_by_status/1` | **all three new** (§11.4) |

Plus the one non-route delegate every solution-pack install goes through:
`Letflow.Definitions.register_variable_schemas/3` (§9.2) — **the single insert path into
`variable_schemas`** (INV-VS-1, AC8), itself calling
`Letflow.Definitions.JsonSchemaShape.check/1` and `Letflow.Engine.VariableSchema.changeset/2`.
