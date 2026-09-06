# Design: REQ-158 — Capability manifest, load-time validation, and the hash fed to LuaScriptAudit (LUA-07)

**Requirement:** REQ-158
**Stage:** S5
**Owner (design):** CODE-DESIGNER
**Owner (implementation):** ELIXIR-DEV
**Date:** 2026-08-27
**Depends on:** REQ-157 (`lib/letflow/engine/lua/capabilities.ex` — reuses `capability()`/`grant_set()`
types, does not redefine them). Completes LUA-07 alongside REQ-058
(`lib/letflow/engine/lua_script_audit.ex`, S3), which shipped only the
audit-persistence half.

---

## 0. Sources read for this design

- `handoffs/WF02-REQ158-20260827/step-01-code-designer.json` (`context.requirement_text`,
  `task.acceptance_criteria`, `context.owned_modules`)
- `docs/requirements.yaml` REQ-158 entry (full `description` and 7-item
  `acceptance_criteria`, read directly — reproduced verbatim in §7 below)
- `lib/letflow/engine/lua_script_audit.ex` (full — read directly, not assumed). In
  particular: the moduledoc's INV-LSA-1 (ordering: `instance_id` validated before the
  executor is ever touched) and INV-LSA-2 (a `manifest_hash`/`registered_hash` mismatch
  is a distinct, pattern-matchable `{:manifest_hash_mismatch, registered_hash,
  actual_hash}` error, and writes no audit row); the `Executor` behaviour's
  `execute_with_manifest/2` callback (`@callback execute_with_manifest(script_ref(),
  registered_hash :: String.t()) :: {:ok, manifest_result()} | {:error, term()}`); and
  `verify_manifest_hash/2`'s exact comparison (private, two clauses): when `actual_hash`
  and `registered_hash` are equal, the result is `:ok`; otherwise the result is the
  distinct, pattern-matchable `{:manifest_hash_mismatch, registered_hash, actual_hash}`
  — a plain equality guard, no normalization, no case-folding.
- `lib/letflow/engine/lua/executor.ex` (full — read directly). Confirmed:
  `run_script/2` (private, lines ~263–285) computes `manifest_hash` as the lowercase-hex
  SHA-256 digest of `script_source` alone (via the standard library's crypto-hash and
  hex-encode facilities) — the SHA-256 of
  the raw Lua source bytes alone, computed only after `Lua.eval!/2` succeeds, with no
  reference to any manifest concept anywhere in this module. `script_ref`'s concrete
  shape here is a bare binary of Lua source text (per this module's own moduledoc, "a
  binary containing the Lua source text to execute").
- `lib/letflow/engine/lua/capabilities.ex` (full — read directly). `capability ::
  String.t()`, `@opaque grant_set :: MapSet.t(capability())`, `new/0`, `new/1`, `add/2`,
  `has?/2`, `check/3`, `check!/3`, `service_capability/1`. This design reuses
  `capability()` and constructs a `grant_set()` via `Capabilities.new/1` from a
  manifest's declared capability list — it does not add a second capability
  representation.
- `lib/letflow/design/req157-lua-capability-model.md` (full — the design that built
  `Capabilities`). Its §8 cross-module table already anticipates this requirement: "A
  manifest's declared capabilities become a `grant_set()` via `Capabilities.new/1`,
  passed to `Platform.install/2` at whatever point REQ-158 wires load-time validation
  in. Not built here." Its §1 scope also states manifest validation is "a separate
  requirement, depends on this one's `Capabilities` grant-set shape but is not built
  here." This design honors both statements: it reuses `Capabilities.new/1` to build the
  grant set, and does not redefine `capability()`/`grant_set()`.
- `docs/migration/decisions/0014-scripting-plugin-runtime-strategy.md` (full). LUA-07 is
  on the "satisfiable substantially as worded" list (§502–506), with the explicit
  caution that the list is "a starting position to verify, not a clearance" (§512–514) —
  this design's own traceability table (§7) is what verifies it for REQ-158's slice.
  Nothing else in that record bears directly on manifest shape or hashing.
PROVENANCE (historical, not current decision authority):
- `R-Co/src/lua/manifest.zig` — **attempted via `find` and confirmed absent in this
  checkout** (no result for `find / -iname "manifest.zig"` or any `R-Co` directory at
  all). This matches the established pattern this session already hit for
  `R-Co/src/lua/capabilities.zig` and `R-Co/src/lua/host_api/mod.zig` (REQ-157 §0/§11
  OQ-1) and for REQ-149's spike. This design proceeds entirely from
  `docs/requirements.yaml` REQ-158's own restatement of the requirement's substance
  (quoted in full in §7 below), which is the only available source for the manifest's
  intended shape in this environment. Flagged as **OQ-1** (§11) — not silently assumed
  equivalent to the original R-Co shape.

---

## 1. Scope boundary

**In scope (per requirement text, restated):**

1. A manifest data representation carrying, at minimum, the declared capability set
   (reusing REQ-157's `Capabilities.capability()` type, not redefining it) and the
   script-identity fields the hash covers (§2).
2. A LOAD-TIME validation entry point — structurally prior to, and independent of, any
   call into `Letflow.Engine.Lua.Executor.execute_with_manifest/2,3` or
   `Letflow.Engine.LuaScriptAudit.execute_script_for_audit/6` — that rejects a manifest
   which does not match the script artifact it is paired with, before any script text
   executes (§3).
3. The exact hash algorithm and the exact bytes/fields it covers, stated precisely
   enough that "a modified manifest is rejected" is a well-defined, testable claim (§4).
4. The explicit, justified relationship between this module's computed hash and
   `LuaScriptAudit`'s `registered_hash` parameter (§5) — decided, not left ambiguous.
5. An explicit statement that this design feeds `LuaScriptAudit.verify_manifest_hash/2`
   (INV-LSA-2) rather than reimplementing or bypassing it (§5.4).

**Out of scope (explicitly):**

- Any change to `lib/letflow/engine/lua_script_audit.ex` itself — INV-LSA-1/INV-LSA-2
  and `verify_manifest_hash/2`'s comparison logic are consumed as-is, unmodified (§5.4).
- Where a manifest and its `registered_hash` are persisted between registration and a
  later load (no Ecto schema, no table). This design's module is pure, in-memory logic
  — like `Capabilities` (§0) — taking a manifest, a script artifact, and a
  previously-registered hash as plain arguments. Where those three values are read from
  (a future manifest-registry table, a plugin/script-registration record, etc.) is not
  decided here. Flagged as **OQ-2** (§11).
- Wiring a manifest's declared capabilities into a running `Lua.t()` VM via
  `Letflow.Engine.Lua.Platform.install/2` (i.e., actually granting them for execution).
  This design produces the `grant_set()` value (§2.3) and states that a caller
  constructs it via `Capabilities.new/1`, but the call site that passes it to
  `Platform.install/2` instead of the current always-empty `install/1` path
  (`Sandbox.new/1` still calls `Platform.install/1` unconditionally, per REQ-157 design
  §1.1) is REQ-159/160/161 territory. Flagged as **OQ-3** (§11).
- The coordinated change this design requires in `lib/letflow/engine/lua/executor.ex`
  (§5.3) is **described here in prose only** — it is not made by this design step, and
  is not made by this run at all (`executor.ex` is not in this run's `owned_modules`).
  It is Step 2a's (ELIXIR-DEV's) responsibility to implement, informed by §5.3.
- Real bodies of `read_variable`/`write_variable`/etc. — unrelated, REQ-159/160.

**File layout:**

| File | Purpose |
|---|---|
| `lib/letflow/engine/lua/manifest.ex` | New. `Letflow.Engine.Lua.Manifest` — the manifest struct, the canonical hash function, and the load-time validation entry point (§2, §3, §4). |
| `test/letflow/engine/lua/manifest_test.exs` | New. Unit tests for the struct, hash determinism/sensitivity, and the load-time gate — see `test/specs/REQ-158.md`. |
| `lib/letflow/design/req158-lua-manifest-validation.md` | This file. |
| `test/specs/REQ-158.md` | Prose test-spec skeleton (this run). |

**Not in this run's `owned_modules`, but affected per §5.3 (described in prose, not implemented here):**

| File | What changes, per this design, at Step 2a |
|---|---|
| `lib/letflow/engine/lua/executor.ex` | `run_script/2`'s `manifest_hash` computation (currently line ~268, a bare SHA-256 of `script_source` alone) must be replaced by a call to this design's `Manifest.compute_hash/2` over the manifest paired with that execution, not the script source alone. `script_ref`'s concrete shape must gain a way to carry the paired `Manifest.t()` alongside the script source. See §5.3 for exactly what changes and why it is safe. |

---

## 2. `Letflow.Engine.Lua.Manifest` — data shape

### 2.1 Struct fields

```
@type t :: %__MODULE__{
        script_id: String.t(),
        capabilities: [Letflow.Engine.Lua.Capabilities.capability()]
      }
```

- **`script_id`** — the identity field the hash covers (§4). A non-empty `String.t()`
  naming the specific script this manifest is paired with (e.g. a script registry
  UUID or stable slug — the concrete source of this value, and whatever registry
  assigns it, is out of this design's scope per §1/OQ-2). Its presence in the hash is
  what makes the hash specific to *this* script rather than to "any script with these
  capabilities" — two different scripts declaring an identical capability list must not
  collide onto the same manifest hash, which a `script_id`-free hash could not
  guarantee.
- **`capabilities`** — a plain `[Letflow.Engine.Lua.Capabilities.capability()]` list
  (i.e., `[String.t()]`), the manifest's declared, requestable capability set — REQ-157's
  own type, reused verbatim, not redefined. Kept as an ordered `list()` rather than
  REQ-157's `grant_set()` (`MapSet.t()`) at the struct level specifically **because** a
  `MapSet.t()` has no canonical serialization order and this design's hash (§4) needs a
  deterministic byte sequence; §2.3 states the one place this list is converted to a
  `grant_set()` for actual capability-checking use. Duplicate entries are permitted in
  the field itself (not an error) but are *not* rendered twice into the hash input
  (§4.2's canonicalization step de-duplicates via the same `Capabilities.new/1` round
  trip through a `MapSet`, before sorting).

### 2.2 Structural validation

```
@type shape_error :: {:invalid_script_id, term()} | {:invalid_capabilities, term()}

@spec validate_shape(t()) :: :ok | {:error, shape_error()}
```

Checks, independent of any hash comparison: `script_id` is a non-empty `String.t()`;
`capabilities` is a `list()` whose every element is a `String.t()`. This is a
precondition check only — it never consults a script artifact or a registered hash. It
exists so a malformed manifest (e.g. a `nil` `script_id`, or a capabilities list
containing a non-string) is rejected with a distinct, named reason before hashing is
even attempted, rather than crashing inside the hash function or silently coercing a bad
value.

### 2.3 Deriving a `grant_set()` for capability-checking

```
@spec to_grant_set(t()) :: Letflow.Engine.Lua.Capabilities.grant_set()
```

Returns `Letflow.Engine.Lua.Capabilities.new(manifest.capabilities)` (REQ-157's own
constructor, called here — not reimplemented). This is the **one and only** conversion
point from a manifest's declared capability list to the `grant_set()` type
`Letflow.Engine.Lua.Platform.install/2` consumes. Whether/when a caller actually invokes
`Platform.install/2` with this returned grant set (rather than the current
always-empty path) is OQ-3 (§11, §1) — out of this requirement's scope — but the
conversion function itself is provided here so that future wiring has exactly one place
to call, mirroring `Capabilities.service_capability/1`'s "one and only place this string
is built" precedent (REQ-157 design §2.5).

### 2.4 R-Co field carried over vs. dropped — required moduledoc content (AC6)

PROVENANCE (historical, not current decision authority):
Per §0, `R-Co/src/lua/manifest.zig` is **not present in this checkout** — confirmed by
`find` returning no result for the file or for any `R-Co` directory at all. This design
cannot state "field X was in the original and is deliberately dropped for reason Y"
against a source it has not read. What it states instead, and what must appear in the
shipped module's moduledoc verbatim in substance, is:

PROVENANCE (historical, not current decision authority):
> This module's `script_id`/`capabilities` shape is derived from
> `docs/requirements.yaml` REQ-158's own restatement of LUA-07 and REQ-157's already-built
> `capability()` type — not from reading `R-Co/src/lua/manifest.zig` directly, because
> that file is absent from this checkout (confirmed by `find`, matching the pattern
> already hit for `R-Co/src/lua/capabilities.zig` and `R-Co/src/lua/host_api/mod.zig` in
> REQ-157's design). No field of the original is named here as "deliberately dropped,"
> because the original was never read to know what fields it had. If a future
> SECURITY-REVIEWER or REVIEWER pass gains access to the original source and finds it
> carried additional fields (e.g. a manifest version/generation number, an author/actor
> identity, an expiry, or a signature), that finding should be reconciled against this
> module rather than assumed already covered.

This is carried into §11 as **OQ-1**, matching REQ-157's OQ-1 precedent exactly (same
missing-source situation, same non-blocking treatment, same explicit flag rather than a
silent "N/A").

---

## 3. Load-time validation entry point (AC1, AC2)

### 3.1 Signature

```
@type load_error ::
        {:manifest_mismatch, registered_hash :: String.t(), computed_hash :: String.t()}
        | {:invalid_manifest, shape_error()}

@spec validate_at_load(
        manifest :: t(),
        script_source :: binary(),
        registered_hash :: String.t()
      ) :: {:ok, manifest_hash :: String.t()} | {:error, load_error()}
```

`validate_at_load/3` is the single function this requirement adds as the LOAD-TIME gate.
It performs, strictly in this order:

1. `validate_shape/1` (§2.2) against `manifest`. On `{:error, shape_error}`, returns
   `{:error, {:invalid_manifest, shape_error}}` immediately — no hash is computed, no
   comparison against `registered_hash` is attempted.
2. `compute_hash/2` (§4) over `manifest` and `script_source`, producing
   `computed_hash`.
3. A plain equality comparison of `computed_hash` against the caller-supplied
   `registered_hash` — the same shape of check as `LuaScriptAudit.verify_manifest_hash/2`
   (§5.1), deliberately, but performed independently and earlier (§3.2). When the two
   values are equal, the result is `{:ok, computed_hash}`; when they differ, the result
   is `{:error, {:manifest_mismatch, registered_hash, computed_hash}}`.

`validate_at_load/3` performs **no I/O of any kind** — no `Repo` call, no file read, no
call into `Executor` or `LuaScriptAudit`. Its three arguments are plain data a caller
must already have obtained: the manifest currently associated with the script (however
that lookup happens — OQ-2), the script's current raw source bytes (the "script
artifact" the requirement text names), and the hash that was recorded at the last
successful registration. This mirrors `Capabilities`'s own "pure grant-set/denial-shape
logic, independent of how or whether it is ever wired into a `Lua.t()`" positioning
(REQ-157 design §3) — `Manifest` is pure manifest/hash-shape logic, independent of how
or whether a caller wires its result into an actual execution.

### 3.2 Why this is structurally prior to, and distinct from, execution (AC2)

`validate_at_load/3` has no dependency on `Letflow.Engine.Lua.Executor` or
`Letflow.Engine.LuaScriptAudit` at all — it does not call either module, and neither
module calls it. The ordering guarantee this requirement's acceptance criteria need
("rejection happens before any script text executes") is a **caller-discipline
guarantee**, not something this module enforces on a caller by construction: the
required calling convention is that a caller obtains `{:ok, manifest_hash}` from
`validate_at_load/3` *before* it ever constructs a call to
`LuaScriptAudit.execute_script_for_audit/6` (which is the only path that reaches
`Executor.execute_with_manifest/2,3`, and therefore the only path that runs any script
text at all — confirmed by reading `lua_script_audit.ex` in full, §0). A caller that
skips `validate_at_load/3` and calls `execute_script_for_audit/6` directly bypasses this
gate entirely — this is stated plainly as a caller-discipline requirement (not a runtime
assertion this module can make on its own, since it has no way to intercept a call it is
never invoked from) and is the reason AC2's test (§7, test spec) must exercise the two
functions **in sequence from the calling code under test**, not merely test
`validate_at_load/3` in isolation. This is the identical shape of guarantee
`LuaScriptAudit` itself already relies on for INV-LSA-1 (`instance_id` validated before
`executor` is touched, enforced by `execute_script_for_audit/6`'s own internal `with`
ordering, not by a separate caller-facing precondition) — the difference here is that the
two functions live in different modules with no call relationship between them, so the
ordering is a documented calling-convention contract rather than a single function's
internal step order.

---

## 4. The hash algorithm and exactly which bytes it covers (AC5)

### 4.1 Algorithm

SHA-256, hex-encoded using lowercase hex digits — the identical digest algorithm and
encoding `lib/letflow/engine/lua/executor.ex`'s `run_script/2` already uses today for its
bare script-source hash (confirmed by reading that file, §0). This design does not introduce a second
hash algorithm alongside it; it changes what bytes the existing algorithm is applied to
(§5.3).

```
@spec compute_hash(t(), script_source :: binary()) :: String.t()
```

### 4.2 Exactly which bytes are covered, in order

The digest is computed over the concatenation, in this exact order, of:

1. The raw bytes of `manifest.script_id`.
2. One `0x00` (NUL) separator byte.
3. The manifest's capability list, **canonicalized** before inclusion: converted through
   `Capabilities.new/1` and back to a list (`Capabilities` reused, §2.3 — this
   deduplicates and gives a `MapSet`-backed set), then sorted in ascending lexicographic
   (byte) order, then each entry joined to the next by a single `0x0A` (LF) separator
   byte. An empty capability list contributes zero bytes at this step (not a placeholder
   string).
4. One further `0x00` (NUL) separator byte.
5. The raw bytes of `script_source`, exactly as supplied — no trimming, no line-ending
   normalization, no encoding transformation of any kind.

The two `0x00` separators (steps 2 and 4) exist so that a `script_id` value and a
capability-list rendering can never be concatenated ambiguously with each other or with
the script source that follows (e.g. a `script_id` of `"ab"` paired with the single
capability `"c"` must not hash identically to a `script_id` of `"a"` paired with the
single capability `"bc"`, were a delimiter character itself reused from within the
capability strings' own alphabet — `0x00` cannot appear inside a `String.t()` capability
token or a script-id token in practice, and is never a legal Lua source byte at a
position that would be mistaken for this separator, since the digest input is a plain
concatenation, not a place where the script source is itself re-parsed).

The full digest is then hex-encoded with lowercase hex digits, matching
`executor.ex`'s existing convention exactly — this is a deliberate
choice so the string shape of the value flowing into `LuaScriptAudit`'s `manifest_hash`
column (a plain `:string` field, §0) does not change format between the pre-REQ-158 and
post-REQ-158 world; only what bytes produced that string changes.

### 4.3 Determinism and sensitivity, stated as the testable claim AC1/AC5 need

- **Determinism:** `compute_hash/2` called twice with an identical `manifest` (including
  identical, possibly differently-*ordered*, `capabilities` lists — order does not
  matter, per the canonicalization sort in step 3) and identical `script_source` produces
  the identical hex string every time. No randomness, no timestamp, no process-specific
  state enters the computation.
- **Sensitivity to a modified manifest:** changing `capabilities` by adding, removing, or
  altering any single capability string changes the canonicalized byte sequence at step
  3 and therefore changes the digest — this is the mechanism that makes "modified
  manifest without re-registration is rejected" (LUA-07's own acceptance text) a
  well-defined, checkable claim rather than an aspiration: a manifest edited after
  registration produces a `computed_hash` in `validate_at_load/3` that differs from the
  `registered_hash` recorded at registration time, and `validate_at_load/3` returns
  `{:error, {:manifest_mismatch, _, _}}` (§3.1).
- **Sensitivity to `script_id`:** changing `script_id` alone (capabilities and
  `script_source` held fixed) also changes the digest, per step 1 — two manifests for two
  different scripts with an identical capability list and identical source text never
  collide onto the same hash.
- **Sensitivity to `script_source`:** changing even a single byte of `script_source`
  changes the digest, per step 5 — this is inherited directly from SHA-256's own avalanche
  property and from `executor.ex`'s pre-existing bare-source-hash behavior; this design
  does not weaken that sensitivity, only extends the input to also cover the manifest.

---

## 5. The hash / `registered_hash` relationship — decided explicitly (AC3, AC4)

### 5.1 The two candidate options, restated

- **(a)** This module's hash covers the manifest AND extends what
  `Executor.execute_with_manifest/2,3`'s hash computation covers, so `registered_hash`
  (as consumed by `LuaScriptAudit.execute_script_for_audit/6`) becomes a hash of
  manifest+script, not just script — requiring a coordinated change to
  `lib/letflow/engine/lua/executor.ex`.
- **(b)** This module validates the manifest as an independent pre-execution gate with
  its own separate hash, entirely disjoint from `Executor`'s existing bare-script-hash
  mechanism, which is left completely untouched.

### 5.2 Decision: **(a)**, with (b)'s "load-time gate is a separate, prior function"
property kept as well

This design adopts **option (a)** for the hash's *coverage* (manifest+script, not script
alone) — but **keeps** the structural property option (b) names, that the load-time gate
(§3) is a separate, independently-callable function invoked strictly before any
execution, distinct from `LuaScriptAudit`'s own post-execution mismatch check. These are
not actually competing axes once separated:

- **Axis 1 — what bytes does "the manifest hash" cover?** Decided: manifest+script (per
  §4.2), not script alone. This is **(a)**'s substance.
- **Axis 2 — when/where does validation happen, and how many gates exist?** Decided:
  TWO gates exist, both fed by the SAME hash function (§4): `validate_at_load/3` (§3),
  called first, before any execution, with no dependency on `Executor` or
  `LuaScriptAudit`; and `LuaScriptAudit.verify_manifest_hash/2` (INV-LSA-2, unchanged),
  called second, after `Executor.execute_with_manifest/2,3` returns, as it already does
  today. This is the structural property option (b) named, and it survives adopting (a)
  because nothing about "one shared hash formula" requires collapsing the two call sites
  into one.

### 5.3 Why axis 1 must be (a), not (b) — argued from the acceptance criteria themselves

Two of REQ-158's own acceptance criteria decide this, not this design's preference:

1. **"a test asserts the manifest hash produced here is what flows into
   `Letflow.Engine.LuaScriptAudit`'s audit row for a successful execution."** The audit
   row's `manifest_hash` column is populated from `actual_hash` — the value
   `Executor.execute_with_manifest/2,3` *returns* (`insert_audit_record(instance_id,
   actual_hash, ...)`, confirmed by reading `lua_script_audit.ex`'s
   `execute_script_for_audit/6`, §0). For "the hash produced by `Manifest.compute_hash/2`
   is what flows into that column" to be true on a *successful* execution, the value
   `Executor` returns as `manifest_hash` must **be** `Manifest.compute_hash/2`'s output
   — which is only possible if `Executor` is computing the hash the same way this module
   does, i.e. over manifest+script. Under option (b) (`Executor` left completely
   untouched, still hashing script-source alone), this criterion could never hold on any
   manifest whose `capabilities` list is non-empty, because the two hash functions would
   structurally diverge the moment a real capability is declared.
2. **LUA-07's own acceptance text, "Modified manifest without re-registration is
   rejected."** As shown in §4.3, a hash that covers `script_source` alone is, by
   construction, insensitive to any edit of `capabilities` — a modified manifest with an
   unchanged script body would hash identically before and after the edit, and
   `validate_at_load/3` would never detect the modification. Rejection of a modified
   manifest is therefore only a well-defined, checkable claim if the hash covers manifest
   bytes, not script bytes alone. This is what actually forces option (a); it is not an
   arbitrary preference for symmetry with §3's load-time gate.

Both of these are properties of *what the hash covers*, not of *how many gates exist or
where they run*. That is why axis 1 and axis 2 are separable, and why this design can
adopt (a) for the hash's substance while keeping (b)'s prior-and-independent load-time
gate as well — the two options as originally posed conflated "does the hash change" with
"is there one gate or two," and resolving them separately is what makes both of REQ-158's
acceptance criteria satisfiable simultaneously (a successful run's audit-row hash matches
this module's output, per criterion 3; AND rejection happens before any execution, per
criterion 2; AND a runtime mismatch still produces `LuaScriptAudit`'s own error, per
criterion 4, §5.4).

### 5.3.1 The coordinated `executor.ex` change this decision requires (prose only — not implemented in this design step)

`Executor.execute_with_manifest/2,3`'s private `run_script/2` (§0, line ~268) computes:

> the SHA-256 hex of the raw script-source bytes alone, after `Lua.eval!/2` succeeds.

Per §5.2/§5.3, this must change to compute the SHA-256 hex of the same manifest-covering
byte sequence §4.2 defines — concretely, a call to this design's
`Letflow.Engine.Lua.Manifest.compute_hash/2`, passed the `Manifest.t()` paired with that
execution and the same `script_source` already in scope in `run_script/2`. This requires
`script_ref`'s concrete shape (currently a bare `binary()` of Lua source, per that
module's own moduledoc, §0) to widen so that a `Manifest.t()` travels alongside the
source text into `execute_with_manifest/2,3` — e.g. a two-field map or struct carrying
both, in place of the bare binary `script_ref` accepts today. This is compatible with the
`LuaScriptAudit.Executor` behaviour's own callback contract without any change to that
behaviour: `script_ref()` is typed as opaque `term()` at the behaviour level specifically
so a concrete `Executor` implementation may choose its own shape (per that behaviour's
own moduledoc, and per decision 0014(d)'s note that the opaque `term()` "accommodates
whatever is chosen"); `manifest_result :: %{manifest_hash: String.t()}` is unchanged,
since the returned value is still a single hex string in the same field. This is
therefore a change entirely internal to `Letflow.Engine.Lua.Executor` (the concrete Lua
implementation) and to whatever constructs its `script_ref` values — not a change to
`LuaScriptAudit`, and not a change to the `Executor` behaviour's own callback signature.
This is Step 2a's (ELIXIR-DEV's) work; it is described here, not performed here, and is
not made by this run (`executor.ex` is outside this run's `owned_modules`, §1).

### 5.4 Explicit statement: this design feeds `LuaScriptAudit.verify_manifest_hash/2` (INV-LSA-2), it does not reimplement or bypass it (AC4)

`LuaScriptAudit.verify_manifest_hash/2` (private, §0) is unchanged by this design and is
not called, wrapped, or duplicated by anything in `Letflow.Engine.Lua.Manifest`. The two
modules perform structurally similar comparisons (§5.2 axis 2) but are independent:

- `Letflow.Engine.Lua.Manifest.validate_at_load/3` (§3) performs its own equality
  comparison, entirely inside this new module, and never calls into
  `LuaScriptAudit` at all.
- `LuaScriptAudit.execute_script_for_audit/6`'s existing `with`-chain (§0) still calls
  its own private `verify_manifest_hash/2` exactly as REQ-058 built it — comparing the
  `registered_hash` a caller supplies to that function against the `actual_hash` the
  injected `Executor` returns — with no code from this design interposed.

The relationship between the two is purely about what **value** flows where, not about
one module calling the other: a caller that has already obtained `{:ok, manifest_hash}`
from `validate_at_load/3` passes that same `manifest_hash` string as the
`registered_hash` argument to `execute_script_for_audit/6`. On a normal, successful
execution (manifest and script both unmodified since the last successful
`validate_at_load/3` call, and §5.3.1's coordinated `executor.ex` change landed), the
`Executor`'s returned `actual_hash` is computed the identical way and therefore equals
that same value, so `verify_manifest_hash/2` returns `:ok` and the audit row's
`manifest_hash` column is populated with that value (AC3, §5.3). On a mismatch — a race
where the script or manifest changed between the load-time check and execution, a
non-conforming `Executor` implementation, or any other divergence —
`verify_manifest_hash/2` runs exactly as it does today and produces its own
`{:error, {:manifest_hash_mismatch, registered_hash, actual_hash}}`, writing zero audit
rows, **regardless of what `Letflow.Engine.Lua.Manifest` did or did not check earlier**
(AC4). Nothing in this design gives a caller a way to skip that check, silence it, or
substitute its own outcome for it — `Letflow.Engine.Lua.Manifest` has no dependency on
`LuaScriptAudit` at all (§3.1), so it structurally cannot intercept or short-circuit
`verify_manifest_hash/2`'s own call site.

---

## 6. Cross-module dependency direction

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.Engine.Lua.Capabilities` (REQ-157) | `Manifest` → `Capabilities` | `Manifest.to_grant_set/1` (§2.3) calls `Capabilities.new/1`; `Manifest`'s `capabilities` field is typed in terms of `Capabilities.capability()`. One-directional — `Capabilities` has, and gains, no dependency back on `Manifest`. |
| `Letflow.Engine.Lua.Executor` (REQ-153/154/155/156, this run does not touch it) | `Executor` → `Manifest` (Step 2a, not this run) | Per §5.3.1, `run_script/2`'s hash computation is planned to call `Manifest.compute_hash/2`. This design does not implement that call; it specifies it for ELIXIR-DEV. |
| `Letflow.Engine.LuaScriptAudit` (REQ-058) | consumes `Manifest`'s output value, no code dependency | A caller passes `Manifest.validate_at_load/3`'s `{:ok, manifest_hash}` value as `execute_script_for_audit/6`'s `registered_hash` argument (§5.4). Neither module calls the other's code. `LuaScriptAudit` itself is unmodified. |
| `Letflow.Engine.Lua.Platform` (REQ-157) | future, not built here (OQ-3) | `Manifest.to_grant_set/1`'s output is the `grant_set()` value a future requirement would pass to `Platform.install/2` in place of the current always-empty grant set (§1, §2.3). |

---

## 7. Acceptance-criteria traceability (all 7, verbatim from `docs/requirements.yaml` REQ-158)

PROVENANCE (historical, not current decision authority):
| # | Acceptance criterion (verbatim) | Design element |
|---|---|---|
| 1 | "a test loads a script whose manifest has been modified after registration and asserts it is REJECTED, which is LUA-07's own acceptance criterion" | §3.1 `validate_at_load/3`, §4.2/§4.3 (hash sensitivity to a `capabilities` edit), §5.3 (why the hash must cover the manifest for this to be detectable at all) |
| 2 | "a test asserts rejection happens before any script text executes -- e.g. a script whose body would set an observable side effect produces none when its manifest is invalid" | §3.2 (structural priority / caller-discipline argument: `validate_at_load/3` has zero dependency on `Executor`/`LuaScriptAudit` and must be called first) |
| 3 | "a test asserts the manifest hash produced here is what flows into Letflow.Engine.LuaScriptAudit's audit row for a successful execution, so 'recorded with each execution' is proven end to end rather than in isolation" | §5.2/§5.3 (decision + justification), §5.3.1 (the coordinated `executor.ex` change that makes this literally true), §5.4 (the value-flow, not code-dependency, relationship) |
| 4 | "a test asserts a mismatch between the computed hash and the caller-supplied registered_hash still yields LuaScriptAudit's own {:manifest_hash_mismatch, ...} error and writes no audit row, confirming INV-LSA-2 is fed rather than bypassed" | §5.4 (explicit "feeds, does not reimplement or bypass" statement); `LuaScriptAudit.verify_manifest_hash/2` itself is untouched (§0, §1 out-of-scope) |
| 5 | "the moduledoc states the hash algorithm and exactly which bytes/fields it covers" | §4.1 (algorithm), §4.2 (exact byte order) — required moduledoc content, verbatim in substance |
| 6 | "the moduledoc names any field of R-Co/src/lua/manifest.zig deliberately not ported, and why" | §2.4 — R-Co's `manifest.zig` is absent from this checkout (confirmed by `find`); no field is named as "deliberately dropped" because the original was never read; flagged as OQ-1 (§11), required moduledoc content stated verbatim in §2.4 |
| 7 | "mix test and mix compile --warnings-as-errors both pass with real output quoted" | Not a design-time artifact — ELIXIR-DEV's Step 2a / TEST-RUNNER's Step 4 responsibility |

---

## 8. Invariants (new)

- **INV-MAN-1:** `Letflow.Engine.Lua.Manifest.compute_hash/2` is deterministic and pure —
  no I/O, no randomness, no wall-clock or process-identity input. Equal inputs (per
  §4.2's canonicalization) always produce an equal output string.
- **INV-MAN-2:** `validate_at_load/3` never calls into `Letflow.Engine.Lua.Executor` or
  `Letflow.Engine.LuaScriptAudit`, and neither of those modules calls into
  `Letflow.Engine.Lua.Manifest` as of this requirement (the planned Step 2a change to
  `Executor`, §5.3.1, is the one exception, and is not made by this run). This is what
  keeps the load-time gate (§3) structurally independent of, and never bypassable by,
  anything on the execution path.
- **INV-MAN-3:** `LuaScriptAudit.verify_manifest_hash/2`'s own comparison and error shape
  (`{:manifest_hash_mismatch, registered_hash, actual_hash}`, INV-LSA-2) are never
  duplicated, wrapped, or shadowed by an equivalently-named function in this module —
  `Manifest`'s own mismatch error is a distinctly-named `{:manifest_mismatch, _, _}`
  tuple (§3.1), deliberately different from `LuaScriptAudit`'s
  `{:manifest_hash_mismatch, _, _}`, so a caller or test can never confuse which gate
  produced which error.
- **INV-MAN-4:** `Manifest.capabilities` is reused, never redefined, from
  `Letflow.Engine.Lua.Capabilities.capability()` — `Manifest` introduces no new
  capability-string format, prefix convention, or validation rule beyond "is a
  `String.t()`" (§2.2); any semantic validation of capability strings themselves (e.g.
  "is this a known/registrable capability") remains `Capabilities`'/`Platform`'s
  concern, not `Manifest`'s.

---

## 9. Open questions — not silently resolved

PROVENANCE (historical, not current decision authority):
**OQ-1 (non-blocking, provenance) — `R-Co/src/lua/manifest.zig` is not present in this
checkout (§0, §2.4).** Confirmed absent by `find` for both the specific file and any
`R-Co` directory at all. This design's manifest shape (`script_id` + `capabilities`) is
taken entirely from `docs/requirements.yaml` REQ-158's own restatement and from
REQ-157's already-built `Capabilities` type, not from reading the original Zig source.
No field is named here as "deliberately dropped," because the original file's field list
was never read. If a future SECURITY-REVIEWER or REVIEWER pass gains access to the
original and finds it carried additional fields this design lacks (a version/generation
number, an author/actor identity, an expiry, a signature, or something else), that
finding should be reconciled against this module rather than assumed already covered.
Not blocking, because the requirement text itself is explicit and detailed enough to
build the load-time gate and its hash from — the same non-blocking treatment REQ-157's
design gave its own identically-shaped OQ-1.

**OQ-2 (non-blocking, forward-looking) — where a manifest, its paired script artifact,
and its `registered_hash` are persisted between registration and a later load is not
decided by this design.** §3.1 states `validate_at_load/3` is pure and takes all three as
plain arguments; it does not decide what reads them from storage before calling it, or
where "registration" (the act that first establishes a `registered_hash`) is
implemented. A future requirement (plausibly REQ-159/160/161, or a dedicated
manifest-registry requirement) must supply that plumbing. Not blocking this design,
because REQ-158's own acceptance criteria (§7) are all statements about the hash
function's and the gate function's *behavior given inputs*, not about a storage layer.

**OQ-3 (non-blocking, forward-looking) — wiring a manifest's `grant_set()` (§2.3) into an
actual executing `Lua.t()` via `Platform.install/2` is not built here.** `Manifest`
provides the conversion function; no call site in this codebase invokes
`Platform.install/2` with a non-empty grant set as of this requirement (per REQ-157
design §1.1, `Sandbox.new/1` still calls the always-empty `install/1`). Left for
REQ-159/160/161 to resolve, per REQ-157 design §8's own forward reference to this
requirement, which this design in turn forwards again.

**OQ-4 (non-blocking, sequencing) — the exact point in the calling code where
`validate_at_load/3` must be invoked relative to script-registration and
script-invocation workflows is a Step 2a integration decision, not a Step 1 design
decision.** This design specifies the function and its ordering *relative to
`execute_script_for_audit/6`* (§3.2) but does not specify, because no such caller exists
yet in this codebase (mirroring `LuaScriptAudit`'s own REQ-058 "No caller yet" note, §0),
what production code path will call it first. ELIXIR-DEV should treat this the same way
REQ-058 treated its own absent caller: build the function and its tests against the
documented contract, without inventing a caller this requirement does not ask for.
