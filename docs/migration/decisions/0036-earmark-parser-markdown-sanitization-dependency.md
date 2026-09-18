# 0036 — `earmark_parser` dependency for help-content markdown sanitization

Status: decided (2026-09-17, `REVIEWER`, REQ-364). Owner: `REVIEWER`. This record adds
`earmark_parser` to the set of approved dependencies for `mix.exs` and records the
sign-off `lib/letflow/design/req363-help-content-data-model.md` §5.4.3 explicitly
withholds from itself. It mirrors decision 0033's format at the same procedural weight,
per that record's own precedent and per REVIEWER's 2026-09-17 determination
(`handoffs/WF02-REQ364-20260917/step-03d-reviewer-determination.json`).

**SECURITY-REVIEWER: already engaged upstream.** This dependency exists specifically
*because* SECURITY-REVIEWER rejected the regex-based alternative across two rounds
(`handoffs/WF02-REQ364-20260917/step-03b-security-reviewer.json`,
`step-03b-security-reviewer-rework1.json`) as structurally bypassable. This record does
not re-open that finding; it approves the dependency the fix requires.

## 0. What prompted this

REQ-364 (`help_content`/`platform_help_content` markdown body sanitization) was
originally designed and implemented (`lib/letflow/help/help_content.ex`) against
`lib/letflow/design/req363-help-content-data-model.md` §5.3, a regex/pattern-based
validator with no new dependency. SECURITY-REVIEWER found two confirmed bypasses
across two rounds (reference-style link definitions; angle-bracket-wrapped autolink
URLs). On the third round, REVIEWER constructed three further bypasses without
changing the threat model (backslash-escaped scheme characters, HTML-entity-encoded
scheme characters, embedded whitespace/control characters — the OWASP `javascript:`
URI filter bypass cheat sheet's standard techniques) and determined the regex approach
is structurally unsound, not incomplete: every bypass stems from the same root cause,
that a regex scans raw source bytes for a `scheme:` substring while CommonMark
link-destination resolution applies escape processing, entity decoding, and whitespace
normalization no regex patch implements completely. REVIEWER declined a third
regex-patch round and routed the design back through CODE-DESIGNER to resolve OQ-4
toward a real, AST-level parser. §5.4 of the same design file is that resolution,
now PASSed by CODE-DESIGN-VALIDATOR twice, including independent verification against
the library's real README/hexdocs/test suite.

## 1. What is being decided

Whether Letflow may add `earmark_parser` (hex package) as a runtime dependency, used
only for `EarmarkParser.as_ast/2` — parsing markdown to a CommonMark AST for the
help-content changeset validator to walk and reject on (raw-HTML nodes,
disallowed-scheme link/image destinations). Never used for rendering; the AST is
inspected, never converted to HTML by this requirement.

## 2. Candidate evaluated

### `earmark_parser` (hex package, `RobertDober/earmark_parser`)

- **Licence:** Apache-2.0. Re-verified directly against hex.pm at sign-off time
  (2026-09-17): confirmed Apache-2.0, matching the design's claim exactly.
- **Last release / maintenance status:** hex.pm lists version 1.4.46, released
  2026-07-17, 42 published versions, not marked retired or deprecated, ~43,000,000
  cumulative downloads — re-verified directly against hex.pm, not taken on the
  design's word. It is the parser `ex_doc` (the Elixir ecosystem's own documentation
  generator) depends on to parse every `@doc`/`@moduledoc` string in every published
  Hex package — a broad, continuously-exercised conformance workout, and a maintenance
  signal independent of `earmark_parser`'s own release cadence.
- **Pure-Elixir/Erlang vs. native/NIF:** pure Elixir. No NIF, no port, no external
  binary — the same shape decision 0033 §2 already preferred (`pdf` over
  `chromic_pdf`'s Chrome-binary requirement) for the same reason: an in-process
  dependency with no external runtime requirement is strictly lower operational risk
  than one that needs a binary provisioned in every environment, when the in-process
  option is otherwise sufficient.
- **Transitive-dependency impact:** hex.pm confirms zero runtime dependencies.
  Accurate as claimed, and it meaningfully reduces supply-chain surface — no
  transitive package inherits a vulnerability into this project's tree through this
  dependency; the entire licence/maintenance/security review scope is the one package
  itself.
- **Due diligence on `earmark` (the different, retired package):** hex.pm lists
  `earmark` (the full Markdown-to-HTML renderer — a different package from
  `earmark_parser`) as **retired**, carrying a recorded security advisory, with an
  archived GitHub repository. `earmark_parser` is not affected by this: it was
  extracted from `earmark` into its own standalone package specifically so a caller
  needing only parsing (not rendering) does not depend on the renderer at all, and
  `earmark_parser` itself carries no retirement flag, no advisory, and no archived-repo
  marker on hex.pm. The two packages are evaluated separately here precisely because
  their names are easy to conflate; this record depends only on the parser, never the
  renderer.
- **Narrowness of usage:** REQ-364's write path calls exactly one function,
  `EarmarkParser.as_ast/2`, and never calls anything HTML-rendering-related — `earmark`
  itself (the renderer) is not proposed and would not be justified, since no code path
  in this requirement ever needs rendered HTML (render-time display is REQ-366's job,
  explicitly out of REQ-364's scope). Depending on `earmark_parser` alone takes exactly
  the capability needed, nothing more.

## 3. Alternatives considered, per the design's own §5.4.1

- **HTML-sanitization library (e.g. `html_sanitize_ex`) instead of a markdown AST
  parser:** rejected in the design and re-affirmed here — REQ-364's input is markdown
  source, not HTML; sanitizing HTML would require first rendering the markdown to HTML
  (via a renderer such as `earmark` itself), meaning the same parsing step happens
  either way, plus a second full pass and a second dependency for no benefit over
  checking the parser's own AST directly.
- **A further regex patch (no new dependency):** rejected by REVIEWER's own prior
  determination (§0 above) as structurally unsound, not merely more expensive —
  the root cause (regex has no notion of resolved destinations, escape processing, or
  entity decoding) cannot be closed by another pattern, only worked around locally
  until the next bypass class is found.
- **Full `earmark` (the renderer) instead of `earmark_parser`:** would work — `earmark`
  re-exports the same parser — but would name a dependency on HTML-rendering machinery
  this requirement never calls, and inherits `earmark`'s own retired/advisory status
  on hex.pm for no benefit. `earmark_parser` is the narrower, correct choice.

## 4. Decision

**Approved: `earmark_parser` may be added to `mix.exs` as a runtime dependency,
scoped to `EarmarkParser.as_ast/2` calls only, per
`lib/letflow/design/req363-help-content-data-model.md` §5.4.2's write-path mechanism.**
No further design artefact is required — §5.4 already specifies the write-path
mechanism at the necessary level of detail; this record's job is the dependency
approval §5.4.3 explicitly withholds from the design itself, not a re-design.

## REVIEWER sign-off

**PASS (2026-09-17, `REVIEWER`, REQ-364).**

Findings against this project's REVIEWER remit:

1. **Idiomatic vs. crutch.** Not applicable in the `gen_statem`/state-machine sense —
   this is a changeset validator, not a process. On its own terms: using a real
   CommonMark parser and walking its AST for `meta[:verbatim]` and `"a"`/`"img"`
   destination nodes (per §5.4.2) is the idiomatic fix for the exact defect class
   found — checking resolved, parser-normalized values instead of re-implementing
   escape/entity/whitespace resolution by hand in a regex, which is precisely the
   crutch REVIEWER's prior determination rejected.
2. **Supervision.** Not implicated — no process, no `Letflow.InstanceSupervisor`
   interaction. `EarmarkParser.as_ast/2` is a pure function call inside a changeset
   validation, synchronous and in-process.
3. **Type-safety gaps.** None introduced by the dependency choice itself. The AST walk
   in §5.4.2 pattern-matches on `{tag, attrs, children, meta}` 4-tuples and
   `meta[:verbatim] == true` — this is inherent to consuming an external library's
   term shape and is not a gap a struct/`@type` change on Letflow's side could close
   (the shape is `earmark_parser`'s, not this project's).
4. **Scope creep.** None found. The dependency is scoped to the one function this
   requirement's write path needs (`as_ast/2`); the design explicitly rejected pulling
   in `earmark` (the renderer) precisely to avoid depending on unused machinery. No
   behaviour, macro, or generic plumbing is introduced ahead of need.

Independently re-verified, not taken on the design's or CODE-DESIGN-VALIDATOR's word:

- **Licence.** Apache-2.0, confirmed directly against hex.pm (§2 above). This project
  has no standalone written licence-compatibility policy document, but decision 0033
  §3's QR-library choice (rejecting BSD-4-Clause's advertising clause in favor of MIT)
  establishes the working bar: permissive, OSI-approved licences with no copyleft or
  extra distribution obligations are acceptable, and Apache-2.0 already sits in this
  project's tree today via `chromic_pdf`'s consideration in 0033 §2 (rejected on
  operational grounds, not licence) and is a strictly more common, more permissive
  choice than the BSD-4-Clause 0033 actually rejected. Apache-2.0 is accepted.
- **Maintenance signal.** hex.pm's version/date/retirement-flag data re-fetched live
  at sign-off time (§2 above), not copied from the design or CODE-DESIGN-VALIDATOR's
  prior checks — matches both parties' independent findings.
- **Zero-runtime-deps claim.** Confirmed accurate against hex.pm; this is the entire
  supply-chain surface added, one package with no further transitive tree.
- **Narrowness of usage.** Confirmed against §5.4.2: exactly one function
  (`as_ast/2`), never a rendering call, matching the design's own stated scope.
- **Numbering.** `ls docs/migration/decisions/` at review time: highest prior file is
  `0035-frontend-login-delegated-to-keycloak.md`; `0036-earmark-parser-markdown-
  sanitization-dependency.md` is the only new file and no other requirement has since
  claimed 0036.

**Verdict: approved. ELIXIR-DEV may add `earmark_parser` to `mix.exs` and proceed with
implementation against `lib/letflow/design/req363-help-content-data-model.md` §5.4,
citing this record (0036) as the recorded sign-off — same pattern as REQ-356's
`mix.exs` entries citing decision 0033.** Gate open for TEST-DESIGNER once
implementation lands.
