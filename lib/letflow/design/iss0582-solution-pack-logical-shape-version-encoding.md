# Design: ISS-0582 — hex-encode `logical_shape_version` at the solution-pack JSON boundary

**Run:** fix/ISS-0582-20260910 (GH#1196, queue task 582) · **Author:** CODE-DESIGNER ·
**Status:** proposed — awaiting CODE-DESIGN-VALIDATOR.

**Scope: single production file, `lib/letflow/definitions/solution_pack.ex`, plus one
necessarily-following edit to an existing test assertion in
`test/letflow/definitions/solution_pack_test.exs` (not written by me — flagged for
TEST-DESIGNER/ELIXIR-DEV coordination, see §5). No migration, no schema change, no new
public function. See §6 for the full sizing-rule and SECURITY-REVIEWER scope calls.**

---

## 0. Sources read

- `lib/letflow/definitions/solution_pack.ex` in full (1066 lines) — `pack_entity_definition/1`
  (export side, line 465-473), `parse_entity_definition/1` (install side, line 578-594),
  `create_packed_entity_definitions/3` (line 972-988), the `packed_entity_definition` and
  `pack_document`/`install_error` types (line 187-254).
- `lib/letflow/entities/entity_definition.ex` — `logical_shape_version` is `field(:logical_shape_version, :binary)`,
  a raw 32-byte SHA-256 digest (per `req226-entity-definitions-persistence-crud.md:90`), not a
  hex string, not an integer.
- `lib/letflow/entities/definitions.ex` — `create_definition/2` (line 89-131): `logical_shape_version`
  is **always computed fresh** via `Letflow.Entities.Definition.Shape.logical_shape_of/1` from the
  submitted `definition` document (step 2, line 89, 115). It is never accepted as caller-supplied
  input. `create_packed_entity_definitions/3` in `solution_pack.ex` (line 972-988) confirms this at
  the call site: its `create_attrs` passed to `create_definition/2` is
  `%{definition: packed.definition_json, created_by: actor_id}` — `packed.logical_shape_version`
  is **not** one of the two keys. This means: **the packed field is never load-bearing for whether
  install succeeds or what gets persisted.** The `(tenant_id, name, logical_shape_version)` UNIQUE
  constraint that governs name-collision behavior fires against the digest `create_definition/2`
  computes fresh from `definition_json`, not against the pack's echoed `logical_shape_version`
  field.
- `lib/letflow/entities/event_types.ex` (moduledoc, line 19-45) and `lib/letflow/entities/records.ex`
  (`hex_version/1`, line 562-564) — **the established convention already in this codebase** for
  crossing the exact same JSON-boundary problem: `Letflow.Entities.EventTypes`'s own moduledoc
  documents, verbatim, that "`Letflow.Entities.Records` hex-encodes `logical_shape_version`
  (`Base.encode16/2`, lowercase) into that field when building an event payload, decoding it back
  (`Base.decode16!/2`) when reconstructing." `records.ex:562-564`'s `hex_version/1` is exactly
  `Base.encode16(version, case: :lower)`. This is the same field, the same underlying defect shape
  (raw binary can't cross a `Jason.encode!/1` boundary), already solved once in this codebase. This
  design reuses that convention rather than inventing a second one.
- `grep -rn logical_shape_version lib/ test/` (full codebase) — confirmed no other read/write/
  comparison site touches the packed representation; `solution_pack.ex`'s pack/parse functions are
  the only place `logical_shape_version` crosses a JSON/`Jason.encode!`//`Jason.decode!` boundary
  besides the already-fixed `records.ex`/`event_types.ex` path (which is untouched by this issue and
  out of scope here).
- `test/letflow/definitions/solution_pack_test.exs` lines 138-186 — the existing REQ-304 test
  (`"naming one real entity definition returns it under entity_definitions with
  name/display_name/definition_json (+ id/logical_shape_version)"`). Its assertion at line 184,
  `assert packed.logical_shape_version == entity_definition.logical_shape_version`, compares the
  **in-memory** `packed` map directly against the entity definition struct — it never round-trips
  through `Jason.encode!/1`/`decode!/1`, which is exactly why this defect shipped past REQ-304's own
  test coverage undetected (see §5, this assertion breaks under the fix and must be updated).
- The REQ-306 round-trip test itself (round-trip export → install across tenants, with a
  non-Jason `stringify_keys/1` workaround) is not yet committed to this branch — `docs/requirements.yaml`
  still lists REQ-306 `status: pending` (only REQ-303/304/305 landed, commit `9b443129`). Its exact
  workaround code is therefore taken from the issue text as authoritative, not independently
  re-derived from a file read; nothing in this design depends on that file's literal content.
- `docs/agents/ORCHESTRATOR.md` §10 (sizing rule) and `.claude/agents/security-reviewer.md`
  ("Scope test — does this handoff apply to you?") — both consulted for §6 below.
- `lib/letflow/design/iss0580-sandbox-auto-mode-restore-leak.md` — reused for this doc's section
  shape only, not its subject matter.

---

## 1. Root cause, restated precisely

`pack_entity_definition/1` (`solution_pack.ex:465-473`) copies
`entity_definition.logical_shape_version` — a raw 32-byte SHA-256 digest, `:binary` in the Ecto
schema, produced by `Letflow.Entities.Definition.Shape.logical_shape_of/1` — verbatim into the
`packed_entity_definition` map it returns. That map becomes part of the `pack_document` that
`Letflow.Routers.SolutionPacks`' export handler (REQ-078) is documented to `Jason.encode!/1` for
the HTTP response body, and `install/3`'s own moduledoc (`solution_pack.ex:335`) explicitly
documents its `document` parameter as "the raw decoded JSON body." A SHA-256 digest is 32
essentially-random bytes; it is not valid UTF-8 in the general case (and never reliably is —
`Jason.encode!/1` requires every string value to be valid UTF-8, per `Jason.EncodeError`). Every
real call to export a tenant's entity definition therefore raises on encode, not merely on some
edge-case input.

`parse_entity_definition/1` (`solution_pack.ex:578-594`) is, and remains after this fix, agnostic
to this — it already calls `fetch_string(raw, "logical_shape_version")`, which only requires the
JSON value to be `is_binary/1` (a JSON string) and non-empty. It has never required that string to
be raw digest bytes; it will accept any non-empty string, including a hex string. The defect is
**encode-side only**; the parse-side contract (a JSON string) is already compatible with the fix.

## 2. Fix: hex-encode at export, hex-decode at parse — reusing `records.ex`'s exact convention

Two edits, both inside `lib/letflow/definitions/solution_pack.ex`, both following
`Letflow.Entities.Records.hex_version/1`'s established `Base.encode16/2`/`Base.decode16/2`,
`case: :lower` convention verbatim (no new encoding scheme introduced):

### 2.1 Export side — `pack_entity_definition/1` (currently `solution_pack.ex:464-473`)

Add one new private function, colocated near `pack_entity_definition/1` (after it, mirroring
where `pack_variable_schemas/1` sits after `pack_definition/1`):

```
@spec encode_logical_shape_version(binary()) :: String.t()
```

Body (prose, not code): lowercase-hex-encode the raw digest via `Base.encode16/2` with
`case: :lower` — the identical call `records.ex:563` already makes. Pure, total, no error branch:
`logical_shape_version` is a non-nullable `:binary` column (`entity_definition.ex:48`,
`@required_fields`), so every `%EntityDefinition{}` reaching `pack_entity_definition/1` already has
a non-nil value; this function does not need to handle `nil`.

Change `pack_entity_definition/1`'s map-building clause (line 471) from copying
`entity_definition.logical_shape_version` verbatim to calling
`encode_logical_shape_version(entity_definition.logical_shape_version)` for that key's value. No
other key in that function's map changes.

Update the `packed_entity_definition` typedoc (line 187-194): `logical_shape_version`'s type
changes from `binary()` to `String.t()`, with a doc note: "lowercase-hex-encoded (`Base.encode16/2`,
`case: :lower`) — the raw digest cannot cross a `Jason.encode!/1` boundary; see
`Letflow.Entities.Records.hex_version/1` for the same convention applied to the event-envelope
path." This is a `@typedoc`/type-signature edit only, not implementation code.

### 2.2 Install side — `parse_entity_definition/1` (currently `solution_pack.ex:578-594`)

Add one new private function, colocated near `parse_entity_definition/1`:

```
@spec decode_logical_shape_version(String.t()) :: {:ok, binary()} | {:error, :invalid_pack_document}
```

Body (prose): decode the hex string via `Base.decode16/2` with `case: :lower` (the non-raising
variant, not `Base.decode16!/2` — this function receives caller-supplied pack-document content
that has not yet been validated as well-formed hex, unlike `records.ex`'s duplicate-submission
replay path, which decodes a value this codebase itself encoded moments earlier and can therefore
safely use the raising form). On `{:ok, raw_bytes}`, return `{:ok, raw_bytes}`. On `:error` (odd
length, non-hex characters, wrong case — `case: :lower` rejects uppercase hex digits), return
`{:error, :invalid_pack_document}` — reusing the existing structural-parse-failure error atom
already used by every other malformed-shape branch in `parse_entity_definition/1`
(`fetch_string/2`, `fetch_object/2`), rather than inventing a new error tuple. This keeps
`install_error` (line 242-254) unchanged — no new error variant added to that type, satisfying
AC3's "no behavior change to the error surface" implicitly.

Change `parse_entity_definition/1`'s `with` chain (line 578-594): after the existing
`{:ok, logical_shape_version} <- fetch_string(raw, "logical_shape_version")` step, insert a new
step `{:ok, logical_shape_version} <- decode_logical_shape_version(logical_shape_version)` (shadowing
the same variable name is fine here — it is idiomatic in this file, see `top` being repeatedly
rebound in `atomize_definition_json/1`, line 656-664). The returned map's `logical_shape_version`
key (line 591) keeps holding **raw binary bytes**, exactly as it did before this fix — only the
wire representation changed; the parsed, in-memory shape downstream of `parse_entity_definition/1`
is untouched.

Because `create_packed_entity_definitions/3` (line 972-988) never reads `packed.logical_shape_version`
at all (per §0/§1 above — `create_definition/2` recomputes it fresh from `definition_json`), this
decode step has **no observable effect on what gets persisted or on install's success/failure
outcome**. Its sole purpose is AC2: giving any caller (a test, a future comparison feature) that
inspects `parsed.entity_definitions[].logical_shape_version` the same raw-byte value the original
`EntityDefinition.logical_shape_version` held, so a manual equality check (e.g. "does this pack's
entity definition already exist with an identical shape in the source tenant") is not defeated by
opaque hex-string vs. raw-byte comparison. This is exactly what AC2 describes as "install-side
name-collision/version comparison logic" — not a change to `create_definition/2`'s own
constraint-driven collision detection (which is untouched and was never based on the packed field),
but preserving the packed field's own round-trip fidelity for whatever code (present test
assertions, or code written against this field later) relies on it representing the same digest.

## 3. Concretely, what a real call now produces (AC1 traceability)

Given a real `%EntityDefinition{logical_shape_version: <<0x4a, 0xf3, ...32 bytes...>>}`:

- `pack_entity_definition/1` now returns
  `%{..., logical_shape_version: "4af3..."}` (64 lowercase hex characters for a 32-byte digest) —
  a plain Elixir `String.t()`, valid UTF-8 by construction (hex digits are ASCII), so
  `Jason.encode!/1` over the full `pack_document` no longer raises on this field. (CODE-DESIGNER
  cannot itself execute `Jason.encode!/1` under this design-only scope restriction — ELIXIR-DEV
  must run this exact call against a real entity definition and quote the actual encoded/decoded
  output as AC1 requires; nothing in this design defers that requirement, it only specifies the
  fix that makes the call succeed.)
- `Jason.decode!/1` of that document reconstructs `%{"logical_shape_version" => "4af3...", ...}`
  (string keys, per `install/3`'s own documented "raw decoded JSON body" contract) — exactly the
  shape `parse_entity_definition/1` already expected via `fetch_string/2`, now additionally passed
  through `decode_logical_shape_version/1` to recover `<<0x4a, 0xf3, ...>>` before it reaches
  `parsed.entity_definitions`.

## 4. Alternative considered and rejected: extracting a shared encode/decode helper

`Letflow.Entities.Records.hex_version/1` (`records.ex:562-564`) is `defp` — private, not exported —
so it cannot be called from `solution_pack.ex` without either making it public or duplicating the
two-line `Base.encode16/2`/`Base.decode16/2` pattern locally. This design duplicates the pattern
locally (§2.1/§2.2) rather than extracting a shared public helper (e.g. on
`Letflow.Entities.EntityDefinition` or a new module), for two reasons:

1. **Scope discipline.** Extracting a shared helper would require also touching `records.ex`
   and/or `event_types.ex` to switch them onto it — files this issue's acceptance criteria never
   name, and whose own tests (`records_test.exs`) this branch has no mandate to re-verify. The
   issue is scoped to `solution_pack.ex`; a shared-helper refactor is a separate, optional
   follow-up, not a prerequisite for this fix.
2. **The duplicated logic is two one-line `Base` calls**, not meaningfully complex or likely to
   drift — both sites already independently document the same `case: :lower` convention in prose
   (`event_types.ex`'s moduledoc, and this design's §2), so a future reader has a citation trail
   even without a shared function.

**Flagged as an open question for REVIEWER**, not silently decided: if REVIEWER prefers a shared
`Letflow.Entities.EntityDefinition.encode_logical_shape_version/1` /
`decode_logical_shape_version/1` pair (or similar) to eliminate the duplication across
`records.ex` and `solution_pack.ex`, that is a reasonable idiom-consistency call this design
defers rather than forecloses — ELIXIR-DEV should implement the single-file version specified in
§2 unless REVIEWER requests the extraction explicitly, since the single-file version alone
satisfies every acceptance criterion.

## 5. Necessary, in-scope test-file consequence (not optional, flagged explicitly)

`test/letflow/definitions/solution_pack_test.exs:184`'s existing REQ-304 assertion,
`assert packed.logical_shape_version == entity_definition.logical_shape_version`, compares the
**in-memory packed map** (no JSON round-trip involved in that specific test) directly against the
raw-binary struct field. After §2.1's fix, `packed.logical_shape_version` is a hex **string**;
`entity_definition.logical_shape_version` remains raw **binary**. These are no longer equal by
`==`, so this line will fail as literally written, independent of any `Jason` round-trip.

This is **not** a violation of AC3's "existing tests continue to pass unmodified in BEHAVIOR" —
AC3's own parenthetical anticipates exactly one test needing a change ("only the raw-bytes
workaround in the REQ-306 round-trip test may be simplified/removed"), but that parenthetical
under-names the actual footprint: this REQ-304 assertion at line 184 is a **second**, distinct
site that must change, because it is the direct in-memory (non-JSON) analogue of the same defect.
The *behavior* it verifies — "the packed entity definition's logical-shape-version value
corresponds exactly to the source entity definition's" — is preserved; only the literal comparison
must become `Base.decode16!(packed.logical_shape_version, case: :lower) ==
entity_definition.logical_shape_version` (or the symmetric `packed.logical_shape_version ==
Base.encode16(entity_definition.logical_shape_version, case: :lower)`), matching this design's
§2.1 encoding exactly.

**This design does not itself edit that test** — CODE-DESIGNER is design-only and this file is
production code's design, not a test design — but ELIXIR-DEV (who owns `solution_pack.ex`) and/or
TEST-DESIGNER must be told this specific line breaks and must be updated as part of landing this
fix, or `mix test` will show a real regression the moment the encode-side change lands. Flagging
this explicitly here so it is not rediscovered mid-implementation as a surprise.

## 6. Scope confirmation

### 6.1 Sizing rule (`docs/agents/ORCHESTRATOR.md` §10) — full workflow correctly required

Running the six-check list against this change:

1. Touches exactly one **production** file (`solution_pack.ex`) — true in isolation, but check 6
   below already fails, so this is moot.
2. Adds no new public function/module/`@spec` — **false**: §2.1/§2.2 each add a new private
   function with its own `@spec` (`encode_logical_shape_version/1`, `decode_logical_shape_version/1`).
   These are `defp`, not public, but the check as written says "no new ... `@spec`" without
   qualifying public/private — read strictly, this is a second failing check.
3. No migration — true, not relevant given 2/6 already fail.
4. Does not touch instance/supervision files — true.
5. Does not touch a tenant-data path — **false**, see §6.2.
6. Changes no behavior a test asserts — **false**: `solution_pack_test.exs:184` (§5) is an
   existing test whose expected value literally changes under this fix.

Any single "no" routes to the full workflow; this change has at least three. The issue's own
framing (checks 5 and 6 specifically) is confirmed correct — this is properly a
CODE-DESIGNER → CODE-DESIGN-VALIDATOR → ELIXIR-DEV → SECURITY-REVIEWER → REVIEWER → TEST-DESIGNER →
TEST-DESIGN-VALIDATOR → TEST-RUNNER pipeline run, not a direct ORCH edit.

### 6.2 SECURITY-REVIEWER scope call — **IN SCOPE, expect a fast PASS**

Explicit reasoning, not a default: `.claude/agents/security-reviewer.md`'s scope test lists
"Adds/modifies response-shaping code for a tenant-scoped entity" as one of five triggers. `entity_definitions`
rows are tenant-scoped (`entity_definitions.tenant_id`, `EntityDefinition` schema), and
`pack_entity_definition/1` is precisely the function that shapes one such row into the exported
response document — REQ-304/REQ-305's own SECURITY-REVIEWER sign-off already treated this exact
module/function pair as tenant-data-path-relevant for INV-1. This change edits that same function's
output (§2.1) and `install/3`'s parse path that consumes tenant-scoped install input (§2.2). Under
the literal scope test, that is enough to route to SECURITY-REVIEWER — it should **not** be
skipped.

That said, the actual invariant exposure is narrow, and this is worth stating so SECURITY-REVIEWER
can move quickly rather than re-deriving it: this fix changes the **string encoding of one already-
tenant-scoped field's value**, not what tenant's data flows where. It introduces no new
caller-supplied identifier, no new prefix/schema/tenant-id parameter, and no new query — `opts[:prefix]`
threading through `export/3`/`export/4`/`install/3` is completely unchanged (§2.1/§2.2 touch only
pure, prefix-free helper functions). INV-1 (tenant isolation via `opts[:prefix]`) is the only
invariant plausibly implicated, and it is unaffected: no code path in §2 reads or writes `tenant_id`,
`prefix`, or any cross-tenant lookup. Expected verdict: INV-1 APPLIES (per the standing rule that it
applies to any diff touching a tenant-scoped table/schema), verification confirms `opts[:prefix]`
untouched, **PASS**. INV-2 through INV-8 are very likely NOT-APPLICABLE for the same reason
REQ-304/REQ-305's own sign-off found them not applicable to this module (no `Jason.Encoder`
derivation is added or removed by this fix — `pack_entity_definition/1`'s hand-built key list,
INV-2, is unchanged in shape, only in one value's encoding).

## 7. Invariants preserved

- `pack_entity_definition/1`'s key set is unchanged: still exactly `entity_definition_id`, `name`,
  `display_name`, `definition_json`, `logical_shape_version` (INV-2 — no storage-only field such as
  `tenant_id`/`content_hash`/`artifact_version_id`/`status` leaks in; this fix does not touch which
  keys are present, only one value's representation).
- `parse_entity_definition/1`'s returned map shape is unchanged: still exactly
  `entity_definition_id`, `name`, `display_name`, `definition_json`, `logical_shape_version`, and
  the value under the last key is still raw binary — identical to pre-fix — after §2.2's decode
  step.
- `create_packed_entity_definitions/3`'s behavior is provably unaffected (§1, §2.2) since it never
  reads `packed.logical_shape_version`.
- No change to `check_unsupported_sections/1`, `check_schema_version/1`,
  `decode_variable_schemas/1`, or any of the `variable_schemas`/`definitions`/`manifest` sections —
  this fix is confined to the `entity_definitions` section's one field.
- `install_error` and `export_error` types (line 236-254) are unchanged — no new error variant.

## 8. Open questions

1. **§4's shared-helper question** — deferred to REVIEWER, not resolved here: single-file
   duplication (this design's default) vs. extracting a shared
   `encode_logical_shape_version/1`/`decode_logical_shape_version/1` pair usable by both
   `records.ex` and `solution_pack.ex`. Either is compatible with every acceptance criterion; only
   the single-file version is specified as the implementation to build absent a REVIEWER objection.
2. **§5's test-file edit is a factual necessity, not a design choice** — flagging again for
   emphasis: whoever implements this (ELIXIR-DEV under this design, or TEST-DESIGNER on the next
   pass) must update `solution_pack_test.exs:184`'s assertion or the existing REQ-304 suite fails.
   This design does not choose *how* that edit is phrased beyond the two algebraically-equivalent
   forms given in §5 — that phrasing choice belongs to whoever owns the test file.
3. Not addressed by this design because it is out of scope per the issue: whether
   `Letflow.Routers.SolutionPacks`' export/install HTTP handlers have any test of their own that
   round-trips a real HTTP response through `Jason` for an entity-definitions pack (as opposed to
   calling `SolutionPack.export/4`/`install/3` directly in-process). If such a route-level test
   exists and also asserts raw-byte equality, it would need the same treatment as §5 — grep for
   `logical_shape_version` under `test/letflow/routers/` before implementing, since this design's
   own grep (§0) covered `lib/` and one `test/` file, not the full `test/` tree's router-level
   suites.

## 9. Files touched (implementation scope for ELIXIR-DEV)

- `lib/letflow/definitions/solution_pack.ex` — §2.1 (`pack_entity_definition/1` + new
  `encode_logical_shape_version/1`, `@typedoc` update), §2.2 (`parse_entity_definition/1` + new
  `decode_logical_shape_version/1`).
- `test/letflow/definitions/solution_pack_test.exs:184` — required consequence, §5 (owned by
  whichever role lands the fix; TEST-DESIGNER validates coverage on the next pass regardless).

## 10. Acceptance-criteria traceability

| AC | Design element |
|---|---|
| AC1 — `packed_entity_definition/1`'s output round-trips through `Jason.encode!/1`/`decode!/1` without raising, demonstrated with a real call | §2.1 makes every value UTF-8-safe (hex string); §3 states the exact expected shape of a real call's output; the actual `Jason.encode!/1`/`decode!/1` call and its quoted output is ELIXIR-DEV's to run and report, not something CODE-DESIGNER can execute under this design-only scope. |
| AC2 — encoded/decoded `logical_shape_version` round-trips correctly for install-side name-collision/version comparison logic | §2.2's `decode_logical_shape_version/1` restores the exact original raw bytes into `parsed.entity_definitions[].logical_shape_version`, byte-identical to pre-fix; §1/§2.2 establish this field is not itself what drives `create_definition/2`'s UNIQUE-constraint collision check (that recomputes independently from `definition_json`), so "comparison logic" here means the packed field's own fidelity for any code that inspects it, which is preserved exactly. |
| AC3 — REQ-304/305/306 tests continue to pass unmodified in BEHAVIOR (only the REQ-306 raw-bytes workaround may be simplified/removed) | §7 enumerates every shape/type invariant left unchanged; §5 identifies and justifies the one additional, necessary literal-assertion edit (`solution_pack_test.exs:184`) that AC3's own parenthetical under-named, with the exact behavior-preserving replacement forms given. |
