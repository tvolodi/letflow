# Design: ISS-0329 — JIT-disabled realm unique constraint collision

**Status:** DESIGN  
**Issue:** ISS-0329  
**Author:** CODE-DESIGNER  
**Date:** 2026-08-23  
**File changed:** `test/letflow/plugs/auth_pipeline_configurable_verifier_test.exs`

---

## 1. Problem Statement

`test/letflow/plugs/auth_pipeline_configurable_verifier_test.exs`, line 140, reads:

```
realm = "jit-disabled-test-realm"
```

This is a hardcoded string literal. The test then calls `insert_tenant_for_realm!(realm)`,
which inserts a row into `tenants` with `idp_realm_id = "jit-disabled-test-realm"`.

`tenants.idp_realm_id` carries a unique constraint (established in the REQ-018/REQ-021
migrations). When `test_parallel.sh` runs with `TEST_PARALLEL_N > 1`, multiple test
partitions execute this module concurrently (the module is `async: false`, but across
partitions the entire VM is distinct). Both partitions attempt to insert a tenant row
with the same `idp_realm_id`, and one of them receives a `Postgrex.Error` for a unique
constraint violation on `tenants_idp_realm_id_index`, causing the test to crash rather
than fail cleanly.

This is the same class of bug that `unique_realm/1` and `unique_slug/1` helpers were
already introduced to solve for other tests in this file and in
`auth_pipeline_test.exs`. Line 140 was simply not updated when the JIT-disabled test
was first written.

---

## 2. Why a Naive `unique_realm/1` Swap is Insufficient

Replacing the literal with `realm = unique_realm("jit-disabled")` generates a
collision-safe realm string (e.g. `"jit-disabled-42"`), but this alone breaks the
assertion `assert conn.status == 403`.

The reason is the lookup path in `Letflow.Oidc.JitProvisioningConfig.for_realm/1`:

- `for_realm/1` reads `Application.fetch_env!(:letflow, :oidc_jit_provisioning)`, which
  returns the compile-time config map from `config/test.exs`.
- `config/test.exs` only registers named realms that tests explicitly configure (e.g.
  `"bpm-default"` with `enabled: true`). A freshly generated realm like
  `"jit-disabled-42"` is not present in this map.
- On a `Map.fetch/2` miss, `for_realm/1` falls through to `default/1`.
- `JitProvisioningConfig.default/1` returns `%JitProvisioningConfig{enabled: true, ...}` —
  JIT provisioning **enabled** is the hardcoded default, mirroring Zig's
  `DEFAULT_JIT_CONFIG`.
- With JIT enabled, `AuthPipeline.provision_user/3` successfully creates a user row and
  returns HTTP 200.
- The test assertion `assert conn.status == 403` therefore fails.

The fix must ensure that the dynamically generated realm is known to
`for_realm/1` as a JIT-disabled realm **before** the pipeline is invoked.

---

## 3. Fix Design

### 3.1 Affected test body

The test at approximately line 138–150 in the `"JIT-disabled realm (403, distinct from
every 401 case)"` describe block:

```
test "a token for a realm with JIT provisioning disabled is rejected 403 end-to-end, no user row created"
```

### 3.2 Signatures referenced (no implementation bodies)

The following existing functions are called by the fix; no new functions are introduced:

- `@spec unique_realm(prefix :: String.t()) :: String.t()`  
  Already defined as a private helper in this test module. Generates
  `"#{prefix}-#{System.unique_integer([:positive, :monotonic])}"`.

- `@spec Application.get_env(app :: atom(), key :: atom()) :: term()`  
  Reads the current value of a config key from the VM's in-memory config table.

- `@spec Application.put_env(app :: atom(), key :: atom(), value :: term()) :: :ok`  
  Writes a new value for the config key. Mutates global VM state; must be reversed
  on_exit.

- `@spec ExUnit.Callbacks.on_exit(callback :: (-> term())) :: :ok`  
  Registers a callback to run after the test completes (pass or fail). Used here to
  restore the original `:oidc_jit_provisioning` config.

- `@spec insert_tenant_for_realm!(realm :: String.t()) :: Letflow.Identity.Tenant.t()`  
  Already defined as a private helper in this test module. Inserts a tenant row,
  provisions and migrates the tenant schema, and registers cleanup on_exit. Sets
  `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` as its first action.

### 3.3 Step-by-step change to the test body

The test body is rewritten (in prose) as follows:

**Step 1 — Generate a unique realm name.**  
Use `unique_realm("jit-disabled")` instead of the literal `"jit-disabled-test-realm"`.
Assign the result to `realm`.

**Step 2 — Snapshot the current `:oidc_jit_provisioning` config.**  
Read `Application.get_env(:letflow, :oidc_jit_provisioning)` (defaulting to an empty
map if absent) and bind it to a local variable (e.g. `original_jit_config`).

**Step 3 — Register an `on_exit` callback to restore the snapshot.**  
Before mutating the config, register `on_exit` to call
`Application.put_env(:letflow, :oidc_jit_provisioning, original_jit_config)`.
Registering the cleanup before the mutation guarantees it runs even if step 4 raises.

**Step 4 — Add the unique realm as JIT-disabled to the config.**  
Call `Application.put_env(:letflow, :oidc_jit_provisioning, ...)` with a new map
formed by merging the realm key into `original_jit_config`. The entry for the realm
must be a plain map with the fields:

- `enabled: false`
- `default_status: :active`
- `default_roles: []`

This mirrors the shape that `JitProvisioningConfig.for_realm/1` reads from each
entry in the config map. With this entry present, `for_realm/1`'s `Map.fetch/2` will
succeed and return the `enabled: false` struct rather than falling through to
`default/1`.

**Step 5 — Insert the tenant (AFTER config mutation).**  
Call `insert_tenant_for_realm!(realm)`. This step must come **after** step 4 because
`insert_tenant_for_realm!/1` calls
`TenantProvisioning.provision_tenant_schema/1`, which sets the Sandbox to `:auto` and
runs real Ecto operations. The ordering requirement is not about provisioning itself —
it is about ensuring the config is in place before the subsequent `call_pipeline/2`
invocation reads it. Placing it after the config mutation also keeps the test body's
logical flow consistent with the existing `setup/0` pattern (config swap → then DB
work).

**Step 6 — Invoke the pipeline and assert.**  
No change to the existing `call_pipeline/2` call or the three assertions
(`conn.status == 403`, `conn.halted`, `user_count_for_tenant == 0`).

### 3.4 Ordering invariant

```
unique_realm  →  snapshot config  →  on_exit(restore)  →  put_env(add realm)
  →  insert_tenant_for_realm!  →  call_pipeline  →  assertions
```

The config mutation precedes `insert_tenant_for_realm!`. This is required both
logically (the pipeline must see the JIT-disabled entry) and as a precaution against
the Sandbox `:auto`-mode side-effect that `insert_tenant_for_realm!/1` triggers.

### 3.5 Consistency with existing setup/0 pattern

The module-level `setup/0` already demonstrates this exact pattern for the `:oidc`
key: snapshot original, put_env the mutated value, on_exit restore. The new test-body
mutation of `:oidc_jit_provisioning` follows the same structure, limited to a single
test body rather than module-level setup, because only this one test requires a
JIT-disabled realm.

---

## 4. Scope Boundary

### In scope

| Item | Status |
|------|--------|
| `test/letflow/plugs/auth_pipeline_configurable_verifier_test.exs` — the single JIT-disabled test body (lines ~138–150) | **CHANGE** |

### Out of scope (explicitly excluded)

| Item | Reason |
|------|--------|
| `config/test.exs` | No compile-time config change is needed or desirable; the fix uses runtime `Application.put_env` deliberately so no other test is affected |
| `lib/letflow/oidc/jit_provisioning_config.ex` | No change to production code |
| Any other file under `lib/` | Production code is correct; this is a test isolation defect only |
| `scripts/test_parallel.sh` | See Section 6 |
| `test/letflow/plugs/auth_pipeline_test.exs` | See Section 5 |

---

## 5. ISS-0108 Note — `auth_pipeline_test.exs:131` (`"bpm-default"`)

`test/letflow/plugs/auth_pipeline_test.exs`, line 131, uses the hardcoded literal
`"bpm-default"` as the `idp_realm_id` for its JIT-enabled tenant fixture. This is a
related but distinct hardcoded-realm problem.

That issue is **already tracked as ISS-0108** and is **out of scope** for this fix.
It is documented here only so the implementer does not conflate the two. The
`"bpm-default"` realm has a corresponding `config/test.exs` entry with `enabled: true`,
making its collision profile and fix approach different from ISS-0329. ISS-0108 should
be addressed in its own fix workflow.

---

## 6. `test_parallel.sh` Exit-Code Concern — Retracted

An earlier draft of the ISS-0329 diagnosis raised a concern that `test_parallel.sh`
may exit 0 even when a partition fails, potentially masking the collision. **This
concern has been retracted as a misread of the script.** The script's actual exit
logic correctly propagates non-zero partition exit codes. No change to
`scripts/test_parallel.sh` is needed or in scope.

---

## 7. Change Summary

### File: `test/letflow/plugs/auth_pipeline_configurable_verifier_test.exs`

**Lines affected:** approximately 140–150 (the body of the single test inside
`describe "JIT-disabled realm (403, distinct from every 401 case)"`).

**Change description (prose, no code bodies):**

1. Line 140: replace the literal `"jit-disabled-test-realm"` with a call to
   `unique_realm("jit-disabled")`.
2. After binding `realm`, add three new statements before the existing
   `insert_tenant_for_realm!` call:
   - Read `Application.get_env(:letflow, :oidc_jit_provisioning, %{})` into a local
     variable.
   - Register `on_exit` to restore that value via `Application.put_env`.
   - Call `Application.put_env` to add the unique realm with
     `%{enabled: false, default_status: :active, default_roles: []}` to the config map.
3. The `insert_tenant_for_realm!(realm)` call and all subsequent assertions remain
   unchanged in logic; only their position in the test body moves down by three lines.

**Net diff:** ~5 lines added (snapshot bind, on_exit, put_env, blank lines for
readability), 1 line changed (the realm literal → unique_realm call). No lines
deleted. No changes outside this one test body.
