# REQ-388 — Audit-log entry for a denied instance-attachment content fetch

Filed from `test/uat-reports/gui-review-2026-09-20-attachment-cross-tenant-probe.md`
(PW-09, EO-005). Independent of REQ-386/387 (signed-link mechanism and its frontend
viewer — not yet built; this design does not reference or depend on either).

Scope: `lib/letflow/routers/instances.ex`'s `handle_get_attachment_content/3` and its
`fetch_scoped_attachment_content/3` helper only. `handle_delete_attachment/3` /
`fetch_scoped_attachment_metadata/3` (the DELETE sibling) are explicitly **out of
scope** — the requirement text scopes this to "instance-attachment content access"
(the GET read path) and EO-005 only concerns a denied *fetch*, not a denied delete.

## 1. Read-before-design confirmations

- `handle_get_attachment_content/3` (instances.ex, the route handler) and
  `fetch_scoped_attachment_content/3` (~line 1156) read in full. Today, on any denied
  branch, neither calls `Letflow.Audit` nor any logging facility beyond the ordinary
  Plug request log.
- `Letflow.Repository.Attachments.get/2` (~line 362) and `get_content/2` (~line 432)
  read in full: `get/2` casts `id` via `Ecto.UUID.cast/1` first — a syntactically
  malformed id short-circuits to `{:error, :invalid_id}` **before any `Repo.get/3`
  query runs**; a syntactically valid id that resolves to no row *or* to another
  tenant's row (invisible under the caller's own `opts[:prefix]`-scoped query — the
  query structurally cannot see it) both resolve to the exact same `{:error,
  :not_found}` — the database round-trip returns `nil` for both, and nothing in `get/2`
  or `get_content/2` can (or should) tell them apart. This fusion is the existing,
  deliberate REQ-211/212 privacy design and is preserved in full by this design (§3).
- `lib/letflow/audit.ex` read in full, plus every existing caller found via
  `grep -rn "Letflow.Audit\." lib/`: `Letflow.Repository.Activation` (inside
  `Ecto.Multi`, via `append_multi/4`), `Letflow.Engine.record_task_activation_rejection_audit/5`
  (ISS-0784), and `Letflow.Routers.TenantSettings.maybe_record_rejected_keys/5`
  (REQ-382). **No async/`Task.start`/backgrounded-write idiom exists anywhere in this
  codebase for an audit write.** Every existing caller is synchronous, in the same
  process that handles the request/mutation, either (a) inside the same `Ecto.Multi`/
  `Repo.transaction/1` as the primary mutation (`append_multi/4`, ISS-0784's own
  `Repo.transaction(fn -> Audit.insert_entry(...) end)`), or (b) — the router-layer
  precedent this design reuses directly — a bare, un-transacted `Audit.insert_entry/3`
  call made from inside the route handler itself, called and its result pattern-matched
  synchronously, **before** the success response is built (`TenantSettings.
  patch_tenant_settings/3`: `maybe_record_rejected_keys(conn, tenant, raw, ...)` runs,
  then `Response.ok(conn, settings_response_map(...))` is returned — the audit write's
  own DB round-trip is fully inside the request's response latency, and its failure is
  logged via `Logger.error/1` and swallowed, never surfaced to the caller or turned into
  a different HTTP status).
- REQ-211/212's not-found-folding test — `test/letflow/routers/req212_attachments_routes_test.exs`,
  `describe "AC5: cross-tenant -> 404, never 403"` (line 342) and `describe "AC6:
  cross-instance, same tenant -> 404"` (line 409) — read in full. AC5's own test builds
  three requests (cross-tenant GET, cross-tenant DELETE, and a genuinely
  never-existed-id GET) and asserts `get_conn.resp_body == never_existed_conn.resp_body`
  byte-for-byte, plus both `.status == 404`. It asserts only on `conn.status` and
  `conn.resp_body` — it never inspects `audit_entries`, so it is structurally
  unaffected by any additional application-side-effect this design adds, provided the
  effect does not change `Response.not_found(conn)`'s own status/headers/body (§4
  confirms this).
- `web/src/api/audit.ts` and `web/src/pages/admin/AuditLogPage.tsx` read directly, in
  full (§6 — the AC4 verdict).

## 2. What actually changes

Two new call sites inside `fetch_scoped_attachment_content/3`, both firing a single
`Letflow.Audit.insert_entry/3` call before the function returns its already-existing
`{:error, :not_found}` tuple. No change to this function's `@spec` (still
`{:ok, Attachment.t(), Artifact.t()} | {:error, :not_found | :content_missing |
:not_available}` — unchanged) and no change to `handle_get_attachment_content/3`'s own
`case`/`with` dispatch — the audit write is a side effect nested inside the existing
`:not_found`-producing clauses, not a new branch the caller has to handle differently.

```
@spec fetch_scoped_attachment_content(String.t(), Ecto.UUID.t(), keyword()) ::
        {:ok, Attachment.t(), Artifact.t()}
        | {:error, :not_found | :content_missing | :not_available}
defp fetch_scoped_attachment_content(raw_attachment_id, instance_id, opts)
```

Internal clause-by-clause disposition (all four of `Attachments.get_content/2`'s
possible returns, matching its own `@spec` union):

| `Attachments.get_content/2` result | Audited? | Resulting tuple (unchanged) |
|---|---|---|
| `{:ok, %Attachment{instance_id: ^instance_id}, artifact}` | no — success | `{:ok, attachment, artifact}` |
| `{:ok, %Attachment{} = attachment, _artifact}` (instance_id mismatch) | **yes** — cross-instance-same-tenant | `{:error, :not_found}` |
| `{:error, :not_found}` (fused cross-tenant / genuinely-never-issued) | **yes** — fused-denied | `{:error, :not_found}` |
| `{:error, :invalid_id}` (malformed UUID, never reaches a `Repo.get/3` at all) | **no** — excluded, §3 | `{:error, :not_found}` |
| `{:error, :content_missing}` | no — different, already-audited-elsewhere concern (data integrity, not access control) | `{:error, :content_missing}` |
| `{:error, :not_available}` | no — scan-status gate (ISS-0399), not an access-control denial | `{:error, :not_available}` |

A new private helper carries the write:

```
@spec record_attachment_access_denied_audit(
        attachment_id :: String.t(),
        found_attachment :: Attachment.t() | nil,
        instance_id :: Ecto.UUID.t(),
        conn :: Plug.Conn.t()
      ) :: :ok
defp record_attachment_access_denied_audit(attachment_id, found_attachment, instance_id, conn)
```

Called as:
- fused-denied clause: `record_attachment_access_denied_audit(raw_attachment_id, nil, instance_id, conn)`
- cross-instance clause: `record_attachment_access_denied_audit(attachment.id, attachment, instance_id, conn)`

`fetch_scoped_attachment_content/3`'s own arity does not currently receive `conn` — it
receives `(raw_attachment_id, instance_id, opts)`. This design widens its argument list
to `(raw_attachment_id, instance_id, opts, conn)` so the audit helper can reach
`conn.assigns.auth_context.user_id` (the actor) and `conn.assigns[:trace_id]`, matching
every other router-layer audit call site's own source of `actor_id`/`trace_id` (§1's
`TenantSettings` precedent, and `actor_id/1` already defined at instances.ex ~line 1329
for this exact purpose on other routes in this same module). `opts` alone already
carries `prefix` (`Keyword.fetch!(opts, :prefix)`, same extraction `TenantSettings` uses)
— no new argument is needed for that. `handle_get_attachment_content/3`'s single call
site is updated to pass `conn` through.

## 3. The malformed/never-issued boundary — decided and justified

The requirement text permits excluding "a genuinely malformed/never-issued UUID... if
indistinguishable from the above at the point the audit write would occur." Two
candidate exclusions were considered against that test:

- **Genuinely-never-issued** (a syntactically valid UUID with no row under any
  tenant): **not excludable**, because it is **not distinguishable** from the
  cross-tenant case at any point in this code — both take the identical
  `Repo.get/3 -> nil -> {:error, :not_found}` path inside `Attachments.get/2`, for the
  same structural reason (tenant isolation makes a foreign row invisible, which is
  indistinguishable from no row existing at all — this fusion is REQ-211/212's own
  deliberate design, confirmed in its moduledoc). There is no code point, at any layer,
  where "cross-tenant" could be audited without also auditing "never-issued" — they are
  the same branch. This design therefore audits the whole fused bucket uniformly (§2's
  table, row 3), which is also what the requirement's "at minimum the cross-tenant
  case" independently requires — since that case cannot be isolated, satisfying it
  necessarily means auditing the never-issued case too.
- **Genuinely-malformed** (`{:error, :invalid_id}` — fails `Ecto.UUID.cast/1` before
  any query runs): **excluded.** This *is* distinguishable at the point the write would
  occur — it is a separate clause in `Attachments.get/2`'s own `case`, reached before
  any `Repo.get/3` call, so `fetch_scoped_attachment_content/3` has full visibility
  into it being structurally different from the other two cases. It is excluded
  because: (a) a malformed id names no real attachment_id at all — there is no
  "attempted attachment_id" to record that means anything (AC1 requires naming "the
  attempted attachment_id"; a string that failed UUID parsing is not an id, it is
  arbitrary input, e.g. a stray path segment, a crawler probe, or a client-side typo
  against a stale bookmark); (b) EO-005's own scenario (steps 2/3) exercises real,
  syntactically-valid attachment ids belonging to another tenant/instance — it never
  exercises garbage input, so nothing in the driving UAT scenario is left uncovered by
  excluding this case; (c) `Letflow.Routers.Dlq`'s own established `:invalid_id ->
  not_found` precedent (cited in this file's own existing comment ~line 1150) treats
  malformed input as a response-shape concern only, never as an audit concern, and this
  design does not diverge from that without a reason EO-005 actually requires.

This boundary is stated here explicitly, per the requirement's own instruction not to
silently narrow coverage without saying which case is excluded and why.

## 4. Timing side-channel (AC3) — mitigation chosen, a pre-existing gap disclosed, and why the audit write itself does not worsen it

**A pre-existing, already-measurable timing asymmetry exists between the two audited
branches, upstream of anything this design adds — disclosed here rather than folded
into an unqualified "no new distinguishing signal" claim.**

Read directly, just now, to confirm this before writing the rest of this section:
`Letflow.Repository.Attachments.get_content/2` (attachments.ex ~432-445) and
`fetch_scoped_attachment_content/3` (instances.ex ~1156-1179).

`get_content/2` has **no concept of `instance_id`** — its `with` chain is
`get/2` (metadata lookup) `<- check_scan_status_clean/1 <- Repo.get(Artifact,
attachment.content_hash, prefix: prefix)`, and that last call fires
**unconditionally whenever the metadata row exists at all**, regardless of which
instance it belongs to. `fetch_scoped_attachment_content/3` only compares
`attachment.instance_id` against the path's `instance_id` **after** `get_content/2`
has already returned. Concretely, today, pre-REQ-388:

- **cross-instance-same-tenant** (a real attachment id, wrong instance): `get/2`'s
  `Repo.get(Attachment, ...)` finds the row, `check_scan_status_clean/1` passes (a real
  row is normally `:clean`), then `Repo.get(Artifact, attachment.content_hash, ...)`
  reads the **full `repository_artifacts.content` blob** — 2 `Repo` round-trips, one of
  them a potentially large byte read, whose result `fetch_scoped_attachment_content/3`
  then discards once it sees the `instance_id` mismatch.
- **cross-tenant / genuinely-never-issued** (fused, §3): `get/2`'s
  `Repo.get(Attachment, ...)` returns `nil` (structurally invisible or absent) —
  1 `Repo` round-trip, no artifact/blob read is ever attempted.

This is a real timing distinguisher between exactly the two branches §2's dispatch
table calls "byte-identical additional work" — but that phrase, correctly, describes
only this design's own addition (the audit-write call), not the total latency of the
branch. The blob-read asymmetry is **pre-existing** (present before REQ-388, entirely
inside `Attachments.get_content/2`, which this design's own §1/§8 already commit to
leaving unmodified) and **not introduced by this design**. §4 as originally written
did not check for it and should not have concluded "no new distinguishing signal is
introduced, by construction" without qualifying which signal that claim covers.

**In-scope vs. out-of-scope judgment call: out of scope for REQ-388, but flagged here
for SECURITY-REVIEWER rather than silently left unaddressed.** Reasoning:

- REQ-388's own requirement text is about adding an audit-log entry for a denied
  fetch — it does not ask this design to restructure `get_content/2`'s lookup
  ordering, and this design's own scope statement (top of file) and §8 already commit
  to `Attachments.get_content/2`/`get/2` being "unchanged; this design only adds a
  caller-side branch, no change to either function's `@spec` or behavior." Fixing the
  asymmetry would mean exactly the opposite: teaching `get_content/2` about
  `instance_id` (or reordering it to check instance match before the artifact/blob
  read), which is a real behavior change to a function two other requirements
  (REQ-211/212) already built and tested against its current shape — a materially
  larger and differently-scoped change than "add an audit write."
- The gap predates REQ-388 by construction (it exists in `main` today, independent of
  whether this design's audit write ships at all) — REQ-388 did not create the
  probing opportunity, it only adds observability for the denial that already carries
  the pre-existing timing signal.
- Counter-consideration (stated for completeness, not adopted): one could argue this
  design is "directly adjacent" enough to justify fixing it inline, since both live in
  the same call chain this design is already touching. This design does not adopt that
  view — the fix belongs in `Attachments.get_content/2` itself (reorder the
  instance-match check before the blob read, or pass `instance_id` into `get_content/2`
  so it can short-circuit), which is squarely REQ-211/212's own module, not a
  route-layer audit concern, and re-shaping it correctly (without breaking
  REQ-211/212's existing tests) is its own sized piece of work.
- **Recommendation, not a filing**: this looks like the same shape of adjacent-finding
  that produced ISS-0782/ISS-0784 this session — SECURITY-REVIEWER should weigh in on
  whether it warrants its own follow-up issue against
  `Letflow.Repository.Attachments.get_content/2` (e.g. "cross-instance-same-tenant
  denial is timing-distinguishable from cross-tenant/never-issued denial via the
  artifact blob read"). This design does not file that issue itself.

**Confirmed: this design's own addition does not make the pre-existing asymmetry
worse.** The audit write (§2's dispatch, §5's `record_attachment_access_denied_audit/4`)
is only reached *after* `get_content/2` has already returned — the blob-read asymmetry
above is fully resolved (one way or the other) before either audited branch calls the
new helper. Checked directly against §5's `attrs` shape: both audited call sites build
the exact same map shape (`actor_id`, `action` — same literal string, `resource_type` —
same literal string, `resource_id` — a UUID string either way, `before_state: nil` in
both, `after_state` — same two keys, `"reason"` a short atom-derived string in both,
comparable length), and both call the same `Audit.insert_entry/3` — no additional
`Repo` read, no different-sized payload, no different code path between the two
audited branches inside the helper itself. The helper's own cost is therefore uniform
across both audited branches, exactly as §2 already claimed; what's corrected here is
that the *total* per-branch latency (upstream `get_content/2` cost + this design's
uniform addition) was already non-uniform before this design touched anything, and
remains non-uniform after, by an amount this design does not change either way.

**Chosen approach for the audit write itself: reuse the existing synchronous, same-process idiom (§1) —
no async/`Task.start`.** This was a genuine two-way choice (the requirement text
explicitly floats async as an option), decided against for a stated reason, not
defaulted into:

1. **No async/backgrounded-write idiom exists anywhere in this codebase to reuse**
   (§1) — introducing one here would be inventing a new cross-cutting mechanism for a
   single call site, which is exactly the kind of unilateral new-mechanism decision
   `Letflow.Audit`'s own moduledoc (the "Capture mechanism" section) already declines
   to make for the trigger-vs-context-boundary question, for the same reason: a new
   mechanism needs its own supervision/failure-mode story (what supervises the
   `Task`? what happens if the tenant schema pool is saturated and the background write
   queues behind the request that spawned it? does a crashed background task alert
   anyone?) that a single MINOR/single-turn-sized requirement is not the place to
   design from scratch. The synchronous, in-process idiom already has an answer to all
   of these (§1's `Logger.error`/`Logger.warning` "log and swallow" precedent), reused
   here unchanged.
2. **What AC3 actually asks to be checked** is that the audit write does not become "a
   new timing side-channel" — i.e., that it does not let a caller learn something *by
   timing* that the response body/status does not already tell them. Two comparisons
   matter:
   - **Within the denied class** (cross-tenant vs. cross-instance-same-tenant vs.
     never-issued) — this is the comparison EO-001/EO-002 actually protect, since these
     are the cases a probing caller cannot already distinguish by status/body. §2's
     dispatch table calls the **same** `record_attachment_access_denied_audit/4`
     helper, doing the **same** shape of work (one `Audit.insert_entry/3` call, one
     insert, no additional `Repo` read beyond that), for **both** audited branches
     (fused-denied and cross-instance) — this design's own **added** work is
     byte-identical between those two branches, and does not widen the gap described
     immediately above. It does **not** follow that the two branches are
     indistinguishable overall: as disclosed just above, `get_content/2` already
     performs a different amount of upstream work per branch (an extra `Repo` round
     trip plus a full artifact-blob read for cross-instance-same-tenant, none for the
     fused case) **before** either branch reaches this design's helper at all — a
     pre-existing gap this design does not close and, per the judgment call above, does
     not attempt to close. Since the requirement excludes only the malformed-input case
     (§3), which remains the fastest of the three (short-circuits before any
     `Repo.get/3` at all, both before and after this change), the corrected claim is:
     this design introduces no *new* distinguishing signal between the two audited
     branches, but a real, pre-existing one already exists between them independent of
     this design, and is disclosed rather than silently carried forward under an
     unqualified "byte-identical" claim.
   - **Denied vs. success** — the status code (404 vs. 200) already tells a caller
     which branch it got; timing adds no information beyond what the response already
     discloses on its own, so this comparison is not a real secret-disclosure channel
     to begin with. This design does not attempt to equalize denied-branch latency
     against success-branch latency (doing so would mean adding a matching dummy
     `Repo` round-trip to every successful fetch, purely to defeat a timing signal that
     duplicates already-public information) — stated here explicitly, per AC3's
     instruction to state the check and why it's sufficient, rather than silently
     picking a scope. Verification method: this reasoning was checked by re-reading
     `fetch_scoped_attachment_content/3`'s existing structure (§1) to confirm the
     success branch and all `:not_found`-folded branches already differ in DB round-trip
     count today (the success branch's caller, `send_attachment_content/3`, streams the
     artifact's byte content; none of the denied branches ever reach that), so a
     status-correlated timing difference already existed before this change and is not
     introduced by it — this design's own addition only needs to avoid making the
     *within-denied-class* timing non-uniform, which §2's table achieves by construction
     (same helper, same call shape, every audited branch).
3. No load/benchmark measurement was run (no test environment with production-shaped
   latency exists in this pipeline) — the sufficiency argument here is structural (same
   *added* code path taken for every audited branch inside this design's own helper),
   not empirical, which is the same evidentiary standard REQ-211/212's own moduledoc
   already relies on for its response-shape indistinguishability claim (design §5.1,
   cited in §1 above). That structural argument covers only this design's own addition
   — it does not extend to, and should not be read as clearing, the pre-existing
   upstream `get_content/2` asymmetry disclosed above, which this design neither
   measured nor attempted to close.

## 5. Audit entry shape

```
%{
  actor_id: conn.assigns.auth_context.user_id,     # Ecto.UUID.t() -- the requesting actor
  action: "attachment.access_denied",               # new action name, "<resource>.<verb>"
                                                     # convention (matches "task.create",
                                                     # "instance.create", "tenant_settings.reject_unrecognized_keys")
  resource_type: "attachment",
  resource_id: attachment_id,                       # the ATTEMPTED attachment_id (AC1) --
                                                     # raw_attachment_id for the fused-denied
                                                     # case (no %Attachment{} exists to read
                                                     # an id from); attachment.id for the
                                                     # cross-instance case (already equal to
                                                     # raw_attachment_id, since that's how the
                                                     # row was found)
  before_state: nil,                                # nothing changed -- matches
                                                     # record_task_activation_rejection_audit/5's
                                                     # own "nothing changed" precedent
  after_state: %{
    "instance_id" => instance_id,                   # the instance_id path segment the
                                                     # request was made against (safe to
                                                     # record -- same-tenant value in both
                                                     # audited cases, never a foreign tenant's
                                                     # instance_id)
    "reason" => "cross_tenant_or_not_found" | "cross_instance"
                                                     # which of the two audited branches this
                                                     # was -- deliberately NOT the raw
                                                     # underlying %Attachment{} fields for the
                                                     # cross-instance case beyond what's
                                                     # already same-tenant-visible (no
                                                     # cross-tenant content ever appears here,
                                                     # by construction -- see INV-1 note in §7)
  },
  trace_id: conn.assigns[:trace_id]                 # matches TenantSettings's own
                                                     # `conn.assigns[:trace_id]` sourcing
}
```

`resource_id`'s type is `:string` (`Letflow.Audit.Entry.resource_id`, not `:binary_id`)
— per `Letflow.Audit`'s own moduledoc, no cast risk exists for this field (unlike
`actor_id`), so passing the raw string form of `attachment_id` is always safe
regardless of validity, consistent with `list_entries/1`'s own documented absence of an
`:invalid_resource_id` clause (§1's read of `audit.ex`).

`timestamp` is not supplied by the caller — `Letflow.Audit.insert_entry/3` computes it
itself (`DateTime.utc_now() |> DateTime.truncate(:microsecond)`, `audit.ex` ~line 216),
so AC1's "a UTC timestamp" is satisfied by every `insert_entry/3` call unconditionally,
with no design action needed beyond calling it.

Call shape, matching `TenantSettings.maybe_record_rejected_keys/5`'s own exactly (§1):

```
case Audit.insert_entry(Letflow.Repo, attrs, prefix) do
  {:ok, _entry} -> :ok
  {:error, reason} -> Logger.error(...); :ok
end
```

Best-effort, log-and-swallow — an audit-write failure must never turn a 404 into a
500, must never raise, and must never delay the caller past whatever `insert_entry/3`
itself takes (no retry loop). This mirrors `record_task_activation_rejection_audit/5`'s
own stated INV-8 discipline (§1) applied to a read path instead of a rollback path.

## 6. AC4 verdict — verified directly, not assumed

**Claim as stated in the requirement:** "`web/src/pages/admin/AuditLogPage.tsx` surfaces
the new entry with no frontend change, matching REQ-382's own precedent."

**Verdict: TRUE as literally stated (no frontend code change is required for the row to
appear), but the operator's ability to *find* it is materially narrower than "surfaces"
might imply on its own — the same gap ISS-0784's design already found and corrected for
a sibling requirement, verified fresh here rather than reused from memory.**

Read directly, just now:

- `web/src/api/audit.ts`'s `AuditLogFilters` interface (lines 4-11): `actor?`,
  `resource_type?`, `from?`, `to?`, `cursor?`, `page_size?`. **No `resource_id` field.**
  `auditApi.list/1` (lines 56-70) sends only these six as query params — it cannot ever
  send a `resource_id` filter, because the type doesn't carry one.
- `AuditLogPage.tsx`'s filter state (lines 46-51: `actor`, `resourceType`, `from`, `to`,
  `cursorStack`, `pageSize`) and its rendered `<input>`s (lines 89-129) mirror
  `AuditLogFilters` exactly — free-text `actor` and `resourceType` inputs, two date
  inputs, a page-size `<select>`. **No `resourceId` state, no input for it, no
  `action`-name filter either.**
- The page's list rendering (below line 160, not fully re-quoted here) maps whatever
  `auditApi.list/1` returns onto table rows generically — it has no allowlist keyed on
  `action`/`resource_type` values, so a row with `action: "attachment.access_denied"`,
  `resource_type: "attachment"` renders exactly like any other row, with no code change
  needed for it to appear. **This half of the claim holds.**

**Honest consumption path** (matching ISS-0784 design §8's own corrected wording,
applied to this entry): an operator investigating EO-005's scenario ("did a Vortex user
attempt to access a SwiftRoute attachment?") can filter `resourceType = "attachment"`
(free-text, not a `<select>` bound to a fixed list) and `actor = <the Vortex user's own
id, if already known>`, narrow `from`/`to` to the suspected window, and then visually
scan the resulting rows' Action column for `"attachment.access_denied"` and Resource
column for the specific `attachment_id` in question. There is no way to filter directly
by `resource_id` (the attempted `attachment_id`) or by `action` value — both gaps are
pre-existing (not introduced by this design, and not this requirement's to fix, per its
MINOR-equivalent sizing matching ISS-0784's own reasoning for declining to widen scope
into `AuditLogFilters`/`AuditLogPage.tsx` changes). Flagged here rather than silently
worked around, matching `core-directives.md`'s "No Issue Left Local-Only" — if
REVIEWER/ELIXIR-DEV judge it worth a follow-up, filing `resource_id`/`action` filter
support as its own requirement is the correct-sized fix, not folding it into REQ-388.

## 7. Security-relevant notes for SECURITY-REVIEWER (required per this requirement's own AC)

- **INV-1 (tenant isolation)**: `prefix` passed to `Audit.insert_entry/3` is
  `Keyword.fetch!(opts, :prefix)` — the same already-resolved, already-reviewed
  `conn.assigns.scoped_opts` value every other call in this handler already uses (no
  new derivation, no caller-suppliable override).
  `Ecto.UUID.t()`.
- **INV-2 (response shape)**: no new field is added to any HTTP response; the audit
  write is a side effect on an existing branch, not a new response shape.
- **INV-6 (new data-access path proves its scoping)**: applies — this is a new write
  call site reaching `audit_entries`. Satisfied by reusing `Audit.insert_entry/3`
  unmodified (§1) with the same `prefix` provenance as INV-1 above.
- **No cross-tenant data leak in the audit row itself**: for the fused-denied case,
  `after_state` never includes a foreign tenant's row content (there is none available
  — `Attachments.get/2` returned `{:error, :not_found}`, no `%Attachment{}` was ever
  read). For the cross-instance case, the `%Attachment{}` read belongs to the caller's
  **own** tenant (that's the whole premise of "cross-instance-**same-tenant**") — no
  invariant is at risk from recording its `id`/the mismatched `instance_id`, both
  already same-tenant-visible values.
- **Pre-existing timing side-channel, disclosed for SECURITY-REVIEWER judgment (§4)**:
  `Letflow.Repository.Attachments.get_content/2` performs its full
  `repository_artifacts.content` blob read unconditionally whenever the metadata row
  exists, before `fetch_scoped_attachment_content/3` ever checks `instance_id` — so a
  cross-instance-same-tenant denial already costs one more `Repo` round-trip (plus a
  blob read) than a cross-tenant/never-issued denial, independent of anything this
  design adds. This predates REQ-388, is not introduced or worsened by this design's
  audit write (§4 confirms the write's own added cost is uniform across both audited
  branches), and this design treats closing it as out of scope for REQ-388 — flagged
  here as a recommendation for SECURITY-REVIEWER to weigh in on, including whether it
  warrants its own follow-up issue against `get_content/2` (similar in shape to how
  ISS-0782/ISS-0784 originated from adjacent findings this session). This design does
  not file that issue itself.

## 8. Cross-module dependencies

- `Letflow.Audit.insert_entry/3` — unchanged, called with a new `attrs` shape (§5) from
  a new caller.
- `Letflow.Repository.Attachments.get_content/2`/`get/2` — unchanged; this design only
  adds a caller-side branch, no change to either function's `@spec` or behavior.
- `Plug.Conn` — `fetch_scoped_attachment_content/3`'s widened arity (§2) requires `conn`
  to flow from `handle_get_attachment_content/3`, its only caller.

## 9. Open questions

- **OQ-1**: `resource_type: "attachment"` vs. `resource_type: "instance"` (the choice
  ISS-0784 made for its own instance-scoped rejection entry) was a real design choice.
  This design picks `"attachment"` because AC1 explicitly requires naming "the attempted
  attachment_id" as the record's own subject, and `Letflow.Audit.list_entries/1`'s
  `resource_type` filter is how an operator would narrow to "all denied attachment
  access", not "all instance history" — flagged for REVIEWER to confirm rather than
  silently deciding it's the only reasonable choice.
- **OQ-2**: whether `after_state.reason`'s two string values
  (`"cross_tenant_or_not_found"` / `"cross_instance"`) are the right vocabulary, or
  whether REVIEWER would prefer atoms-as-strings matching `Letflow.Audit`'s own
  `action` naming convention more closely (e.g. `"fused_denied"` /
  `"cross_instance_same_tenant"`) — left as a naming judgment call, not a structural
  question; TEST-DESIGNER should treat whichever literal ships as the contract to test
  against, not invent a third spelling.
- **OQ-3** (not silently resolved): whether a future requirement should widen
  `AuditLogFilters`/`AuditLogPage.tsx` to add `resource_id`/`action` filters (§6) is
  explicitly left unresolved here — out of this requirement's own scope, named for a
  possible follow-up requirement rather than decided one way or the other.
