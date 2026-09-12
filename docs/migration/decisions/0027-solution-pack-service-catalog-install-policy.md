# 0027 — SolutionPack `service_catalog_entries` install policy: permanently rejected, not merely interim

Status: decided (2026-09-12, `CODE-DESIGNER`, REQ-321), pending its own
`SECURITY-REVIEWER` and `REVIEWER` gates (sections below, not yet filled in).
Owner: `ORCH` (this record settles the policy question `check_unsupported_sections/1`'s
own stale surrounding comment has left UNOWNED since REQ-192 landed; it produces
no implementation, and none is scheduled by it).

## Re-verification performed (before deciding anything)

All of the following was read in full, in the current tree, on this branch, before
any answer below was written — not assumed from the requirement text:

- `lib/letflow/definitions/solution_pack.ex`:
  - `check_unsupported_sections/1` (lines 886-887): confirmed the current two-clause
    shape — `defp check_unsupported_sections(%{service_catalog_entries: []}), do: :ok`
    / `defp check_unsupported_sections(_parsed), do: {:error, :unsupported_pack_section}`.
    This is a pure, pre-transaction check, step 2 of `install/3`'s `with` chain (after
    `parse_document/1`, before `check_schema_version/1`).
  - The comment immediately above it (lines 864-885): confirmed it is stale exactly as
    described — it previously deferred the install-time visibility policy to REQ-192,
    then self-corrects that REQ-192 is `done` and landed the service-catalog route
    surface *without* lifting the restriction, leaving the policy UNOWNED. It also
    carries a live NOTE (added by ELIXIR-DEV during REQ-305) flagging that the
    now-superseded design doc for `entity_definitions` once specified a joint
    `%{service_catalog_entries: [], entity_definitions: []}` passing clause, which
    would have made `entity_definitions` permanently uninstallable — the shipped code
    correctly implements only the single-key `service_catalog_entries` clause quoted
    above, confirming `entity_definitions` is NOT gated by this function today.
  - The moduledoc's `service_catalog_entries` bullet (lines 27-53, "still not
    supported"): confirmed it restates the same UNOWNED-policy history and states
    "Export still always emits `[]`; install still **rejects** a non-empty array."
  - `install/3` (line ~402) and `run_install/5` (line ~940): confirmed the exact
    `with`-chain step order — `parse_document/1` → `check_unsupported_sections/1` →
    `check_schema_version/1` → `decode_variable_schemas/1` →
    `TenantProvisioning.tenant_id_for_schema_name/1` → `run_install/5`, and that
    `run_install/5`'s own `Repo.transaction/1` body runs `insert_install_row/2` →
    `create_packed_definitions/3` → `create_packed_entity_definitions/3` →
    `register_packed_schemas/3`, with a single shared `with`/`else ->
    Repo.rollback(reason)` clause — confirmed there is exactly one rollback path, not
    one per step.
  - The moduledoc's "Install is ALL-OR-NOTHING" section (lines 89-99), quoted
    verbatim below in §5.
  - The moduledoc's "Tenant scoping (INV-1)" section (lines 71-84): confirmed "No
    function here takes a tenant id, schema name or slug as a caller-supplied
    argument," with `solution_pack_installs`' own row as the sole named exception,
    whose `tenant_id` is *derived* from the resolved prefix.
- `lib/letflow/service_catalog.ex` in full:
  - Moduledoc's "GLOBAL table" section (lines 24-60): confirmed `service_catalog`
    lives in the default/public schema, has no `:prefix` option, and is not in
    `Letflow.TenantProvisioning.tenant_scoped_migrations/0` — a deliberate divergence
    from `docs/migration/decisions/0003-ecto-schema-strategy.md` Dimension B (line 37
    there: "Multi-tenancy representation: schema-per-tenant... adopted as the general
    rule for all business tables under Decision B, not treated as a special case"),
    justified because `service_id` is globally unique across all tenants regardless
    of scope and a `scope: :global` row must be referenceable by every tenant
    simultaneously — neither property is expressible as a per-tenant-schema copy.
  - "No `opts[:prefix]` on any function" (lines 65-73): confirmed every function
    instead takes an explicit `tenant_id`.
  - `register/1` (lines 147-152, def at 152): confirmed the `@spec` return type
    includes `{:error, :duplicate_service_id}` and the body (line 194-195) maps ANY
    unique-constraint hit on the `service_id` primary key to that one atom,
    regardless of who owns the conflicting row.
  - `get_for_tenant/2` (lines 226-228): confirmed SVC-01's three-way visibility rule
    — global visible to all, tenant-scoped visible only to its owner, another
    tenant's row and a genuinely missing row both return `{:error, :not_found}`
    (INV-5 indistinguishability, applied at read time).
  - `update_scope/2` (line 435): confirmed it takes `service_id` and new attrs only —
    no `opts[:prefix]`, matching the GLOBAL-table shape.
  - "The context module has never enforced authorization" — searched this module for
    any role/permission check: confirmed there is none; `Letflow.ServiceCatalog`'s
    five functions are pure Ecto CRUD with no `Letflow.Api.Authorization` call
    anywhere in the file.
- `lib/letflow/service_catalog/entry.ex` in full: confirmed the `Entry` schema
  (`@primary_key {:service_id, :string, autogenerate: false}`) already carries every
  field a packed entry would need — `endpoint_url`, `request_schema`,
  `response_schema`, `required_auth` (`Ecto.Enum`), `timeout_ms`, `retry_policy`,
  `scope` (`Ecto.Enum`, `:global`/`:tenant`), `owner_tenant_id`, `created_at`,
  `updated_at`. No field is missing that a pack-carried entry would require.
- `priv/repo/migrations/20260830000001_create_service_catalog.exs`: confirmed the
  table's DDL matches `Entry`'s field list exactly, with DB-level `CHECK` constraints
  for scope/owner consistency and enum ranges, and the PK is the `service_id` column
  itself (no separate unique index needed for global uniqueness).
- `lib/letflow/engine/service_task_dispatcher.ex` in full:
  - Moduledoc's `route_kind: :catalog_service` section: confirmed
    `catalog_lookup_stub/2` returns `{:error, :not_registered}` **unconditionally**
    for every `service_id` today — "No dispatch row with `route_kind:
    :catalog_service` can ever reach `:advance` through this module's own poll loop
    today; every such attempt gives up immediately."
  - Moduledoc's SSRF-gate section (INV-9): confirmed `Letflow.Webhooks.UrlValidator.validate/2`
    is called immediately before the module's single `:httpc.request/4` call site
    inside `http_transport/3`, and confirmed (by the same section) that
    `http_transport/3` is reached **only** by `route_kind: :inline_url` — a
    `:catalog_service` dispatch never reaches `http_transport/3` or the validator at
    all, because it is intercepted by the unconditional stub first.
- `lib/letflow/engine/lua_script_audit.ex` in full: confirmed its moduledoc's own
  statement, quoted directly: "This module is a MINIMAL, deliberately narrow
  engine-side call path that (a) invokes an injected script executor and (b)
  persists the resulting manifest hash to a queryable audit record... It is NOT the
  SERVICE_TASK script-execution handler." Confirmed its schema
  (`lua_script_execution_audit`) has exactly four meaningful columns —
  `instance_id`, `manifest_hash`, `actor_id`, `executed_at` — and that its single
  public function, `execute_script_for_audit/6`, takes an `executor :: module()` and
  a `registered_hash` to diff against an executor-reported `manifest_hash`. None of
  this shape has any counterpart in a service-catalog entry: there is no "executor,"
  no "manifest hash," and no later execution step this audit format is built to
  attest to.
- `lib/letflow/api/authorization.ex`: confirmed the two permission names and their
  resolution chain:
  - `required_permission/1` maps `:DefinitionsCreate` → `:DefinitionsWrite` (lines
    668-680).
  - `required_permission/1` maps `:AdminServicesManage` (and `:AdminServicesRead`) →
    `:UsersGroupsRolesManage` (lines 703-704), with the inline comment "platform-admin
    enforced in handler, per Zig's comment."
  - `role_allows?/2` (lines 751+): confirmed `:PLATFORM_ADMIN` is granted every
    permission unconditionally (line 754); confirmed `:PROCESS_DESIGNER`'s permission
    list (lines 756-780) includes `:DefinitionsWrite` but does **not** include
    `:UsersGroupsRolesManage`; confirmed no other role's list includes
    `:UsersGroupsRolesManage` either — it is `:PLATFORM_ADMIN`-exclusive in practice.
  - `lib/letflow/routers/solution_packs.ex` line 167: confirmed `authz_post
    "/install", :DefinitionsCreate do`.
  - `lib/letflow/routers/admin_services.ex` lines 129/133/137: confirmed all three
    service-catalog write routes (`POST /`, `PATCH /:service_id`, `DELETE
    /:service_id`) are gated on `:AdminServicesManage`.
  - **Conclusion: the asymmetry the requirement names is real.** A `:PROCESS_DESIGNER`
    holds `:DefinitionsCreate` → `:DefinitionsWrite` and can call `POST
    /solution-packs/install` today, but does **not** hold `:AdminServicesManage` →
    `:UsersGroupsRolesManage`, and therefore cannot call any service-catalog write
    route directly. If a packed entry installed with no further gate, pack install
    would be a `:DefinitionsCreate`-only path to a write the HTTP surface otherwise
    reserves for `:PLATFORM_ADMIN` alone.
- The current S10 stage file's own "Open questions" section (around line 190):
  confirmed it already names "whether `service_catalog_entries` in a pack document
  unblocks here — and who now owns that policy" as an explicitly recorded,
  not-yet-decided item, and separately confirms gaps 4 and 5 are unowned as of this
  record.
- Decision `0022` (the S10 stage's own bucket-rule record), "The bucket rule" (lines
  53-72): confirmed rule 1 — a bucket-B requirement, and by extension this bucket-B
  decision record, may not name what any single vertical's gap is actually for, only
  its bucket and gap number. Confirmed this record's own content, and the gap
  numbers it cites, name nothing vertical-specific.

**Conclusion of re-verification: the requirement's own framing holds in full.** The
rejection is real, current, and unowned; the GLOBAL-table asymmetry is real and
structural; the SSRF-gate/stub asymmetry is real (a catalog-routed dispatch cannot
reach `http_transport/3`'s validator at all today, because it never gets past the
unconditional stub); the authorization asymmetry is real (`:DefinitionsCreate` ≠
`:AdminServicesManage`, and no role but `:PLATFORM_ADMIN` holds both); and
`Letflow.ServiceCatalog` enforces no authorization of its own, as its moduledoc says.

## Question

Six concrete sub-questions, none of which the existing code answers on its own:

1. Is a packed `service_catalog_entries` entry permitted to install at all?
2. If yes, what scope may it carry, and may the pack document itself name
   `scope`/`owner_tenant_id`?
3. If yes, who may install a pack that registers an outbound capability, and at what
   layer is that enforced?
4. Does a packed entry need `Letflow.Engine.LuaScriptAudit`'s audit path, a new one
   modeled on it, existing timestamps, or none?
5. What happens on a `service_id` collision — same-tenant vs. global/other-tenant —
   and does the chosen shape leak a cross-tenant existence signal (INV-5)?
6. Does lifting the restriction require any migration/schema change, or is it pure
   install-path policy?

## Decision

### 1. NOT PERMITTED. The rejection is the permanent, documented stance, not an interim one.

**A solution-pack document may not carry `service_catalog_entries`. This is a
permanent policy decision, not a placeholder awaiting a future requirement.**
`check_unsupported_sections/1`'s hard-fail — `%{service_catalog_entries: []} -> :ok`,
anything else `-> {:error, :unsupported_pack_section}` — stays exactly as it is
today, unconditionally, indefinitely.

**Out-of-band provisioning path:** the existing `POST /service-catalog` route
(`lib/letflow/routers/admin_services.ex`, gated on `:AdminServicesManage`, resolving
to permission `:UsersGroupsRolesManage`, `:PLATFORM_ADMIN`-only in the current role
matrix) is the sole path by which a service-catalog entry is registered, whether that
entry backs S10 gap 4, gap 5, or anything else. The current S10 stage file's own
"Open questions" section already named this as the alternative S10 may take, and
this record takes it.

**Follow-on work this record does NOT do:** `check_unsupported_sections/1`'s
surrounding comment (the stale REQ-192 deferral) and the moduledoc's
`service_catalog_entries` bullet are now provably stale in a *new* way — they still
frame the policy as "UNOWNED," when after this record it is OWNED and settled as
"never." Correcting that comment and that bullet to cite this record instead is
follow-on editorial work for a later requirement against `lib/letflow/definitions/solution_pack.ex`
— explicitly out of this record's scope fence, which leaves that file byte-identical.

### 2. Scope — the rejected design's shape, stated concretely

Since §1 is NO, this describes the permissive design this record does NOT adopt (see
"What this record does not decide" and the rejected-option section below for why),
concretely enough for a later requirement to build if circumstances change:

- **`:tenant`-scoped-to-the-installing-tenant would be the only value derivable at
  install time**, with `owner_tenant_id` set from the resolved `TenantProvisioning.tenant_id_for_schema_name(prefix(opts))`
  value — the exact mechanism `run_install/5` already uses to derive
  `solution_pack_installs.tenant_id` — never read from pack content. This mirrors
  every other `install/3` write's tenant-scoping discipline (moduledoc's "Tenant
  scoping (INV-1)" section, re-verified above).
- **`:global` would never be permitted through this path, under any additional
  gate.** `Letflow.ServiceCatalog`'s own moduledoc (lines 24-60, re-verified above)
  states the reason structurally, in its own words: a `scope: :global` row is "by
  definition referenceable by every tenant," which makes a `:global` packed entry a
  cross-tenant capability grant delivered by a single tenant's install action — the
  install actor's own tenant boundary provides no containment for the blast radius
  of that write. No install-time gate (an extra permission check, an extra
  confirmation flag) changes the fact that the *artefact* (a tenant's pack document)
  is the wrong origin for a *cross-tenant* grant; the origin needs to be a
  platform-level action against a platform-level table, which the existing
  `POST /service-catalog` (`:AdminServicesManage`) route already is.
- **The pack document itself would never be allowed to carry `scope` or
  `owner_tenant_id` as a document field, under the rejected design either.** Both
  values would always be derived at install time — `scope: :tenant` fixed by policy,
  `owner_tenant_id` fixed to the resolved prefix's tenant — and any `scope`/
  `owner_tenant_id` key present in the document's own `service_catalog_entries`
  content would be ignored (never read into the create call), for the same reason
  `entity_definitions` never reads a tenant identifier out of pack content (0026 §5,
  re-verified above as still the governing precedent): pack content is trusted as
  *entry* data, never as a source of *tenant scope*.

### 3. Authorization — the rejected design's shape, stated concretely

- **Concrete permission, from the existing vocabulary: `:AdminServicesManage`
  (resolving to `:UsersGroupsRolesManage`, `:PLATFORM_ADMIN`-only in the current
  role matrix) — the same permission the existing service-catalog write routes
  already require.** No new permission name is proposed.
- **This differs from installing a definitions-only pack**, which requires only
  `:DefinitionsCreate` (`:DefinitionsWrite`) — a permission `:PROCESS_DESIGNER`
  already holds.
- **Mechanism, if built: the ROUTE layer performs a second, conjunctive permission
  check when the parsed document's `service_catalog_entries` is non-empty** —
  `lib/letflow/routers/solution_packs.ex`'s `install` action would need to check
  `has_permission?(ctx.roles, :UsersGroupsRolesManage)` in addition to the
  `:DefinitionsCreate` check `authz_post` already performs, conditioned on the
  parsed document's content, not unconditionally on every install call (an
  entity-definitions-only or process-definitions-only pack must not suddenly
  require `:PLATFORM_ADMIN`). **The route layer, not `install/3` itself, and not
  `Letflow.ServiceCatalog`, is the right layer, for two independent reasons stated
  by the code's own moduledocs:** `Letflow.ServiceCatalog`'s moduledoc states the
  context module "has never enforced authorization" and this record does not
  propose changing that division of labor (matching how `Letflow.Definitions.create/2`,
  `Letflow.Entities.Definitions.create_definition/2`, and every other `install/3`-called
  context function also enforce no authorization of their own — authorization is
  uniformly a route-layer concern in this codebase, per `Letflow.Api.Authorization`'s
  own moduledoc and every `authz_*` macro call site). Threading a caller-supplied
  "capability" argument into `install/3` itself would duplicate that check inside a
  pure context function that has no other authorization awareness anywhere in its
  ~1000 lines, and would create a second place a permission decision could be made
  inconsistently with the route's own `authz_post` gate.
- **This reconciles the two verified facts:** today, `POST /solution-packs/install`
  is `:DefinitionsCreate`-gated and `POST /service-catalog` is
  `:AdminServicesManage`-gated; a permissive design's job is exactly to close the gap
  those two facts describe (a `:DefinitionsCreate`-only actor gaining an
  `:AdminServicesManage`-class write) by requiring BOTH permissions when — and only
  when — the pack content actually exercises the catalog-write capability.

### 4. Audit — existing `solution_pack_installs` row + `service_catalog`'s own timestamps are sufficient; neither `LuaScriptAudit`'s path nor a new record modeled on it is needed

**Chosen answer (stated for the rejected design, since no packed entry can exist to
be audited under §1's actual decision): if this were ever built, the existing
`solution_pack_installs` row (which already durably records `pack_id`,
`installed_version`, `installed_at`, and the derived `tenant_id` for every install,
per `insert_install_row/2`) plus `service_catalog`'s own `created_at`/`updated_at`
columns (already stamped by `register/1`/`update_scope/2`) would be sufficient audit
— no dedicated new audit record is needed.** This is a different answer than
`entity_definitions` needed no new discussion for (it needed none, having no
"later outbound execution" concern at all) and a different answer than
`LuaScriptAudit`'s own concern class:

- **`Letflow.Engine.LuaScriptAudit` is the wrong model to reuse, by its own
  moduledoc's explicit statement**, quoted above: it is "a MINIMAL, deliberately
  narrow engine-side call path" built around one specific shape of risk — an
  injected `Executor` producing a `manifest_hash` that must be diffed against a
  `registered_hash` at the moment of execution, so that a mismatch (someone swapped
  the script body after it was registered) is caught and never silently recorded as
  trusted. A service-catalog entry has no analogous "manifest" to hash and no
  "executor" whose output needs diffing — `endpoint_url` doesn't get compiled,
  interpreted, or hashed before use; it is read as a plain string at dispatch time.
  Reusing `LuaScriptAudit`'s table or function would misuse a schema built for a
  hash-mismatch class of risk to record a shape of event that has no hash to
  mismatch.
- **Nor does the entry warrant "a new record modeled on it."** `LuaScriptAudit`'s
  pattern earns its narrowness because a script's behavior is opaque until executed
  and the audit exists specifically to catch drift between registration and
  execution. A `service_catalog` row's `endpoint_url` is not opaque in that way, and
  more importantly, INV-9's own rule (re-verified above) already requires the actual
  outbound-request call site to re-validate the URL "at the point of the actual
  request call — not at ingestion time alone" — that re-validation duty already
  falls on the dispatcher (`http_transport/3`'s `UrlValidator.validate/2` call),
  independent of any audit trail, and is not something a durable audit *record*
  would add. What a durable audit trail is *for* here — knowing who registered what,
  when, and under what pack — is already fully answered by `solution_pack_installs`
  (which install, by which actor_id, of which pack_id/version, at what
  installed_at) joined with `service_catalog.created_at`/`updated_at` (when the row
  itself was written/last changed). No information a bespoke audit table would add
  is missing from that join.

### 5. Install conflict — both cases, and why the shared `{:error, :duplicate_service_id}` disclosure would be acceptable under the rejected design specifically because of §3's gate

Since `register/1` (re-verified above) maps **any** unique-constraint hit on the
`service_id` primary key to the same `{:error, :duplicate_service_id}` atom,
regardless of who owns the pre-existing row:

- **(a) A row already owned by the installing tenant:** the installing tenant
  already knows it registered that `service_id` (it is the tenant's own prior
  action), so an error naming that collision discloses nothing the tenant didn't
  already know. Consistent with `SolutionPack.install/3`'s documented all-or-nothing
  stance, quoted from the moduledoc: *"`Letflow.Definitions.create/2` has no upsert,
  no skip and no idempotent branch: it inserts, or it returns an error... which the
  route maps to a 409 that aborts the entire install."* The rejected design's
  `create_packed_service_catalog_entries/3` (hypothetical, per §4's naming
  convention for the other packed-artefact helpers) would treat `register/1`'s
  `{:error, :duplicate_service_id}` exactly the same way
  `create_packed_entity_definitions/3` already treats a `create_definition/2` error
  today: `{:halt, error}` inside the reduce, flowing into `run_install/5`'s single
  shared `with`/`else -> Repo.rollback(reason)` clause — the whole install,
  including any already-created definitions/entity-definitions from the SAME pack,
  rolls back. No new rollback path.
- **(b) A row that exists globally or under ANOTHER tenant — the interesting case,
  because it is a potential INV-5 existence oracle.** `register/1` surfaces the
  IDENTICAL `{:error, :duplicate_service_id}` atom for this case as for case (a),
  since `service_id` is the primary key across all tenants and the changeset-level
  check (re-verified above) does not distinguish ownership. **This record states the
  disclosure explicitly rather than leaving it unaddressed: yes, this shape would
  disclose that SOME row with that exact `service_id` string already exists
  somewhere in the system (globally or under another tenant) — it does not disclose
  WHO owns it or under which scope.** Under the rejected design, **this is acceptable
  specifically because of §3's authorization answer, not despite it**: the only
  caller who could ever reach this path is one who already holds
  `:AdminServicesManage` (`:PLATFORM_ADMIN` in the current role matrix) — the SAME
  actor class that can already call `Letflow.ServiceCatalog.list_all/1` (an
  unrestricted, all-tenants, all-scopes list function, re-verified to exist in the
  module above) directly through the existing admin surface. A `:PLATFORM_ADMIN`
  caller gains no NEW cross-tenant visibility from this collision error that
  `list_all/1` doesn't already hand them outright; the oracle only becomes a genuine
  INV-5 problem for a caller who does NOT already have platform-wide visibility —
  and §3's gate is precisely what keeps such a caller (e.g. a bare
  `:DefinitionsCreate`-holding `:PROCESS_DESIGNER`) out of this path entirely. This
  is why §3's authorization answer and §5's conflict answer are not independent
  choices: relaxing §3 to allow a tenant-scoped-only actor to install
  `service_catalog_entries` would reopen this exact oracle for an actor class that
  has no legitimate reason to learn whether an arbitrary `service_id` string exists
  elsewhere in the system, and the rejected design's own internal consistency
  depends on keeping both restrictions together, not adopting one without the
  other.

### 6. Migration or pure policy — PURE POLICY, no schema change of any kind

**Lifting the restriction would require zero migration or schema change.**
Re-verified directly from `lib/letflow/service_catalog/entry.ex` and
`priv/repo/migrations/20260830000001_create_service_catalog.exs`: the `service_catalog`
table and its `Entry` schema already carry every field a packed entry would need to
round-trip through `register/1` — `service_id` (the PK), `endpoint_url`,
`request_schema`, `response_schema`, `required_auth`, `timeout_ms`, `retry_policy`,
`scope`, `owner_tenant_id`, `created_at`, `updated_at`. Nothing in
`Letflow.ServiceCatalog.register/1`'s existing signature or the table's DDL is
missing a column, an enum value, or a constraint that a pack-sourced entry would
need. Were this restriction ever lifted, the entire remaining work is: (a) a new
`packed_service_catalog_entry()` type and its parse/pack functions in
`solution_pack.ex`, (b) extending `check_unsupported_sections/1` analogous to how
`entity_definitions` was added (0026 §1(c)), and (c) the route-layer authorization
change in §3 above — all install-path policy, parsing, and validation code; no
`priv/repo/migrations/` file, no `Entry` changeset change, and no DB constraint
change of any kind.

### 7. The option NOT taken: the permissive design, described concretely

**The rejected option is the permissive design itself** — the shape described
piece-by-piece in §§2-5 above: install-time-derived `:tenant`-only scope with
`:global` never reachable through this path, a route-layer conjunctive
`:AdminServicesManage` + `:DefinitionsCreate` gate, "existing timestamps are
sufficient" audit, and a shared `{:error, :duplicate_service_id}` conflict shape
whose acceptability depends on the authorization gate. **Why it was not taken, on
the merits, independent of the individual mechanism choices above:**

1. **The GLOBAL-table asymmetry is structural, not a formatting gap.** Every other
   write `install/3` performs is `opts[:prefix]`-scoped and cannot reach outside the
   installing tenant's own schema, full stop (moduledoc's "Tenant scoping (INV-1)"
   section). A `service_catalog_entries` install would be the sole write in this
   module's history that reaches a table living outside any tenant's schema at all.
   Even the *`:tenant`-scoped-only* variant of the permissive design still WRITES to
   that global table — it just constrains the `scope` column's value — so the
   asymmetry is not fully closed by restricting scope; it is only contained. A
   permanent "no" removes the asymmetry entirely rather than containing it.
2. **The dispatch side offers no operational upside today to offset the added
   surface.** `catalog_lookup_stub/2`'s unconditional `{:error, :not_registered}`
   (re-verified above) means no packed entry, however it was scoped or gated, could
   be *dispatched* to at all today — S10 gaps 4/5 cannot actually invoke a
   catalog-routed SERVICE_TASK yet regardless of this record's answer, because that
   requires a separate, not-yet-built requirement to replace the stub with a real
   lookup. Building install-time support now would add authorization surface,
   parsing surface, and an INV-5-sensitive conflict path for a capability that
   cannot be exercised end-to-end until an unrelated, unscheduled requirement lands.
3. **The out-of-band path is not a compromise — it is the SAME mechanism the
   permissive design would still gate behind (`:AdminServicesManage`), with less
   code.** Since §3's own reasoning requires the permissive design to restrict
   catalog-registering installs to `:AdminServicesManage` holders anyway, the
   permissive design does not expand WHO can register a catalog entry — it only
   adds a second way (`POST /solution-packs/install` with a populated
   `service_catalog_entries` section) for the SAME already-privileged actor to do
   something `POST /service-catalog` already lets them do directly, in one call,
   today. The marginal value of the pack-delivery path, for an actor who already has
   the more direct route available, is convenience — bundling a catalog
   registration into a larger pack install — not new capability. That is a real but
   modest value, and it does not outweigh points 1 and 2.

**If circumstances change** — most plausibly, once a real `service_catalog`-backed
dispatch lookup replaces `catalog_lookup_stub/2` and S10 gap 4 or 5 has a concrete,
scheduled need to ship a catalog entry alongside a pack rather than provisioning it
separately — a later requirement can adopt the permissive design exactly as
specified in §§2-5 above, including the authorization gate in §3 (which that later
requirement should treat as load-bearing, not optional, per the reasoning in §5) and
the audit answer in §4.

## Reasoning

Each sub-question's justification is stated inline with its answer above, because
each turns on a different piece of the codebase (the GLOBAL-table divergence for
§2, the permission-resolution chain for §3, `LuaScriptAudit`'s own narrow-scope
statement for §4, `register/1`'s unconditional collision atom for §5, and
`Entry`'s already-complete field list for §6). The one cross-cutting principle: this
record treats "no operational benefit yet + real structural asymmetry now" as
sufficient reason to keep a restriction in place, the same posture
`check_unsupported_sections/1` has held since before this record — this record's
contribution is converting that posture from "unowned and stale" to "owned and
permanent," not inventing a new posture.

## Consequences

- **No code changes anywhere.** `check_unsupported_sections/1` and its two clauses
  remain exactly as they are; `lib/letflow/definitions/solution_pack.ex` is
  untouched by this record (verified: `git diff -- lib/letflow/definitions/solution_pack.ex`
  is empty).
- **`lib/letflow/definitions/solution_pack.ex`'s stale comment and moduledoc bullet
  remain stale until a later requirement updates them to cite this record** instead
  of the REQ-192 deferral — that editorial correction is explicitly out of this
  record's scope (see "What this record does not decide").
- **S10 gaps 4 and 5 proceed via the existing `POST /service-catalog`
  (`:AdminServicesManage`) route** for any service-catalog entry either needs,
  provisioned out-of-band from whatever pack that gap's own requirement installs.
- **No design artefact is produced under `lib/letflow/design/`**, per this record's
  own answer to sub-question 1 (NO) and the requirement's own instruction that a
  design artefact is produced only when sub-question 1 is YES.
- **The permissive design described in §§2-5 and "The option NOT taken" above
  remains available to a later requirement**, named concretely enough to be adopted
  without re-deriving the mechanism, should the stub/authorization/audit landscape
  described in point 2 of that section change.

## What this record does not decide

- **Whether or when `catalog_lookup_stub/2` is replaced with a real
  `service_catalog`-backed lookup.** That is a separate, unscheduled S6-adjacent
  requirement this record does not file and does not assume.
- **The exact route-layer conjunctive-permission code** (`solution_packs.ex`'s
  `install` action gaining a second `has_permission?/2` check) — described in §3
  above as the mechanism a later requirement would use, not built or specified at
  the code-signature level, because §1's actual answer is NO and no implementation
  or design artefact follows from a "no."
- **Correcting `lib/letflow/definitions/solution_pack.ex`'s stale comment and
  moduledoc bullet** to cite this record instead of the stale REQ-192 deferral —
  explicitly assigned to a later requirement, per this record's own scope fence
  (`solution_pack.ex` stays byte-identical here).
- **Whether S10 gap 4 or gap 5's own requirement should itself provision any
  needed service-catalog entry via the `POST /service-catalog` route as part of its
  own acceptance criteria, or expect a human/operator step** — a scheduling and
  requirement-sizing decision for gap 4/5's own `REQ-ANALYST` pass, not this
  record's to make.
- **Implementation of any kind.** No file under `lib/letflow/definitions/`,
  `lib/letflow/service_catalog.ex`, `lib/letflow/service_catalog/`,
  `lib/letflow/routers/`, `lib/letflow/api/`, `priv/repo/migrations/`, or `test/` is
  touched by this record.

## SECURITY-REVIEWER sign-off

**Verdict: PASS.**

**Scope note (per this requirement's own framing): this is a DESIGN-TIME /
POLICY-TIME review, not a review of running code.** This record's actual decision
(§1: NOT PERMITTED) ships no code — `git diff -- lib/letflow/definitions/solution_pack.ex`
is empty, independently re-confirmed below — so there is no packed-entry install path
in the current tree to review as "code." What this sign-off assesses is (a) whether
the policy choice itself is sound against INV-9/INV-1/INV-5, and (b) whether the
record's characterization of the *rejected* design's own risk shape (offered as a
record for a future reviewer, per §7) is accurate, since a future requirement could
otherwise cite an inaccurate characterization as settled.

**INV-9 (tenant-controlled outbound URL validation), addressed by name.**
Independently re-verified, not taken on the record's word:

1. `lib/letflow/definitions/solution_pack.ex` lines 886-887: `check_unsupported_sections/1`
   is exactly the two-clause hard-fail the record quotes —
   `%{service_catalog_entries: []} -> :ok` / anything else `-> {:error, :unsupported_pack_section}`
   — confirmed unchanged, and `git status --porcelain` for this branch shows only the
   new `0027-*.md` file as untracked; no tracked file, including this one, carries a
   diff. **This does eliminate the packed-entry outbound-URL surface entirely for the
   pack-install path**: since no `service_catalog_entries` array can ever pass this
   gate, no pack-supplied `endpoint_url` can ever reach `Letflow.ServiceCatalog.register/1`
   via `install/3`, so there is no new `endpoint_url` ingestion point for INV-9 to
   apply to today. This is the correct verdict for the path this record actually
   governs.
2. `lib/letflow/engine/service_task_dispatcher.ex`, re-read in full: confirmed
   `route_kind: :catalog_service` dispatches through `catalog_lookup_stub/2` (line
   401, unconditional `{:error, :not_registered}`) and never reaches `http_transport/3`
   or its `UrlValidator.validate/2` call (lines 335-337) — only `route_kind: :inline_url`
   reaches that validator (moduledoc lines 37-51, confirmed against the `case` at line
   682). The record's characterization of this asymmetry (§4, "the rejected design")
   is accurate: even if a packed entry existed, it could not be *dispatched to* today,
   because the dispatch side is independently stubbed regardless of this record's
   answer.
3. **Residual risk correctly left out of this record's scope, checked directly rather
   than assumed.** I read `lib/letflow/routers/admin_services.ex`'s `handle_register/1`
   (lines 187-213) and `lib/letflow/service_catalog/entry.ex`'s changeset (lines 96-99):
   the existing out-of-band `POST /service-catalog` route accepts `endpoint_url` as a
   plain string with only `validate_length(:endpoint_url, max: 2048)` — there is no
   `UrlValidator.validate/2` call, or any SSRF-shaped check, anywhere in
   `ServiceCatalog.register/1` or its changeset at *registration* time. This is a real,
   pre-existing gap in the admin route, independent of this record. **It is correctly
   out of scope for this record to fix or even formally assess**, for two reasons this
   record's own scope fence already establishes: (a) that route's behavior is
   unchanged, pre-existing, and not touched by anything decided here — this record
   introduces no new caller-supplied `endpoint_url` path, it only declines to add one;
   (b) it carries no live exploitation path today, because `catalog_lookup_stub/2`'s
   unconditional stub (point 2 above) means a registered entry's `endpoint_url` is
   never dispatched to by any code path yet, catalog- or pack-sourced. Flagging this
   for the record: once `catalog_lookup_stub/2` is replaced with a real lookup (the
   record's own "if circumstances change" note), `admin_services.ex`'s registration
   path acquiring dispatch-time consequences without its own ingestion-time or
   dispatch-time URL check becomes a live INV-9 question that requirement will need to
   answer — but it is not this record's question, and this record correctly stays
   silent on it rather than reaching outside its own scope fence.

**INV-1 (tenant data isolation), addressed by name.** Re-read
`check_unsupported_sections/1` directly (not the record's paraphrase) and confirmed
`git diff main...HEAD -- lib/letflow/definitions/solution_pack.ex` is empty — the
file is genuinely byte-identical to `main`, matching the record's own "Consequences"
claim. Since the chosen policy is a permanent, unconditional rejection with zero new
code, there is no caller-supplied tenant identifier and no write reaching outside the
installing tenant's prefix, because there is no new write path of any kind. The
rejected design's own §2 tenant-scoping claims (derive `owner_tenant_id` from
`TenantProvisioning.tenant_id_for_schema_name(prefix(opts))`, never from pack content;
`:global` never reachable through this path) are internally consistent with every
other `install/3` write's discipline (moduledoc's "Tenant scoping (INV-1)" section,
independently re-read) and correctly flagged as needing re-verification again if a
later requirement actually adopts them — appropriately hedged, not presented as
already-verified running code.

**INV-5 (not-found/forbidden indistinguishability), addressed by name.** §5's
conflict-disclosure reasoning is explicitly and correctly scoped to the *rejected*
design only — the section header says so directly ("...the rejected design
specifically because of §3's gate") and the record's own "Reasoning"/"Consequences"
sections confirm no code implementing this exists. I checked whether this hypothetical
reasoning could leak into or affect *actual shipped behavior* today: it cannot, because
(a) no packed `service_catalog_entries` path exists to produce the
`{:error, :duplicate_service_id}` disclosure being reasoned about, and (b) the existing
`GET`/register paths' own INV-5 behavior — `get_for_tenant/2`'s three-way visibility
rule collapsing "another tenant's entry" and "genuinely missing" to the same
`{:error, :not_found}` (re-verified at `lib/letflow/service_catalog.ex` lines 226-228)
— is untouched and unmentioned as needing any change. The §5 reasoning itself is also
sound as reasoning about the hypothetical: it correctly identifies that
`register/1`'s shared `{:error, :duplicate_service_id}` atom is an existence oracle in
the abstract, and correctly ties its acceptability to the same `:AdminServicesManage`
gate that already governs the identical oracle via `list_all/1` on the existing admin
surface — it does not claim the oracle is safe in general, only safe for the actor
class that already holds equivalent visibility another way.

**Overall: PASS.** The chosen policy (permanent rejection, §1) fully eliminates the
INV-9 pack-install surface, introduces no INV-1 violation because it introduces no
code, and the INV-5 reasoning is soundly scoped to a hypothetical with no bearing on
shipped behavior. The one residual item worth naming for a future requirement — the
existing `POST /service-catalog` route's absence of any dispatch-shaped URL
validation at registration time — is real but pre-existing, unchanged, and currently
inert (per point 3 above), and this record's silence on it is the correct scope
discipline rather than an omission.

*(SECURITY-REVIEWER, 2026-09-12, REQ-321)*

## REVIEWER sign-off

**Verdict: PASS (2026-09-12, `REVIEWER`, REQ-321).**

**1. Decision-record consistency — `0022`.** Read `0022` in full. Its bucket
rule (rule 1: "a bucket-B requirement may not name exams... not in its title,
not in its acceptance criteria, not in the module it produces") applies here
because REQ-321's own `description` declares bucket B. Grepped this record for
`exam`/`bilimbaga`/`question bank`/`certificate` (case-insensitive): zero
matches. The record cites S10 "gap 4" and "gap 5" by number only, exactly as
`0022`'s rule 1 requires, and never names what those gaps are for. No
re-decision of `0022` found: this record does not touch the vertical/fork/
federate question `0022` §"Decision" settled, and does not redraw the
bucket table — it only produces the bucket-B artefact `0022` already
authorizes CODE-DESIGNER/REQ-ANALYST to produce for that bucket.

**2. Decision-record consistency — `0026`.** Read `0026` in full, independently
of this record's own citations of it. `0026` §4 established that
`service_catalog_entries`'s existing `check_unsupported_sections/1` reject
clause is the PRECEDENT for a "reject-until-supported, never silently drop"
pattern, which `0026` then reused for `entity_definitions`. `0027` does not
re-derive or restate that pattern's general shape as if inventing it — it
correctly treats `0026` as having already settled the pattern, and confirms
only that `service_catalog_entries`'s own clause (the original of the pair)
now stays in place *permanently* rather than becoming a second "reject until a
future requirement lifts it" placeholder. That is an extension consistent with
`0026`, not a re-decision of it: `0026` never claimed `service_catalog_entries`
would eventually be supported, and `0027` does not contradict `0026`'s own
`entity_definitions` answers (schema versioning, `:inactive`-only install
semantics, whole-transaction collision abort) anywhere in `0027`'s text — I
checked `0027` §§1-7 against `0026` §§1-5 point by point and found no
overlapping claim stated differently. `0027`'s §2 tenant-scoping-derivation
language (`owner_tenant_id` from `TenantProvisioning.tenant_id_for_schema_name(prefix(opts))`,
never from pack content) is the same mechanism `0026` §5 already established
for `entity_definitions`, correctly cited as precedent (0027 §2, "This mirrors
every other `install/3` write's tenant-scoping discipline") rather than
re-argued from scratch. `0027`'s §1 also correctly preserves `0026`'s own
`NOTE (ELIXIR-DEV, REQ-305)` finding that `entity_definitions` is NOT gated by
`check_unsupported_sections/1`'s single-key clause — re-read that comment
directly in `solution_pack.ex` (lines 874-885) and confirmed `0027` states the
same conclusion (§ "Re-verification performed" and the moduledoc-comment
citation) without altering it.

**3. Consistency with `solution_pack.ex`'s all-or-nothing stance.** Read the
moduledoc's "Install is ALL-OR-NOTHING" section directly (lines 88-103):
`Letflow.Definitions.create/2` "has no upsert, no skip and no idempotent
branch," and a duplicate maps to an error the route turns into a 409 aborting
the whole install. `0027` §5(a)/(b) describes the rejected design's
hypothetical `create_packed_service_catalog_entries/3` as following the
identical shape — `register/1`'s `{:error, :duplicate_service_id}` flowing
into `{:halt, error}` inside the reduce, then `run_install/5`'s single shared
`with`/`else -> Repo.rollback(reason)` clause, "no new rollback path." This
matches the existing all-or-nothing precedent exactly (the same treatment
`0026` §2 specifies for `entity_definitions`'s own collision case) and
proposes no divergent partial-success or per-section rollback behavior.
Since §1's actual answer is NOT PERMITTED, none of this runs today — the
consistency question is only about whether the *hypothetical* mechanism, if
ever built, would fit the existing transactional discipline, and it does.

**4. No executable implementation code.** Grepped the full document for
`def `, `case `, `with `, and pipeline-shaped fragments. Two literal
two-clause quotations appear (Decision §1, lines 173-174, and inside
SECURITY-REVIEWER's own section, line 497) — both are the verbatim shipped
`check_unsupported_sections/1` clauses (`solution_pack.ex` lines 886-887),
quoted as evidence during re-verification, not proposed as new code; I
diffed them against the actual file and they match character-for-character.
Every other occurrence of `def`/`with`/`Repo.`/`Enum.`-shaped text in the
document (checked line by line) is prose naming an existing function
(`register/1`, `run_install/5`, `Repo.transaction/1`) or describing the
rejected design's hypothetical mechanism in sentence form — no function
definition, no `case`/`with` block, and no pipeline is written as executable
Elixir anywhere in this record. This matches CODE-DESIGN-VALIDATOR's
characterization; I did not take it on trust.

**5. Structural consistency with `0026`'s own shape.** `0027`'s section order
(`## Question` / `## Decision` / `## Reasoning` / `## Consequences` /
`## What this record does not decide` / `## SECURITY-REVIEWER sign-off` /
`## REVIEWER sign-off`) matches `0026`'s exactly, with the same additive
`## Re-verification performed` section placed before `## Question` (0026 uses
an analogous `## Independence...`/`## Re-verification performed` pairing in
the same position). Nothing in CODE-DESIGNER's numbered §§1-7 or in
SECURITY-REVIEWER's INV-9/INV-1/INV-5 sections contradicts the rest of the
document: SECURITY-REVIEWER's residual-risk note (the existing
`POST /service-catalog` route's own missing dispatch-time URL validation) is
explicitly scoped as pre-existing and out of this record's fence, which
agrees with this record's own "Consequences" and "What this record does not
decide" sections rather than reopening either.

**No defects found. This gate PASSes.** Ready for ORCH to commit/push/merge.
