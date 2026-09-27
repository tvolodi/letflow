# ISS-0833 (addendum_2026_09_26_b) — Fix design: a safe declaration escape hatch for A4b's `unparseable_at` sub-check

**Issue:** ISS-0833 (queue Q-833, GH-1831), addendum `addendum_2026_09_26_b` · **Step:** CODE-DESIGNER
**Scope:** the ONE residual failure in `test/docs/requirement_status_invariants_test.exs` —
`"A4b: the on-disk shape-violation set equals known_shape_anomalies:, and every record cites
a closed, pinned volume"` — specifically its `unparseable_at` sub-check, for exactly 9 entries
in the closed, digest-pinned `docs/status/requirement_status.v22.yaml`: REQ-405, REQ-409,
REQ-410, REQ-411, REQ-412, REQ-413, REQ-414, REQ-415, REQ-416.

This is a design artefact. No implementation code — `@spec`-only signatures, field-shape
tables, and prose. ELIXIR-DEV implements from this; TEST-DESIGNER writes the negative
controls this doc specifies.

---

## 1. The gap, restated precisely

`test/support/status_history.ex`'s `shape_anomalies/1` and the test file's own
`unparseable_at/2` (private, `requirement_status_invariants_test.exs:744-770`) are two
different detectors over the same 9 malformed entries:

- `shape_anomalies/1` finds, per entry, a `misnamed_field`/`field: "at"` record (the `at:`
  slot is occupied by an undocumented field — `summary:` for 8 entries, `workflow:` for
  REQ-405) **and** a separate `extra_field` record (the real timestamp, sitting under
  `timestamp:`, two-to-six lines away). All 18 records (2 per entry × 9) are already
  correctly declared in `docs/status/requirement_status.index.yaml`'s
  `known_shape_anomalies:` and satisfy A4b's `undeclared`/`unfound`/`misattributed`/
  `not_closed_and_pinned` sub-checks — confirmed by reading the index at lines 5201–5389+
  (this doc's investigation) and by the issue's own addendum.
- `unparseable_at/2`'s `from_declared` clause (lines 754-767) walks exactly those declared
  `misnamed_field`/`field: "at"` records, re-reads the ACTUAL file content at each one's
  `found_line` (never trusting the declaration's own text), and reports a finding whenever
  that live-read value does not parse as ISO-8601. For these 9 entries the live-read value
  IS `>` (a YAML fold marker, for the 8 `summary:` cases) or `WF02-REQ405-20260925` (a run-id,
  for the `workflow:` case) — genuinely unparseable, by design (design §13.5's explicit
  "declaring the field NAME wrong does not license an unparseable timestamp").

There is no declaration key that can silence `unparseable_at`'s finding for these 9 records.
`a4b_clean?/1` ANDs five sub-checks; `unparseable_at` is the one with no escape hatch at all.

The real timestamp is not missing data — it is present, in the same entry, under the
already-declared `extra_field`/`timestamp` record, and IS ISO-8601-parseable (verified by
reading the volume directly: `requirement_status.v22.yaml:860` is
`timestamp: 2026-09-25T03:39:10Z`; `:1113` is `timestamp: 2026-09-26T00:10:00Z`; the
remaining 7 follow the same pattern). The gap is architectural, not data-quality: the two
detectors don't talk to each other, and nothing lets a human assert "the real value lives
over there, and it's fine" without also being able to assert "trust me, it's fine" for an
entry that has no real timestamp anywhere.

---

## 2. Chosen mechanism: (a), a same-entry cross-referencing declaration

New index key **`known_unparseable_at:`**, sibling to `known_shape_anomalies:`. A record in
it exempts one `unparseable_at`/`from_declared` finding **only when a second, independently
declared and disk-verified record on the SAME entry can be mechanically read to actually
contain a parseable timestamp.** Nothing about the exemption is taken on the declaration's
word — every fact it depends on is re-derived from disk at check time, exactly as
`unparseable_at/2` already does for the primary `misnamed_field` finding it's paired with.

### 2.1 Why (a) over a looser alternative

Two looser alternatives were considered and rejected:

- **A bare `known_unparseable_at:` list keyed only by `{path, entry_line}`, taken on faith
  once declared.** Rejected: this is exactly the hole design §13.5 was already built to
  close — "declaring the field NAME wrong does not license an unparseable timestamp" is a
  general statement, and a bare list would let any entry with ANY `misnamed_field`/`at`
  finding be silenced by adding one line, real timestamp elsewhere or not. It would not
  distinguish these 9 genuinely-recoverable entries from a hypothetically-truly-corrupt one.
- **Relaxing `unparseable_at/2` to accept any parseable value found ANYWHERE in the entry's
  raw text (auto-search, no declaration at all).** Rejected: this makes the checker itself
  do undeclared, un-reviewed inference over free text (a `note:` block could easily contain
  an incidental ISO-8601-shaped substring — a date mentioned in prose) — turning a
  declared, audited exception list into a silent heuristic. It would also not fit the
  project's established pattern (`known_anomalies:`/`known_shape_anomalies:`) of "every
  known deviation from the documented shape is enumerated and reviewed once, not
  re-inferred every run."

(a) keeps the project's existing shape: a small, explicitly declared, mechanically
re-verified list — the same posture as `known_shape_anomalies:` itself — extended with one
additional cross-check (a sibling record must exist and its OWN cited line must
independently parse). This is additive, not a loosening of the existing unconditional check:
`unparseable_at`'s live-read-and-parse logic for the PRIMARY record is untouched; the new
key only ever *removes* an already-computed finding, and only after re-deriving, from disk,
that the removal is warranted.

### 2.2 Schema: `known_unparseable_at:` record

One record per exempted `misnamed_field`/`field: "at"` finding (9 records total for this
fix — one per affected entry; REQ-405 needs exactly one, not two, despite having two
`known_shape_anomalies:` records, because only the `misnamed_field`/`at` one feeds
`unparseable_at`'s `from_declared` clause — the `extra_field` one is the sibling being
cited, not itself a finding needing exemption).

| Field | Type | Meaning |
|---|---|---|
| `path` | `String.t()` | Volume path. Must equal the exempted record's `path`. |
| `entry_line` | `pos_integer()` | The entry's `- req:` line. Must equal the exempted record's `entry_line`. |
| `req` | `String.t()` | Same `req:` as the entry (cross-check / readability, not load-bearing). |
| `field` | `"at"` (literal) | Always `"at"` — this key only ever exempts the `at:` slot. |
| `found_as` | `String.t()` | Must equal the `known_shape_anomalies:` `misnamed_field`/`field: "at"` record's own `found_as` for this `{path, entry_line}` (`"summary"` or `"workflow"`). |
| `found_line` | `pos_integer()` | Must equal that same record's `found_line` (the line holding the unparseable fold-marker / run-id text). Redundant with the lookup by design — see §2.3 step 2 — kept as a second independent equality check, not a convenience. |
| `verified_via` | `%{kind: "extra_field", field: String.t(), found_line: pos_integer()}` | Names the SIBLING `known_shape_anomalies:` record — by `kind`, `field` (e.g. `"timestamp"`), and `found_line` — whose own on-disk content is the real timestamp. |
| `should_have_been` | `String.t()` | Prose, matching the project's existing convention on every other declared record. |
| `cause` | `String.t()` | Prose, matching the project's existing convention. |

### 2.3 Verification algorithm (prose — no bodies, per the "no implementation code" rule)

For each `unparseable_at`/`from_declared` candidate finding `f` (a record shaped
`%{path:, entry_line:, field: found_as, value:}` — see current lines 762-767):

1. **Look up.** Find a `known_unparseable_at:` record `x` with
   `x.path == f.path and x.entry_line == f.entry_line and x.found_as == f.field`. None found
   → `f` is NOT exempt (falls through to `unparseable_at` as today; this is the default,
   fail-closed state — a bug pattern absent a declaration stays red, exactly as it does now).
2. **Cross-check the sibling exists and is itself declared.** Find a
   `known_shape_anomalies:` record `s` with `s.path == x.path and s.entry_line == x.entry_line
   and s.kind == "extra_field" and s.field == x.verified_via.field and
   s.found_line == x.verified_via.found_line`. None found → NOT exempt. (This is the crux
   of the anti-gaming property — see §3.)
3. **Re-read disk, live, at the sibling's line — never at the declaration's own claimed
   value.** `value = value_at(x.path, x.verified_via.found_line)` (reuse the existing
   `value_at/2` helper, unchanged).
4. **Mechanically re-parse.** `parseable_iso8601?(value)` (reuse the existing predicate,
   unchanged). `false` → NOT exempt. `true` → `f` IS exempt; drop it from the finding set.
5. **Closed-and-pinned, same as every other declared record.** `x`'s `path` must also pass
   `closed_pinned_and_warranted?/3` (the same helper `known_shape_anomalies:` records are
   already checked against) — an exemption citing a volume that is not closed-and-pinned is
   itself a finding (§2.4), not a silent pass.

### 2.4 New/changed function signatures

`test/support/status_history.ex`:

```
@spec parse_index(Path.t()) :: %{
        roll_rule: map(),
        volumes: [map()],
        known_anomalies: [map()],
        known_shape_anomalies: [map()],
        known_unparseable_at: [map()]
      }
```
(`parse_index/1`'s body already parses arbitrary named sections generically via
`split_sections/1` + `parse_list/1` — adding a `known_unparseable_at:` section is the same
pattern as `known_shape_anomalies:` one line above it. No new parsing primitive needed; the
existing `denull/1` normalisation should also be applied to this section for the same reason
it's applied to `known_shape_anomalies:` — a nested map field (`verified_via:`) parses as a
flat prefix under the current line-oriented parser, so `verified_via_kind`/`verified_via_field`/
`verified_via_found_line` are the ACTUAL on-disk key names `parse_list/1` will produce (see
§2.5 — this is a real constraint on the YAML shape, not free choice).)

`test/docs/requirement_status_invariants_test.exs` (private test-only functions):

```
@spec unparseable_at(volumes :: [map()], declared :: [map()], exemptions :: [map()]) ::
        [map()]
```
(signature grows one arg — `exemptions` is `index.known_unparseable_at`; `from_declared`'s
comprehension gains one `Enum.reject/2` pass using `exempt_unparseable_at?/2` below, applied
ONLY to `from_declared` candidates, never to `from_disk` ones — an on-disk entry whose
CORRECTLY NAMED `at:` field is itself unparseable is a different, more serious defect this
mechanism must not be reachable from; see §3.4)

```
@spec exempt_unparseable_at?(exemptions :: [map()], known_shape_anomalies :: [map()],
        candidate :: map()) :: boolean()
```
(implements §2.3 steps 1-4; steps not applicable to closed-volume gating live in the next
function)

```
@spec invalid_unparseable_at_exemptions(volumes :: [map()], roll_rule :: map(),
        known_shape_anomalies :: [map()], exemptions :: [map()]) :: [map()]
```
(NEW finding — §2.5's 6th A4b sub-check: every `known_unparseable_at:` record that fails
§2.3 step 2, step 4, or step 5. This is what makes a bogus declaration LOUD instead of
silently inert — see §3.2.)

`a4b_findings/1` gains one key:

```
%{
  undeclared: [...],
  unfound: [...],
  not_closed_and_pinned: [...],
  misattributed: [...],
  unparseable_at: unparseable_at(index.volumes, declared, index.known_unparseable_at),
  invalid_unparseable_at_exemptions:
    invalid_unparseable_at_exemptions(index.volumes, index.roll_rule, declared,
      index.known_unparseable_at)
}
```

`a4b_clean?/1`'s list of checked keys grows from 5 to 6
(`:invalid_unparseable_at_exemptions` added). `a4b_message/2` gains one more labelled
section, same pattern as the other five (design §13.5's "message is part of the contract" —
so the new section needs its own explanatory paragraph, not just a count, matching every
existing one in that function).

### 2.5 On-disk YAML shape for the 9 real declarations (ELIXIR-DEV writes these verbatim; not reproduced here as literal YAML per this doc's "no implementation" scope, but the exact fields are specified)

Because `parse_list/1`'s field parser (`test/support/status_history.ex:489-510`) only
recognises TWO indentation levels (`  - key: value` starts an item, `    key: value` adds a
flat field to it — see the two regexes at lines 190/492-493, no nested-mapping support),
`verified_via:` CANNOT be written as a nested YAML mapping under a `known_unparseable_at:`
record — it must be three flat sibling fields at the record's own indentation, using a
prefix convention consistent with how the rest of the project already reads (`roll_rule:`'s
own fields are flat too). Concretely, each of the 9 records needs exactly these flat keys:

`path`, `entry_line`, `req`, `field` (literal `"at"`), `found_as`, `found_line`,
`verified_via_kind` (literal `"extra_field"`), `verified_via_field`, `verified_via_found_line`,
`should_have_been`, `cause`.

`exempt_unparseable_at?/2`'s lookups in §2.3 read `x.verified_via_field` /
`x.verified_via_found_line` accordingly (not `x.verified_via.field` — the flat names are
the REAL parsed shape, and the nested-map framing in §2.2's table is the CONCEPTUAL shape;
§2.2's table names the nested form for readability of intent, this section is the
authoritative on-disk field-name list ELIXIR-DEV must use).

The 9 records' concrete field values (derivable directly from the `known_shape_anomalies:`
entries already read in §1 — ELIXIR-DEV should re-derive them from `SH.shape_anomalies/1`
output rather than transcribe this table, per this project's existing practice noted in
`addendum_2026_09_26_b` ("declared... verified programmatically... rather than transcribed
by hand")):

| req | entry_line | found_as | found_line | verified_via_field | verified_via_found_line |
|---|---|---|---|---|---|
| REQ-405 | 858 | workflow | 862 | timestamp | 860 |
| REQ-409 | 1111 | summary | 1116 | timestamp | 1113 |
| REQ-410 | 1127 | summary | 1132 | timestamp | 1129 |
| REQ-412 | 1144 | summary | 1149 | timestamp | 1146 |
| REQ-411 | (read from disk — same pattern, entry_line 1161-ish per index ordering) | summary | (sibling) | timestamp | (sibling) |
| REQ-413 | (read from disk) | summary | (sibling) | timestamp | (sibling) |
| REQ-414 | (read from disk) | summary | (sibling) | timestamp | (sibling) |
| REQ-415 | (read from disk) | summary | (sibling) | timestamp | (sibling) |
| REQ-416 | (read from disk) | summary | (sibling) | timestamp | (sibling) |

(REQ-411/413/414/415/416's exact `entry_line`/`found_line` pairs were visible in this
session's index read at lines ~5395-5666 but are elided here rather than hand-copied, per
the same "re-derive, don't transcribe" discipline the addendum itself calls out — ELIXIR-DEV
has both the index (already declaring the `misnamed_field`/`at` and `extra_field`/`timestamp`
records for all 9) and `SH.shape_anomalies/1` to cross-check against directly.)

---

## 3. Adversarial trace — could this be gamed?

**Attack: declare a `known_unparseable_at:` record for an entry that has NO real timestamp
anywhere, to smuggle a genuinely-corrupt `at:` value past A4b.**

Walk it through §2.3 mechanically:

1. Attacker writes a `known_unparseable_at:` record citing `{path, entry_line, found_as}`
   matching a real (or even fabricated) `misnamed_field`/`at` finding, and a `verified_via`
   pointing at SOME field/line they claim holds the real timestamp.
2. **Step 2 of §2.3 fires:** the checker does not trust `verified_via`'s claim that this
   field/line holds a timestamp — it requires a MATCHING record to already exist in
   `known_shape_anomalies:` with `kind: "extra_field"` at that exact `{path, entry_line,
   field, found_line}`. Two sub-cases:
   - **If the attacker also fabricates that `extra_field` declaration:** it must ALSO match
     what's actually on disk, because `known_shape_anomalies:` is itself under A4b's
     existing `undeclared`/`unfound` set-equality check (§13.5's pre-existing mechanism,
     unchanged by this fix). A fabricated `extra_field` record naming a field/line that
     ISN'T actually an extra field on that entry (e.g., citing a line that's part of the
     `note:` block, or doesn't exist, or is already one of the five documented fields)
     fails `SH.shape_anomalies/1`'s own on-disk computation — it becomes an `unfound`
     finding (declared but not on disk) and A4b goes red on THAT sub-check, independent of
     `unparseable_at`. The attacker cannot get a free-standing exemption without ALSO
     tripping the pre-existing, already-hardened symmetric-difference check.
   - **If the attacker points at a real, already-legitimately-declared `extra_field`
     record:** that record's `found_line` is real, on-disk, extra-field content — by
     construction of what `extra_field` means in `shape_anomalies/1` (§13.7: a field beyond
     the five, not otherwise accounted for). Step 4 of §2.3 then LIVE-READS that exact
     line and mechanically re-parses it. If it genuinely isn't a timestamp (e.g. the
     attacker points at an entry's stray `run_id:` extra field, which is real but not a
     timestamp), `parseable_iso8601?/1` returns `false`, the exemption fails step 4, and —
     because of the NEW `invalid_unparseable_at_exemptions` finding (§2.4) — this is not a
     quiet no-op: it is itself a reported A4b failure, forcing the bogus declaration to be
     visibly wrong rather than silently inert.
3. **There is no path where a fabricated timestamp claim survives.** The only way for
   `exempt_unparseable_at?/2` to return `true` is for a REAL line, on REAL disk, at a
   POSITION independently confirmed by the pre-existing (unrelated, already-adversarially-
   hardened) `known_shape_anomalies:` set-equality machinery, to mechanically parse as
   ISO-8601 RIGHT NOW, at check time. Nothing about the exemption's truth is taken from the
   declaration's own prose (`should_have_been:`/`cause:` are documentation, read by humans,
   never consumed by `exempt_unparseable_at?/2`'s logic).

**Second-order attack: what if the attacker points `verified_via` at a real `extra_field`
that happens to be a coincidentally-parseable-looking string that ISN'T semantically a
timestamp** (e.g. a `run_id:` value that happens to parse — unlikely given
`DateTime.from_iso8601/1`'s strictness, but not impossible for some contrived value)?

This residual risk is real but narrow, and is the SAME class of risk `unparseable_at/2`
already accepts for the PRIMARY check today (nothing stops a human from writing a
plausible-but-wrong ISO-8601 string as an `at:` value and having it pass `parseable_iso8601?`
— A4b has never asserted semantic correctness of a timestamp, only its syntactic parseability
and its provenance via the closed-and-pinned/append-only chain of custody). The mitigation is
the same one the project already relies on elsewhere for anything under
`known_shape_anomalies:`/`known_anomalies:`: these are REVIEWED, PROSE-DOCUMENTED, ONE-TIME
declarations against FROZEN, digest-pinned volumes (§2.3 step 5) — not live, ongoing
inference. A reviewer (REVIEWER or RELEASE-VALIDATOR, at the point ELIXIR-DEV's PR is
gated) reads `cause:`/`should_have_been:` prose exactly as they already do for every other
declared record, and confirms by eye that the cited sibling really is the timestamp field
the incident report says it is — the mechanical check's job is narrower and different: it
guarantees the citation POINTS AT SOMETHING REAL AND PARSEABLE, closing off the "declare
anything, get a free pass" failure mode the issue's addendum worried about; it was never
meant to replace human review of WHICH real thing is being cited, exactly as
`known_shape_anomalies:` itself has never mechanically verified that a `cause:` string is
honest prose.

### 3.4 Why `from_disk` findings are never exemptable

§2.4 explicitly restricts the new reject-pass to `from_declared` candidates only. A
`from_disk` finding means an entry's field CORRECTLY NAMED `at:` holds unparseable content —
there is no `misnamed_field` companion record for it to hang a `verified_via` citation off
of, and inventing one would let a genuinely-corrupt CORRECTLY-NAMED timestamp field be
excused via an unrelated extra field, which is exactly the "smuggle real corruption past the
check" failure mode this whole design exists to prevent. This case is architecturally
excluded, not just unaddressed: `unparseable_at_exemption`'s only entry point is the
`from_declared` comprehension.

---

## 4. Test-designer notes (not written here; TEST-DESIGNER's job at the next step)

Existing A4b negative controls (`requirement_status_invariants_test.exs:206`, `:238`) are
the template. This fix needs, at minimum:

- **Positive fixture:** a fixture volume with one entry shaped like the 9 real ones
  (`misnamed_field`/`at` found under `summary:` as an unparseable fold marker, `extra_field`/
  `timestamp` holding a real ISO-8601 value), both `known_shape_anomalies:` records declared,
  ONE `known_unparseable_at:` record declared and correctly cross-referencing → asserts
  `findings.unparseable_at == []` and `findings.invalid_unparseable_at_exemptions == []`.
- **Negative control A — orphaned citation:** `known_unparseable_at:` citing a
  `verified_via` field/line with NO matching `known_shape_anomalies:` `extra_field` record →
  asserts the ORIGINAL `unparseable_at` finding still fires (exemption did not apply) AND
  `invalid_unparseable_at_exemptions` reports it.
- **Negative control B — sibling doesn't parse:** `verified_via` cites a real, legitimately
  declared `extra_field` record whose actual on-disk value is NOT ISO-8601 (e.g. citing the
  `run_id:` field instead of `timestamp:`) → same two assertions as control A.
- **Negative control C — open/unpinned volume:** the exempting `known_unparseable_at:`
  record cites a volume that is not `status: closed` (or lacks `frozen_prefix_sha256:`) →
  exemption must not apply even though the sibling genuinely parses, mirroring the existing
  negative control 2 pattern for `known_shape_anomalies:` itself.
- **Regression run against the real files:** `mix test test/docs/requirement_status_invariants_test.exs`
  standalone, expecting 20/20 once the 9 real `known_unparseable_at:` records (§2.5) are
  added to `docs/status/requirement_status.index.yaml`.

---

## 5. Open questions (explicitly not resolved here)

- **Should `known_unparseable_at:` also get an `unfound`-style symmetric check** (a declared
  exemption whose target `misnamed_field`/`at` finding no longer exists at all, e.g. because
  it was already fixed some other way)? Not required to close the gaming vector this fix
  targets — a "declared exemption for a problem that no longer exists" is inert, not unsafe
  — but it would match the project's existing symmetric-difference discipline everywhere
  else in A4b/A5. Left for REVIEWER/CODE-DESIGN-VALIDATOR to decide whether it's in scope
  for this MINOR fix or a follow-up.
- **`entry_line`/`found_line` values for REQ-411/413/414/415/416** are not transcribed in
  §2.5's table (only REQ-405/409/410/412 are, from lines directly read this session) —
  ELIXIR-DEV must re-derive them from the live index/volume rather than guess, per §2.5's
  own note.
