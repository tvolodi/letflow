# Design: content-type allowlist enforcement for instance-attachment uploads (REQ-389)

**Status:** design, pending CODE-DESIGN-VALIDATOR.
**Requirement:** REQ-389 (`docs/requirements.yaml`, letflow-queue task 749, GH-1637, stage S6).
**Filed from:** `test/uat-reports/gui-review-2026-09-20-shipment-attach-delivery-note.md` (PW-09
step 3), EO-002 ("a plain explanation of the limit" for a refused video upload).
**Depends on:** REQ-211 (`lib/letflow/design/req211-instance-attachments-core.md`), REQ-212
(`lib/letflow/design/req212-instance-attachments-routes.md`) — both `status: done`.
**Sibling requirements (not in scope here):** REQ-390 (storage-quota, `status: done`), REQ-391
(history/attribution, `status: done`), REQ-392 (frontend rejection-message screen, depends on
this requirement, still `pending`).

## 0. What exists today (read in full before this design, not assumed)

- `Letflow.Repository.Attachments.upload/2` (`lib/letflow/repository/attachments.ex`) runs, in
  this order (current code, confirmed by reading `upload/2` and `do_upload_after_scan/6`
  directly):
  1. `measured_byte_size = byte_size(raw_bytes)`; if `> @max_upload_bytes` (25 MiB),
     `{:error, :file_too_large}` immediately — no hashing, no scan, no write.
  2. `content_hash = :crypto.hash(:sha256, raw_bytes)`.
  3. `run_attachment_scan/2` (ISS-0399) — `{:error, :infected, verdict}` /
     `{:error, :scan_unavailable}` both fail closed, no write.
  4. Inside `do_upload_after_scan/6`: resolve `tenant_id`, then `check_storage_quota/3`
     (REQ-390) — `{:error, :storage_quota_exceeded}` fails closed, no write.
  5. `Repo.transaction/1`: upsert `repository_artifacts`, insert `instance_attachments` with
     `scan_status: :clean`.
  6. Post-commit, best-effort `record_attachment_attached_event/2` (REQ-391).
- **Nothing anywhere in this pipeline inspects or restricts the caller-declared
  `content_type` string against any allowed/disallowed set.** `content_type` flows straight
  from the multipart `%Plug.Upload{}` part (`lib/letflow/routers/instances.ex`,
  `upload_attrs_from_conn/3`) into `upload_attrs()`, and from there into both the
  `repository_artifacts` upsert and the `instance_attachments` insert, unchanged. A caller
  declaring `content_type: "video/mp4"` is accepted today exactly like `application/pdf`,
  provided it clears the size ceiling, the scan, and the quota.
- **INV-a** (`Letflow.Repository.Attachments`'s own moduledoc, quoted in full since this
  design's §4 turns on its exact wording): *"Nothing in this module, and nothing any caller
  of this module may assume, treats the stored `content_type` value as verified against the
  actual byte content — no magic-byte/MIME-sniffing check is performed anywhere here. A
  caller declaring `content_type: "application/pdf"` for a file that is not actually a PDF is
  accepted and stored exactly as declared."* This is not one of the numbered `INV-1..INV-9`
  invariants in `docs/agents/instructions/security-invariants.md` (grepped that file
  exhaustively — zero `INV-a` hits there); it is this module's own local invariant, scoped to
  this module's moduledoc alone. §4 below is this design's required treatment of it (AC4).
- Route layer (`lib/letflow/routers/instances.ex`, `handle_upload_attachment/2` →
  `render_upload_attachment/2` clauses): `{:error, :file_too_large}` → `Response.
  payload_too_large/2` (413); `{:error, :infected, verdict}` → `Response.unprocessable/2`
  (422); `{:error, :scan_unavailable}` → `Response.service_unavailable/2` (503).
  `{:error, :storage_quota_exceeded}` (REQ-390, confirmed present in `upload/2`'s current
  `@spec`) is rendered by an existing clause not reproduced above — not touched by this
  design.
- **`Letflow.Api.Response`/`Letflow.Api.Error` already has an unused, purpose-built
  constructor for exactly this shape**: `Response.unsupported_media_type(conn, detail)` →
  `Error.unsupported_media_type/1` → HTTP 415, `type: ".../problems/unsupported-media-type"`,
  `title: "Unsupported Media Type"`. Confirmed by reading `lib/letflow/api/response.ex:169-171`
  and `lib/letflow/api/error.ex:240-249` (REQ-066/068) — currently called only from
  `lib/letflow/plugs/content_type.ex` (request `Content-Type` header validation, an unrelated
  Plug-level check on the *request envelope*, not this module's attachment-body field) and
  `lib/letflow/plugs/safe_json_parser.ex`. Reusing this existing 415 constructor for the new
  attachment rejection is both idiomatic (matches this codebase's REQ-066 Problem-Details
  convention exactly) and distinct in status code from `:file_too_large` (413) and
  `:infected`/`:scan_unavailable` (422/503) — satisfying AC2's "distinct... response bodies"
  wording without inventing a new status code or Problem-Details `type`.
- **Existing test fixtures using non-allowlisted-by-requirement-text content types**, grepped
  exhaustively across every test file that calls `Attachments.upload/2` or drives the
  `POST /instances/:id/attachments` route: `text/plain` (the attachments-test module's own
  default `upload_attrs/1` fixture, plus `req386`/`req388` route tests), `application/json`
  (one `attachments_test.exs` no-canonicalisation test), `text/csv` (one `req212` route test),
  `application/octet-stream` (one `req212` route test proving `upload/2`'s own size check is
  reachable when Plug.Parsers is bypassed — this test's content_type value is incidental to
  what it is actually testing), and `application/pdf` (multiple `req212`/`engine_complete_task`
  tests, already accepted, AC3's own named example). §2.1 below designs the allowlist to
  include every one of these, precisely so none of these already-`done` requirements' tests
  need a content_type fixture edit — see §2.3 for why this is the deliberate, judgement-based
  choice rather than a narrower list that would force touching five unrelated test files.

## 1. Scope, restated

1. A module-level content-type allowlist for instance attachments (§2).
2. `upload/2` checks the caller-declared `content_type` against it **before** the size
   ceiling, the malware scan, the storage-quota check, and any `repository_artifacts`/
   `instance_attachments` write, returning a new tagged error (§3).
3. The route layer renders the new error as a 415, naming the rejected `content_type` and the
   allowed set in plain language (§3.3).
4. A test proves no `repository_artifacts`/`instance_attachments` row is created for a
   rejected upload (§3.4 — TEST-DESIGNER's job to write, shape given here).
5. An explicit statement of why this does not contradict INV-a (§4).

**Out of scope** (per the requirement text): any MIME-sniffing/content inspection (INV-a is
unchanged, §4); the frontend rejection-message screen (REQ-392); storage-quota tracking
(REQ-390, already done, untouched by this design beyond being pushed one step later in the
check order, §3.1).

## 2. The allowlist itself

### 2.1 Concrete list and shape

A **fixed, compile-time module attribute** — `Letflow.Repository.Attachments`'s own
`@max_upload_bytes` precedent (moduledoc, "flagged for REVIEWER as a judgement-based number
with no requirement-stated value") is the established idiom in this exact module for a
judgement-call constant with no config surface, and this design follows it rather than
introducing `Application.get_env/3` config for a value nothing in this codebase's config
files (`config/*.exs`, grepped) currently parameterises per-tenant or per-environment. A
`MapSet` (not a plain list) for O(1) membership check, matching this module's own existing
style of using the right built-in data structure for a membership test (no other module in
`lib/letflow/repository/` currently does a content-type membership check to pattern-match
against, so this is a fresh but idiomatic choice, not a deviation from one):

```
@allowed_content_types MapSet.new([
  # Requirement-named example, already accepted pre-this-change (AC3) — must remain so.
  "application/pdf",

  # Common image types (requirement text's own phrase).
  "image/jpeg",
  "image/png",
  "image/gif",
  "image/webp",

  # Common office-document types (requirement text's own phrase).
  "application/msword",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.ms-excel",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "application/vnd.oasis.opendocument.text",
  "application/vnd.oasis.opendocument.spreadsheet",

  # Plain-text / structured-data document types already exercised by
  # already-`done` REQ-211/212/386/388/391 tests as attachment content_type
  # fixtures (§0) -- kept allowed so none of those tests needs an edit.
  "text/plain",
  "text/csv",
  "application/json",

  # Generic/unknown binary -- kept allowed for the same §0 reason (one
  # req212 route test uses it), and because INV-a already establishes that
  # a caller can declare ANY content_type string for ANY bytes (§4) -- an
  # honest "I don't know a more specific type" declaration is not a
  # meaningfully different trust posture than a caller who lies about a
  # specific type, so excluding it would not close any real gap while it
  # would force an unrelated test-fixture edit.
  "application/octet-stream"
])
```

**Video/audio MIME types are excluded** (requirement text, explicit): nothing in this list
starts with `video/` or `audio/`, and none of `video/mp4`/`audio/mpeg`/etc. is added.

**FLAGGED FOR REVIEWER**, same posture as `@max_upload_bytes`'s own comment: this is a
judgement call with no requirement-stated value. The requirement text names only
`application/pdf` concretely and says "common image types, common office-document types" —
the exact office/image MIME strings above, and the decision to also allow
`text/plain`/`text/csv`/`application/json`/`application/octet-stream` for pre-existing-test-
fixture-compatibility reasons, are this design's own judgement call, not requirement-dictated.

### 2.2 Why a fixed list, not a per-tenant/configurable one

No existing requirement, decision record, or config surface (`config/*.exs`, grepped) gives
tenants a per-tenant allowed-content-type setting — REQ-390's storage *quota* is per-tenant
precisely because the requirement text says so explicitly; this requirement's text does not.
Building tenant-configurability nobody asked for would be scope creep beyond REQ-389's own
acceptance criteria. A future REQ can widen this to per-tenant config the same way REQ-390
added `Tenant.storage_allowance_bytes` — noted as a natural extension point, not built here.

### 2.3 Why this list does not silently break already-`done` REQ-211/212/386/388/391 tests

Named explicitly per this project's own convention (REQ-391's design §2.5 precedent: flag a
cross-cutting consequence rather than let ELIXIR-DEV discover it mid-build). §0's grep found
five content_type values already exercised by tests belonging to *other*, already-`done`
requirements: `text/plain`, `application/json`, `text/csv`, `application/octet-stream`,
`application/pdf`. All five are in §2.1's allowlist. **Consequence: zero pre-existing test
files need a content_type fixture edit as a result of this requirement** — the only new test
code needed is REQ-389's own (§3.4), plus (see §3.1) two already-`done` REQ-390 tests whose
assertions this design's *reordering* affects, named explicitly below rather than left for
ELIXIR-DEV to discover as a surprise failure.

## 3. `upload/2` — check placement, new error tag, route rendering

### 3.1 Placement: first check in `upload/2`, before byte-size measurement's use as a gate

**Decision:** the content-type check runs as the very first statement inside `upload/2`,
before the `if measured_byte_size > @max_upload_bytes` branch — not merely "before the size
check fires an error" but literally the first branch evaluated, so a request with a
disallowed `content_type` and an oversized body is rejected for content-type, never for size
(mirrors this same module's already-established "which check wins when two conditions are
both true" precedent — REQ-390's own test "`file_too_large` triggers without triggering
storage_quota (AC3)" already established that convention for the size-vs-quota ordering; this
design extends the same one-check-wins-and-is-observable-by-test discipline one level
earlier).

**Shape of the change (prose, not a diff):** `upload/2`'s current first action is `raw_bytes =
Map.fetch!(attrs, :raw_bytes)` followed immediately by the `measured_byte_size` size-ceiling
branch (§0). This design inserts one new guard immediately before that size-ceiling branch:
fetch `content_type` from `attrs` (`Map.fetch!/2`, matching this function's existing style of
asserting required keys are present — `upload_attrs()`'s own `@type` already marks
`content_type` `required`), test membership via `MapSet.member?(@allowed_content_types,
content_type)`, and return `{:error, :content_type_not_allowed}` immediately — before
`raw_bytes` is even measured — when it is not a member. Every existing step (size measurement,
hashing, scan, quota check, transaction, post-commit event) is otherwise unchanged and
unreordered relative to each other; only this one new guard is prepended ahead of all of them.

**Consequence for two existing REQ-390 tests, named explicitly (not silently left for
ELIXIR-DEV to discover):** `"storage_quota_exceeded triggers without hitting file_too_large
(AC3)"` and `"file_too_large triggers without triggering storage_quota (AC3)"` (`test/letflow/
repository/attachments_test.exs`) both call `upload_attrs/1` (default `content_type:
"text/plain"`, §2.1 — allowed) — **unaffected**, since `text/plain` clears the new first
check and every subsequent check runs exactly as before. No existing test's *content_type*
value falls outside the allowlist (§2.3), so no existing test's *outcome* changes — this
reordering is invisible to every currently-passing test. Named here anyway because "the new
first check runs before everything, including checks whose relative order to each other is
unchanged" is exactly the kind of ordering claim AC1 requires be checked, not assumed.

### 3.2 New error tag and `@spec` widening

```
@spec upload(upload_attrs(), opts()) ::
        {:ok, Attachment.t()}
        | {:error, :content_type_not_allowed}
        | {:error, :file_too_large}
        | {:error, :storage_quota_exceeded}
        | {:error, :tenant_not_found}
        | {:error, :infected, verdict :: String.t()}
        | {:error, :scan_unavailable}
        | {:error, Ecto.Changeset.t()}
```

`{:error, :content_type_not_allowed}` — a plain two-element tagged tuple, no third "verdict"
element (unlike `:infected`), since the rejected value and the allowed set are both derivable
by the route layer from `attrs`/`@allowed_content_types` without `upload/2` needing to thread
them through the return value itself (§3.3 shows the route layer already has `content_type`
in scope from `upload_attrs_from_conn/3`'s own attrs map, and can read the allowed set via
`Attachments.allowed_content_types/0`, a new public accessor — see below — rather than
duplicating the list at the route layer).

**New public accessor**, so the route layer never hardcodes or duplicates the allowlist:

```
@spec allowed_content_types() :: MapSet.t(String.t())
```
Returns `@allowed_content_types` verbatim. Public specifically so `lib/letflow/routers/
instances.ex`'s rendering clause (§3.3) can enumerate the allowed set for the response body
without a second, drift-prone copy of the list living at the route layer — same
single-source-of-truth discipline `@max_upload_bytes`'s own value already gets (that value is
referenced only in this module's own doc/tests, not duplicated at the route layer either,
since the route layer never needs to *name* the byte ceiling in its 413 body; this one does
need to name the allowed set in its 415 body, per AC2, hence the new accessor).

### 3.3 Route layer rendering (`lib/letflow/routers/instances.ex`)

New `render_upload_attachment/2` clause, same pattern as the existing `:file_too_large`/
`:infected`/`:scan_unavailable` clauses immediately above/below it:

```
@spec render_upload_attachment(Plug.Conn.t(), {:error, :content_type_not_allowed}) :: Plug.Conn.t()
```

Matches on `{:error, :content_type_not_allowed}` and calls `Response.unsupported_media_type/2`
(415), naming BOTH the rejected `content_type` (read from the same `upload_attrs_from_conn/3`
result already in scope at the call site — the attrs map's own `:content_type` field) and the
allowed set (`Attachments.allowed_content_types/0`, joined with `", "`, **sorted** for a
stable/deterministic response body across runs — `MapSet` enumeration order is not
guaranteed, so sorting before joining is required for the response body's own text to be
test-assertable, per AC2's "a test asserts the response body text").

Detail string shape (plain language, per AC2 and EO-002's "readable explanation naming the
limit"): `"content type \"<rejected>\" is not allowed for attachments; allowed types are:
<sorted, comma-joined allowed set>"`. Distinct in both **status code** (415, vs. 413/422/503)
and **body text** (names the rejected type and the allowed set, vs. `:file_too_large`'s
"uploaded file exceeds the maximum allowed size" and `:infected`'s "uploaded file failed a
content scan (#{verdict})" — neither of which names a content_type or a set) from every
existing clause, satisfying AC2 verbatim.

`upload_attrs_from_conn/3` itself needs no change — `content_type` is already read out of the
`%Plug.Upload{}` part (existing code, `lib/letflow/routers/instances.ex`, confirmed above);
only a new rendering clause and the call site's access to that same already-extracted value
are needed.

### 3.4 Required test coverage (TEST-DESIGNER's job — shape given here per this design's own
### convention of not leaving the assertion shape ambiguous, same as REQ-391 §2.4/§4 did)

Context-module-level (`test/letflow/repository/attachments_test.exs`), mirroring the existing
`"an upload exceeding the 25 MiB ceiling is rejected before any persistence, with neither row
created (AC4)"` test's own shape exactly:

- **`"a disallowed content_type is rejected before any persistence, with neither row created
  (AC1)"`** — call `Attachments.upload/2` via `upload_attrs(content_type: "video/mp4")` (video
  is explicitly excluded, §2.1); assert the return is `{:error, :content_type_not_allowed}`;
  assert `Repo.aggregate(Artifact, :count, prefix: schema) == 0` and
  `Repo.aggregate(Attachment, :count, prefix: schema) == 0` — the same two zero-row assertions
  the existing `:file_too_large` test already makes for its own rejection path.

- **`"content_type_not_allowed triggers without hitting file_too_large or storage_quota (AC1
  ordering)"`** — construct a request that would independently fail on size (an oversized
  ~26 MiB `raw_bytes`) and on quota (a tenant whose `storage_allowance_bytes` is already
  exhausted), but with `content_type: "video/mp4"`; asserting the return is exactly `{:error,
  :content_type_not_allowed}` (never `{:error, :file_too_large}` or `{:error,
  :storage_quota_exceeded}`) proves the new check runs strictly first, same proof-of-ordering
  idiom the two existing REQ-390 AC3 tests already establish for size-vs-quota (§3.1).

- **`"application/pdf continues to be accepted (AC3 regression, same fixture REQ-211/212's own
  tests use)"`** — call `Attachments.upload/2` via `upload_attrs(content_type:
  "application/pdf")`, the same value already asserted in
  `test/letflow/routers/req212_attachments_routes_test.exs:165` and
  `test/letflow/engine_complete_task_test.exs:539/568`; assert `{:ok, %Attachment{content_type:
  "application/pdf"}}`.

Route-level (`test/letflow/routers/req212_attachments_routes_test.exs` or a new
`req389_*_test.exs`, matching this codebase's per-requirement route-test-file convention
already visible in `req212_attachments_routes_test.exs`/`req386_attachment_links_routes_
test.exs`/`req388_attachment_access_denial_audit_test.exs`), for AC2:

- **`"POST .../attachments with a disallowed content_type returns 415 naming the type and the
  allowed set"`** — drive a multipart upload with `content_type: "video/mp4"`; assert
  `conn.status == 415`; assert the response body's `"detail"` text contains `"video/mp4"` AND
  names at least one allowed type (e.g. `"application/pdf"`) — proving both halves of AC2's
  "naming the rejected content_type and the allowed set" wording.

## 4. Why this does NOT contradict INV-a (AC4 — the acceptance criterion most load-bearing
## for this design's own pass/fail)

**INV-a's exact scope, restated precisely** (quoted in full in §0): INV-a is a claim about
**verification against byte content** — "no magic-byte/MIME-sniffing check is performed
anywhere here," "a caller declaring `content_type: "application/pdf"` for a file that is not
actually a PDF is accepted and stored exactly as declared." INV-a is silent on, and makes no
claim about, whether the **declared string itself** may be checked against anything at all —
it only forecloses one specific kind of check: inferring/verifying content_type **from the
bytes**.

**What this requirement adds is a different check, over a different input, answering a
different question:**

| | INV-a's subject (unchanged) | REQ-389's new check |
|---|---|---|
| **Input examined** | `raw_bytes` (the actual byte content) | `content_type` (the caller-declared string) |
| **Question asked** | "Do these bytes actually match a PDF's/JPEG's/etc. magic-byte signature?" | "Is this declared string a member of a fixed allowlist of strings?" |
| **Answer's trustworthiness claim** | None — deliberately not computed at all | None — the declared string is exactly as trustworthy (or not) after this check as before it |
| **What a lying caller can still do** | Declare `application/pdf` for non-PDF bytes — accepted, unchanged by this requirement | Declare `application/pdf` (an allowed string) for a video file's actual bytes — **still accepted**, exactly as INV-a's own example already describes |

**The load-bearing point:** this requirement's allowlist check operates entirely on the
**declared string**, never on `raw_bytes`. A caller who wants to upload an actual video file
and is willing to *lie* about its `content_type` (declare `"application/pdf"` or any other
allowlisted string) is **not stopped by this requirement** — and is not supposed to be; that
would require the magic-byte inspection INV-a explicitly disclaims, which stays explicitly
out of scope for this requirement too (§1's "OUT OF SCOPE" line, requirement text's own
words). What this requirement stops is a caller who **declares** an excluded type (e.g.
honestly declares `"video/mp4"` for an actual video file, as this scenario's own UAT-review
finding describes — the GUI's file picker/browser sets `content_type` from the file's
extension/registered MIME type, not from an adversarial hand-crafted request). This is a
**coarser, string-level filter**, applied identically regardless of whether the declared
string happens to be true — exactly the same trust posture INV-a already assigns to
`content_type` everywhere else in this module. The allowlist doesn't make `content_type` a
"validated fact" (INV-a's phrase) about the bytes; it makes it a **gated declaration space** —
the set of strings a caller may declare shrinks, but nothing about whether a given declaration
is *true* is, or was ever, checked. Restated as the one sentence a future reader most needs:
**INV-a is a statement about what is never inferred from bytes; this requirement is a check
on what may be asserted as a string — the two operate on disjoint inputs and neither
contradicts, weakens, or reopens the other.**

**Editorial consequence for the moduledoc:** `Letflow.Repository.Attachments`'s own moduledoc
(INV-a's home, §0) should gain one clarifying sentence at the end of the existing INV-a
section — not a rewrite, an addition — along these lines: *"REQ-389 adds a check of the
declared `content_type` string against a fixed allowlist (§`@allowed_content_types`); this is
a check of the caller's own assertion, not of the underlying bytes, and does not weaken this
invariant — a caller can still declare any allowlisted type for any actual byte content,
exactly as before."* ELIXIR-DEV should add this sentence when implementing, so a future reader
of the moduledoc encounters the same non-contradiction argument in the code's own permanent
documentation, not only in this design doc.

## 5. Security relevance (this design's own determination, not silently decided)

**This design does not believe SECURITY-REVIEWER is required as a hard gate**, consistent
with the task briefing's framing ("a stricter, more restrictive check on an existing
tenant-scoped upload path, not new tenant-data exposure"), for these concrete reasons:

- **INV-1 (tenant isolation):** untouched — the new check reads only `attrs[:content_type]`
  and the fixed `@allowed_content_types` module attribute; no tenant-scoping code path
  (`opts[:prefix]`, `tenant_id` derivation) is added, removed, or reordered relative to it.
- **INV-2 (server-side field authorization):** untouched — no new response field is added;
  the 415 body's "allowed set" text is a fixed, non-tenant-specific, non-secret constant
  (the same list is identical for every tenant, §2.2), not a value that could leak one
  tenant's data to another.
- **This is strictly a new rejection path, narrowing what is accepted — it cannot newly
  expose, leak, or grant access to anything a caller could not already do before this
  requirement.** The only novel capability this design's own §2.1 slightly relaxes is that
  `application/octet-stream` and three other pre-existing-fixture-driven types are
  *explicitly* enumerated as allowed (§2.3) rather than implicitly accepted by omission of any
  check — but every one of those five types was already fully accepted, unconditionally,
  before this requirement (§0), so no new content_type value becomes acceptable that wasn't
  already accepted today. Net effect on the accepted set: strictly a subset of today's
  (unbounded) accepted set — video/audio move from "accepted" to "rejected"; nothing moves
  the other direction.

**If CODE-DESIGN-VALIDATOR or REVIEWER disagrees** — e.g. on the view that "naming the
allowed set in an unauthenticated-adjacent 4xx body" is itself information disclosure worth a
SECURITY-REVIEWER look — that determination should be made explicitly by them, not silently
overridden by this design; noted here so it is a visible, re-examinable judgement call rather
than an assumption baked in without a trace.

## 6. Summary of all touched files (implementation surface, not code)

| File | Change |
|---|---|
| `lib/letflow/repository/attachments.ex` | New `@allowed_content_types` module attribute (§2.1); `upload/2` gains the first-checked content-type gate (§3.1) and a widened `@spec` (§3.2); new public `allowed_content_types/0` accessor (§3.2); moduledoc's existing INV-a section gains one clarifying sentence (§4) |
| `lib/letflow/routers/instances.ex` | New `render_upload_attachment/2` clause for `{:error, :content_type_not_allowed}` → `Response.unsupported_media_type/2` (415), naming the rejected type and the allowed set (§3.3) |
| `test/letflow/repository/attachments_test.exs` | New tests: rejection-with-no-persistence (AC1), ordering-proof (AC1), `application/pdf` regression (AC3) — TEST-DESIGNER's job, shape given (§3.4) |
| `test/letflow/routers/req212_attachments_routes_test.exs` (or new `req389_*_test.exs`) | New route-level 415 test (AC2) — TEST-DESIGNER's job, shape given (§3.4) |

No existing test file needs a content_type fixture edit (§2.3) — this is a deliberate design
property, not an oversight; a future reader who finds a test breaking because of this change
should treat that as a signal the allowlist (§2.1) needs revisiting, not that the test was
wrong.

## 7. Open questions (not silently resolved)

- **OQ-1 (§2.1):** the exact allowed-type list beyond `application/pdf` and the
  video/audio-exclusion is this design's own judgement call, explicitly flagged for REVIEWER
  (same posture as `@max_upload_bytes`). A future requirement could narrow or widen it (e.g.
  drop `application/octet-stream` once/if the five pre-existing test fixtures naming it are
  deliberately updated) without needing to touch `upload/2`'s own check logic.
- **OQ-2 (§2.2):** per-tenant-configurable allowed types are out of scope here (no requirement
  or decision record asks for it) but a natural extension point if a future requirement needs
  it, following REQ-390's `Tenant.storage_allowance_bytes` precedent.
- **OQ-3 (§5):** whether SECURITY-REVIEWER should look at this anyway, given the "name the
  allowed set in the response body" AC2 requirement — this design's own read is no, but names
  the question explicitly rather than assuming.
