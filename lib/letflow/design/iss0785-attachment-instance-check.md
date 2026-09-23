# Design: ISS-0785 — Thread `instance_id` into `get_content/2`

**Issue:** ISS-0785  
**Status:** DESIGN  
**Author:** CODE-DESIGNER (WF03-ISS0785-20260923)  
**Related requirements:** REQ-211, REQ-212  
**Affected files (primary):** `lib/letflow/repository/attachments.ex`  
**Affected files (call site):** `lib/letflow/routers/instances.ex`  

---

## 1. Problem summary

`get_content/2` in `Letflow.Repository.Attachments` reads the full
`repository_artifacts.content` blob unconditionally whenever the
`instance_attachments` metadata row exists in the tenant schema —
regardless of which instance that row belongs to. The instance-ownership
check occurs in `fetch_scoped_attachment_content/3` in instances.ex
**after** `get_content/2` returns, causing a cross-instance-same-tenant
denial to cost 2 Repo round-trips while a cross-tenant or never-issued
denial costs 1 — a timing distinguisher between two denial classes that
REQ-211/REQ-212 (EO-001/EO-002) explicitly intend to be indistinguishable.

---

## 2. Modified `get_content/3` — public function signature

```
@spec get_content(id :: String.t(), instance_id :: Ecto.UUID.t(), opts()) ::
        {:ok, Attachment.t(), Artifact.t()}
        | {:error, :invalid_id | :not_found | :content_missing | :not_available}
```

**Parameters:**

| Name | Type | Description |
|---|---|---|
| `id` | `String.t()` | Raw (uncast) attachment UUID from the URL path segment |
| `instance_id` | `Ecto.UUID.t()` | Already-validated instance UUID from the request context (assured cast-valid by the time this is called; see §4) |
| `opts` | `keyword()` | Must contain `prefix: schema_name` (tenant schema); same shape as the existing `opts()` type alias used throughout this module |

**Return values:** identical to the existing `get_content/2` return shape — no new error atoms introduced. `:not_found` is the unified denial atom for: invalid UUID, non-existent row, cross-tenant row (nil Repo result), and cross-instance-same-tenant mismatch.

**Note:** `get_content/2` → `get_content/3` is an arity change only at the module boundary. The `EntityAttachments.get_content/2` sibling in `lib/letflow/repository/entity_attachments.ex` is a separate module with a different contract and is **not affected** by this fix.

---

## 3. New private `check_instance_match/2`

```
@spec check_instance_match(Attachment.t(), Ecto.UUID.t()) ::
        :ok | {:error, :not_found}
```

**Inputs:**

| Name | Type | Description |
|---|---|---|
| `attachment` | `Attachment.t()` | Already-fetched metadata struct (result of `get/2` inner step) |
| `instance_id` | `Ecto.UUID.t()` | Validated instance UUID from caller context |

**Outputs:**

- `:ok` — `attachment.instance_id == instance_id` (same-instance, pass through)  
- `{:error, :not_found}` — `attachment.instance_id != instance_id` (cross-instance denial, indistinguishable from all other denial paths)

**Implementation shape (signatures only, no body):** Two function heads over `%Attachment{instance_id: instance_id}` — one matching the passed `instance_id` (returns `:ok`) and one catch-all (returns `{:error, :not_found}`). Pattern matches on the struct field directly, consistent with `check_scan_status_clean/1`'s own shape in this module.

---

## 4. Updated `with` chain in `get_content/3`

**Revised chain order:**

```
get(id, opts)                            # step 1 — metadata lookup + tenant scope
→ check_instance_match(attachment, instance_id)  # step 2 — NEW, before blob read
→ check_scan_status_clean(attachment)    # step 3 — scan gate (unchanged)
→ Repo.get(Artifact, content_hash, ...)  # step 4 — blob read (unchanged)
```

**Key ordering constraint:** `check_instance_match/2` is inserted **between** the metadata fetch (step 1) and the scan gate (step 3). Placing it before the scan gate is intentional and required: a cross-instance attachment should not reveal scan status (that would be a different side-channel distinguisher). The denial for cross-instance `:not_found` must be structurally indistinguishable from the metadata-miss `:not_found` at step 1.

**No blob read occurs** when `check_instance_match/2` returns `{:error, :not_found}` — the `with` chain short-circuits before step 4. This collapses the cross-instance case to the same 1-round-trip cost as the cross-tenant/never-issued cases (INV-5 preserved, §6).

---

## 5. Call site change in `instances.ex`

### 5a. `fetch_scoped_attachment_content/3`

**Current call:**
```
Attachments.get_content(raw_attachment_id, opts)
```

**Updated call:**
```
Attachments.get_content(raw_attachment_id, instance_id, opts)
```

`instance_id` is already available at this call site — it is cast and
bound earlier in the same `with` chain in both callers
(`handle_get_attachment_content/3` at ~line 1139, and
`handle_get_attachment_link_content/3` at ~line 1309), and is passed
into `fetch_scoped_attachment_content/3` as its second parameter. No
new data flow is required.

### 5b. Decision on the redundant pattern match

**Current downstream match in `fetch_scoped_attachment_content/3`:**
```elixir
{:ok, %Attachment{instance_id: ^instance_id} = attachment, artifact} ->
  {:ok, attachment, artifact}

{:ok, %Attachment{}, _artifact} ->
  {:error, :not_found}
```

**Decision: KEEP as defense-in-depth.**

**Rationale:**
1. The pin-match (`^instance_id`) now redundantly rechecks what
   `check_instance_match/2` already enforced inside `get_content/3`.
   It can never fire the second branch (cross-instance `{:ok, %Attachment{}, _artifact}`)
   after the fix — `get_content/3` will have already returned
   `{:error, :not_found}` for that case.
2. However, removing it would widen the surface that a future caller
   of `get_content/3` (with a different instance_id argument) might
   misuse. Keeping the explicit pin-match in the router ensures that
   even if a future refactor accidentally passes the wrong
   `instance_id` to `get_content/3`, the router layer will still
   catch a mismatched return and deny it — defense-in-depth per
   the project's invariant model.
3. The match imposes zero additional Repo cost — it is a pure Elixir
   pattern match on an already-returned struct.
4. The second branch (`{:ok, %Attachment{}, _artifact} ->`) is now
   structurally dead code — document it as an explicit dead branch that
   exists for defense-in-depth, not as live logic. ELIXIR-DEV should
   add a comment stating it cannot fire after the fix, so future
   readers don't remove it thinking it's an oversight.

---

## 6. Invariants preserved

### INV-5 — Response shape indistinguishability (REQ-211/212 EO-001/EO-002)

All four denial categories converge to `{:error, :not_found}` at exactly **1 Repo round-trip**:

| Denial class | Repo cost (before fix) | Repo cost (after fix) |
|---|---|---|
| Never-issued UUID (cast fails) | 0 trips (UUID cast error) | 0 trips (unchanged) |
| Cross-tenant (nil Repo result) | 1 trip (metadata fetch → nil) | 1 trip (unchanged) |
| Cross-instance-same-tenant (attachment found, wrong instance) | **2 trips** (metadata + blob read) | **1 trip** (metadata + early exit via `check_instance_match`) |
| `:invalid_id` folded to `:not_found` at call site | 0 trips | 0 trips (unchanged, `invalid_id` not surfaced past `get_content`) |

After the fix, all denial paths that reach a metadata-row result cost exactly 1 Repo round-trip. The timing distinguisher between "exists in my tenant, wrong instance" and "doesn't exist / wrong tenant" is eliminated.

### Same-instance valid access path (INV-RT-1 / scan gate)

A valid same-instance request still follows the full chain: metadata fetch → instance match (`:ok`) → scan gate → blob read. No regression to the happy path.

### `get/2` unchanged

`get/2` (used by routes that only need metadata — DELETE, list) keeps its existing 2-argument `@spec`. It has no concept of `instance_id`. The instance-ownership check for DELETE paths continues to live in `fetch_scoped_attachment_metadata/3` in instances.ex (same pattern-match shape as before, not affected by this fix since metadata-only paths never read the blob).

---

## 7. Tests requiring updates

The following test call sites use `get_content/2` and will need to be updated to `get_content/3` by passing a matching `instance_id` as the second argument:

| File | Describe/test description | Change needed |
|---|---|---|
| `test/letflow/repository/attachments_test.exs` | `"a non-EICAR upload gets scan_status: :clean and its content is fetchable via get_content/2"` | Pass `attachment.instance_id` as second arg |
| `test/letflow/repository/attachments_test.exs` | `"a :pending row … is rejected with {:error, :not_available}"` | Pass `pending_attachment.instance_id` as second arg |
| `test/letflow/repository/attachments_test.exs` | `"an :infected row … is rejected with {:error, :not_available}"` | Pass `infected_attachment.instance_id` as second arg |

**New tests to add** (by ELIXIR-DEV/TEST-DESIGNER in their respective steps):
- `get_content/3` with a mismatched `instance_id` (same tenant, different instance) → `{:error, :not_found}`, and no artifact blob is fetched (assert via query-count or absence of content side-effect)
- The new test should confirm the cross-instance case costs 1 Repo query, not 2 (use `Ecto.Adapters.SQL.Sandbox` query-logging or equivalent)

**`EntityAttachments` tests** (`test/letflow/repository/entity_attachments_test.exs`): no changes — `EntityAttachments.get_content/2` is a separate module unaffected by this fix.

---

## 8. Acceptance criteria mapping

| AC from ISS-0785.yaml (task.acceptance_criteria) | Design element |
|---|---|
| `get_content/3` signature fully specified with @spec-style types | §2 — full `@spec` with all three parameters and all return-atom variants |
| `check_instance_match/2` signature and return types specified | §3 — full `@spec` with `:ok \| {:error, :not_found}` |
| `with` chain order: `get/2 → check_instance_match/2 → check_scan_status_clean/1 → Repo.get` blob | §4 — chain order explicitly stated and rationale for position given |
| instances.ex call site change described | §5a — updated call with `instance_id` sourced from existing parameter |
| Decision on redundant pattern match documented | §5b — KEEP, with defense-in-depth rationale and note about now-dead branch |
| INV-5 preservation argument stated | §6 — table showing all four denial classes collapse to 1 Repo round-trip |
| No implementation code in design doc (signatures and shapes only) | This document — no function bodies, no `.ex` code blocks |
| Every AC from ISS-0785.yaml maps to a design element | This table |

---

## 9. Open questions

None. All design decisions are fully resolved. ELIXIR-DEV may proceed directly to implementation.

---

## 10. Concurrent-run note (WF02-REQ388-20260923)

REQ-388 adds audit-log writes inside `fetch_scoped_attachment_content/3` **after** the `get_content` call returns, triggering on denied branches. This fix reorders work that happens **inside** `get_content` before it returns. The two changes are logically independent: REQ-388's audit write always fires post-return at the router layer; this fix's instance-check fires pre-blob-read inside the context module. No design conflict. ELIXIR-DEV will rebase onto `main` at Step Final to incorporate REQ-388's merged changes before completing the fix.
