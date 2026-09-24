# Design: Frontend Wire-Type Corrections (ISS-0815 / ISS-0814 / ISS-0811 / ISS-0809)

> **Retroactive design artefact** — implementations were committed to `main` before this
> document was written (WF-03 retroactive run
> `WF03-BATCH-ISS0809-ISS0811-ISS0814-ISS0815-20260925`).  This document records the
> interface decisions and design rationale that the downstream validators
> (CODE-DESIGN-VALIDATOR, SECURITY-REVIEWER, REVIEWER) need to evaluate the commits.
>
> Implementation commits: ISS-0815 → `a03230be`, ISS-0814 → `36e584d3`,
> ISS-0811 → `8acde894`, ISS-0809 → `4424a6a7`.

---

## 0. Scope

All four issues belong to the same defect class: a TypeScript interface in
`web/src/types/api.ts` declared required fields that the backend never emits (or
declared wrong values for fields it does emit), so every consumer was silently reading
`undefined` or comparing against a value that could never match.  No backend logic
changed in these fixes; only `web/src/types/api.ts` and the pages that consumed the
wrong types were corrected.

Files changed across all four fixes:

| File | Issues |
|---|---|
| `web/src/types/api.ts` | ISS-0815, ISS-0814, ISS-0811, ISS-0809 |
| `web/src/pages/admin/UserDetailPage.tsx` | ISS-0814 |
| `web/src/pages/admin/UsersPage.tsx` | ISS-0814 |
| `web/src/pages/admin/GroupsPage.tsx` | ISS-0811 |
| `web/src/pages/instances/InstanceDetailPage.tsx` | ISS-0809 |

---

## 1. Wire Shape: `User` (ISS-0815 + ISS-0814)

### 1.1 Backend source of truth — `user_map/1`

`lib/letflow/routers/identity.ex` (lines ~729–740) hand-builds the response map:

```
@spec user_map(Letflow.Identity.User.t()) :: map()
defp user_map(%Letflow.Identity.User{} = user) do
  %{
    "id"           => user.id,
    "username"     => user.username,
    "display_name" => user.display_name,
    "email"        => user.email,
    "status"       => Atom.to_string(user.status),
    "auth_source"  => Atom.to_string(user.auth_source),
    "inserted_at"  => iso8601(user.inserted_at),
    "updated_at"   => iso8601(user.updated_at)
  }
end
```

Exactly **8 keys**.  `password_hash`, `external_id`, `external_realm`, `roles`,
`created_at`, and `is_active` are not present.  The timestamp key is `inserted_at`,
not `created_at`.

### 1.2 What was wrong before

| Field | Old declaration | Problem |
|---|---|---|
| `roles` | `roles: string[]` (required) | Never emitted; first `.map()` call throws |
| `created_at` | `created_at: string` (required) | Field does not exist on the wire; `inserted_at` is the correct key |
| `status` | `status?: 'ACTIVE' \| 'INACTIVE'` (uppercase) | Wire value is `"active"` / `"inactive"`; every `=== 'ACTIVE'` comparison is permanently `false`; status writes fail 422 (see §2) |

TypeScript could not catch these because required fields with wrong values are a value
mistake, not a type-shape mistake; `tsc` only checks structural assignability.

### 1.3 Corrected `User` interface

```typescript
export interface User {
  // Required fields — exactly what user_map/1 emits
  id: string
  username: string
  display_name: string
  email: string
  status: 'active' | 'inactive'          // ISS-0814: lowercase, matches Ecto.Enum
  auth_source: string
  inserted_at: string                     // ISS-0815: was created_at (wrong key)
  updated_at: string

  // Optional legacy / caller-set fields (NOT emitted by user_map/1)
  user_id?: string
  is_active?: boolean
  roles?: string[]                        // ISS-0815: was required; never sent by backend
  role_ids?: string[]
  group_ids?: string[]
  last_login_at?: string
}
```

**Decision: `roles` stays in the interface as optional.**  Several write-path callers
(`usersApi.create`, `usersApi.update`) set `role_ids` rather than `roles`; keeping
`roles?: string[]` preserves the existing optional-field call sites without requiring a
cascading rename, while removing the dangerous required claim that causes runtime
throws.  If a future requirement adds `roles` to `user_map/1`'s output it must be
tracked in a separate requirement and the optional status should be re-evaluated at
that time.

**Decision: `inserted_at` replaces `created_at`.**  No web/ code was reading
`user.created_at` before the fix (it would have silently been `undefined`);
`UsersPage.tsx`'s `Created` column now reads `u.inserted_at`.  The backend has no
`created_at` key on users and no migration is planned to add one.

### 1.4 AC mapping

| AC | Design element |
|---|---|
| User matches what `user_map/1` actually emits | §1.3 required-field list = 8 keys from `user_map/1` |
| Every required field is one the backend sends | Each required field is drawn verbatim from `user_map/1`'s map literal |
| Timestamp field web/ reads is `inserted_at` | `inserted_at: string` in required section; `created_at` removed |
| `roles` removed or backend emits it | `roles` demoted to optional; backend does not emit it |
| `npm run type-check` passes | Removal of required-missing fields eliminates phantom type errors |
| Wire-shape test added | `web/src/api/__tests__/identity.wire-shape.test.ts` added in commit `a03230be` |

---

## 2. Status Casing Decision (ISS-0814)

### 2.1 Canonical casing: lowercase

The authoritative casing is **lowercase** (`"active"` / `"inactive"`), which is the
value the backend has always emitted and validated.  The path through the backend is:

```
Ecto.Enum field  [:active, :inactive]
     ↓
user_map/1       Atom.to_string(user.status)   → "active" / "inactive"
     ↓
parse_status_param/1  accepts only "active"/"inactive" → :status_invalid (422) otherwise
     ↓
@status_schema   allows only ["active", "inactive"]
```

There is no `String.upcase` anywhere in `routers/identity.ex` or `identity.ex`.

### 2.2 UI display

`UsersPage.tsx`'s status column renders the badge label as `'ACTIVE'` / `'INACTIVE'` for
user-facing display, but it derives those labels from a comparison against the wire
value:

```typescript
{u.status === 'active' ? 'ACTIVE' : 'INACTIVE'}
```

The display text is uppercase; the wire comparison is lowercase.

### 2.3 Write path

`UserDetailPage.tsx` holds status in local React state as the **UI-facing** strings
`'ACTIVE'` / `'INACTIVE'` (to drive the `<select>` control).  Before submitting, it
converts to the canonical lowercase wire value:

```typescript
status: status.toLowerCase() as 'active' | 'inactive'
```

This is the correct pattern: UI state may use any display string, but the wire layer
always sends lowercase.

### 2.4 Detail page seed fix

`UserDetailPage.tsx`'s `useEffect` now seeds the `status` state from the fetched
user's real status, using a bridge function `userStatus(user)`:

```typescript
function userStatus(user: User): 'ACTIVE' | 'INACTIVE' {
  if (user.status === 'active') return 'ACTIVE'
  if (user.status === 'inactive') return 'INACTIVE'
  return user.is_active ? 'ACTIVE' : 'INACTIVE'
}
```

The fallback through `is_active` is a defensive legacy guard; new code should rely
exclusively on the lowercase `user.status` field.

### 2.5 `AdminUserFilters` (filter writes)

Any filter query sending `status=ACTIVE` would have received a 422 from
`parse_status_param/1`.  The filter was corrected to send lowercase values, matching
the schema's allowed list.

### 2.6 AC mapping

| AC | Design element |
|---|---|
| One canonical casing chosen and recorded | §2.1: lowercase is canonical |
| `User.status` matches backend wire value | `status: 'active' \| 'inactive'` in `User` |
| `UserDetailPage` status control reflects fetched user's real status | §2.4: `useEffect` seeds from `userStatus(user)` |
| Test asserts exact wire casing in both directions | `web/src/api/__tests__/identity.wire-shape.test.ts` in commit `36e584d3` |

---

## 3. `Group` Wire Shape and Members Column Removal (ISS-0811)

### 3.1 Backend source of truth — `group_map/1`

`lib/letflow/routers/identity.ex` (lines ~748–756):

```
@spec group_map(Letflow.Identity.Group.t()) :: map()
defp group_map(%Letflow.Identity.Group{} = group) do
  %{
    "id"           => group.id,
    "name"         => group.name,
    "display_name" => group.display_name,
    "description"  => group.description,
    "created_at"   => iso8601(group.inserted_at)
  }
end
```

Exactly **5 keys**.  `is_system` and `member_count` are not present.

**Note:** `group_map/1` uses `"created_at"` (not `"inserted_at"`) as the timestamp key.
This matches the current `Group` interface's `created_at: string` field.

### 3.2 What was wrong before

| Field | Old declaration | Problem |
|---|---|---|
| `is_system` | `is_system: boolean` (required) | Never emitted; always `undefined` on wire |
| `member_count` | `member_count?: number` (optional) | Never emitted; `GroupsPage.tsx` Members column rendered `0` (undefined coerced to number in the column accessor) |

### 3.3 Corrected `Group` interface

```typescript
export interface Group {
  id: string
  name: string
  display_name: string
  description?: string
  created_at: string

  // Optional legacy fields (NOT emitted by group_map/1)
  group_id?: string
  is_system?: boolean       // ISS-0811: was required; never sent by backend
  member_count?: number     // ISS-0811: never sent; column removed
}
```

### 3.4 Members column removal rationale

`GroupsPage.tsx`'s `DataTable` previously had a column:

```typescript
{ id: 'members', header: 'Members', accessor: (g) => g.member_count ?? 0 }
```

Because `member_count` is never sent by `group_map/1`, this column always showed `0`
for every group — a silent data lie rather than an error.

**Decision: column removed.**  Adding `member_count` to `group_map/1` would require
an aggregate query (`COUNT(group_memberships WHERE group_id = ...)`) on every list
response — a non-trivial backend change that is a separate tracked requirement, not a
bug fix.  Showing a permanent `0` is worse UX than showing no column.  The column is
removed; real member counts are available to the user by opening the "Manage members"
dialog, which fetches the actual member list from
`GET /api/v1/identity/groups/:id/members`.

### 3.5 Delete button condition fix

The old Delete button was conditionally shown based on `!group.is_system && !group.member_count`.
Since neither field is emitted, that condition was always `true` (both `undefined`, so
`!undefined && !undefined` = `true`), meaning the button was always rendered.  This was
not a functional regression (the backend enforces any deletion constraints), but the
condition was semantically dead code.

**Decision: condition removed.**  The Delete button is now shown unconditionally.
Backend-side deletion constraints remain the enforcement point.

### 3.6 AC mapping

| AC | Design element |
|---|---|
| Members column shows real count or is removed | §3.4: column removed; rationale documented |
| `Group` type matches `group_map/1` | §3.3: required fields = exactly 5 keys from `group_map/1` |
| No required field the server never sends | `is_system` and `member_count` demoted to optional |
| Test covers rendered member count | Regression test in commit `8acde894` |

---

## 4. Cancel Dialog Definition Name Fix (ISS-0809)

### 4.1 Backend source of truth — `instance_map/1`

`lib/letflow/routers/instances.ex` (GET /instances/:id response):

```
defp instance_map(projection) do
  %{
    "instance_id"    => projection.instance_id,
    "definition_id"  => projection.definition_id,
    "correlation_key"=> projection.correlation_key,
    "status"         => status_string(projection.status),
    "variables"      => projection.variables,
    "started_at"     => DateTime.to_iso8601(projection.started_at),
    "completed_at"   => optional_iso8601(projection.completed_at),
    "cancelled_at"   => optional_iso8601(projection.cancelled_at),
    "error_detail"   => projection.error_detail
  }
end
```

`definition_name` and `definition_version` are **not** emitted.  Only
`definition_id` is present on a `GET /instances/:id` response.

### 4.2 What was wrong before

`ProcessInstance` declared:

```typescript
definition_name: string      // required — never on the wire
definition_version: string   // required — never on the wire
```

`InstanceDetailPage.tsx` (line 366, pre-fix) built the dialog's `instanceName` prop as:

```typescript
instanceName={`${instance.definition_name} v${instance.definition_version}`}
// → "undefined v undefined" at runtime
```

A prior commit (`cb3c6c49`) had already fixed the *detail row* by using `definition`
from `useDefinition(instance?.definition_id)`, but the *Cancel dialog* prop was missed.

### 4.3 Corrected `ProcessInstance` interface

```typescript
export interface ProcessInstance {
  instance_id: string
  definition_id: string
  // definition_name and definition_version NOT emitted by GET /instances/:id (ISS-0809)
  definition_name?: string
  definition_version?: string
  correlation_key?: string
  status: InstanceStatus
  current_nodes: string[]
  current_tokens?: Token[]
  active_tokens?: Token[]
  updated_at?: string
  current_tasks?: Task[]
  definition_snapshot?: DefinitionGraph
  variables: Record<string, unknown>
  error_detail?: Record<string, unknown>
  started_at: string
  completed_at?: string
  cancelled_at?: string
}
```

### 4.4 Cancel dialog fix

The correct data source for the Cancel dialog's `instanceName` prop is the same
`useDefinition(instance?.definition_id)` result that the detail-row fix already uses:

```typescript
const { data: definition } = useDefinition(instance?.definition_id ?? '')

// ...

<CancelInstanceDialog
  instanceName={definition ? `${definition.name} v${definition.version}` : '—'}
  ...
/>
```

The `'—'` placeholder renders while the definition fetch is in flight (or if it fails).
This is the correct UX behaviour: a neutral em-dash rather than a misleading literal
string `"undefined v undefined"`.

**This is the same pattern already established by `cb3c6c49`** for the detail row —
the fix makes the Cancel dialog consistent with the established pattern, not an
independent new approach.

### 4.5 AC mapping

| AC | Design element |
|---|---|
| Cancel dialog shows real name/version | §4.4: sourced from `useDefinition(instance?.definition_id)` |
| `ProcessInstance` no longer promises optional fields as required | §4.3: `definition_name?` / `definition_version?` |
| `npm run type-check` passes | Removing required-never-sent fields eliminates phantom errors |
| Test covers Cancel dialog rendered instance name | Test added in commit `4424a6a7` |

---

## 5. `@spec` Annotations and TypeScript Interface Summaries

All changes are in `web/src/types/api.ts` (TypeScript) and in existing Elixir
`@spec` annotations in `lib/letflow/routers/identity.ex` and
`lib/letflow/routers/instances.ex`.  No Elixir `@spec` lines changed in these
commits (the backend was not touched).  The relevant backend specs for reference:

```elixir
# lib/letflow/routers/identity.ex
@spec user_map(Letflow.Identity.User.t()) :: map()   # 8 keys, see §1.1
@spec group_map(Letflow.Identity.Group.t()) :: map()  # 5 keys, see §3.1

# lib/letflow/routers/instances.ex
# instance_map/1 has no @spec, but emits 9 keys (see §4.1); no @spec change needed
```

### TypeScript interface signatures (post-fix)

```typescript
// User — matches user_map/1 exactly (ISS-0815, ISS-0814)
interface User {
  id: string; username: string; display_name: string; email: string
  status: 'active' | 'inactive'   // lowercase, Ecto.Enum atom
  auth_source: string
  inserted_at: string; updated_at: string
  user_id?: string; is_active?: boolean; roles?: string[]
  role_ids?: string[]; group_ids?: string[]; last_login_at?: string
}

// Group — matches group_map/1 exactly (ISS-0811)
interface Group {
  id: string; name: string; display_name: string
  description?: string; created_at: string
  group_id?: string; is_system?: boolean; member_count?: number
}

// ProcessInstance — definition_name/version marked optional (ISS-0809)
interface ProcessInstance {
  instance_id: string; definition_id: string
  definition_name?: string; definition_version?: string   // NOT in instance_map/1
  // ... remainder unchanged
}
```

---

## 6. Root Cause Pattern

All four issues share the same defect class (same as ISS-0745):

> A TypeScript interface in `web/src/types/api.ts` declares a field as required (or
> declares a value domain that does not match the backend) when no backend serializer
> emits that field (or emits it with a different value).  TypeScript's structural
> assignability check does not catch this because `tsc` verifies that a value *can be
> assigned to* a type, not that a runtime JSON response *will* satisfy it.

The systemic fix is tracked in ISS-0813 (add a wire-shape coupling mechanism so
`user_map/1` and the `User` interface cannot drift apart again).  Each of these four
issues adds a targeted regression test as a near-term guard.

---

## 7. Open Questions

None.  All four issues are purely corrective (aligning the frontend type with an
already-stable backend wire shape).  No backend migrations, no new routes, no new
backend behaviour is required.  The backend wire shapes documented in §1.1, §3.1, and
§4.1 are the stable sources of truth and did not change in these commits.
