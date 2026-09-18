# REQ-365 — Design: platform-scope help-content authoring path

Stage S7. Owner: `CODE-DESIGNER`. Status: design only — no implementation code in this
document (signatures / type shapes / literal content text only, per
`.claude/agents/code-designer.md`).

## 0. Premises verified against the tree (2026-09-18)

- `lib/letflow/design/req363-help-content-data-model.md` (read in full) §3 already
  decided **where** platform-scope help content lives: a separate table,
  `platform_help_content`, in the `public` schema (no `prefix()`, no `if prefix() do`
  guard, not registered in `Letflow.TenantProvisioning.tenant_scoped_migrations/0`) —
  the same "ordinary, ungoverned-by-tenant-provisioning migration" shape `users`/
  `tenants` already use. That table does **not** exist yet: confirmed by grep, no
  `platform_help_content` migration or schema module is present anywhere in the tree.
  Only `lib/letflow/help.ex` + `lib/letflow/help/help_content.ex` (REQ-364, tenant-scoped)
  exist so far.
- `priv/repo/migrations/20260816000001_create_tenants.exs` and
  `20260816000004_create_users.exs` (read in full) are the concrete "ordinary migration"
  precedent §3 points at: `create table(:name, primary_key: false)` with **no**
  `prefix:` option anywhere, no `if prefix() do` guard, plain `Ecto.Migration` — this
  design's `platform_help_content` migration (§1 below) copies that exact shape, not
  `help_content`'s tenant-scoped one.
- `lib/letflow/help.ex` and `lib/letflow/help/help_content.ex` (both read in full) are
  REQ-364's already-built, already-shipped tenant-scoped write path. This design reuses
  their **exact calling convention** (function names, arity shape minus the
  prefix/tenant concept, error-tuple vocabulary, "never caller-supplied"
  `status`/`confirmed_at`/`confirmed_for_definition_version` rule, `:draft`⇄`:live`
  transition semantics) rather than inventing a different one, per the task's explicit
  instruction.
- `lib/letflow/help/help_content.ex`'s moduledoc (read in full) documents the **current,
  amended (2026-09-17) sanitization mechanism**: `EarmarkParser.as_ast/2` parses `:title`
  and `:body` once each into a CommonMark AST, and `validate_markdown_safety/2` (private,
  today) walks that AST for raw-HTML nodes (`meta[:verbatim] == true` or
  `meta[:comment] == true`) and for `"a"`/`"img"` destination nodes whose (numeric-entity-
  decoded) scheme is `javascript`/`data`/`vbscript`, plus a plain-text fallback scan
  (`@raw_html_tag_pattern`) for raw HTML the parser leaves unstructured when inline with
  surrounding text. This is the **only** sanitization mechanism in the codebase — §5
  below reuses it verbatim via extraction, not a second implementation.
- **File-name correction on this design's own handoff:** `context.artifacts_in` names
  `docs/migration/decisions/0036-help-content-markdown-sanitization.md`. No file by that
  exact name exists. The real, landed decision record for this mechanism is
  `docs/migration/decisions/0036-earmark-parser-markdown-sanitization-dependency.md`
  (confirmed present, read in full) — same decision number, corrected filename. Cited by
  its real name throughout this document; flagged here per this project's own "verify a
  checkable claim before building on it" discipline (`docs/anti-patterns.md`,
  "Inheriting a claim from a record instead of re-deriving it from the source").
- `docs/requirements.yaml`'s REQ-358/359/360 chain (read via
  `lib/letflow/design/req358-uat-scope-branching-env.md`,
  `lib/letflow/design/req359-ba-role.md`,
  `lib/letflow/design/req360-platform-login-routing-uat-scenario.md`, all read in full)
  is the platform-vs-tenant / agent-authored-not-human-form precedent this requirement
  applies, per its own text — REQ-360 in particular is the worked "platform content
  authored by an agent, permanent corpus" example this requirement's authoring path must
  match in spirit (a record written by CODE-DESIGNER/ELIXIR-DEV, not a UI form).
- No dedicated frontend route/component exists for "the login screen" — `web/src/auth/
  ProtectedRoute.tsx` (read in full) redirects an unauthenticated session straight to a
  Keycloak-hosted login page (`docs/migration/decisions/0035-frontend-login-delegated-to-
  keycloak.md`, read in full: "No in-app token-paste login screen exists"), and
  `req360`'s own design (§0, read in full) confirms there is also no distinct
  post-login landing route today — every authenticated role lands on `/` →
  `TenantDashboardPage`, with role differences expressed only in `AppShell.tsx`'s
  nav-item filtering (`PLATFORM_ADMIN` sees additional `/admin/*` links). There is
  therefore no existing `screen_id`-shaped identifier anywhere in the tree for this
  screen to reuse — §4 below picks one explicitly, reasoned from the requirement text's
  own repeated naming ("the login-routing screen") and from REQ-360's already-shipped
  UAT scenario id (`platform-login-routing-by-role`), not guessed.

---

## 1. The `platform_help_content` table

Lives once, in the `public`/default Postgres schema — **not** tenant-scoped, no
`prefix()` concept at all (req363 design §3). Reuses `help_content`'s column shape
(req363 §1.1) verbatim, minus nothing, per req363 §3's own instruction ("identical field
list, different table/schema, no cross-referencing between the two tables").

### 1.1 Columns

| Column | Type | Null? | Default | Notes |
|---|---|---|---|---|
| `id` | `:binary_id` | not null | autogenerate | primary key, `primary_key: false` + explicit `add :id, :binary_id, primary_key: true`, matching `help_content`/`users`/`tenants` |
| `screen_id` | `:string` | not null | — | same open-ended-string convention as `help_content.screen_id` (req363 §1.1) — length-bounded (max 255) |
| `process_definition_id` | `:binary_id` | nullable | `NULL` | column exists for shape-parity with `help_content` (req363 §3), but see §3.3 below: the platform write path in this design **rejects any non-nil value** for this column — req363's own **OQ-2** ("does a platform-scope process definition concept exist at all?") is still unresolved, and this design does not resolve it either, per this run's own instruction not to silently guess. Keeping the column nullable/present but unwritable-for-now is the concrete way this design avoids both silently inventing a resolution and silently dropping the column req363 already specified |
| `title` | `:string` | not null | — | length-bounded (max 255), same as `help_content.title` |
| `body` | `:text` | not null | — | markdown source, same allowed subset and same sanitization rule as `help_content.body` (§5 below) |
| `status` | `:string` (`Ecto.Enum` `:draft` \| `:live`) | not null | `"draft"` | identical two-state lifecycle to `help_content.status` (req363 §2) — no third state invented for the platform path |
| `confirmed_at` | `:utc_datetime_usec` | nullable | `NULL` | identical semantics to `help_content.confirmed_at` (req363 §4.1) |
| `confirmed_for_definition_version` | `:string` | nullable | `NULL` | identical semantics to `help_content.confirmed_for_definition_version` (req363 §4.2) — since §3.3 below never lets `process_definition_id` be set on this table today, this column is always `NULL` in practice for now, but the column stays present for shape-parity and so a future OQ-2 resolution needs no migration |
| `media` | `:map` (jsonb array) | not null | `[]` | same reservation-only column as `help_content.media` (req363 §6) |
| `created_by` | `:binary_id` | not null | — | bare UUID, no FK — see §3.4 for the agent-pipeline sentinel value this design specifies for the FIRST REAL CONTENT row |
| `created_at` / `updated_at` | `:utc_datetime_usec` | not null | Ecto.Schema autogeneration | `timestamps(inserted_at: :created_at, type: :utc_datetime_usec)`, matching `help_content` |

### 1.2 Constraints and indexes

Same three-index shape as `help_content` (req363 §1.2), **with no `prefix:` option
anywhere** — this table has exactly one physical copy, not one per tenant:

- **Primary key**: `id`.
- **`status` enum constraint**: `Ecto.Enum` on the schema side only, no DB-level CHECK —
  same convention as `help_content.status`.
- **`idx_platform_help_content_screen`**: index on `(screen_id)` — no `prefix:` —
  primary lookup pattern ("give me the platform help content for this screen").
- **`idx_platform_help_content_process_definition`**: partial index on
  `(process_definition_id)` `WHERE process_definition_id IS NOT NULL` — no `prefix:` —
  kept for shape-parity/future-readiness with `help_content`'s equivalent index even
  though §3.3 means it is inert today (no row will ever have a non-null value here until
  OQ-2 is resolved).
- **`idx_platform_help_content_status`**: index on `(status)` — no `prefix:` — serves
  "list only `live` content" queries, same as `help_content`.
- No uniqueness constraint on `(screen_id, process_definition_id)` — same reasoning as
  req363's own **OQ-1** (not stated by any requirement text, not invented here either).

### 1.3 Migration shape (design-level, no implementation code)

New file, e.g. `priv/repo/migrations/<timestamp>_create_platform_help_content.exs`,
module `Letflow.Repo.Migrations.CreatePlatformHelpContent`:

- **NOT tenant-scoped**: no `if prefix() do` guard anywhere in the migration body, no
  `prefix: prefix()` on the `create table(...)` call or on any of its three indexes —
  this is the single load-bearing difference from `20260917000001_create_help_content.exs`
  (which is guarded and registered), and matches `20260816000001_create_tenants.exs` /
  `20260816000004_create_users.exs`'s unguarded, unregistered shape exactly (§0).
- **NOT registered in `Letflow.TenantProvisioning.tenant_scoped_migrations/0`** — that
  list is exclusively for migrations that must be replayed once per newly-provisioned
  tenant schema; `platform_help_content` is created exactly once, ever, by the normal
  `mix ecto.migrate` run against the default/public schema, the same way `users` and
  `tenants` already are. Registering it there would be a bug (replaying `CREATE TABLE
  platform_help_content` once per tenant provisioning, in the tenant's own schema, which
  is precisely the "conflation" req363 §3 forbids).
- `create table(:platform_help_content, primary_key: false)` (no `prefix:` argument at
  all — the call takes only the options `help_content`'s migration needs plus
  `prefix:`; this migration omits that option entirely, it does not pass `prefix: nil`
  or similar) with the column list from §1.1, same types/nulls/defaults.
- Three `create index(:platform_help_content, [...], name: :idx_platform_help_content_*,
  ...)` calls, same shape as req363 §1.2's three indexes minus `prefix:` (and the
  process-definition index keeps its `where: "process_definition_id IS NOT NULL"`
  clause).
- No foreign keys — same bare-UUID, no-`references/2` convention as `help_content`
  (req363 §0/§1.1) and `users`/`tenants` (§0 above): `created_by` has no FK for the same
  reason `help_content.created_by` has none (cross-schema/cross-migration-set FK is not
  this codebase's convention for this shape), and `process_definition_id` has no FK for
  the additional reason that, unlike `help_content`, there is today no tenant schema this
  platform-level table could even meaningfully FK into (OQ-2).
- No DB-level `DEFAULT NOW()`/`DEFAULT gen_random_uuid()` — Ecto.Schema autogeneration
  handles both, same as every other table in this codebase.

---

## 2. The `Letflow.Help.PlatformHelpContent` Ecto schema

New file, `lib/letflow/help/platform_help_content.ex`. Same field list as
`Letflow.Help.HelpContent` (req363 §1.3), backed by the `platform_help_content` table:

```
defmodule Letflow.Help.PlatformHelpContent do
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "platform_help_content" do
    field(:screen_id, :string)
    field(:process_definition_id, Ecto.UUID)
    field(:title, :string)
    field(:body, :string)
    field(:status, Ecto.Enum, values: [:draft, :live], default: :draft)
    field(:confirmed_at, :utc_datetime_usec)
    field(:confirmed_for_definition_version, :string)
    field(:media, {:array, :map}, default: [])
    field(:created_by, Ecto.UUID)
    timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
  @type status :: :draft | :live
end
```

**No `@schema_prefix`** — not for the same reason `HelpContent` omits it (many
per-tenant Postgres schemas, one `prefix:` passed per call), but for the *opposite*
reason: `platform_help_content` lives in exactly **one** schema, the connection's
default (`public`), so no caller ever needs to pass a `prefix:` option for this schema at
all — every `Repo` call against this schema in §3 is a plain call with no `prefix:`
keyword, not a call that happens to pass `prefix: "public"` explicitly. This is a
distinct rationale from `HelpContent`'s, stated explicitly per this design's own
convention of not leaving a "why no `@schema_prefix`" question unanswered.

### 2.1 Changesets — same two-changeset shape as `HelpContent`, reusing the shared validator (§5)

```
@spec create_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
def create_changeset(platform_help_content, attrs)

@spec update_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
def update_changeset(platform_help_content, attrs)
```

- `create_changeset/2`: casts `[:screen_id, :process_definition_id, :title, :body,
  :created_by]`, `validate_required([:screen_id, :title, :body, :created_by])` — same
  cast/required list as `HelpContent.create_changeset/2`.
- `update_changeset/2`: casts `[:screen_id, :process_definition_id, :title, :body]`,
  `validate_required([:screen_id, :title, :body])` — same as
  `HelpContent.update_changeset/2`. Neither changeset ever casts `:status`,
  `:confirmed_at`, or `:confirmed_for_definition_version` — identical "never
  caller-supplied" rule as `HelpContent` (req363 §4.1/§4.2, `Letflow.Help`'s own
  moduledoc).
- Both call `validate_length(:screen_id, min: 1, max: 255)`,
  `validate_length(:title, min: 1, max: 255)`, and the **shared** markdown-safety
  validator from §5 against `:title` and `:body` — not a re-implementation.

---

## 3. The `Letflow.Help.Platform` context module — write path

### 3.1 Decision: a second context module, not a platform-scoped variant of each `Letflow.Help` function

**Decision: `Letflow.Help.Platform` is a separate module**, mirroring `Letflow.Help`'s
public surface (same function *names*, same conceptual shape, same error-atom
vocabulary) but with `opts :: [prefix: String.t()]` dropped from every signature, not
folded into `Letflow.Help` as an extra clause/branch. Reasoning, stated explicitly per
this run's own instruction not to leave this as an open question:

- Every one of `Letflow.Help`'s six public functions threads `opts` through
  `Keyword.fetch!(opts, :prefix)` and then `TenantProvisioning.tenant_id_for_schema_name/1`
  as its *first* action, and every one of its error unions includes
  `{:error, :invalid_prefix}`. A platform-scope call has no prefix to fetch and no schema
  name to validate — accepting an `opts` parameter that is either ignored (misleading:
  the signature would imply a prefix option does something) or required-but-meaningless
  (forcing every caller to pass `[]` or a dummy value with no semantic content) is worse
  than a signature that accurately reflects "this table is not tenant-scoped, there is no
  prefix concept here at all."
- `Letflow.Help`'s existing `@type opts`, `@type create_error`, and every function head
  are already written and shipped (REQ-364) against the tenant-scoped shape. Branching
  each of them internally on "is this a platform call" would mean every function grows a
  second code path with a different precondition-check sequence (`fetch/2` looking up
  `HelpContent` vs `PlatformHelpContent`, `resolve_confirmed_version/2` needing a `prefix`
  for one branch and none for the other) inside what is otherwise one small, currently
  cleanly-scoped module — this is the same "one module branching on a runtime flag
  instead of two modules for two distinct persistence shapes" question req363 §3 already
  answered at the *schema* level (`HelpContent` vs a new `PlatformHelpContent`, not one
  schema with a `scope` column) applied one level up. This codebase's own per-domain-
  context convention (cited in `Letflow.Help`'s own moduledoc — one context module per
  schema-backed domain, e.g. `Letflow.Identity`, `Letflow.TenantProvisioning`) supports a
  second module for a second, differently-shaped persistence unit rather than widening
  one module's responsibility.
- A future caller (REQ-ANALYST/the agent pipeline, or a later admin-facing route) that
  needs to know "is this the tenant path or the platform path" gets that answer from
  **which module it calls**, not from inspecting an `opts` value at every call site — a
  clearer, statically-visible distinction than a runtime branch would give.

`Letflow.Help.Platform`'s moduledoc must state this reasoning (or reference this design
section) so a future reader does not "simplify" the two modules back into one without
re-deriving why they were split, mirroring `Letflow.Help.HelpContent`'s own moduledoc
practice of citing its governing design section inline.

### 3.2 Function signatures

Exactly the six actions `Letflow.Help` exposes (create/update/publish/reconfirm/
withdraw/read), same names, same error-tuple *shape* per function, `opts` dropped:

```
@type create_error ::
        {:error, :status_not_accepted}
        | {:error, :confirmed_at_not_accepted}
        | {:error, :confirmed_for_definition_version_not_accepted}
        | {:error, :process_definition_id_not_supported}
        | {:error, Ecto.Changeset.t()}

@doc "Creates a new platform-scope help content draft. Same reject-caller-supplied-
      status/confirmed_at/confirmed_for_definition_version rule as
      Letflow.Help.create_draft/2. See §3.3 for :process_definition_id_not_supported."
@spec create_draft(attrs :: map()) :: {:ok, PlatformHelpContent.t()} | create_error()
def create_draft(attrs)

@doc "Updates an existing platform draft's mutable fields (:screen_id, :title, :body —
      NOT :process_definition_id, see §3.3). {:error, :not_a_draft} if currently :live."
@spec update_draft(id :: Ecto.UUID.t(), attrs :: map()) ::
        {:ok, PlatformHelpContent.t()}
        | {:error, :not_found}
        | {:error, :not_a_draft}
        | {:error, :process_definition_id_not_supported}
        | {:error, Ecto.Changeset.t()}
def update_draft(id, attrs)

@doc "Publishes a draft: :draft -> :live, confirmed_at from the real clock.
      confirmed_for_definition_version is always set to nil (see §3.3 — no
      process_definition_id is ever set on a platform row today, so there is nothing to
      resolve a version against)."
@spec publish(id :: Ecto.UUID.t()) ::
        {:ok, PlatformHelpContent.t()} | {:error, :not_found} | {:error, :not_a_draft}
def publish(id)

@doc "Re-confirms an already-:live row: bumps confirmed_at (real clock). :title/:body
      untouched, same contract as Letflow.Help.reconfirm/2."
@spec reconfirm(id :: Ecto.UUID.t()) ::
        {:ok, PlatformHelpContent.t()} | {:error, :not_found} | {:error, :not_live}
def reconfirm(id)

@doc "Withdraws an already-:live row back to :draft. Same live->draft legality as design
      req363 §2 / Letflow.Help.withdraw/2."
@spec withdraw(id :: Ecto.UUID.t()) ::
        {:ok, PlatformHelpContent.t()} | {:error, :not_found} | {:error, :not_live}
def withdraw(id)

@doc "Lists platform help content attached to screen_id. No opts/prefix parameter — this
      table has exactly one copy."
@spec get_by_screen(screen_id :: String.t()) :: {:ok, [PlatformHelpContent.t()]}
def get_by_screen(screen_id)
```

No `get_by_process_definition_id/1` is specified for the platform module: since §3.3
never lets a platform row carry a non-nil `process_definition_id`, such a query would
always return `[]` today — including it would be dead code with nothing to exercise it
until OQ-2 is resolved. Flagged here rather than silently omitted without explanation.

No `{:error, :invalid_prefix}` anywhere in this module's error unions — there is no
prefix concept to be invalid (§3.1).

### 3.3 `process_definition_id` — the concrete resolution of req363's OQ-2 for this write path

req363 §3 left OQ-2 ("does a platform-scope process definition concept exist at all?")
explicitly open, and this design does not resolve the underlying product question
either — that would be silently re-deciding something req363 deliberately deferred.
What this design **does** decide, concretely, so the write path is buildable without
guessing: `create_draft/1` and `update_draft/2` both **reject** any `attrs` map that
carries a non-nil `:process_definition_id` (or `"process_definition_id"`) key with
`{:error, :process_definition_id_not_supported}`, checked before any other validation —
mirroring `Letflow.Help`'s own `reject_key/4` pattern (used there for
`:status`/`:confirmed_at`/`:confirmed_for_definition_version`) applied to this field
instead. Rationale: there is no single tenant schema a platform-level row could validate
a `process_definition_id` against (`process_definitions` rows live one-per-tenant-schema,
and a platform row by definition belongs to no one tenant) — `Letflow.Help`'s own
`validate_process_definition_ref/2` mechanism has no meaningful platform-scope
equivalent to call. Rejecting outright (rather than accepting-and-not-validating, which
would silently create an unenforced, possibly-dangling reference) keeps the column's
current state honest: present in the schema for future parity, never actually
populated until a future requirement resolves OQ-2 and this design's rejection is
lifted. `publish/1`/`reconfirm/1` therefore always resolve `confirmed_for_definition_version`
to `nil` unconditionally — there is no `resolve_confirmed_version/2`-shaped branch to
write for this module, since the `process_definition_id: nil` case is the *only* case.

### 3.4 `created_by` for agent-authored platform content

Every `help_content`/`platform_help_content` row requires a non-null `created_by`
(bare UUID, no FK — req363 §0/§1.1). Tenant-scoped content (REQ-364) is authored by a
real signed-in tenant user, so `created_by` is that user's real id. Platform-scope
content is explicitly **not** authored through any UI (this requirement's own scope
note: "Explicitly NOT a new UI — platform help authoring is agent-pipeline-driven") —
there is no signed-in human user backing a platform-content write, so `created_by` needs
a value that is not a fabricated/guessed real user id.

**Decision:** this design reserves the well-known nil-UUID,
`"00000000-0000-0000-0000-000000000000"`, as the documented sentinel for "this row was
authored by the agent pipeline, not attributable to an individual signed-in user."
`Letflow.Help.Platform`'s moduledoc must name this constant explicitly (e.g. as a
`@agent_pipeline_author_id` module attribute referenced from this design section) rather
than leaving each future caller to invent its own value ad hoc — the goal is one
consistent, greppable sentinel across every platform-authored row, not a different
placeholder per call site. This is a new convention (no prior platform-authored,
attributable-content row exists in this codebase before this requirement) — flagged for
REVIEWER to confirm rather than treated as self-evidently settled, since "which sentinel
value" is a real choice with no existing precedent to defer to.

---

## 4. FIRST REAL CONTENT — the login-routing screen's help entry

### 4.1 `screen_id`: `"login-routing"`

No `screen_id`-shaped registry exists anywhere in this codebase today (§0) — this design
picks the value REQ-366's future read path will query, reasoned explicitly rather than
guessed:

- The requirement text itself (REQ-365's own description, quoted in this design's
  handoff) refers to this screen exclusively as **"the login-routing screen"**, twice,
  and explicitly ties it to "the same screen REQ-360's UAT scenario covers."
- REQ-360's own already-shipped, permanent UAT scenario file is
  `test/fixtures/uat/scenarios/platform/platform-login-routing-by-role.yaml`, scenario
  `id: platform-login-routing-by-role` (`lib/letflow/design/req360-platform-login-
  routing-uat-scenario.md`, read in full, §0). That id already carries a `platform-`
  scope prefix and a `-by-role` behavior-detail suffix specific to the *UAT scenario's
  own* naming convention (matching `test/fixtures/uat/scenarios/platform/`'s directory
  convention for scenario filenames) — neither belongs on a `screen_id`, which is a
  different namespace (req363 §1.1: "an open-ended string, not an enum... not this
  table's concern to enumerate" — screen identifiers, not scenario identifiers).
- Stripping the scenario-specific `platform-`/`-by-role` decoration and keeping the
  substantive, requirement-text-native name yields `"login-routing"` — the same term
  REQ-365's own description already uses as the screen's name, kept short and
  route-shaped like `help_content`'s own worked examples in req363 §1.1
  (`"process-designer"`, `"instance-detail"`).
- This is a platform-scope entry specifically because the login-routing *behavior*
  (Keycloak-hosted redirect, role-based landing) is not owned by any one tenant — it is
  shared infrastructure every tenant's users go through identically, matching REQ-358's
  platform-vs-tenant split criterion (`lib/letflow/design/req358-uat-scope-branching-
  env.md`, read in full) and REQ-360's own worked platform example.

### 4.2 The literal content to publish

**Title** (≤255 chars): `Signing in and where you land`

**Body** (markdown, within §5's allowed subset — headings, paragraphs, lists, bold —
no raw HTML, no disallowed-scheme links; verified against §5's rules by inspection: no
`<`/`>` characters, no `[text](url)` links at all in this draft, so no scheme to check):

```
# Signing in

When you open Letflow, you're taken to a secure sign-in page to enter your username and
password. This page is provided by Letflow's identity provider, not by Letflow itself —
you may notice the page looks a little different from the rest of the app.

After you sign in successfully, you're brought straight back into Letflow automatically.
There's nothing else you need to do — no separate "continue" step, no extra click.

## Where you land after signing in

Once you're signed in, you'll see your workspace dashboard, showing your processes and
instances.

- If you're a **regular user or tenant administrator**, this dashboard is scoped to your
  own organization.
- If you're a **platform administrator**, you land on the same kind of starting page,
  but you'll also see extra menu items — like **Tenants** — that only platform
  administrators can see and use.

## If something goes wrong

If your sign-in doesn't succeed, or your session has expired, you're sent back to the
sign-in page automatically so you can try again. You never need to manually type in a
web address or hunt for a login link — Letflow always routes you to the right place on
its own.
```

This is the exact text a later implementation step (ELIXIR-DEV, per this task's own
"a later step will publish" framing) calls `Letflow.Help.Platform.create_draft/1` and
then `Letflow.Help.Platform.publish/1` with — `attrs = %{screen_id: "login-routing",
title: "Signing in and where you land", body: <the markdown above>, created_by:
"00000000-0000-0000-0000-000000000000"}` (§3.4's sentinel). `process_definition_id` is
omitted from `attrs` entirely (nil by default), consistent with §3.3 — this content is
not scoped to any one process definition.

---

## 5. Write-path sanitization — reused, not reinvented

**No second sanitizer.** The task is explicit this must reuse req363/364's mechanism,
not build a parallel one. Concretely:

- **Extraction, not duplication.** `lib/letflow/help/help_content.ex`'s private
  `validate_markdown_safety/2` and everything it calls (`walk/1`, `walk_node/1`,
  `walk_text/1`, `flatten_plain_text/1`, `raw_html_node?/2`, `destination_violation/2`,
  `scheme_violation_for/2`, `unsafe_scheme?/1`, `scheme_letters/1`,
  `decode_numeric_entities/1`, `decode_entity_code/1`, `codepoint_to_binary/2`,
  `safe_codepoint/1`, plus `@raw_html_tag_pattern`, `@disallowed_url_schemes`,
  `@numeric_entity_pattern`) move to a new shared module, **`Letflow.Help.MarkdownSafety`**,
  exposing one public function:

  ```
  @spec validate(changeset :: Ecto.Changeset.t(), field :: atom()) :: Ecto.Changeset.t()
  def validate(changeset, field)
  ```

  Same behavior, same two user-facing error messages (`"must not contain raw HTML
  tags"`, `"must not contain javascript:/data:/vbscript: link or image URLs"`), same
  `add_error/3`-never-a-raised-exception contract, same `{:ok, ast, _}` /
  `{:error, ast, _}` both-branches-walked handling (help_content.ex moduledoc's "Round 3
  fixes" item 3, INV-8) — this extraction changes *where* the code lives, not what it
  does or how it's tested.
- **Both schemas call the same function.** `Letflow.Help.HelpContent.validate_common/1`
  and `Letflow.Help.PlatformHelpContent`'s equivalent private helper (§2.1) both call
  `Letflow.Help.MarkdownSafety.validate(changeset, :title)` and
  `Letflow.Help.MarkdownSafety.validate(changeset, :body)` — one implementation, two
  call sites, exactly mirroring how §3's `platform_help_content` table reuses
  `help_content`'s column shape rather than re-deriving it.
- **No dependency change.** `earmark_parser` is already a `mix.exs` dependency
  (decision 0036, REQ-364) — this design adds no new library, just relocates existing,
  already-REVIEWER-approved logic into a shared module. No new REVIEWER dependency
  sign-off is needed for this extraction (unlike req363 §5.4.3's original addition).
- This satisfies this requirement's own acceptance criterion ("no separate, weaker
  validation for the platform path") structurally: there is only one sanitization
  code path in the tree after this change, called from two schemas, not two
  independently-maintained implementations that could drift apart.

---

## 6. Cross-module dependencies

- `Letflow.Help.Platform` depends on `Letflow.Help.PlatformHelpContent` (its schema) and
  `Letflow.Repo` (plain calls, no `prefix:` option) — no dependency on
  `Letflow.TenantProvisioning` (no prefix/tenant concept applies).
- `Letflow.Help.PlatformHelpContent` depends on `Letflow.Help.MarkdownSafety` (§5).
- `Letflow.Help.HelpContent` (existing) is modified to depend on
  `Letflow.Help.MarkdownSafety` instead of housing the validator itself (§5) — its
  public changeset functions/signatures/error contract are unchanged; only the
  validator's *location* moves.
- `Letflow.Help.Platform` has **no** dependency on `Letflow.Definitions.ProcessDefinition`
  (unlike `Letflow.Help`), since §3.3 means no platform row ever needs to resolve a
  process definition's version.
- No change to `Letflow.Help` (tenant-scoped, REQ-364)'s own public function signatures.

---

## 7. Acceptance-criteria mapping

| Acceptance criterion (verbatim from this run's handoff) | Design element |
|---|---|
| a platform-scope help-content write path exists, reusing REQ-364's context-module shape against wherever REQ-363's design placed platform rows, not a parallel schema/mechanism | §1 (table, reusing req363 §3's placement exactly), §2 (schema, same field list), §3.1–§3.2 (`Letflow.Help.Platform`, same function names/error-tuple shape as `Letflow.Help`, reasoned decision for a second module over a branching one) |
| real help content for the login-routing screen is authored and published through this path, in plain end-user language — the actual published text is quoted in this requirement's close-out | §4.1 (`screen_id` chosen and reasoned: `"login-routing"`), §4.2 (literal title + markdown body, plain end-user language, no SHALL-statement prose) |
| the write path enforces the same sanitization rule REQ-363/364 established for tenant-scoped content — no separate, weaker validation for the platform path | §5 (extraction into `Letflow.Help.MarkdownSafety`, both schemas call the one implementation, no new dependency, no second mechanism) |

---

## 8. Open questions

- **OQ-1 (carried from req363, unchanged)** — no uniqueness constraint on
  `(screen_id, process_definition_id)` for either table. Not resolved here either;
  req363's own reasoning stands.
- **OQ-2 (carried from req363, narrowed but not resolved)** — whether a platform-scope
  "process definition" concept exists at all is still open. This design's own
  contribution (§3.3) is narrower than resolving it: it specifies that, *until* OQ-2 is
  resolved, the platform write path rejects any attempt to set
  `process_definition_id` at all, rather than silently accepting an unvalidated
  reference or guessing a validation scheme. A future requirement that resolves OQ-2
  must revisit `Letflow.Help.Platform.create_draft/1`/`update_draft/2` to lift this
  rejection and add whatever validation OQ-2's resolution implies.
- **OQ-5 (new)** — `created_by`'s agent-pipeline sentinel value (§3.4,
  `"00000000-0000-0000-0000-000000000000"`) is a new convention with no prior precedent
  in this codebase (every existing `created_by`-bearing row to date is authored by a
  real signed-in user). Flagged for REVIEWER sign-off on the specific value chosen — an
  alternative (e.g. a real, provisioned "system" user row in `users`) was not chosen
  here because REQ-364/`Letflow.Help`'s own convention never required `created_by` to
  reference an existing `users` row (no FK, req363 §0), so inventing a real user row
  purely to satisfy this column would be adding machinery this design has no acceptance
  criterion asking for; the sentinel is the smaller, already-consistent-with-existing-
  no-FK-convention choice. Named explicitly rather than picked silently, per this
  project's own "don't silently resolve an open question by guessing" instruction.
- **OQ-6 (new)** — this design specifies `Letflow.Help.MarkdownSafety` as an extraction
  target but does not itself rewrite `help_content.ex`'s current inline implementation
  file-by-file (that is ELIXIR-DEV's implementation job, per Step 2a) — flagged so
  ELIXIR-DEV does not treat "the validator already exists in help_content.ex" as
  sufficient without actually performing the extraction §5 specifies; a `Letflow.Help.
  Platform` implementation that merely copy-pastes `validate_markdown_safety/2` into
  `platform_help_content.ex` would violate this requirement's own "reuse... do not
  reinvent a second sanitizer" acceptance criterion even though it would produce
  correct behavior, because it creates the two-independently-maintained-implementations
  risk this design's §5 explicitly designs against.
