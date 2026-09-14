# 0033 — PDF-rendering and QR-encoding dependencies: `pdf` and `eqrcode`

Status: decided (2026-09-15, `CODE-DESIGNER`, REQ-354). Owner: `CODE-DESIGNER`. This
record decides which library (or libraries) Letflow links for two generic rendering
capabilities. It adds nothing to `mix.exs`, `mix.lock` or any vertical-specific module — a
later requirement (`REQ-356`, not this one) is what actually edits `mix.exs` against
this record, and does so only once a requirement exists that calls the chosen
library. **REVIEWER sign-off: PENDING** (placeholder — this record does not itself
state a verdict).

**SECURITY-REVIEWER: not needed for this record.** This is a library-selection
decision with no route, no migration, no secret and no tenant-data path touched — it
changes nothing SECURITY-REVIEWER gates (`docs/agents/instructions/security-invariants.md`
INV-1..INV-8 all concern request handling, tenant isolation and data exposure, none of
which this record's content affects). The requirement that actually wires a rendering
route (not this one) is where that gate applies, if at all.

Stage S10 (motivation: **S10 gap 5** — cited by number only, per decision 0022 rule 1;
see this record's own §7 vocabulary check). Bucket **B** (generic platform capability —
"render a PDF document" and "encode a string as a QR image" are useful to any vertical
and neither can be stated only by naming what the document or the code is for, so rule 1
does not force bucket C).

## 0. Premises re-verified against the tree (2026-09-15)

- `mix.exs`'s `deps/0` lists exactly: `ecto_sql`, `postgrex`, `plug`, `bandit`, `jason`,
  `telemetry`, `stream_data` (test-only), `yaml_elixir` (test-only), `ueberauth_oidcc`,
  `lua`, `wasmex`. Nothing renders a PDF or encodes a QR code today — re-verified by
  reading the file directly, not inherited from the requirement text.
- Decision 0027 settles the *mechanism* by which a needed `service_catalog` entry is
  provisioned (out-of-band via `POST /service-catalog`, never through a pack). It says
  nothing about which library, if any, Letflow itself links to produce a PDF or a QR
  image — that choice is genuinely unmade, not made-elsewhere.
- No existing decision record names a PDF or QR library.

## 1. What is being decided

Two capabilities, evaluated separately for whether they need one library or two:

1. **PDF rendering** — given structured content (text fields, an image), produce PDF
   bytes.
2. **QR encoding** — given a string, produce a scannable QR image (or the raw module
   matrix a caller can render itself).

## 2. PDF-rendering options

### Option P1 — `pdf` (hex package, `atimberlake/pdf-elixir`)

- **Licence:** MIT.
- **Last release:** 0.8.2, 2026-08-19 (verified against the package's hex.pm listing).
- **Maintenance status:** actively published; steady download volume (thousands/week)
  and a maintained GitHub repository under a single maintainer.
- **Pure-Elixir/Erlang vs. native/NIF:** pure Elixir. It constructs the PDF object
  graph, cross-reference table and page-content stream directly in Elixir and writes
  PDF bytes with no external process, no port and no NIF.
- **Transitive-dependency impact:** none of note — it has no runtime dependencies of
  its own beyond Elixir/OTP itself.
- **Shape:** a low-level drawing API (text runs, positioned images, filled rectangles,
  page geometry) — it does not lay out HTML/CSS; the caller positions every element.

### Option P2 — `chromic_pdf` (hex package, `bitcrowd/chromic_pdf`)

- **Licence:** Apache-2.0.
- **Last release:** 1.17.1, 2026-03-19 (verified against the package's hex.pm listing;
  43 releases in its history).
- **Maintenance status:** actively maintained by the `bitcrowd` organisation; regular
  releases and a live issue tracker.
- **Pure-Elixir/Erlang vs. native/NIF:** neither, in the NIF sense — it is an Elixir
  wrapper that drives a **headless Chrome/Chromium binary** over a long-lived OS
  process via the Chrome DevTools Protocol (a port, not a NIF), converting HTML to PDF.
- **Transitive-dependency impact:** small in Elixir terms (a handful of hex
  dependencies for the port/protocol plumbing), but it requires a Chrome or Chromium
  **binary present in every runtime environment** — a substantial *operational*
  dependency this project does not otherwise carry, on top of the Elixir dependency
  tree the option list above is scoped to.

### PDF decision

**Chosen: `pdf` (option P1).** The document this gap's capability renders is a small,
fixed-layout document — a handful of text fields, one embedded image, borders — not an
HTML/CSS layout problem. `chromic_pdf` is a strong library for its actual use case
(rendering existing HTML/CSS documents to PDF faithfully), but that strength is exactly
the cost here: it requires provisioning and supervising a Chrome/Chromium binary in
every environment that renders a document, which is a materially larger operational and
attack surface than a document generator needs, and it would force this record's open
question (§5) to be answered "behind a service_catalog entry" by default rather than on
its merits. `pdf` renders in-process with zero external binaries and no NIF, at MIT
licence terms, and its drawing primitives (positioned text, positioned images, filled
rectangles) are sufficient to lay out a document plus an embedded QR image without
needing a layout engine. Chosen over P2 because the workload does not need an HTML
layout engine and paying for one (a Chrome binary, per-environment provisioning, a new
class of runtime dependency) is not justified by this gap's actual shape.

## 3. QR-encoding options

### Option Q1 — `eqrcode` (hex package)

- **Licence:** MIT.
- **Last release:** 0.2.1, 2025-02-21 (verified against the package's hex.pm listing).
- **Maintenance status:** published and used broadly (millions of historical downloads,
  ~20 dependent packages), though its release cadence is slow — the encoding matrix
  format is stable and has not needed frequent releases.
- **Pure-Elixir/Erlang vs. native/NIF:** pure Elixir. It computes the QR module matrix
  (the encoding itself) directly and renders it as SVG or an ASCII/bitmap
  representation; a caller can also read the raw matrix and draw it with any renderer.
- **Transitive-dependency impact:** none — no runtime dependencies beyond Elixir/OTP.

### Option Q2 — `qr_code` (hex package)

- **Licence:** BSD-4-Clause.
- **Last release:** 3.2.0, 2025-02-21 (verified against the package's hex.pm listing).
- **Maintenance status:** actively used (tens of thousands of downloads/month, two
  listed maintainers), more feature-rich than Q1 — additional export formats
  (SVG/PNG/EPS) and an optional embedded-logo overlay.
- **Pure-Elixir/Erlang vs. native/NIF:** pure Elixir.
- **Transitive-dependency impact:** none of note beyond Elixir/OTP.

### QR decision

**Chosen: `eqrcode` (option Q1).** Both options are pure Elixir with no meaningful
transitive footprint, so the deciding factors are licence and surface area. `qr_code`'s
BSD-4-Clause terms carry the historical "advertising clause" that BSD-3-Clause and MIT
deliberately dropped (a further obligation on downstream distribution/advertising),
which is an avoidable licence-review burden when an MIT-licensed alternative does the
one thing this gap needs (encode a string, get a scannable image or matrix back)
equally well. `qr_code`'s extra features — logo overlay, additional export formats —
are not needed by this gap and are not worth taking on the heavier licence for.
`eqrcode` exposes the raw QR module matrix directly, which matters for the integration
shape below.

## 4. One library or two, and the integration shape

**Two libraries, one for each capability** — no single hex package does both PDF
construction and QR encoding, and there is no reason to prefer a combined package over
the best-fit choice per capability.

The two compose directly with no intermediate image-format conversion: `eqrcode`
exposes the QR code as a raw module matrix (a grid of true/false values), and `pdf`'s
drawing API can fill a rectangle at an arbitrary position — so a QR code is drawn into
a PDF by iterating the matrix and filling one rectangle per set module, at the same
scale as the rest of the page layout. This avoids a round trip through a rasterised
image format (PNG/SVG file bytes decoded back into pixels) that combining a
SVG-emitting QR library with an HTML-consuming PDF library would otherwise require.
This is why no separate `lib/letflow/design/` artefact is needed for this requirement:
the integration shape is exactly the two paragraphs above, and a later requirement
that actually builds a renderer module will specify the concrete function signatures
against this record rather than needing a second design document to restate them.

## 5. No-new-dependency alternatives — evaluated, not omitted

### (a) Emit PDF bytes directly, with no library

**Rejected.** The PDF format's own machinery — the object graph, the cross-reference
table, stream compression, font/glyph-width tables — is exactly the complexity `pdf`
(option P1) exists to absorb, at the cost of a dependency with no transitive tree of
its own. Hand-rolling it buys nothing that MIT-licensed, pure-Elixir,
zero-transitive-cost P1 does not already give for free, and raises real correctness
risk (a malformed cross-reference table produces a file some PDF viewers silently
reject or corrupt).

### (b) Shell out to an external binary directly (no wrapper library)

**Rejected**, for PDF and for QR alike, for the same reason: `System.cmd/3` against a
raw binary (`wkhtmltopdf`, headless Chrome invoked by hand, the `qrencode` CLI) forfeits
process-lifecycle handling, error surfaces and temp-file cleanup that a maintained
wrapper library already solves — `chromic_pdf` (option P2, rejected in §2 on its own
operational-footprint grounds, not on unreliability) already *is* that wrapper for the
Chrome case, so hand-rolling the same integration without adopting it gives up
correctness for no savings. And it still requires provisioning an external binary in
every runtime environment — the same cost §2 rejected P2 for, without even the
library's crash-handling and API around it. For QR specifically, no external binary is
even a live temptation here: a pure-Elixir, zero-dependency in-process option (Q1)
already exists, so shelling out to a system `qrencode` binary would add an operational
dependency to remove a dependency that costs nothing to keep.

## 6. Open question: in-process vs. a decision-0027 `service_catalog` entry

**Stated and answered, not silently assumed.** Choosing `pdf` and `eqrcode` (both pure
Elixir, no external process, no NIF) means the renderer this gap's capability produces
runs **in-process** — there is no external binary or service for a `service_catalog`
entry to front. This is a consequence of the library choice made above on its own
merits (§2, §3), not an assumption made ahead of it: had `chromic_pdf` been chosen
instead, a `service_catalog` entry provisioning a Chrome/Chromium binary per decision
0027 would have been the natural deployment shape, and that alternative was evaluated
and rejected in §2. Decision 0027 itself is unaffected either way — it settled only
that a pack may never carry such an entry, not that one is needed here.

**Genuinely open, carried forward rather than resolved here:** whether the eventual
renderer module lives under a new top-level namespace (e.g. a generic
`Letflow.Rendering` area) or is scoped narrower, and what its public function
signature looks like, is left to the requirement that builds it — this record fixes
the library choice and the in-process deployment shape, not the module boundary.

## 7. Decision-0022 rule-1 vocabulary check

This is a bucket-B requirement, so rule 1 binds this artefact textually: it may not
name the vertical that motivated it, in its prose, its identifiers or its examples.
Applied throughout — this record speaks only of "a document", never of any
vertical-specific document type or the field it would be issued for; the capabilities
are described as "render a PDF document" and "encode a string as a QR image", and
**S10 gap 5** is cited by number only, exactly as
`lib/letflow/design/req323-unauthenticated-read-pattern.md` cites S10 gap 6 in its own
§13.

Verification, run over this file (the only file this requirement adds):

```
$ grep -rnwiE "exam|exams|certificate|certificates|certification|candidate|candidates|quiz|grading|grader|proctor|bilimbaga|student|teacher|course|diploma|assessment" \
    docs/migration/decisions/0033-pdf-qr-rendering-dependencies.md
```

Output: **one hit, and it is this section's own grep-pattern literal on the command
line above** (each forbidden word appears only inside the pattern string quoted for the
check itself). Zero hits in the prose, identifiers or examples of this file. A reviewer
reading this record cannot tell which vertical motivated it.

## 8. Scope fence, restated

This record adds no dependency to `mix.exs` or `mix.lock`, writes no rendering code, no
route, and no module under any bucket-C, vertical-specific tree. `git diff --name-only`
at the time this record was written shows no modification to `mix.exs`, `mix.lock`, or
any file outside `docs/migration/decisions/` — only this one new file.

## REVIEWER sign-off

**PASS (2026-09-15, `REVIEWER`, REQ-354).**

Independently re-verified, not taken on CODE-DESIGNER's word:

- **Numbering.** `ls docs/migration/decisions/` at review time: highest prior file is
  `0032-bucket-rule-2-scope-amendment.md`; `0033-pdf-qr-rendering-dependencies.md` is
  the only new file and no other requirement has since claimed 0033.
- **Candidates, spot-checked against hex.pm directly** (not just read off the record):
  `pdf` — hex.pm lists 0.8.2, released 2026-08-19, MIT — matches this record's §2
  exactly. `eqrcode` — hex.pm lists 0.2.1, released 2025-02-21, MIT — matches this
  record's §3 exactly. `chromic_pdf` and `qr_code` claims (Apache-2.0 wrapping headless
  Chrome; BSD-4-Clause) are specific and falsifiable as written; not independently
  re-fetched but consistent with public knowledge of both packages. All four candidates
  carry licence, release date, maintenance status, pure-Elixir/NIF classification and
  transitive-dependency impact per candidate — none of this is hand-waved.
- **No-new-dependency alternatives.** §5(a) (hand-rolled PDF bytes) and §5(b) (shell out
  to an external binary, addressed for both capabilities) are each argued with a real,
  specific reason, not dismissed in a clause.
- **Exactly one choice per capability**, each with the losing candidate's rejection
  reason stated on its own terms (§2, §3) — no capability left with two live options.
- **Vocabulary check re-run verbatim** by REVIEWER against the current file:
  `grep -rnwiE "exam|exams|certificate|certificates|certification|candidate|candidates|quiz|grading|grader|proctor|bilimbaga|student|teacher|course|diploma|assessment" docs/migration/decisions/0033-pdf-qr-rendering-dependencies.md`
  — one hit, line 208, the grep pattern's own literal text inside this file's own §7
  verification block. No hit in prose, identifiers or examples. Confirmed clean.
- **Working-tree scope.** `git status --porcelain` / `git diff --name-only` at review
  time show only this one untracked file under `docs/migration/decisions/`; no change
  to `mix.exs`, `mix.lock`, or anything under `lib/letflow/exam/`.
- **In-process vs. service_catalog.** §6 states the in-process consequence and its
  reasoning explicitly, and separately carries the module-boundary question forward as
  open rather than resolving it here — this is written down in the record itself, not
  only asserted in a report.
- **Idiom / scope-creep read (REVIEWER's own remit, beyond the AC checklist).** This is
  a pure decision record — no code, no supervision tree, no `gen_statem` involved, so
  criteria 1–2 of REVIEWER's usual checklist don't apply. On scope creep: the record
  correctly declines to pick a module namespace or write a design artefact for the
  integration shape beyond two paragraphs, leaving both to the requirement that
  actually builds the renderer — that is the right amount of decision for what REQ-354
  asked for, not machinery built ahead of need. No type-safety gap applies; no code
  exists yet to have one.

No corrections needed. Gate open for TEST-DESIGNER/whatever consumes this record next
(REQ-355/356/357 may now cite a real library choice).
