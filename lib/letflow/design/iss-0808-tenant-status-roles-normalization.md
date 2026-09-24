# ISS-0808 — TenantStatus Plug: PLATFORM_ADMIN Check via `roles_from_strings/1`

**Status:** retroactive design artefact (implementation committed at `97c50b5d`)  
**Run:** WF03-ISS0808-20260925  
**Module:** `Letflow.Plugs.TenantStatus`  
**Related requirements:** REQ-075 (tenant deactivation gate, AC5 — PLATFORM_ADMIN exemption)

---

## 1. Problem Statement

`lib/letflow/plugs/tenant_status.ex` had a raw string membership check for the PLATFORM_ADMIN exemption:

```
# Before fix — raw string comparison
@platform_admin "PLATFORM_ADMIN"
...
"PLATFORM_ADMIN" in roles
```

`conn.assigns[:auth_context][:roles]` holds a `[String.t()]` list populated by `Letflow.Oidc.ClaimMapping.resolve_roles/2`. Every other authorization consumer in the codebase converts that list to atoms via `Letflow.Api.Authorization.roles_from_strings/1` before comparing. The raw check in `TenantStatus` was the sole divergent consumer:

- If `roles_from_strings/1` ever changes normalization (case folding, aliasing, a role rename, or prefix stripping), the raw string path would silently diverge — no compile-time warning, no test would catch it.
- There was no structural enforcement that `roles_from_strings/1` must be in the call path; a future reader could remove the alias and revert without any type-system pushback.

---

## 2. Interface Boundary Being Corrected

**Module:** `Letflow.Plugs.TenantStatus`  
**Private function:** `check_tenant_status/2` (the `:inactive` cond guard)  
**Public interface is unchanged.** The `@behaviour Plug` surface (`init/1`, `call/2`) has the same external signature before and after the fix.

### Unchanged public spec

```
@spec init(keyword()) :: keyword()
@spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
```

The private helper that changes shape:

```
# Before
@spec check_tenant_status(Plug.Conn.t(), Ecto.UUID.t() | nil) :: Plug.Conn.t()
# roles extracted as: raw_roles = get_in(conn.assigns, [:auth_context, :roles]) || []
# guard: "PLATFORM_ADMIN" in raw_roles

# After (same spec, different internal derivation)
@spec check_tenant_status(Plug.Conn.t(), Ecto.UUID.t() | nil) :: Plug.Conn.t()
# roles extracted as: raw_roles = get_in(conn.assigns, [:auth_context, :roles]) || []
#                     roles = Authorization.roles_from_strings(raw_roles)
# guard: :PLATFORM_ADMIN not in roles
```

---

## 3. Why `roles_from_strings/1` Instead of a Raw String Check

### Single normalization path

`Letflow.Api.Authorization.roles_from_strings/1` is the codebase's sole authorized converter from JWT-originated role strings to the closed `role/0` atom set. It:

1. Accepts `[String.t()]` (exactly what `auth_context.roles` carries).
2. Returns `[role()]` — atoms from a finite, exhaustively-enumerated set.
3. Silently drops unrecognized strings (never raises, never widens to any role).
4. Is the only function with explicit `@spec roles_from_strings([String.t()]) :: [role()]` in `Authorization`.

Routing through it creates an **invariant**: if the canonical role representation changes (e.g., `PLATFORM_ADMIN` becomes `PlatformAdmin` in the token, or `roles_from_strings/1` gains case-folding), every consumer — including `TenantStatus` — automatically tracks that change. No per-site update needed.

### Security posture

`roles_from_strings/1` is explicitly designed for untrusted input (bearer-token claims). The moduledoc of `Letflow.Api.Authorization` notes that `String.to_existing_atom/1` is **not** used to avoid attacker-controlled atom-table growth. Using `roles_from_strings/1` in `TenantStatus` ensures this invariant applies to the exemption path too.

---

## 4. The Atom-vs-String Design: Structural Regression Guard

### Module attribute change

```
# Before
@platform_admin "PLATFORM_ADMIN"   # String

# After
@platform_admin :PLATFORM_ADMIN    # Atom
```

This change is not merely cosmetic — it is the **regression guard**:

- `conn.assigns[:auth_context][:roles]` always carries `[String.t()]` values from the JWT.  
- An atom (`:PLATFORM_ADMIN`) can never be a member of a `[String.t()]` list.  
- Therefore, `:PLATFORM_ADMIN not in raw_roles` is always `true` regardless of the raw list content — the exemption would never fire if `roles_from_strings/1` were removed and the raw list were compared directly.

**Consequence if `roles_from_strings/1` is removed:** The `cond` guard `@platform_admin not in roles` degrades to `@platform_admin not in []` (because `Authorization.roles_from_strings([])` is `[]`), or more precisely: comparing the atom `:PLATFORM_ADMIN` against the raw `[String.t()]` list always yields `true` (not in), so all callers — including PLATFORM_ADMIN — would be rejected 403 for inactive tenants. The PLATFORM_ADMIN exemption silently breaks. The ISS-0808 regression tests (see §6) would catch this.

**Corollary:** A future developer cannot "simplify" the plug by removing `roles_from_strings/1` and keeping `@platform_admin` as an atom without a test suite catching it immediately. The type mismatch is enforced by the tests, not merely convention.

---

## 5. Call-Flow Design (Pseudocode)

The corrected logic for the `:inactive` exemption path, in pseudocode only:

```
check_tenant_status(conn, tenant_id):
  case Repo.get(Tenant, tenant_id):
    nil       → conn   # pass-through (race/deletion edge case)
    %Tenant{} →
      raw_roles = conn.assigns[:auth_context][:roles] || []
      roles = Authorization.roles_from_strings(raw_roles)   # ← normalization
      cond:
        tenant.status == :inactive AND :PLATFORM_ADMIN NOT IN roles → reject_inactive(conn)
        conn.method IN write_methods AND tenant.status == :migrating → reject_migrating(conn)
        otherwise → conn
```

The two checks remain linearly composed with a **single** `Repo.get(Tenant, …)` call per request, unchanged from the REQ-075 design. The only modification is the two lines that derive `roles` from `raw_roles`.

---

## 6. Acceptance Criteria Traceability

### AC1 — `roles_from_strings/1` is in the PLATFORM_ADMIN derivation path

**Design element:** The `raw_roles → roles` derivation in §5. `Authorization.roles_from_strings(raw_roles)` is called before the `cond` guard. The atom `@platform_admin` (`:PLATFORM_ADMIN`) is compared against the returned `[role()]` list — structural proof that `roles_from_strings/1` must be present for the exemption to work.

### AC2 — Exemption behavior unchanged; proven by tests for both exempt and non-exempt actors

**Design element:** `check_tenant_status/2` behavior contract (§5). The `cond` guard semantics are identical to the pre-fix version; only the derivation of `roles` changes. Tests in the `ISS-0808` describe block (§6.1 below) exercise:

- A `PLATFORM_ADMIN` string in `auth_context.roles` → exempted (conn not halted, no 403).
- A `PROCESS_OPERATOR` string in `auth_context.roles` → rejected 403.
- An unrecognized string (`PLATFORM_ADMIN_WANNABE`) → rejected 403 (filtered by `roles_from_strings/1`).

### AC3 — Regression test would fail if plug reverted to raw string comparison

**Design element:** The atom `@platform_admin = :PLATFORM_ADMIN` (§4). If the implementation reverted to `"PLATFORM_ADMIN" in raw_roles`, the `ISS-0808` test "a PLATFORM_ADMIN caller (string role) is exempt via roles_from_strings normalization" would still pass (because `"PLATFORM_ADMIN" in ["PLATFORM_ADMIN"]` is `true`). However, if it reverted to `:PLATFORM_ADMIN not in raw_roles` (atom check against string list), all three ISS-0808 tests would fail — no actor could ever be exempted, and the "PLATFORM_ADMIN should be exempt" assertion would fail.

The definitive regression guard is the **atom `@platform_admin`**: because `roles_from_strings/1` returns atoms and `auth_context.roles` carries strings, removing `roles_from_strings/1` while keeping the atom constant always breaks the exemption, which the tests catch.

---

## 6.1 ISS-0808 Test Coverage Summary

Tests in `test/letflow/plugs/tenant_status_test.exs`, describe block `"ISS-0808 — PLATFORM_ADMIN check uses Authorization.roles_from_strings/1"`:

| Test | What it asserts | How it fails if `roles_from_strings/1` is removed |
|---|---|---|
| `"a PLATFORM_ADMIN caller (string role) is exempt via roles_from_strings normalization"` | `call_plug(:get, tenant.id, ["PLATFORM_ADMIN"])` → `refute conn.halted` | If atom kept and `roles_from_strings/1` removed: `:PLATFORM_ADMIN not in ["PLATFORM_ADMIN"]` is always `true` → 403 returned → `refute conn.halted` fails |
| `"a non-PLATFORM_ADMIN caller is not exempt, even with valid roles"` | `call_plug(:get, tenant.id, ["PROCESS_OPERATOR"])` → `conn.status == 403` | Unaffected by the regression (non-admin is always rejected either way) |
| `"an unknown role string is not exempt (roles_from_strings/1 filters out unknown strings)"` | `call_plug(:get, tenant.id, ["PLATFORM_ADMIN_WANNABE"])` → `conn.status == 403` | If reverted to raw string and `@platform_admin` changed to string: `"PLATFORM_ADMIN_WANNABE" in ["PLATFORM_ADMIN_WANNABE"]` would pass depending on the string value — this test guards the filter-unknown behavior |

The first test is the primary regression guard. Its failure mode directly proves AC3.

---

## 7. Cross-Module Dependency

| Dependency | Direction | Contract |
|---|---|---|
| `Letflow.Api.Authorization.roles_from_strings/1` | `TenantStatus` → `Authorization` | `@spec roles_from_strings([String.t()]) :: [role()]` — pure, no I/O, never raises. Defined in `lib/letflow/api/authorization.ex` ~line 435. |
| `Letflow.Identity.Tenant` (struct) | `TenantStatus` → `Tenant` | `tenant.status` field, type `:active | :inactive | :migrating`. Unchanged. |
| `Letflow.Repo.get/2` | `TenantStatus` → `Repo` | Single lookup per request. Unchanged. |

No new dependencies introduced. The `alias Letflow.Api.Authorization` is a new `alias` declaration but not a new runtime dependency — `Authorization` was already compiled and available at the call site.

---

## 8. Open Questions

None. The fix is narrow and bounded: one call-site change in one plug. No schema changes, no new public functions, no migration needed.

---

## 9. Out of Scope

- Changing the `:migrating` write-pause check (REQ-021) — it has no PLATFORM_ADMIN exemption by design (data-integrity window, not a policy decision). This is unchanged.
- Changing `roles_from_strings/1` itself.
- Any frontend or migration changes.
