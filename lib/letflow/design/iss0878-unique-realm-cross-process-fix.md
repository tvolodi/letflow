# ISS-0878 — cross-process-unique `unique_realm/1` fixture design

## Problem (from diagnosis, `handoffs/WF03-ISS0878-20260929/step-01-issue-fixer.json`)

Four test files each define their own private `unique_realm/1`, all built on
`System.unique_integer([:positive, :monotonic])`, which is unique only within one BEAM
VM process. `scripts/test_parallel.sh` shards the suite across N independent OS
processes (separate BEAM VMs) against one shared Postgres instance, and
`tenants_idp_realm_id_partial_index` is a single global unique index with no
partition scoping. Two partitions independently making their first
`unique_realm(same_prefix)` call in the same window can produce an identical string
and collide on insert (`Ecto.InvalidChangesetError`, `idp_realm_id: ["has already
been taken"]`).

Affected private definitions (byte-identical pattern, confirmed by direct read):

- `test/letflow/plugs/auth_pipeline_test.exs:64-66`
- `test/letflow/api/authorization_ac9_test.exs:49`
- `test/letflow/oidc/provider_registry_multi_realm_test.exs:83`
- `test/letflow/identity_test.exs:80-82` (found during diagnosis; **in scope for this
  fix** — see "Scope decision" below)

Established precedent for the fix: `test/support/tenant_slug.ex`'s
`Letflow.TenantSlugFixture.unique_slug/1`, built for the identical failure class
(ISS-0059) using `Ecto.UUID.generate()` instead of any counter, since a UUID carries
no in-process or wall-clock state that can repeat across VMs.

## Scope decision

`test/letflow/identity_test.exs`'s `unique_realm/1` is **folded into this fix**, not
deferred. It is byte-identical to the vulnerable pattern in the 3 originally-filed
files, so leaving it "found but unfixed" would repeat exactly the kind of partial-fix
gap ISS-0329 itself left behind (per the diagnosis's own framing). It becomes the 4th
call site converted below.

**Explicitly out of scope for this fix** (not touched, no call-site change): other
files that share the same vulnerable `System.unique_integer/1`-based `unique_realm/1`
pattern but were not named in ISS-0878's `affected_files` or surfaced by this
diagnosis's grep as in-scope —
`test/letflow/plugs/auth_pipeline_configurable_verifier_test.exs`,
`test/letflow/routers/mobile_tenant_config_test.exs`,
`test/letflow/routers/tenant_config_test.exs`. These exhibit the same theoretical
exposure and should be filed as a follow-up issue (same consolidation, wider sweep)
rather than pulled into this fix's diff — keeping this change's blast radius matched
to what ISS-0878 actually diagnosed.

## Design

### 1. New shared helper — extend `test/support/tenant_slug.ex`

Add one function to the existing `Letflow.TenantSlugFixture` module (no new file/
module — the module already exists specifically to hold cross-process-unique
`tenants` fixture generators, and `idp_realm_id` is a column on the same `tenants`
table as `slug`).

```
@spec unique_realm(prefix :: String.t()) :: String.t()
def unique_realm(prefix \\ "realm") when is_binary(prefix)
```

- Body shape (mirrors `unique_slug/1` exactly, substituting the UUID for the counter):
  build the string as `"#{prefix}-" <> Ecto.UUID.generate()`. No other logic —
  same proportion as `unique_slug/1`.
- Default argument `"realm"` is required to match `identity_test.exs`'s existing
  call convention, where `unique_realm()` (no argument) is called directly at several
  sites (e.g. current lines 592, 599, 653, 765) as well as `unique_realm(prefix)`
  with an explicit prefix elsewhere. The other 3 files only ever call with an explicit
  prefix, so the default is unused but harmless there.
- Moduledoc addition: append one sentence noting the function also fixes ISS-0878
  (mirrors the existing ISS-0059 callout for `unique_slug/1`), so a future reader
  sees why both generators exist side by side in one module.
- No new test file for this helper itself — per the diagnosis's own "why existing
  tests didn't catch it" note, the failure mode is a cross-OS-process race that no
  single-process unit test can exercise; the helper's correctness is proven the same
  way `unique_slug/1`'s already is, by the call sites that depend on it continuing to
  pass under `scripts/test_parallel.sh`.

### 2. Call-site changes (4 files)

For each file: remove the file's own private `unique_realm/1` `defp`, and either
(a) call `Letflow.TenantSlugFixture.unique_realm/1` directly at every existing call
site, or (b) keep a thin private delegating wrapper of the same name/arity so
in-body call sites (`unique_realm("prefix")`) don't need to change at all. Use
option (b) uniformly — it exactly mirrors `identity_test.exs`'s own existing
`unique_slug/1` wrapper (`defp unique_slug(prefix \\ "tenant"), do:
Letflow.TenantSlugFixture.unique_slug(prefix)`), keeps the diff minimal (one `defp`
body changed per file, zero changes to any assertion or call-site argument), and
avoids introducing a module alias into files that don't already have one.

No test file already aliases `Letflow.TenantSlugFixture` except
`provider_registry_multi_realm_test.exs` (`alias Letflow.TenantSlugFixture`, used for
`unique_slug/1`-equivalent tenant slugs there) — so only that file's wrapper can use
the bare `TenantSlugFixture.unique_realm/1` name; the other 3 need either a new
`alias Letflow.TenantSlugFixture` line or the fully-qualified
`Letflow.TenantSlugFixture.unique_realm/1` call. Use the fully-qualified call in the
wrapper body in all 4 files for consistency and to avoid an extra alias-line diff.

#### `test/letflow/plugs/auth_pipeline_test.exs`

Replace lines 64-66:
```
defp unique_realm(prefix) do
  "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
```
with:
```
defp unique_realm(prefix) do
  Letflow.TenantSlugFixture.unique_realm(prefix)
end
```
No other line in this file changes — all 3 existing call sites (lines 221, 223, 250)
already call `unique_realm("owned-by-a")`/`unique_realm("owned-by-b")`/
`unique_realm("unrelated")` and keep doing so unchanged.

#### `test/letflow/api/authorization_ac9_test.exs`

Replace line 49:
```
defp unique_realm(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
```
with:
```
defp unique_realm(prefix), do: Letflow.TenantSlugFixture.unique_realm(prefix)
```
Existing call site (line 70, `unique_realm("ac9")`) unchanged.

#### `test/letflow/oidc/provider_registry_multi_realm_test.exs`

Replace line 83:
```
defp unique_realm(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
```
with:
```
defp unique_realm(prefix), do: TenantSlugFixture.unique_realm(prefix)
```
(This file already has `alias Letflow.TenantSlugFixture` at line 72, so the
unqualified form is used here for consistency with its own existing
`TenantSlugFixture.unique_slug/1`-style calls in the same file, if any; otherwise the
fully-qualified form is equally correct — either is acceptable, ELIXIR-DEV's choice,
since both compile identically given the existing alias.)

All 12 existing call sites (lines 160, 161, 182, 183, 211, 212, 241, 251, 281, 316,
332 — all `unique_realm("ac2-a")`-style, explicit-prefix calls) unchanged. The
moduledoc's own line 30 sentence ("`unique_realm/1` (`System.unique_integer/1`-
suffixed)...") must be updated to say "UUID-suffixed" instead, since it now
inaccurately describes the mechanism — this is a doc-comment correction, not a
behavioral change, and is in scope as part of "no stale rationale left behind."

#### `test/letflow/identity_test.exs`

Replace lines 80-82:
```
defp unique_realm(prefix \\ "realm") do
  "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
```
with:
```
defp unique_realm(prefix \\ "realm") do
  Letflow.TenantSlugFixture.unique_realm(prefix)
end
```
Keep the default argument (`\\ "realm"`) — required, since this file calls both
`unique_realm()` and `unique_realm("prefix")` at existing sites (lines 548, 568, 592,
599, 613, 628, 653, 666, 667, 682, 693, 702, 765, 789 — all unchanged). The adjacent
comment block at lines 77-79 ("this project's established `Ecto.UUID.generate()`-
per-test convention") already correctly describes the *intended* convention — it
becomes accurate once this change lands (it was previously aspirational/inaccurate
for `unique_realm/1` specifically, matching only `unique_slug/1`); no comment text
change needed there.

### 3. Invariants preserved

- No assertion, expected value, or test description changes anywhere — this is a
  fixture-generation-only fix, per acceptance criterion 4.
- No `lib/` or `priv/repo/migrations/` changes — per acceptance criterion 5, this is
  entirely `test/` and `test/support/` scoped.
- Every call site's arity and call shape (`unique_realm(prefix)` / `unique_realm()`)
  is unchanged; only the string-generation mechanism inside the (now single, shared)
  implementation changes, from a per-VM counter to `Ecto.UUID.generate()`.
- `Letflow.TenantSlugFixture` gains a second, independent public function
  (`unique_realm/1`) alongside `unique_slug/1`; neither calls the other, and neither's
  existing behavior/signature changes.

## Open questions

None — this is a small, mechanical, single-pattern substitution across 4 known call
sites, following an established in-repo precedent (`unique_slug/1` / ISS-0059) with
no new design decisions required. The only judgment call left to ELIXIR-DEV is the
qualified-vs-aliased call form inside `provider_registry_multi_realm_test.exs`'s
wrapper, noted above as either being acceptable.
