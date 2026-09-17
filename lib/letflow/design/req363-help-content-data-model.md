# REQ-363 — Design: In-app help content data model

Stage S7. Owner: `CODE-DESIGNER`. Status: design only — no implementation code in this
document (signatures / type shapes / column lists only, per `.claude/agents/code-designer.md`).

**This is a fresh design, not a revision of a prior attempt.** A prior pass on this
requirement was built against an incomplete stub of the requirement text before the real,
fully-scoped REQ-363 landed via WF-01 (`docs/requirements.yaml`, read in full for this run).
That prior design is discarded; nothing here inherits from it. Source of truth for scope is
`docs/requirements.yaml`'s REQ-363 entry, read directly for this run.

---

## 0. Premises verified against the tree (2026-09-16)

- `lib/letflow/definitions/process_definition.ex` (read in full): `field(:version, :string)`
  — **`ProcessDefinition.version` is `:string`, not an integer.** The migration
  (`priv/repo/migrations/20260816193001_create_process_definitions.exs`) confirms this at
  the DB layer too: `add :version, :string, null: false`. See §4 for how this resolves the
  requirement text's stated "integer" framing.
- `process_definitions` (same migration) is the tenant-scoping convention this design
  mirrors: `primary_key: false` + explicit `add :id, :binary_id, primary_key: true`,
  `create table(..., prefix: prefix())` guarded by `if prefix() do`, every index built with
  `prefix: prefix()`, `timestamps(inserted_at: :created_at, type: :utc_datetime_usec)`, no
  DB-level defaults on `id`/timestamps (Ecto.Schema autogenerates them), registered in
  `Letflow.TenantProvisioning.tenant_scoped_migrations/0`. A later migration
  (`20260820000004_drop_tenant_id_process_definitions.exs`, decision 0006 D2 / REQ-064) drops
  the table's own `tenant_id` column entirely — under Decision B the Postgres schema
  (`prefix`) **is** the tenant boundary, so a tenant-scoped table does not also carry a
  redundant `tenant_id` column today. `help_content` follows the **current** convention
  (no `tenant_id` column), not the original 2026-08-16 one.
- No FK constraints exist on `process_definitions.created_by` (bare `:binary_id`, no
  `references/2`) — `users` lives in the public/default schema while `process_definitions`
  lives in a tenant schema, so a real FK can't cross that boundary. `help_content.created_by`
  and `help_content.process_definition_id` follow the same bare-UUID, no-FK-constraint
  convention (see §1.1's constraint list for exactly which reference is enforced and how).
- `lib/letflow/design/req358-uat-scope-branching-env.md` §1.2 (read in full — REQ-358's own
  landed design) is the precedent this design's platform-vs-tenant split must be consistent
  with: platform vs. tenant is decided by an explicit field (`scope:` there), not by
  structural table location alone, and REQ-358 documents its default/back-compat reasoning
  inline rather than silently assuming. §3 below follows the same shape: an explicit `scope`
  concept, stated home for each side, no conflation.
- `lib/letflow/definitions/solution_pack.ex` and its migrations are the REQ-041 precedent
  this requirement's own `depends_on: [REQ-041]` names for the self-service/tenant-schema
  precedent — confirmed `done`, confirmed present in the tree.
- `mix.exs` `deps()` (read in full, lines 37-90): no markdown-rendering library
  (`earmark`/`md_ex`/similar) and no HTML-sanitization library (`html_sanitize_ex`/similar)
  is currently a dependency anywhere in the tree. This is load-bearing for §5's
  recommendation — there is no existing sanitizer to just "call."

---

## 1. The `help_content` table

Tenant-schema-scoped, mirroring `process_definitions`'s **current** (post-REQ-064)
convention exactly: lives in every tenant's own Postgres schema via `prefix()`, not in
`public`, and carries no `tenant_id` column of its own (the schema/prefix *is* the tenant
boundary, per Decision B — see §0).

### 1.1 Columns

| Column | Type | Null? | Default | Notes |
|---|---|---|---|---|
| `id` | `:binary_id` | not null | autogenerate | primary key, `primary_key: false` + explicit `add :id, :binary_id, primary_key: true` on the table, matching `process_definitions` |
| `screen_id` | `:string` | not null | — | route/screen identifier this help content is attached to (e.g. `"process-designer"`, `"instance-detail"`) — an open-ended string, not an enum: the set of screens is not closed and is not this table's concern to enumerate. Length-bounded (max 255, mirroring `process_definitions.name`'s bound) |
| `process_definition_id` | `:binary_id` | **nullable** | `NULL` | when non-null, scopes this help content to one specific process definition (staleness tracking, §4, applies). No DB-level FK — same bare-UUID, no-`references/2` convention as `process_definitions.created_by` (§0): the referenced row lives in the same tenant schema but Ecto/Postgres FK enforcement across two independently-migrated tables in the same tenant schema is not this codebase's existing convention for this shape (`process_definitions` itself carries no FK to anything). Application-level: the write-path context module (REQ-364) is expected to validate the referenced `process_definitions.id` exists in the same tenant schema before insert/update — that validation is REQ-364's own design, out of scope here beyond naming the expectation |
| `title` | `:string` | not null | — | length-bounded (max 255) |
| `body` | `:text` | not null | — | markdown source, constrained to the subset defined in §5; never raw HTML |
| `status` | `:string` (Ecto.Enum `:draft` \| `:live`) | not null | `"draft"` | see §2 — two states only, deliberately not `process_definitions`'s four-state model |
| `confirmed_at` | `:utc_datetime_usec` | **nullable** | `NULL` | see §4. Null means "never confirmed since creation/last edit" — a genuinely different state from "confirmed a long time ago," so this is nullable, not defaulted to insert time |
| `confirmed_for_definition_version` | `:string` | **nullable** | `NULL` | see §4 for the integer/string resolution. Only meaningful when `process_definition_id` is non-null; NULL when `process_definition_id` is NULL or when never confirmed |
| `media` | `:map` (jsonb) | not null | `[]` | **reservation only, not implemented** — see §6. Stored as a jsonb array; no element shape defined by this requirement |
| `created_by` | `:binary_id` | not null | — | bare UUID, no FK (same convention as `process_definitions.created_by`, §0) |
| `created_at` / `updated_at` | `:utc_datetime_usec` | not null | Ecto.Schema autogeneration | `timestamps(inserted_at: :created_at, type: :utc_datetime_usec)`, matching `process_definitions` exactly — no DB-level `DEFAULT NOW()` |

### 1.2 Constraints and indexes

- **Primary key**: `id`.
- **`status` enum constraint**: stored as the Postgres `:string` column with an
  `Ecto.Enum` over `[:draft, :live]` on the schema side (bare atom-list form, matching
  `process_definitions.status`'s own documented lowercase-dump convention, §0 / INV-DEF-3
  precedent) — dumps as `"draft"` / `"live"`. No DB-level CHECK constraint is added, mirroring
  `process_definitions`'s own documented choice not to duplicate enum enforcement at the DB
  layer (the write path, i.e. REQ-364's changesets, is the single source of truth for the
  allowed-value set, exactly as `process_definitions.status` already establishes for this
  codebase).
- **`idx_help_content_screen`**: index on `(screen_id)`, `prefix: prefix()` — serves the
  primary lookup pattern ("give me the help content for this screen").
- **`idx_help_content_process_definition`**: partial index on `(process_definition_id)`
  `WHERE process_definition_id IS NOT NULL`, `prefix: prefix()` — mirrors
  `process_definitions.idx_def_stage`'s partial-index-on-nullable-column convention (§0);
  serves "give me help content scoped to this process definition" and keeps the index
  compact by not indexing the common NULL case.
- **`idx_help_content_status`**: index on `(status)`, `prefix: prefix()` — mirrors
  `process_definitions.idx_def_status`; serves "list only `live` content" queries (the
  expected read path for end users, vs. `draft` for authoring UI).
- No uniqueness constraint on `(screen_id, process_definition_id)` or similar: the
  requirement does not state at-most-one-help-entry-per-screen, and REQ-364/366 may
  legitimately want multiple help entries per screen (e.g. multiple sections). Not invented
  here — flagged as **OQ-1** below if a future requirement needs it.

### 1.3 Ecto schema shape (type shapes only, no bodies)

```
defmodule Letflow.Help.HelpContent do
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "help_content" do
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

No `@schema_prefix` — same INV-DEF-7 reasoning as `ProcessDefinition`: this table lives in
many Postgres schemas, one per tenant, so every read/write passes `prefix: schema_name`
explicitly at call time. `schema_name` comes from a `Letflow.TenantProvisioning.Registration`
row, same as every other tenant-scoped schema in this codebase.

**Migration registration**: the migration creating `help_content` MUST be registered in
`Letflow.TenantProvisioning.tenant_scoped_migrations/0` and guarded with `if prefix() do`,
exactly like `process_definitions`'s own migration — a guarded-but-unregistered migration is
inert forever; a registered-but-unguarded one corrupts `public`. This is REQ-364/ELIXIR-DEV's
implementation step, named here so the design doesn't silently omit it.

---

## 2. Draft/live lifecycle — why two states, not `ProcessDefinition`'s four

`status` is `:draft | :live` only. This is a **deliberate simplification the requirement
text states explicitly and forbids silently upgrading**:

> "Two states only: `draft` and `live`. No version history, no deprecation, no archival.
> This is a deliberate simplification the user chose after being shown the fuller
> alternative — do not 'improve' this into a heavier lifecycle without a fresh user
> decision."

`ProcessDefinition.status` (`:draft | :active | :deprecated | :archived`, §0) exists as a
proven pattern in this same codebase and was the "fuller alternative" the requirement's own
Why-section says was shown and rejected for this table. This design does not port it. If a
future session finds draft/live insufficient (e.g. wanting to keep prior published text
around), that is **a finding to report to REQ-ANALYST for a fresh requirement**, not a
unilateral redesign of this table — stated here so a future reader of this file does not
"fix" it on their own initiative.

No `archived_at` column (unlike `process_definitions`), no transition-history table: there
is nothing to archive or version in a two-state model with no history requirement.

Transition semantics (for REQ-364's context module to implement, named here so the design
states the full shape even though building it is REQ-364's job): `draft → live` and
`live → draft` are both legal in either direction — unlike `ProcessDefinition`'s one-way
`draft → active → deprecated → archived` chain, there is no requirement text basis for
making `live → draft` illegal (e.g. pulling back a published help entry for correction is
an expected, ordinary operation, not an exceptional one). This is stated as a design
decision, not left to REQ-364 to invent, since a one-way-only transition would be exactly
the kind of unstated assumption `.claude/agents/code-designer.md` warns against leaving
implicit.

---

## 3. Platform-vs-tenant split

The requirement text is explicit that tenant-owned and platform-owned help content are two
categories that "must NOT be conflated in the schema," and instructs consistency with
REQ-358's already-landed `scope` pattern (§0's premise, read in full).

**Decision, following REQ-358 §1.2's shape (an explicit field distinguishing the two, not
structural table location alone — but adapted, because REQ-358's `scope` lives inside one
shared YAML corpus with no execution-time isolation concern, whereas `help_content` rows are
read/written through tenant-schema `prefix()` selection, which is Letflow's actual tenant
isolation mechanism everywhere else in this codebase, §0):**

- **Tenant-owned help content** lives in `help_content` in each tenant's own Postgres
  schema (`prefix()`), exactly as designed in §1 — this is the table and schema this design
  builds.
- **Platform-owned help content does NOT live in any tenant schema.** Its home is a
  **separate table, `platform_help_content`, in the `public` schema** (no `prefix()`,
  created without the `if prefix() do` guard — a normal, ungoverned-by-tenant-provisioning
  migration, the same shape `users`/`tenants` already use per §0's FK-boundary note).
  Rationale for a separate table rather than a `scope`-style discriminator column on one
  shared `help_content` table: unlike REQ-358's YAML corpus (one file set, read by one
  process, where a `scope:` field is sufficient because there is no structural isolation
  mechanism to violate), `help_content` rows are governed by Letflow's real multi-tenant
  boundary — the Postgres schema/`prefix()` mechanism (Decision B, §0). Putting a platform
  row in a tenant's own schema-scoped table (even flagged `scope: platform`) would mean a
  platform-authored row physically lives inside one arbitrarily-chosen tenant's schema, is
  duplicated or absent for every other tenant, and is invisible to `Repo`'s
  tenant-`prefix()`-scoped queries used everywhere else — a structural conflation the
  requirement explicitly forbids, not merely a style preference. A same-shaped table in
  `public` avoids this: platform rows are queried without any `prefix:` at all, exactly
  the same way `users`/`tenants` already are (§0).
  `platform_help_content` reuses `help_content`'s **column shape** (§1.1) as designed,
  minus nothing — `screen_id`, `process_definition_id` (still nullable; a platform-scope
  process definition concept is out of this requirement's scope to resolve, flagged as
  **OQ-2** below), `title`, `body`, `status`, `confirmed_at`,
  `confirmed_for_definition_version`, `media`, `created_by`, timestamps — identical field
  list, different table/schema, no cross-referencing between the two tables.
- This requirement does **not** build the platform-side authoring path (that is REQ-365,
  per the requirement text's own scope note) — this design only ensures the schema for both
  categories exists and is never conflated, i.e. `platform_help_content`'s **existence and
  shape** is in scope here; the write/authoring flow that populates it is REQ-365's design
  to produce.
- Consistency with REQ-358: both designs use an explicit, named mechanism to keep
  platform and tenant material distinguishable rather than relying on convention — REQ-358
  uses a field (`scope:`) because its storage has no per-tenant physical isolation; this
  design uses a physically separate table/schema because `help_content`'s storage already
  has per-tenant physical isolation as its primary mechanism, and preserving that isolation
  for platform rows means giving them their own home rather than layering a field onto the
  tenant-isolated table. Both satisfy the same requirement-level intent ("never conflate
  platform and tenant material") via the mechanism appropriate to each table's actual
  storage model.

---

## 4. Staleness mechanism: `confirmed_at` / `confirmed_for_definition_version`

### 4.1 `confirmed_at`

`:utc_datetime_usec`, nullable, present on every row (both `help_content` and
`platform_help_content`). Set explicitly by whoever publishes/re-confirms the content —
**never inferred** from `updated_at` or any other signal. This is the sole staleness signal
for non-process-scoped (`process_definition_id` is `NULL`) help content, per the
requirement's own text: "there is no per-screen version concept anywhere in this codebase
today... `confirmed_at` alone is the accepted, deliberately coarser signal for that
category." Setting this field is REQ-364's context module's job (a `confirm/1`-shaped
function of some kind) — this design states the field and its semantics, not the function
body.

### 4.2 `confirmed_for_definition_version` — the integer/string discrepancy, resolved explicitly

**What the requirement text says:** "integer, matching
`Letflow.Definitions.ProcessDefinition.version`."

**What I verified in the real code (§0):** `lib/letflow/definitions/process_definition.ex`
line 88 declares `field(:version, :string)`, and the table's own migration
(`priv/repo/migrations/20260816193001_create_process_definitions.exs` line 78) declares
`add :version, :string, null: false`. **`ProcessDefinition.version` is `:string`, not
`:integer`, at both the Ecto schema layer and the Postgres column layer.** This is a genuine
discrepancy between the requirement text's stated type and the actual, current codebase
state — not a stub-vs-real-requirement issue (this is the real, WF-01-landed requirement
text, read directly, §0), and not something I am resolving by guessing.

**Resolution:** `help_content.confirmed_for_definition_version` (and
`platform_help_content`'s copy of the same column) is designed as **`:string`**, matching
`ProcessDefinition.version`'s actual type. I am reading the requirement's stated intent —
"matching `Letflow.Definitions.ProcessDefinition.version`" — as the controlling clause, and
its parenthetical type label ("integer") as an imprecise gloss on that intent rather than a
literal instruction to diverge from the very column it says to match. A `:integer` column
cannot "match" a `:string` column for the comparison this field exists to perform (compare
stored value against the process definition's live `version` to detect drift, per the
requirement's own staleness description) — an integer column would require either a lossy
cast of `ProcessDefinition.version`'s string values to integers (which is not guaranteed to
be possible: `process_definitions.version`'s `validate_length(:version, min: 1, max: 255)`
in `create_changeset/2` places no numeric-format constraint on it, so a live tenant version
string like `"1.0.3-beta"` would not cast) or an unstated normalization scheme this design
has no basis to invent. Designing `:string` is therefore the reading that actually satisfies
the comparison the field exists to serve, not a silent override of the requirement — it is
recorded here, with the exact file/line evidence, per this run's explicit instruction not to
resolve this silently in either direction.

**If this resolution is wrong** (i.e. if the requirement's "integer" framing was actually
the controlling intent and `ProcessDefinition.version`'s current `:string` type is itself
the thing that should someday change), that is a decision-record-level conflict between this
requirement and REQ-027/030's already-`done`, already-shipped schema — flagged here as
**OQ-3** for REVIEWER/CODE-DESIGN-VALIDATOR sign-off, not resolved unilaterally in that
direction, per core-directives.md's "don't silently re-decide what a decision record already
settled."

### 4.3 Comparison mechanism

A **pure read**, exactly as the requirement text specifies ("the comparison is a pure read
(no new job/worker)"): given a `help_content` row with non-null `process_definition_id`, the
content is staleness-flaggable when
`confirmed_for_definition_version != <that process definition's current :version value>`
(string equality, both sides `:string`) — or when `confirmed_for_definition_version` is
`NULL` (never confirmed against any version). Computing and **displaying** the resulting
"may be outdated" signal is REQ-366's job per the requirement text; this design defines only
the field and the comparison rule, as instructed.

---

## 5. Write-path sanitization (this requirement's own scope)

The requirement text is explicit this is **not** deferred to REQ-366's render-time
sanitization: "This requirement's write path (the context module's create/update functions)
must reject raw HTML and constrain content to a markdown subset... at write time... defense
in depth."

### 5.1 What is rejected (named explicitly, per the acceptance criterion's own wording)

The write-path changeset (REQ-364's `create_changeset/2` / `update_changeset/2` — this
design specifies the *rule*, REQ-364 implements the function body) MUST reject `body` (and
`title`) content containing any of:

- **Raw HTML tags** — any substring matching an HTML tag opening/closing construct, e.g.
  `<tagname ...>` or `</tagname>`, for any `tagname` — not an HTML-tag denylist (a denylist
  of "known-dangerous" tags is incomplete by construction; markdown's own syntax does not
  require any raw HTML tag to express headings/emphasis/lists/links/code, so the write path
  can reject **all** raw angle-bracket tag constructs rather than trying to enumerate unsafe
  ones).
- **`<script>` / `</script>`** — covered by the raw-HTML-tag rule above, named explicitly
  per the acceptance criterion's own wording, since this is the single most safety-critical
  case to be unambiguous about.
- **Event handler attributes** — any `on<word>=` pattern (`onclick=`, `onerror=`, `onload=`,
  etc.) — covered by the raw-HTML-tag rule above (an event handler attribute can only appear
  inside an HTML tag, which is already rejected), named explicitly per the acceptance
  criterion's own wording for the same reason.
- **`javascript:` URIs** inside markdown link/image syntax (`[text](javascript:...)`) —
  markdown's own link syntax `[text](url)` is allowed (§5.2), so this is the one case that
  needs a rule of its own beyond "reject raw HTML": the write path additionally rejects any
  markdown link/image `url` component whose scheme (case-insensitive, leading/trailing
  whitespace stripped) is `javascript:`, `data:`, or `vbscript:`.

### 5.2 What is allowed (the markdown subset)

Not an open-ended "any markdown" allowance — a stated subset, since "constrain content to a
markdown subset" is the requirement's own wording, not "allow arbitrary markdown":

- Headings (`#` through `######`)
- Emphasis: `*italic*`/`_italic_`, `**bold**`/`__bold__`
- Lists: unordered (`-`/`*`) and ordered (`1.`)
- Links: `[text](url)`, subject to §5.1's scheme rejection
- Code: inline `` `code` `` and fenced ``` ``` ``` blocks (fenced-block content is treated as
  literal text, never re-parsed for further markdown or HTML — this is what makes it safe to
  allow verbatim)
- Blockquotes (`>`)
- Paragraphs / line breaks

No raw HTML of any kind (§5.1), no markdown extensions this list doesn't name (e.g. no
raw-HTML-passthrough extensions some markdown dialects support) unless a future requirement
explicitly widens this list.

### 5.3 Mechanism — flagged, not silently decided

**No existing dependency in this codebase implements either half of this** (§0: `mix.exs`
has no markdown-rendering or HTML-sanitization library today). Two candidate mechanisms,
named with reasoning rather than picked silently, per this run's explicit instruction:

1. **Regex/pattern-based validation with no new dependency** — a changeset validator
   function that scans `body`/`title` for the angle-bracket-tag pattern (§5.1) and the
   disallowed-URL-scheme pattern, rejecting the changeset (`add_error/3`) on any match. This
   requires no new library, no REVIEWER library sign-off, and is sufficient to express every
   rule in §5.1 (all of which are pattern-shaped, not structural-parse-shaped) — rejecting
   the *presence* of a raw tag or bad URL scheme does not require actually parsing markdown
   into a tree. This is the mechanism I recommend REQ-364 implement, specifically **because**
   it needs no new dependency and this codebase's own precedent
   (`check_requirements_registration`'s moduledoc, cited in REQ-358's design §0) already
   states "adding one [a parsing dependency] for a bug fix would be a library choice
   requiring REVIEWER sign-off" — the same reasoning applies here: a regex-based validator
   satisfies every stated rule without incurring that sign-off cost.
2. **A real HTML-sanitization library** (e.g. `html_sanitize_ex`) run against a
   markdown-to-HTML preview of the input, rejecting if sanitization would strip anything —
   more robust against pattern-evasion (e.g. malformed/obfuscated tags a regex might miss),
   but requires adding a new dependency, which per this project's own convention (cited
   above) needs REVIEWER sign-off before REQ-364 can take a dependency on it.

**Superseded — see §5.4.** Option 1 (regex/pattern-based validation, no new dependency) was
built by ELIXIR-DEV against this section as originally written and reached
`lib/letflow/help/help_content.ex`. SECURITY-REVIEWER found two real, confirmed bypasses
across two review rounds (reference-style link definitions resolving a URL the inline-site
regex never scanned; angle-bracket-wrapped autolink URLs `<javascript:...>` the tag-pattern
regex misidentified as an HTML tag and the link-pattern regex never matched as a link). On
the third round, REVIEWER (`handoffs/WF02-REQ364-20260917/step-03d-reviewer-determination.json`)
constructed three further bypasses without changing the threat model at all — backslash-escaped
scheme characters, HTML-entity-encoded scheme characters, and embedded whitespace/control
characters inside a scheme name (the OWASP `javascript:` URI filter bypass cheat sheet's
standard techniques) — and determined the regex approach is **structurally unsound, not
incomplete**: every one of these five bypasses stems from the same root cause, that the regex
scans raw source bytes for a `scheme:` substring while a real CommonMark parser's link-
destination resolution applies escape processing, entity decoding, and whitespace
normalization the regex never implements and cannot be patched to implement completely (each
patch closes the specific case found and leaves the general class open). REVIEWER explicitly
declined a third regex-patch round and routed this back through CODE-DESIGNER to resolve
OQ-4 in the direction of option 2 — a real parser, AST-level. §5.4 is that resolution. Option
1's specific bypasses, and the reasoning that no further regex patch is acceptable, are kept
here rather than deleted, so a future reader does not "rediscover" option 1 as a live
alternative.

### 5.4 Resolved mechanism (amended 2026-09-17, per REVIEWER's determination) — `earmark_parser`

**OQ-4 is resolved: a real CommonMark parser, AST-level destination checking.** No
regex/pattern-based option remains live for this requirement.

#### 5.4.1 Library choice: `earmark_parser`

**Chosen: `earmark_parser`** (hex package `earmark_parser`, the parsing engine the `earmark`
Markdown-to-HTML renderer itself depends on and exposes as a standalone package).

- **Licence:** Apache-2.0.
- **Maintenance status:** actively maintained (`RobertDober/earmark_parser`); it is the
  parser `ex_doc` — the Elixir ecosystem's own documentation generator — depends on to parse
  every `@doc`/`@moduledoc` string in every published Hex package, which is about as
  broad and continuously-exercised a conformance workout as a Markdown parser gets in this
  ecosystem.
- **Pure-Elixir/Erlang vs. native/NIF:** pure Elixir. No NIF, no port, no external binary —
  same shape this project already prefers per decision 0033 §2's P1-over-P2 reasoning (an
  in-process, no-external-binary library beats one that requires provisioning something
  outside the BEAM, when the in-process option is otherwise sufficient).
- **Transitive-dependency impact:** none of note — `earmark_parser` has no runtime
  dependencies of its own beyond Elixir/OTP.
- **Why this over full `earmark` (the renderer, not just the parser):** this requirement never
  needs rendered HTML — §5's write path only ever needs to *inspect* the parsed structure and
  reject the changeset; it never displays the result (render-time display is REQ-366's job,
  out of this requirement's scope per §5's own opening). Depending on `earmark_parser` alone
  (not `earmark`) takes exactly the capability needed — `EarmarkParser.as_ast/2`, a function
  that turns a markdown string into a CommonMark AST — with no HTML-rendering code path
  pulled in unused. (Taking `earmark` instead would work too, since it re-exports the same
  parser, but would name a dependency on rendering machinery this requirement never calls.)
- **Why an AST parser over an HTML-sanitization library (e.g. `html_sanitize_ex`):** this
  requirement's input is markdown source, not HTML. A sanitizer like `html_sanitize_ex`
  parses and cleans *HTML* — to use one here, REQ-364 would first have to render the markdown
  to HTML (via some renderer, i.e. `earmark` itself or similar) and then sanitize *that*,
  meaning the same CommonMark-parsing step happens either way, plus a second full pass and a
  second dependency. Checking link/image destination nodes directly on the parser's own AST
  is the smaller, more direct mechanism — one dependency, one parse pass, no intermediate
  HTML string ever constructed or discarded.
- **Why this closes all five confirmed/constructed bypasses, not just the two SECURITY-REVIEWER
  found:** `EarmarkParser.as_ast/2` is a real CommonMark-conformant parser. Reference-style
  link definitions are resolved to their target destination by the parser itself as part of
  producing the AST — there is no "inline site" vs. "definition site" distinction left for a
  destination check to miss, because by the time the AST exists, every link/image node already
  carries its *resolved* destination regardless of which markdown syntax produced it. The same
  is true for autolinks (`<scheme:...>`), backslash-escaped characters, and HTML-entity-encoded
  characters within a destination: CommonMark's spec mandates that a conformant parser resolve
  backslash escapes and decode entities as part of producing inline content, including link
  destinations, before that content is available to a caller at all — this is normal parser
  behavior, not a security feature bolted on, which is exactly why "the parser already handles
  it correctly" is the point of using one instead of hand-rolling the equivalent logic in a
  regex (per REVIEWER's determination, cited above). Embedded whitespace/control characters
  are likewise normalized by the parser as part of tokenizing a destination (CommonMark link
  destinations are either angle-bracket-delimited, where whitespace/control characters are
  spec-disallowed and the parser will not treat the construct as a valid destination at all,
  or bare, where the destination token itself ends at the first ASCII whitespace/control byte
  per spec) — there is no path through the parser's own destination-token production that
  leaves raw whitespace/control bytes sitting inside a value the write path later scheme-checks.

#### 5.4.2 Write-path mechanism (design-shape level, no implementation code)

Replaces §5.3 option 1's regex-based validator function shape. The changeset validator
(still invoked from `create_changeset/2`/`update_changeset/2`, still rejecting via
`add_error/3`, `{:error, changeset}`, never a raised exception — that contract from the
original §5.3 is unchanged) now does the following, for each of `:title` and `:body`:

1. **Parse.** Call `EarmarkParser.as_ast/2` on the field's string value. `earmark_parser`
   returns `{:ok, ast, deprecation_messages}` on a clean parse or `{:error, ast, error_messages}`
   on a malformed-but-still-parseable input (CommonMark parsers are error-tolerant by design —
   there is no markdown input that fails to produce *some* AST). Both tuple shapes carry an
   `ast` (a list of node terms, CommonMark's own element-tree shape); the validator walks the
   `ast` value from either branch — a non-empty `error_messages`/`deprecation_messages` list is
   not itself a rejection reason (this requirement rejects specific *content* shapes named in
   §5.1, not "syntactically unusual markdown").
2. **Walk the AST for raw-HTML nodes.** `earmark_parser`'s AST distinguishes raw HTML
   constructs (block-level HTML and inline HTML spans/tags) from parsed markdown constructs as
   their own, separately-tagged node kind — the parser itself already does the "is this an
   HTML tag or is this markdown-safe content" classification §5.1's raw-HTML-tag rule wants,
   which is the same "let the library's own correct classification do the work" principle as
   the destination check. If the walk finds any raw-HTML-classified node anywhere in the tree
   (top level or nested inside any container node — list item, blockquote, emphasis, etc.),
   the changeset is rejected under §5.1's raw-HTML-tag rule. This single check subsumes the
   `<script>`/event-handler-attribute cases §5.1 names explicitly, exactly as the original
   §5.3 reasoning already established (an event-handler attribute or a `<script>` tag can only
   appear as a raw-HTML construct, which this check already catches in full).
3. **Walk the AST for link/image destination nodes.** Separately, walk the same tree for every
   node representing a resolved link or image (`earmark_parser`'s AST represents these as
   element nodes carrying an `href` or `src` attribute in the node's attribute list — the
   *already-resolved* destination string, per §5.4.1's "resolved" explanation above; not raw
   source text). For every such node found, extract the scheme (the substring before the first
   `:`, case-insensitive, with leading/trailing whitespace trimmed the same way §5.1's original
   rule states) and reject the changeset under §5.1's scheme rule if it is one of `javascript`,
   `data`, or `vbscript`.
4. **Fenced/inline code content needs no separate stripping step.** §5.3's original mechanism
   needed `strip_code_regions/1` as a standalone pre-pass because a regex has no concept of
   "this span is a code span" — it can only be told to skip byte ranges that look like one.
   `earmark_parser`'s AST represents fenced and inline code as their own distinct node kind
   (code content, not re-parsed as markdown or HTML) by construction — steps 2 and 3 above
   walk *only* raw-HTML nodes and link/image-destination nodes respectively, so code-span/
   code-block node content is never visited by either check in the first place. No equivalent
   of `strip_code_regions/1` is needed in the amended mechanism; the AST shape itself is what
   makes §5.2's "fenced-block content is treated as literal text" guarantee hold, rather than a
   separate blanking pass over source text.
5. **Reject, don't strip.** Same as §5.3's original commitment: finding a disallowed node
   anywhere in the tree adds a changeset error (`add_error/3`) and the changeset is invalid —
   the write path never silently strips the offending construct and saves a modified `body`.

No change to §5.1 (what is rejected) or §5.2 (the allowed markdown subset) — §5.4 only
replaces *how* those rules are enforced, not what they say.

#### 5.4.3 New dependency — flagged for REVIEWER sign-off, not self-approved

Per this project's own convention (decision 0033, REQ-356's `pdf`/`eqrcode` precedent, cited
in the original §5.3): **this design amendment names and justifies a library choice; it does
not itself approve adding `earmark_parser` to `mix.exs`.** That approval is REVIEWER's to give,
at the same procedural weight as REQ-356's PDF/QR library sign-off — ELIXIR-DEV's
implementation of this amended §5.4 must not add the dependency and merge without a recorded
REVIEWER sign-off, exactly as REQ-356's dependency entries in `mix.exs` each carry an explicit
"Flagged for REVIEWER sign-off ... must be recorded before this merges" comment. Whether that
sign-off is recorded as a new `docs/migration/decisions/` record (mirroring 0033's format) or
inline in the implementation handoff is REVIEWER's call, not this design's.

---

## 6. `media` — reservation only

`media` is a `{:array, :map}` (jsonb array) column, `default: []`, on both `help_content`
and `platform_help_content`. Per the requirement text: "the schema must reserve a `media`
field... now rather than requiring a later migration that has to backfill every existing
row." No element shape is defined by this requirement — no changeset validation is applied
to `media`'s contents (any array of maps is structurally acceptable at the schema layer,
though REQ-364's changeset need not even cast it if no write path sets it yet). REQ-368 or a
later requirement designs actual media storage/rendering; this design's only obligation is
that the column exists with the stated default so no later migration needs a data backfill.

---

## 7. Acceptance-criteria mapping

| Acceptance criterion (docs/requirements.yaml REQ-363, verbatim source) | Design element |
|---|---|
| `help_content` table schema: tenant-schema-scoped via prefix, same convention as `ProcessDefinition` | §0 (verified convention), §1 (table), §1.3 (schema module, no `@schema_prefix`) |
| fields for `screen_id`/route identifier | §1.1 row 2 |
| `process_definition_id` (nullable, FK) | §1.1 row 3 (nullable; "FK" resolved as application-level reference per `process_definitions`'s own no-DB-FK convention, stated explicitly) |
| `title` | §1.1 row 4 |
| `body` (markdown) | §1.1 row 5, §5 (markdown subset + sanitization rule) |
| `status` (draft\|live enum, no other values) | §1.1 row 6, §2 (lifecycle + why) |
| `confirmed_at` | §1.1 row 7, §4.1 |
| `confirmed_for_definition_version` (nullable integer) | §1.1 row 8, §4.2 (integer/string discrepancy resolved explicitly with file/line evidence) |
| `media` (jsonb, reserved/unused) | §1.1 row 9, §6 |
| `created_by` | §1.1 row 10 |
| `timestamps` | §1.1 row 11 |
| design explicitly states why draft/live (not `ProcessDefinition`'s four-state lifecycle) was chosen, citing requirement's own Why section | §2 (verbatim quote + citation) |
| design states the platform-vs-tenant help distinction explicitly, platform rows NOT tenant-schema-scoped, states where they live, consistent with REQ-358's scope field | §3 (full section: `platform_help_content` in `public`, reasoning for divergence from REQ-358's field-based approach, explicit consistency argument) |
| design specifies write-path sanitization/validation rule (rejected shapes named explicitly: raw HTML, script tags, event handler attributes) as this requirement's own scope, not deferred to REQ-366 | §5.1 (each named explicitly), §5.3 (original mechanism, superseded), §5.4 (amended, resolved mechanism — `earmark_parser` AST walk, OQ-4 resolved) |

---

## 8. Open questions

- **OQ-1** (§1.2) — no uniqueness constraint on `(screen_id, process_definition_id)`;
  requirement text does not ask for at-most-one-entry-per-screen and REQ-364/366 may want
  multiple entries per screen. Left open rather than guessed.
- **OQ-2** (§3) — `platform_help_content.process_definition_id`: whether a "platform-scope
  process definition" concept exists at all (process definitions today are tenant-schema
  data per `process_definitions`'s own design) is out of this requirement's scope to
  resolve; the column is included in `platform_help_content` for shape-parity with
  `help_content` but its practical meaning for platform rows is left to REQ-365.
- **OQ-3** (§4.2) — the integer/string discrepancy's resolution (`:string`, matching the
  real `ProcessDefinition.version` column) is this design's reading of the requirement's
  intent over its literal word choice; flagged for REVIEWER/CODE-DESIGN-VALIDATOR sign-off
  in case the literal "integer" instruction was meant to be controlling instead (which would
  imply a fresh decision to change `ProcessDefinition.version`'s own type, a decision-record-
  level question this design does not have authority to make).
- **OQ-4** (§5.3/§5.4) — **RESOLVED 2026-09-17** by REVIEWER's determination
  (`handoffs/WF02-REQ364-20260917/step-03d-reviewer-determination.json`): the regex/pattern-
  based option built against this design's original §5.3 proved structurally unsound (five
  confirmed/constructed bypasses across three review rounds — see §5.3's superseded note).
  §5.4 now names and specifies `earmark_parser` (AST-level link/image destination and raw-HTML
  node checking) as the mechanism ELIXIR-DEV must implement. The new dependency itself still
  requires a separate REVIEWER sign-off before merge (§5.4.3) — resolving *which* library and
  *how* it integrates is this amendment's job; approving the `mix.exs` addition is REVIEWER's,
  same as REQ-356's precedent.

### What changes for ELIXIR-DEV's existing implementation

`lib/letflow/help/help_content.ex` (read in full for this amendment, current state) built
§5.3 option 1 exactly: `@raw_html_tag_pattern`, `@markdown_link_pattern`,
`@markdown_reference_link_pattern`, `@disallowed_url_schemes`, `validate_no_raw_html/2`,
`validate_no_unsafe_link_scheme/2`, `contains_unsafe_link_scheme?/1`, `urls_unsafe?/2`,
`unsafe_scheme?/1`, and the `strip_code_regions/1` code-span pre-pass. Per §5.4:

- **All of the above module attributes and private functions are replaced**, not patched
  again — they implement exactly the regex mechanism §5.3 documents as superseded. None of
  the five bypasses is closeable by adding another pattern to this set (that is the substance
  of REVIEWER's "structurally unsound" finding); ELIXIR-DEV should delete them rather than
  layer a sixth pattern on top.
- **`validate_common/1`'s call sequence changes shape**: instead of calling
  `validate_no_raw_html/2` and `validate_no_unsafe_link_scheme/2` per field via
  `validate_change/3` over the raw string, the replacement validator (§5.4.2 steps 1–3) parses
  each field's value once via `EarmarkParser.as_ast/2` and walks the resulting AST for both
  raw-HTML nodes and disallowed-scheme link/image-destination nodes in that same walk — the
  two checks can share one parse per field rather than needing two independent passes, since
  both `validate_no_raw_html/2`'s and `validate_no_unsafe_link_scheme/2`'s existing signatures
  (`changeset, field -> changeset`) and call sites in `validate_common/1` stay the *shape* the
  same; only their internals move from regex-over-string to AST-walk-over-parsed-tree.
  `validate_length(:screen_id, ...)` and `validate_length(:title, ...)` are untouched — those
  never depended on the sanitization mechanism.
- **`strip_code_regions/1` is deleted, not ported** — §5.4.2 step 4 explains why: the AST
  shape itself excludes code-span/code-block content from both checks, so there is no
  equivalent pre-pass to write.
- **The changeset error contract is unchanged**: `add_error/3` with the same two user-facing
  messages (`"must not contain raw HTML tags"`, `"must not contain javascript:/data:/vbscript:
  link or image URLs"`) is still the right shape — §5.4 changes detection, not the rejection
  contract or the messages a caller sees.
- **`mix.exs` gains one new dependency**, `{:earmark_parser, "~> ..."}` (ELIXIR-DEV verifies
  the current hex.pm version at implementation time), flagged per §5.4.3 — implementation must
  not proceed past adding this line without a recorded REVIEWER sign-off, mirroring the
  `{:pdf, ...}`/`{:eqrcode, ...}` sign-off comments already in `mix.exs` for REQ-356.
- **The module moduledoc's "Write-path sanitization" section** (currently citing "design §5.3's
  option 1") needs updating to cite §5.4 and the amended mechanism once reimplemented — named
  here so ELIXIR-DEV doesn't leave a stale citation pointing at the superseded section.
