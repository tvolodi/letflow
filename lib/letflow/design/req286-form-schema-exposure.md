# REQ-286 — Expose `form_schema` in the task-detail response, under a security gate

**Requirement:** REQ-286 (`docs/requirements.yaml`, stage S8; full `description` and all
8 `acceptance_criteria` read directly from that entry, per `core-directives.md`'s "Load
Scoped Context, Not Whole Files").
**Owner (implementer):** `ELIXIR-DEV`.
**Depends on:** REQ-273 (`tasks.form_schema` populated at activation).
**No implementation code below** — signatures, `@spec`-style types, and verbatim
citations of existing code only, matching REQ-126's/REQ-083's own convention. The
moduledoc replacement text in §6 is documentation prose, not code.

---

## 0. Sources read for this design

- REQ-286's own `docs/requirements.yaml` entry (`id: REQ-286`, lines 16918-16961).
- `lib/letflow/routers/tasks.ex` (full moduledoc + `handle_get_by_id/3`,
  `task_list_item_map/2`, `task_detail_map/3`).
- `lib/letflow/engine/task.ex` (full) — the `tasks` schema and all three changesets
  (`insert_changeset/2`, `complete_changeset/2`, `assignment_changeset/2`).
- `lib/letflow/engine/task_activation.ex` (full) — `resolve_form_schema/1`,
  `insert_attrs/4`, moduledoc section "`form_schema` is a rendering payload only
  (REQ-273)".
- `lib/letflow/design/req273-form-schema-activation.md` (referenced; REQ-273's own
  commit message and moduledoc restate its content directly, cited below).
- `lib/letflow/tasks.ex` (full) — `get_task/2`, `get_form_version/2`,
  `task_list_item_map/2`/`task_detail_map/3` (the actual map-building functions live in
  `routers/tasks.ex`, not `tasks.ex` — confirmed by direct read; see §2).
- `lib/letflow/design/req126-form-version-pinning.md` — the version-pinning precedent
  this requirement's AC3 must match.
- `lib/letflow/plugs/authorize.ex` (full) — the tenant-scoping mechanism every
  `authz_get`/`authz_post` route passes through before a handler runs.
- `docs/agents/instructions/security-invariants.md` INV-1, INV-2, INV-5 (full text of
  each, quoted where relevant in §5).
- `git log --oneline --all | grep 273` and `git show --stat 37879a64` / `3860abe2` —
  confirms REQ-273 landed and its own commit message's explicit scope-fence statement.
- `lib/letflow/engine/variable_schema.ex` moduledoc — REQ-109's own statement that
  `variable_schemas` remains the sole validation authority (scope-fence confirmation
  for §7).

---

## 1. Re-verification (requirement's own instruction: "re-verify at start")

### 1a. `task_detail_map/3`'s current key count — confirmed 13, not re-derived

`task_list_item_map/2` (`lib/letflow/routers/tasks.ex:529-543`) builds an 11-key map:
`id`, `instance_id`, `node_id`, `node_name`, `status`, `assignee_type`, `assignee_ref`,
`created_at`, `token_id`, `form_id`, `form_version`.

`task_detail_map/3` (`lib/letflow/routers/tasks.ex:554-559`) is verbatim:

```
defp task_detail_map(%Letflow.Engine.Task{} = task, correlation_key, form_version) do
  task
  |> task_list_item_map(form_version)
  |> Map.put("correlation_key", correlation_key)
  |> Map.put("updated_at", DateTime.to_iso8601(task.updated_at))
end
```

11 + `correlation_key` + `updated_at` = **13 keys, confirmed** — matches the
requirement's own count exactly. (This citation is the one exception the CODE-DESIGNER
convention allows: verbatim reproduction of *existing* code for verification, not new
implementation code.)

### 1b. REQ-273 landed and `form_schema` is genuinely populated at activation — confirmed

`git log --oneline --all | grep 273` shows `37879a64 feat(REQ-273): populate
tasks.form_schema at activation, shape-validated and version-pinned (#1103)`, merged to
main. `git show --stat 3860abe2` (the underlying commit) touches
`lib/letflow/engine/task_activation.ex`, `lib/letflow/engine/sub_process.ex`, and their
test files. `lib/letflow/engine/task_activation.ex:159-170`
(`resolve_form_schema/1`) is live code today, reading
`node.attributes["form_schema"]` and shape-checking it via
`Letflow.Definitions.JsonSchemaShape.check/1` before `insert_attrs/4`
(`task_activation.ex:196-216`) includes it in the seven-key attrs map passed to
`Letflow.Engine.Task.insert_changeset/2`. `lib/letflow/engine/task.ex:70` declares
`field(:form_schema, :map)`, and `insert_changeset/2` (`task.ex:88-96`) casts it.
Confirmed: the column is genuinely written today, not merely schema-declared.

### 1c. The current moduledoc's exclusion statement — quoted verbatim (lines 91-93 region)

`lib/letflow/routers/tasks.ex:86-95` (the "Response allowlists (INV-2, AC5)" section)
reads, verbatim, in full (not only the three-line span the requirement names, since the
surrounding sentence is one unit and must be replaced as a whole):

> `task_list_item_map/2` (11 keys) / `task_detail_map/3` (13 keys, adds
> `correlation_key`/`updated_at`) are hand-built maps, never a
> `Jason.Encoder`/struct-wholesale encoding — matching `Letflow.Routers.Identity`'s
> `user_map/1` discipline exactly. `claimed_by` is omitted entirely (no Letflow schema
> column exists yet — REQ-085's own concern). `form_schema`/`output_variables`/
> `completed_by`/`completed_at`/`cancelled_at` are also excluded — none is named by any
> REQ-083 acceptance criterion, and `form_schema` is unpopulated (always `nil`) in this
> codebase today (REQ-047 §4.4's own open question) — a distinct concern from
> `form_id`/`form_version` below (identity/version, not rendering payload).

Both premises this sentence rests on are now false: (a) `form_schema` is no longer
unpopulated — REQ-273 populates it at activation (§1b above); (b) the "no REQ-083
acceptance criterion names it" framing is superseded — REQ-286 (this requirement) is the
acceptance-criterion authority that now names it. §6 below drafts the replacement.

There is also a second, shorter reference at `lib/letflow/routers/tasks.ex:520-522` (a
`#` comment immediately above `task_list_item_map/2`'s own `@spec`):

> `# inserted_at/updated_at are deliberately excluded (see moduledoc, design §5.5);`
> `# tasks.form_schema (the unrelated, still-unpopulated rendering payload) is also`
> `# excluded -- see moduledoc.`

This comment is not named by any AC line-number reference but says the same now-false
thing and must be corrected in the same edit for internal consistency (a moduledoc that
says "now exposed" sitting three lines above a comment that still says "excluded" would
be a self-contradiction the same reader could catch a paragraph later). §6 covers both.

---

## 2. The exposure mechanism

`form_schema` becomes the map's 14th key inside `task_detail_map/3` only — **not**
inside `task_list_item_map/2`. This is a deliberate scope decision, not an oversight:

- The requirement's title and all 8 ACs speak only of "the task-detail response" (`GET
  /tasks/:id`, `handle_get_by_id/3`) — no AC exercises `GET /tasks` or `GET
  /tasks/inbox`.
- `task_list_item_map/2` is the shared base both the list routes and the detail route
  build on; adding `form_schema` there would silently widen `GET /tasks`/`GET
  /tasks/inbox` (list/inbox responses, potentially many rows per response) to also carry
  a JSON-Schema-shaped rendering payload per row — a payload that can be arbitrarily
  large per REQ-273's own shape-check tolerance — with zero acceptance criterion
  covering that surface. That would be scope creep on a response-shaping change, exactly
  the kind of unstated widening `INV-6`/`SECURITY-REVIEWER`'s review is positioned to
  catch. If a future requirement wants `form_schema` on the list/inbox responses too, it
  should get its own AC and its own SECURITY-REVIEWER pass, not inherit one from this
  requirement's design silently.

**Mechanism — `task.form_schema` is already a field on the `%Letflow.Engine.Task{}`
struct `task_detail_map/3` already receives as its first argument.** No new query, no
new join, no new function argument is needed: `handle_get_by_id/3`
(`lib/letflow/routers/tasks.ex:279-290`) already calls `Tasks.get_task(id, opts)`,
which already `select`s the full `Task.t()` struct (`lib/letflow/tasks.ex:264`,
`select: {t, ip.correlation_key, s.definition_ver}` — `t` is the whole struct, every
column including `form_schema`), and already threads that struct into
`task_detail_map(task, correlation_key, form_version)`. The struct handed to
`task_detail_map/3` already carries the populated `form_schema` value; the map-building
function simply never reads that field today.

The change to `task_detail_map/3`'s body is a single additional `Map.put/3` call in the
existing pipe chain, reading `task.form_schema` directly off the struct already in
scope — the same idiom `task_detail_map/3` already uses twice (`correlation_key`,
`updated_at`). Updated signature (type unchanged, only the body's key count changes —
CODE-DESIGN-VALIDATOR note: this is a signature/shape statement, not a function body):

```
@spec task_detail_map(
        Letflow.Engine.Task.t(),
        correlation_key :: String.t() | nil,
        form_version :: String.t() | nil
      ) :: map()
```

(Signature is unchanged from today — `form_schema` is read off the already-passed
`Task.t()` argument, not a new parameter.) Output shape: the same 13-key map plus one
new key, `"form_schema" => task.form_schema` (type `map() | nil`, JSON-serialised as a
JSON object or `null`).

No change to `task_list_item_map/2`'s signature, body, or key count (stays 11 keys). No
change to `Letflow.Tasks.get_task/2`'s signature, query, or return shape — it already
returns the whole struct. No new join, no new `Repo` call, no new `opts` field.

---

## 3. The nil case (AC2) — no special-casing required

`Map.put(map, "form_schema", task.form_schema)` where `task.form_schema` is `nil` (the
common case today, per REQ-273's own `resolve_form_schema/1`: "absent or explicit JSON
`null` stays `nil`, never `%{}` or any other invented default" —
`task_activation.ex:145`) produces `%{..., "form_schema" => nil}` in the Elixir map.
`Jason.encode/1` (the encoder `Letflow.Api.Response.ok/2` uses for every existing key in
this same map, including `correlation_key` and `form_version`, both already nullable
today) serialises Elixir `nil` as JSON `null` with no special-casing, exactly the same
as every other nullable key already flowing through this function
(`correlation_key`, `form_version` are both `String.t() | nil` today and already prove
this path). No `case`, no `if task.form_schema do`, no conditional key omission is
needed or should be added — a conditional branch here would be an unstated,
unrequired divergence from the plain-`Map.put/3` idiom every other nullable key in this
function already uses.

AC2's "or omits it" alternative is explicitly not the chosen shape — `null` is, matching
existing precedent (`correlation_key`/`form_version` are never omitted when `nil`
either).

---

## 4. The version-pinning proof (AC3) — automatic, no additional mechanism

**Claim:** serving `task.form_schema` is automatically the version pinned to the task at
activation time, with no version-comparison, no snapshot re-fetch, and no new pinning
logic of any kind needed in this requirement.

**Proof, walked through against the actual schema:**

1. `tasks.form_schema` is written exactly once, at row-insertion time, by
   `Letflow.Engine.TaskActivation.insert_attrs/4` (`task_activation.ex:196-216`), which
   is only ever called from `append_multi/6` / `append_multi_from_existing_records/6`
   (task-activation paths, `EE-03`) — never from any completion, claim, assign, or
   reassign code path.

2. Grep-level confirmation that nothing ever `UPDATE`s the column after insertion:
   `lib/letflow/engine/task.ex` declares exactly three changesets over the `tasks`
   schema — `insert_changeset/2` (`task.ex:86-98`, casts `:form_schema` among seven
   fields), `complete_changeset/2` (`task.ex:106-111`, casts only `[:status,
   :output_variables, :completed_by, :completed_at, :cancelled_at]` — `:form_schema` is
   absent from this cast list), and `assignment_changeset/2` (`task.ex:121-127`, casts
   only `[:assignee_type, :assignee_ref]` — `:form_schema` is absent here too). A field
   not named in a changeset's `cast/3` allowlist cannot be written by that changeset,
   structurally (`Ecto.Changeset.cast/3`'s own contract) — so the only code path in this
   codebase that can ever set `tasks.form_schema` is `insert_changeset/2`, called exactly
   once, at row creation. There is no fourth changeset and no direct
   `Repo.update`/`Ecto.Query` `update:` clause anywhere in `lib/letflow/` that touches
   this column (confirmed by the full-repo `form_schema` grep in §0 — every hit is
   either the schema field declaration, the activation-time resolver/writer, this
   design's own read-path reference, or a moduledoc/comment prose mention; none is an
   `update`).

3. Given (1) and (2): `task.form_schema`, once read off any given task row at any
   later time, is *by construction* identical to the value written at that row's
   activation — there is no second write to overwrite it with. This is a stronger
   guarantee than typical "pinning" (which usually means "compare a live value against a
   stored version marker and prefer the stored one") — here there is no live value to
   compare against on the read path at all, because nothing downstream of activation
   ever mutates this column. Reading the column *is* reading the pinned value; there is
   no additional pinning mechanism to build because the database row itself already
   embodies the pin.

4. This also explains why REQ-273's own commit message states plainly (quoted in
   §1b's git-log excerpt): *"Version pinning needs no new machinery: the graph
   TaskActivation is always handed is already pinned to the instance's snapshot per
   REQ-126's own read-side precedent."* — REQ-273 pins the value once, at write time, by
   sourcing it from the version-pinned `graph` (`instance_definition_snapshots`, not a
   fresh `process_definitions` read — `task_activation.ex`'s own moduledoc, §"form_schema
   is a rendering payload only", last two sentences). REQ-286 (this requirement) inherits
   that pin for free on the read side, the same way `Letflow.Tasks.get_form_version/2`
   (REQ-126) is a *separate, still-live* join against `instance_definition_snapshots`
   because `form_version` is derived at *read* time from a table that is *not* the task
   row itself — whereas `form_schema` needs no such join, because it was already
   materialised onto the task row itself at write time. The two mechanisms differ (join
   vs. column) but land on the same guarantee (the served value matches the version
   active when the task was created), which is exactly what AC3's test (advance the
   definition after activation, assert the served schema is unchanged) is designed to
   demonstrate empirically.

**Open question this design does NOT need to resolve:** none — the reasoning above is
closed given the current changeset set. Flagged only as a watch-item for future
maintainers: if a future requirement ever adds a fourth `Task` changeset that includes
`:form_schema` in its cast list (e.g. some hypothetical "edit a pending task's form"
feature), that future requirement would silently break this pinning guarantee and must
re-derive this proof — this design does not attempt to guard against that in code (no
such changeset exists today, so there is nothing to guard against yet), it only names
the risk so ELIXIR-DEV/REVIEWER on that hypothetical future change know to re-check this
document.

---

## 5. Cross-tenant leak analysis (for SECURITY-REVIEWER — INV-1, INV-2, INV-5)

**Query path traced, end to end, for `GET /tasks/:id`:**

1. `Letflow.Plugs.AuthPipeline` (runs before `Letflow.Plugs.Authorize`, per
   `authorize.ex`'s own moduledoc "## Ordering") populates `conn.assigns.auth_context`
   from the caller's authenticated session/token — `user_id`, `tenant_id`, `roles`. The
   `tenant_id` here is server-derived from the authenticated credential, never a
   request body/query/path parameter.

2. `Letflow.Plugs.Authorize.call/2` (`plugs/authorize.ex:96-124`) — mounted
   unconditionally on every router using `Letflow.Api.AuthorizedRouter` (which
   `Letflow.Routers.Tasks` does, `tasks.ex:106`) — calls
   `Letflow.Api.Context.scoped_repo_opts(conn)`, which resolves `[prefix: schema]` from
   that same server-derived `tenant_id` (not shown in this design's read set verbatim,
   but its call contract is exercised at `authorize.ex:98`; `scoped_repo_opts/1` is out
   of this requirement's diff and unchanged by it). On success, this becomes
   `conn.assigns.scoped_opts` (`authorize.ex:122`) — the *only* `opts` value
   `handle_get_by_id/3` ever receives (`tasks.ex:125-127`, `conn.assigns.scoped_opts`
   passed positionally, no alternate code path).

3. `handle_get_by_id(conn, id, opts)` (`tasks.ex:279-290`) calls `Tasks.get_task(id,
   opts)`, which does `prefix = Keyword.fetch!(opts, :prefix)` (`tasks.ex:250`) and
   issues `Repo.one(query, prefix: prefix)` (`tasks.ex:267`) — the query itself
   (`tasks.ex:257-265`) is a plain `where: t.id == ^id` with no `tenant_id`/`instance_id`
   filter of its own; **all** tenant scoping is carried by the `prefix:` option alone,
   per Decision 0003 Dimension B (schema-per-tenant).

4. Per 0003 Dimension B, each tenant's `tasks` table lives in a *physically separate*
   Postgres schema (not a shared table partitioned by a `tenant_id` column — `tasks`
   carries no `tenant_id` column at all, confirmed by `Letflow.Engine.Task`'s own
   moduledoc section "No `tenant_id` column (Decision 0006 D2)"). A query issued with
   `prefix: "tenant_a"` can only ever resolve rows that physically exist inside
   `tenant_a`'s own Postgres schema — a task `id` that belongs to `tenant_b` simply does
   not exist as a row anywhere `tenant_a`'s prefixed query can see it, at the database
   engine level, not at an application-level filter that could have a bug in it.

5. Consequence for `form_schema` specifically: `form_schema` is not a separately-fetched
   value with its own scoping decision to get right — it is one column on the exact same
   struct (`t`, `tasks.ex:264`'s `select`) that `id`, `instance_id`, `node_id`, and every
   other already-exposed column come from, fetched via the exact same
   already-tenant-scoped `Repo.one(query, prefix: prefix)` call. There is no code path by
   which `task.form_schema` could be populated from a row this query didn't return — the
   struct handed to `task_detail_map/3` is the literal row `Repo.one/2` returned for
   *this* `prefix`, or the whole call already returned `{:error, :not_found}` before
   `task_detail_map/3` is ever invoked (`tasks.ex:267-268`: `nil -> {:error, :not_found}`).
   **A `form_schema` authored under one tenant can only ever be written to a task row
   physically stored in that tenant's own Postgres schema (by REQ-273's activation path,
   which itself runs inside that same tenant's already-`prefix`-scoped transaction — not
   examined further here since REQ-273's own SECURITY-REVIEWER pass covers the write
   side), and can only ever be read back through a query scoped to that same schema. There
   is no cross-tenant read path for this column to traverse, because there is no
   mechanism in this codebase (or in Postgres's own schema-search-path semantics) by which
   a `prefix: "tenant_a"` query could return a row that was physically inserted into
   `tenant_b`'s schema.**

6. **INV-1 (tenant data isolation):** satisfied — the query is `prefix`-scoped
   (`tasks.ex:267`), the scope is server-derived from the authenticated credential
   (`Authorize` plug, step 2), never caller-supplied, and `tasks` carries no `tenant_id`
   column to get out of sync (Decision 0006 D2). This requirement adds no new query and
   no new `prefix` derivation — it reads one more field off an already-correctly-scoped
   struct.

7. **INV-2 (server-side field authorisation):** satisfied by construction —
   `task_detail_map/3` remains a hand-built allowlist map (never `Jason.Encoder`/struct-
   wholesale encoding, per the moduledoc's own "Response allowlists" discipline this
   requirement's §6 rewrite preserves), and `form_schema`'s inclusion is a single
   explicit `Map.put/3` line reviewable in the diff — not a wildcard/struct-dump that
   could accidentally leak an unvetted field alongside it.

8. **INV-5 (not-found/forbidden indistinguishability):** unaffected by this change —
   `get_task/2`'s existing `{:error, :not_found}` branch (`tasks.ex:268`) is reached
   identically whether `id` doesn't exist anywhere or exists only in another tenant's
   schema (the moduledoc's own citation: "A cross-tenant `id` and a genuinely
   nonexistent `id` resolve through this same single code path to `{:error, :not_found}`
   — no branch exists that could tell them apart," `tasks.ex:237-241`). This requirement
   adds no new branch before or after that check, so the property is preserved
   unchanged — the added `Map.put/3` for `form_schema` executes only on the already-
   established success path, strictly after the not-found check has already passed.

**Net assessment for SECURITY-REVIEWER:** this change touches zero query logic, zero
authorization logic, and zero scoping logic. It reads one additional already-fetched,
already-tenant-scoped struct field into an already-tenant-scoped response map. The
cross-tenant question the requirement specifically flags ("whether a form_schema
authored in one tenant can ever be served to another") reduces to the same schema-per-
tenant guarantee every other field in this response already relies on — this design
finds no distinct new risk surface `form_schema` introduces beyond what `id`/
`node_name`/`assignee_ref`/every other existing key already carries.

---

## 6. Moduledoc rewrite (AC5) — replacement text

### 6a. Primary replacement — `lib/letflow/routers/tasks.ex`'s "Response allowlists" section

The paragraph quoted in §1c (`tasks.ex:86-95`) is replaced with the following prose
(ELIXIR-DEV: this is the literal replacement text, to be inserted verbatim as the new
moduledoc paragraph — not further paraphrased):

> `task_list_item_map/2` (11 keys) / `task_detail_map/3` (14 keys, adds
> `correlation_key`/`updated_at`/`form_schema`) are hand-built maps, never a
> `Jason.Encoder`/struct-wholesale encoding — matching `Letflow.Routers.Identity`'s
> `user_map/1` discipline exactly. `claimed_by` is omitted entirely (no Letflow schema
> column exists yet — REQ-085's own concern). `output_variables`/`completed_by`/
> `completed_at`/`cancelled_at` remain excluded — none is named by any REQ-083 or
> REQ-286 acceptance criterion. `form_schema` (REQ-286) is exposed on the task-detail
> response only, not on `task_list_item_map/2` (so `GET /tasks`/`GET /tasks/inbox` do
> not carry it) — sourced directly from the task's own `form_schema` column, which
> `Letflow.Engine.TaskActivation` (REQ-273) populates once, at activation, from the
> node's `form_schema` attribute in the version-pinned graph the instance was created
> or last promoted against. No `Task` changeset ever writes this column a second time
> (`insert_changeset/2` is the only one that casts it), so reading the column back is
> automatically the version pinned at activation — no live re-fetch of the current
> process definition, and no additional pinning mechanism, is involved. `null` is
> served, not omitted, when a task's node carries no `form_schema` (the common case
> until definitions start authoring one). This requirement introduces no validation of
> submitted task-completion output against this schema; `variable_schemas` (REQ-109)
> remains the sole server-side validation authority — `form_schema` here is a rendering
> payload only, never fed into `Letflow.Engine.VariableMerge` or any output-variable
> check.

### 6b. Secondary correction — the `#` comment above `task_list_item_map/2` (`tasks.ex:520-522`)

Replaced with:

> `# inserted_at/updated_at are deliberately excluded from this function (see`
> `# moduledoc, design §5.5); tasks.form_schema is likewise excluded from this`
> `# function specifically -- it is exposed only on task_detail_map/3's output`
> `# (REQ-286), not here, so GET /tasks and GET /tasks/inbox do not carry it.`

### 6c. `task_detail_map/3`'s own `@doc false` comment (`tasks.ex:545-548`)

The existing comment ("Same eleven keys as task_list_item_map/2, plus correlation_key
and updated_at -- thirteen keys total.") is updated to state fourteen keys and name
`form_schema` as the third addition, for the same internal-consistency reason as §1c —
ELIXIR-DEV should not leave a stale key count sitting directly above the function it
describes.

---

## 7. Scope-fence confirmation (AC6, AC7)

- **No validation wiring introduced.** This design adds exactly one read (`Map.put/3`
  reading `task.form_schema`) to one existing function (`task_detail_map/3`). No call to
  `Letflow.Definitions.JsonSchemaShape`, `Letflow.Engine.VariableMerge`, or
  `Letflow.Engine.VariableSchema` (REQ-109's module) appears anywhere in this design.
  `variable_schemas` (REQ-109, `lib/letflow/engine/variable_schema.ex`) remains the sole
  server-side validation authority for task-completion output, exactly as its own
  moduledoc already states and as REQ-273's moduledoc already confirmed for the write
  side ("this module does not, and must never, feed it into `Letflow.Engine.VariableMerge`
  or any output-variable validation path" — `task_activation.ex:48-51`, restated for the
  read side in §6a's replacement text above). ELIXIR-DEV's own post-implementation grep
  (AC6) should confirm zero new references to those modules in the diff.
- **No file under `web/` is touched.** This design's only file targets are
  `lib/letflow/routers/tasks.ex` (the `task_detail_map/3` body, the two moduledoc/comment
  edits in §6) and its accompanying test file(s) under `test/letflow/routers/` (per
  TEST-DESIGNER, out of this design's scope). Nothing in `web/src/components/forms/
  DynamicFormRenderer.tsx` or any other frontend path is named as a target — the
  requirement's own description explicitly notes that component "still receives
  nothing" today and that wiring it up is not this requirement's job. ELIXIR-DEV's `git
  diff --stat` (AC7) should show no `web/` path.

---

## 8. Summary of changes for ELIXIR-DEV

| File | Change |
|---|---|
| `lib/letflow/routers/tasks.ex` | `task_detail_map/3` body: add one `Map.put("form_schema", task.form_schema)` to the existing pipe chain. No signature change. |
| `lib/letflow/routers/tasks.ex` | Moduledoc "Response allowlists" paragraph (`tasks.ex:86-95`): replace per §6a. |
| `lib/letflow/routers/tasks.ex` | `#` comment above `task_list_item_map/2` (`tasks.ex:520-522`): replace per §6b. |
| `lib/letflow/routers/tasks.ex` | `@doc false` comment above `task_detail_map/3` (`tasks.ex:545-548`): update key count 13→14, name `form_schema`, per §6c. |

No migration, no new query, no new join, no changes to `lib/letflow/tasks.ex`, no
changes to `lib/letflow/engine/task_activation.ex` or `lib/letflow/engine/task.ex`, no
changes to `task_list_item_map/2`'s key set, no changes under `web/`.

## 9. Open questions

None. Every acceptance criterion (AC1-AC8) maps to a concrete element above: AC1→§2,
AC2→§3, AC3→§4, AC4→§5 (SECURITY-REVIEWER handoff content), AC5→§6, AC6→§7, AC7→§7,
AC8 (`mix letflow.check`) is a TEST-RUNNER/ELIXIR-DEV execution step, not a design
element, and is not blocked by anything in this design.
