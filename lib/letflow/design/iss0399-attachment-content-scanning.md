# Design: ISS-0399 — Content-scanning/antivirus pipeline for instance attachments

**Status:** design only — no implementation code below, signatures/shapes only, per
`docs/agents/workflows/WF-02_requirement_implementation.md` Step 1's convention (this
design doc follows the same presentation style as
`lib/letflow/design/req211-instance-attachments-core.md`, read in full before writing
this).

**This document produces:** a pluggable, tenant-agnostic scan step wired into
`Letflow.Repository.Attachments.upload/2` and `get_content/2` (REQ-211, shipped), plus
a new behaviour + default adapter and one migration. It does **not** touch REQ-212's
route/controller layer's own files beyond naming the one required follow-up edit in
§7 OQ-4 — that edit is ELIXIR-DEV's Step 2a scope, not redesigned here.

**Tenant-data path — SECURITY-REVIEWER review is required (see §6).** Every acceptance
criterion in `docs/issues/ISS-0399.yaml`'s description is addressed below; nothing is
left as "TBD."

---

## §0. Context read before writing this design

- `lib/letflow/design/req211-instance-attachments-core.md` §4.0 item 8 — the original
  deferral this issue exists to close: *"No antivirus/content-scanning pipeline exists
  for uploaded attachment bytes. This is a deliberately deferred follow-up, not an
  oversight — flag it for a future issue if malicious-upload risk becomes a concrete
  concern before S8."* This document is that issue's design.
- `lib/letflow/repository/attachments.ex` (shipped) — `upload/2`'s existing step
  ordering: (1) measure `byte_size`, reject `:file_too_large` **before** any hashing,
  upsert, or insert; (2) compute `content_hash`; (3) upsert `repository_artifacts`; (4)
  derive `tenant_id`; (5) insert `instance_attachments`. The size-check's
  reject-before-persist ordering is the precedent this design's scan step reuses
  exactly (§2 below) — a new failure mode inserted at the same point in the sequence,
  not a bolted-on afterthought.
- `lib/letflow/repository/attachment.ex` (shipped) — the `Attachment` Ecto schema this
  design adds one field to (§1).
- `priv/repo/migrations/20260901000002_create_instance_attachments.exs` (shipped) — the
  migration this design's new migration follows the same tenant-scoped-migration
  convention from (`if prefix() do` guard, `Letflow.TenantProvisioning.tenant_scoped_migrations/0`
  registration).
- `lib/letflow/oidc/token_verifier.ex` — the existing precedent in this codebase for a
  `@behaviour` + `Application.get_env/3`-resolved swappable adapter (real implementation
  vs. a test double), reused as the shape for §3's `AttachmentScanner` behaviour.
- `docs/agents/instructions/security-invariants.md` — INV-1 (tenant scoping), INV-4
  (no secrets), INV-8 (typed error handling, no unhandled crash on a realistic failure
  path — the scanner-unavailable branch, §2 step 3b) all apply; see §6.
- Grepped this codebase for any existing job-queue/background-worker infrastructure
  (`grep -rn "Oban\|GenServer" lib/letflow/repository/`, and scanned
  `lib/letflow/scheduler/poller.ex`, `lib/letflow/admission.ex`): **none exists that
  fits this use case.** `Letflow.Admission` is a concurrency-limiter for inbound
  instance-creation load, not a job-execution/retry queue; `Letflow.Scheduler.Poller`
  polls timer rows, not an arbitrary deferred-work mechanism. This absence is load-bearing
  for §2's synchronous-scan decision below — introducing new supervised background-job
  infrastructure is out of this issue's scope (MINOR severity, not currently blocking
  per the issue's own text) and would be a materially larger change than this deferral
  warrants today.

---

## §1. Schema change — `instance_attachments.scan_status`

### 1.1 New column

| Column | Type | Constraints |
|---|---|---|
| `scan_status` | `:string` (app-level `Ecto.Enum`) | `null: false`, `default: "pending"` at the DB level. Enum values: `:pending`, `:clean`, `:infected`, `:error`. |

**Why a DB-level default of `"pending"`, even though app code always explicit-sets it
on every new insert (§2 step 5 below sets `:clean` — `:infected`/`:error` never reach
insert at all, per §2's reject-before-persist ordering):** the default is what every
**pre-existing** `instance_attachments` row (any row inserted before this migration
ships, in any environment where one exists) receives automatically on migration —
`"pending"`, not `"clean"`. This is a deliberate fail-closed choice: an old row that
was never scanned must not silently read as `:clean`. See §4.2's `get_content/2` gate
and §7 OQ-2 for the backfill/rescan follow-up this implies.

`Ecto.Enum` (not a Postgres native `ENUM` type) — matches this table's own existing
`content_type` column precedent (`req211` design §1.2: "Plain string (open set)... no
`Ecto.Enum`" was `content_type`'s choice for a genuinely open set; `scan_status` is the
opposite case, a genuinely closed 4-value set, so `Ecto.Enum` over a plain `:string`
column is the correct match here, not a contradiction of that precedent) — stored as a
`:string` column so no Postgres-level `ALTER TYPE` migration hazard exists if a fifth
value is ever needed later.

No index added on `scan_status` — this design's only read of it is a single-row
existence/equality check inside `get_content/2` (§4.2), already reached via the
row's primary key. Bulk queries (e.g. "list all `:infected` rows across a tenant" for an
admin/ops view) are not an acceptance-criterion of this issue; flagged as non-blocking
in §7 OQ-5 rather than speculatively indexed now.

### 1.2 Migration

New file, same tenant-scoped-migration shape as the shipped
`20260901000002_create_instance_attachments.exs` (`if prefix() do` guard mandatory,
registration in `Letflow.TenantProvisioning.tenant_scoped_migrations/0` mandatory — both
halves, per that module's own manifest comment):

```
priv/repo/migrations/<timestamp>_add_scan_status_to_instance_attachments.exs
```

```
if prefix() do
  schema = prefix()
  alter table(:instance_attachments, prefix: schema) do
    add :scan_status, :string, null: false, default: "pending"
  end
end
```

No raw SQL, no string interpolation of tenant/user data (INV-7) — plain Ecto migration
DSL only, identical in kind to the shipped migration's own INV-7 statement.

### 1.3 Ecto schema change — `lib/letflow/repository/attachment.ex`

Add to the `schema "instance_attachments" do` block:

```
field(:scan_status, Ecto.Enum, values: [:pending, :clean, :infected, :error])
```

`changeset/2`'s `@required_fields` gains `:scan_status` (the caller — always
`Letflow.Repository.Attachments.upload/2`, never an external caller per this schema
module's existing "structural insert changeset" convention — supplies it explicitly,
same as every other field; no caller-facing default is exposed through the changeset
path, only through the raw DB column default backfill case in §1.1).

---

## §2. Where the scan runs — decision and justification

**Decision: synchronous, in-process, inline inside `upload/2`, before any persistence
— not async / not a pending-then-background-scanned state machine.**

Revised step sequence for `Letflow.Repository.Attachments.upload/2` (steps 1-2
unchanged from the shipped module; new step 3 inserted; old steps 3-6 renumbered 4-7):

1. Compute `byte_size = byte_size(raw_bytes)`. If it exceeds `@max_upload_bytes`,
   return `{:error, :file_too_large}` immediately — unchanged from shipped behavior.
2. Compute `content_hash = :crypto.hash(:sha256, raw_bytes)` — unchanged.
3. **NEW.** Call the configured scanner adapter (§3) synchronously:
   `scanner_mod().scan(raw_bytes, content_type)`.
   - `{:ok, :clean}` → continue to step 4.
   - `{:ok, :infected, verdict}` → **do not** upsert `repository_artifacts` or insert
     `instance_attachments`. Emit one structured `Logger.warning/2` audit entry (fields:
     `tenant_id` derived the same way step 4 below derives it, `instance_id`,
     `uploaded_by`, `content_hash`, `verdict` — never the raw bytes themselves, INV-4-
     adjacent hygiene even though `verdict` is not a secret) so a rejected malicious
     upload attempt is not silently invisible to operators, since (by construction) no
     `instance_attachments` row exists to record it in. Return
     `{:error, :infected, verdict}`.
   - `{:error, reason}` (scanner itself unavailable/errored — e.g. a future real
     external-AV adapter's network call timed out; the default adapter in §3 can never
     produce this branch, see §3.2) → **fail closed**: do not upsert or insert, same as
     the infected branch. Return `{:error, :scan_unavailable}`. No audit-log entry here
     (this is an infrastructure failure, not an attempted-malicious-upload signal —
     logging it as a plain `Logger.error/2` with `reason` is still appropriate but is
     ordinary operational logging, not the security-audit trail step 3's infected
     branch performs).
4. Upsert the `repository_artifacts` row — unchanged from shipped step 3.
5. Derive `tenant_id` — unchanged from shipped step 4.
6. Insert the `instance_attachments` row, now including `scan_status: :clean` (the only
   value ever passed here — this code path is unreachable unless step 3 returned
   `{:ok, :clean}`, so `:clean` is the sole literal this insert ever writes; `:infected`
   and `:error` are never written by `upload/2` itself, only read back later via a
   pre-existing/backfilled row, §1.1).
7. Return `{:ok, attachment}` / `{:error, changeset}` — unchanged.

### 2.1 Why synchronous rather than async/quarantine-then-scan

**The issue's own framing states the binding constraint: "a malicious file must never
be servable/downloadable before it's cleared."** Two ways to satisfy that:

- **(a) Synchronous, reject-before-persist (chosen).** Nothing is written to either
  `repository_artifacts` or `instance_attachments` unless the scan already returned
  `:clean`. There is no window, no intermediate row, and no code path anywhere that
  could serve an unscanned or infected attachment's bytes, because no such row can ever
  exist. This is a stronger guarantee than a runtime status check on read — the same
  "structurally nothing to ignore" pattern `req211`'s own INV-b uses for `byte_size`
  (§4.0 item 4 of that design): here, there is structurally no persisted infected row to
  guard against on the read side, not merely a guard that happens to catch it (§4.2's
  `get_content/2` gate is still added, but as defense-in-depth for the backfill/pending
  case in §1.1, not as this design's primary enforcement mechanism).
- **(b) Async — insert immediately in a `:pending` state, scan in a background
  worker, flip status on completion.** Rejected for this issue, for two independent
  reasons: (i) it requires new supervised background-job infrastructure this codebase
  does not currently have anywhere in `lib/letflow/repository/` or adjacent — §0's grep
  found none reusable, and standing one up is a materially larger, separately-designed
  change, not proportionate to a MINOR-severity deferred follow-up; (ii) a `:pending`
  row *is* servable-in-principle the instant it exists unless every single read path is
  independently disciplined to check `scan_status` first — that is strictly more
  places that must get the check right (every current and future caller of `get/2`,
  `get_content/2`, `list/2`-then-download) than (a)'s single choke point at `upload/2`.

**This decision is revisited, not permanent:** if a future real external-AV adapter
(ClamAV daemon, cloud AV API) makes the synchronous scan call's latency unacceptable
for the upload request's own response time, that is exactly the trigger named in §7
OQ-1 for moving to (b) — at that point `scan_status: :pending` (already a defined enum
value, §1.1, unused by any code path today) becomes load-bearing rather than reserved.
Choosing option (a) now does not foreclose (b) later; it is additive.

---

## §3. Scanning mechanism — pluggable behaviour + default adapter

### 3.1 Behaviour — `Letflow.Repository.AttachmentScanner`

New file: `lib/letflow/repository/attachment_scanner.ex`

```
@callback scan(raw_bytes :: binary(), content_type :: String.t()) ::
            {:ok, :clean}
            | {:ok, :infected, verdict :: String.t()}
            | {:error, reason :: term()}
```

Resolved the same way `Letflow.Oidc.TokenVerifier`'s implementation is resolved (§0):
`Application.get_env(:letflow, :attachment_scanner, Letflow.Repository.AttachmentScanner.SignatureHeuristic)`
inside `Letflow.Repository.Attachments`, called once per `upload/2` invocation (§2 step
3) as `scanner_mod().scan(raw_bytes, content_type)`. The third argument to
`Application.get_env/3` is the default adapter itself (§3.2) — no separate
`Mix.env()` branch is needed anywhere in `Letflow.Repository.Attachments`, unlike a
config key with no safe built-in default; this one is safe out of the box in every
environment, including a fresh `dev`/`test` checkout with no config override at all.

### 3.2 Default adapter — `Letflow.Repository.AttachmentScanner.SignatureHeuristic`

New file: `lib/letflow/repository/attachment_scanner/signature_heuristic.ex`

**What it is, stated explicitly (per this issue's own instruction to be explicit about
the choice and why):** a real, working, in-process signature-based scanner — not a
stub, not a TODO — using the **EICAR Anti-Virus Test File** string as its one detection
signature. EICAR is the antivirus industry's own standard 68-byte test string (defined
by the European Institute for Computer Antivirus Research, deliberately not a real virus
— every real AV engine, including ClamAV, is built to flag it), chosen here specifically
*because* it lets this scanner be genuinely real code with a genuinely real, deterministic,
harmless positive case TEST-DESIGNER can construct in a test (`"upload the EICAR string
→ get {:error, :infected, _}"`) without needing an actual malware sample or a live
ClamAV daemon in CI.

```
@spec scan(raw_bytes :: binary(), content_type :: String.t()) ::
        {:ok, :clean} | {:ok, :infected, verdict :: String.t()}
```

Behavior: if `raw_bytes` contains the EICAR signature as a substring (a plain
`String.contains?/2`-shaped check — this default deliberately does not attempt magic-
byte/file-type sniffing or any content-type-based branching, consistent with INV-a's
existing "`content_type` is never a validated fact" statement carried over from
`req211`), return `{:ok, :infected, "eicar-test-signature"}`; otherwise
`{:ok, :clean}`. **This adapter can never return `{:error, _}`** — it performs no I/O,
no network call, no external process; the `{:error, _}` branch exists in the behaviour
contract (§3.1) solely for a future adapter that *does* have an external failure mode
(§3.3), and `upload/2`'s §2 step 3 handling of that branch is exercised by a test double,
not by this default adapter.

**Explicitly out of scope for this default adapter, named rather than silently
omitted:** real malware-signature-database matching, heuristic/behavioral analysis, and
any actual ClamAV/cloud-AV integration. Swapping in a real engine later means writing
one new module implementing the same `@callback scan/2` and changing one config value
— no change to `Letflow.Repository.Attachments` itself.

### 3.3 Future real-adapter shape (not built by this issue — named so the seam is
proven, not just asserted)

A `Letflow.Repository.AttachmentScanner.ClamAV` (or cloud-API-backed) adapter would
implement the same `@callback scan/2`, translate a ClamAV `INSTREAM` protocol response
(or an HTTP API response) into the same three-shape return contract, and map any
connection/timeout failure to `{:error, reason}` — exercising the fail-closed branch
§2 step 3 already handles. Not designed further here; this subsection exists only to
show the seam in §3.1 is real, not hypothetical.

---

## §4. Function signature changes

### 4.1 `upload/2` (was: `lib/letflow/repository/attachments.ex` §4.1 of req211's
design)

```
@spec upload(upload_attrs(), opts()) ::
        {:ok, Attachment.t()}
        | {:error, :file_too_large}
        | {:error, :infected, verdict :: String.t()}
        | {:error, :scan_unavailable}
        | {:error, Ecto.Changeset.t()}
```

`upload_attrs()` itself is **unchanged** — the caller still supplies no scan-related
field; `scan_status` is entirely derived/internal, matching INV-b's "structurally
nothing to ignore" shape for `byte_size` (§0).

### 4.2 `get_content/2` (was: req211's REQ-212-addendum function, shipped)

```
@spec get_content(id :: String.t(), opts()) ::
        {:ok, Attachment.t(), Artifact.t()}
        | {:error, :invalid_id | :not_found | :content_missing | :not_available}
```

New branch: after the existing two-lookup mechanism (metadata via `get/2`, then the
`repository_artifacts` content lookup keyed by `content_hash`) succeeds, add one more
check **before** returning `{:ok, attachment, artifact}`: if
`attachment.scan_status != :clean` (covers `:pending`, `:infected`, `:error` —
uniformly, not differentiated in the returned error atom itself; see §7 OQ-3 for why
this is a stated decision, not an oversight), return `{:error, :not_available}` instead.
Bytes are never returned to the caller in this branch — the `Artifact.content` value is
not read/returned at all once the gate fails; the two-lookup mechanism's second query
may still execute (cheap, single-row, no behavior change to when it runs) but its result
is discarded on this branch rather than surfaced.

**Why this defense-in-depth gate still matters given §2's reject-before-persist
guarantee already makes an `:infected`/`:error` row structurally unreachable via
`upload/2` itself:** it is the only code path that can ever observe a **pre-existing**
`:pending` row — every row that existed before this migration's rollout, in any
environment, defaults to `:pending` (§1.1) and has never been scanned by this
mechanism at all. Without this gate, such a row's bytes would be servable today,
unscanned, silently — exactly the gap this issue exists to close. `list/2` and `get/2`
are **not** changed to filter on `scan_status` — a `:pending`/`:infected` row still
appears in a `list/2` listing (its metadata, including the new `scan_status` field
returned on every `Attachment` struct, is not itself sensitive) and `get/2`'s metadata-
only fetch still succeeds; only the byte-serving path (`get_content/2`) is gated,
because that is the only path that can leak actual file content.

`list_params()`/`list/2`'s own `@spec` is otherwise unchanged.

### 4.3 Moduledoc requirement (binding on ELIXIR-DEV at implementation, same pattern as
req211 §4.0)

`Letflow.Repository.Attachments`'s moduledoc's existing "Content-scanning deferral"
section (§4.0 item 8 of req211, quoted in §0 above) must be replaced — not merely
appended to — with a statement of the mechanism actually implemented: which adapter is
configured by default, the synchronous/reject-before-persist decision and one-sentence
why (§2), and a pointer to this document. Leaving the old deferral text in place
alongside the new mechanism would misdescribe the module to the next reader.

---

## §5. What happens to an infected/failed-scan attachment

Stated plainly, consolidating §2/§4 above into one answer per the issue's own
question:

- **Infected, caught synchronously on upload (the normal case going forward):**
  nothing is persisted — no `repository_artifacts` row, no `instance_attachments` row.
  The upload call returns `{:error, :infected, verdict}` to its caller (REQ-212's route
  layer, per §7 OQ-4, must map this to a 4xx response naming rejection, not a 500).
  One structured audit-log warning is emitted (§2 step 3). Nothing is "deleted" because
  nothing was ever written — there is no cleanup step because there is nothing to clean
  up.
- **Scanner unavailable on upload:** same as above (nothing persisted), returns
  `{:error, :scan_unavailable}` instead — fail closed, not fail open. The caller may
  retry.
- **A pre-existing `:pending` row (backfill case, §1.1), or a row somehow left
  `:infected`/`:error` (not reachable via this module's own code today, but not
  provably unreachable forever — e.g. a future async follow-up per §2.1(b), or a
  direct DB write outside this module):** the row is **not deleted** and **not
  automatically quarantined-and-removed** by this design. `get_content/2` blocks byte
  access (`{:error, :not_available}`, §4.2); `list/2`/`get/2` still show the row's
  metadata unchanged, including its `scan_status`, so a tenant/operator can see the row
  exists and why it's unavailable rather than it silently vanishing. `delete/2` is
  unchanged — a tenant may still hard-delete such a row via the existing delete path
  exactly as any other attachment (no new restriction added there; this design does not
  need one, since deleting an unavailable row is not a security concern, only *serving*
  one is).

---

## §6. For SECURITY-REVIEWER

This is a tenant-data path (attachment byte content); SECURITY-REVIEWER review is
required at Step 2c, same as REQ-211/REQ-212 themselves. Invariants assessed by this
design (ELIXIR-DEV's own Step 2c handoff must re-confirm against the actual diff, not
copy this table):

- **INV-1 (tenant isolation).** No change to tenant-scoping mechanism — every new
  function call (`scanner_mod().scan/2`) is pure/local, takes no `prefix`, touches no
  `Repo` call itself, and runs entirely inside `upload/2`'s and `get_content/2`'s
  existing `opts[:prefix]`-scoped call sites. Applies, satisfied by construction (no new
  data-access path added, §7 OQ-5 aside).
- **INV-4 (secrets by reference only).** No secret material is introduced. §2 step 3's
  audit-log entry explicitly excludes raw bytes; a future real adapter's own API
  key/credential (§3.3, not built here) would need its own INV-4-compliant
  `System.get_env/1`/`config/runtime.exs` resolution when it is eventually built — flagged
  for that future work, not applicable to anything shipped by this design.
- **INV-6 (new data-access paths prove their scoping).** The new migration (§1.2) adds a
  column, not a new table/route; no new data-access path in the INV-6 sense is
  introduced. Named here so SECURITY-REVIEWER doesn't need to re-derive that
  conclusion from scratch.
- **INV-7 (no SQL string interpolation).** §1.2's migration is plain Ecto DSL, no raw
  SQL.
- **INV-8 (typed error handling, no unhandled crash).** §2 step 3's `{:error, reason}`
  branch is exactly this invariant's concern — a scanner adapter that raises or a
  network call that fails must not crash `upload/2`'s caller; the `with`/`case`-shaped
  handling ELIXIR-DEV implements must wrap the adapter call so any raised exception from
  a future non-default adapter is caught and turned into `{:error, reason}` before it
  reaches `upload/2`'s own control flow — the default adapter (§3.2) cannot raise (pure
  binary pattern match), but the seam (§3.1) is written for adapters that can.

---

## §7. Open questions — not silently resolved

- **OQ-1.** If/when a real external-AV adapter with genuine network latency replaces
  the default (§3.3), §2's synchronous-inline decision should be revisited — this
  design states the trigger condition but does not pre-design the async follow-up
  itself (deliberately: designing infrastructure for a hypothetical future adapter
  this issue does not build would be speculative).
- **OQ-2.** Backfill/rescan of any pre-existing `instance_attachments` rows (created
  before this migration ships, in any environment where one might exist — the issue's
  own text states "not currently a blocking concern," consistent with treating this as
  low-probability but not zero-probability). This design's migration default
  (`:pending`, §1.1) makes such rows fail closed (undownloadable) rather than silently
  `:clean`, which is the safe behavior, but does not itself provide a rescan mechanism
  to move them to `:clean`. A `mix letflow.rescan_attachments` task (re-reading each
  `:pending` row's `repository_artifacts.content` by `content_hash` and re-running §3's
  scanner) is a reasonable follow-up but is not designed here — named as a candidate,
  not committed to.
- **OQ-3.** `get_content/2`'s `{:error, :not_available}` deliberately does not
  differentiate `:pending`/`:infected`/`:error` in the returned error atom (§4.2) — the
  caller can still distinguish via the `Attachment.scan_status` field already returned
  by `get/2`/`list/2` if REQ-212's route layer chooses to surface it. This design
  decided uniform-atom-plus-inspectable-field over three separate error atoms because
  the three cases share one caller-facing consequence ("not downloadable right now")
  and REQ-212's route layer is free to branch on `scan_status` itself if a richer
  response is wanted later — flagged for REVIEWER at Step 2d if this reads as the wrong
  call.
- **OQ-4 (implementation-scope note, not a schema/behavior question).** REQ-212's
  already-shipped route layer (`lib/letflow/routers/instances.ex` — the attachment
  byte-content GET route, per `lib/letflow/design/req212-instance-attachments-routes.md`)
  has an existing error-to-HTTP-status mapping for `get_content/2`'s return shape. That
  mapping must be extended for the two new `upload/2` error branches
  (`{:error, :infected, _}` → a 4xx, not 500; `{:error, :scan_unavailable}` → a 5xx or
  a 4xx retry-able status, ELIXIR-DEV's call per this codebase's existing
  `Letflow.Api.Error`/`Letflow.Api.Response` conventions) and the new `get_content/2`
  branch (`{:error, :not_available}` → a 4xx, not a 404 — this is a genuine
  metadata-exists-but-content-blocked case, distinct from the true not-found case
  `get/2` already returns 404 for). Named explicitly here so this required edit to an
  already-`done` requirement's file is not missed at Step 2a — it is in this design's
  implementation scope even though it is not this design's own new file.
- **OQ-5.** No index/admin-listing mechanism for "all `:infected`/`:pending` rows across
  a tenant" is designed here (§1.1) — out of this issue's stated acceptance criteria;
  candidate for a later requirement if operational visibility into rejected-upload
  volume becomes a real need.

---

## §8. Acceptance-criteria mapping (per the issue's own "Key design questions to
resolve concretely")

| Issue's question | Resolved in |
|---|---|
| Where does the scan run (sync/blocking vs. async/quarantine)? Decision + justification. | §2, §2.1 |
| Actual scanning mechanism — pluggable behaviour with a real default adapter, explicit about the choice. | §3.1, §3.2, §3.3 |
| Schema/state changes (`scan_status` field) + migration. | §1 |
| What happens to an infected/failed-scan attachment (deleted/quarantined/download blocked)? | §5 |
| SECURITY-REVIEWER review required, stated explicitly. | §6 (and this document's own header) |
