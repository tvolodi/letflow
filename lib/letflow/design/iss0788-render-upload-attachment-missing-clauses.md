# Design: Missing `render_upload_attachment/2` Clauses (ISS-0788)

**Issue:** ISS-0788  
**Run:** WF03-ISS0788-20260924  
**Affected file:** `lib/letflow/routers/instances.ex`  
**Status:** Design (Step 2)

---

## §0 Background

`Letflow.Repository.Attachments.upload/2` can return `{:error, :storage_quota_exceeded}`
and `{:error, :tenant_not_found}` per its `@spec` (lines 183–190,
`lib/letflow/repository/attachments.ex`). The private helper
`render_upload_attachment/2` in `lib/letflow/routers/instances.ex` is the sole
rendering path for that return value. It has five clauses:

| Pattern | HTTP |
|---|---|
| `{:ok, attachment}` | 201 |
| `{:error, :file_too_large}` | 413 |
| `{:error, :infected, verdict}` | 422 |
| `{:error, :scan_unavailable}` | 503 |
| `{:error, %Ecto.Changeset{}}` | 422 |

Neither `:storage_quota_exceeded` nor `:tenant_not_found` is matched. Either atom
reaching `render_upload_attachment/2` raises `FunctionClauseError` (HTTP 500).

**This design does NOT claim that any such clauses already exist — they do not.**
See §5 (AC4) for the req389 design-doc disposition.

---

## §1 New Function Head Signatures

### §1.1 `{:error, :storage_quota_exceeded}`

```
defp render_upload_attachment(conn, {:error, :storage_quota_exceeded})
  :: Plug.Conn.t()
```

**HTTP status:** 409 Conflict  
**Response builder:** `Response.conflict/2` (exists at `lib/letflow/api/response.ex:159`)  
**Response body (detail text):** `"tenant storage quota has been reached"`

**Rationale for 409:**
- 413 (Content Too Large) is already used for `:file_too_large` (individual file exceeds
  the per-file byte ceiling). `:storage_quota_exceeded` is a different constraint — the
  aggregate tenant-level quota — and must not reuse the same status.
- 422 is already used for two other error atoms.
- 503 is reserved for infrastructure unavailability.
- 409 Conflict accurately describes the condition: the request conflicts with the current
  resource state (quota exhausted). `Response.conflict/2` exists in the module; no new
  helper required.
- 415 (Unsupported Media Type) is semantically wrong for this condition.

### §1.2 `{:error, :tenant_not_found}`

```
defp render_upload_attachment(conn, {:error, :tenant_not_found})
  :: Plug.Conn.t()
```

**HTTP status:** 422 Unprocessable  
**Response builder:** `Response.unprocessable/2` (exists at `lib/letflow/api/response.ex:175`)  
**Response body (detail text):** `"request tenant does not exist"`

**Rationale for 422 and message text:**
- Matches the `{:error, :tenant_not_found}` convention used in
  `lib/letflow/routers/admin_services.ex:229` (`Response.unprocessable`) and
  `lib/letflow/design/req192-service-catalog-routes.md` (same pattern, 422).
- The admin_services instance uses the text
  `"owner_tenant_id does not name an existing tenant"` because the tenant is identified
  via an explicit request-body field. In the attachment-upload route the tenant is implicit
  from `scoped_opts` (the JWT auth scope), not from a named field; the message
  `"request tenant does not exist"` is accurate and avoids a misleading field reference.
  The HTTP code (422) is identical to the convention.

---

## §2 Clause Ordering

The `%Ecto.Changeset{}` head must remain last among the error clauses because it is a
structural match that is a broad catch-all for any changeset-valued second argument.
All atom-pattern clauses must precede it.

Proposed complete order after the fix:

1. `{:ok, attachment}` — success (unchanged)
2. `{:error, :file_too_large}` — 413 (unchanged)
3. `{:error, :infected, verdict}` — 422 (unchanged, arity-3 tuple)
4. `{:error, :scan_unavailable}` — 503 (unchanged)
5. `{:error, :storage_quota_exceeded}` — 409 **← NEW**
6. `{:error, :tenant_not_found}` — 422 **← NEW**
7. `{:error, %Ecto.Changeset{}}` — 422 (unchanged, remains last)

The two new heads are inserted at positions 5–6, between `:scan_unavailable` and
`%Ecto.Changeset{}`, preserving the catch-all's terminal position.

---

## §3 Cross-Module Dependencies

| Symbol | Module | Used for |
|---|---|---|
| `Response.conflict/2` | `Letflow.API.Response` (response.ex:159) | §1.1 |
| `Response.unprocessable/2` | `Letflow.API.Response` (response.ex:175) | §1.2 |

Both functions already exist. No new helpers, aliases, or imports are required.

---

## §4 Invariants

- **INV-5 (uniform not-found body):** Not applicable here — neither `:storage_quota_exceeded`
  nor `:tenant_not_found` represents a not-found probe that INV-5 governs. The
  `:tenant_not_found` atom in this context means the scoped auth tenant is absent from
  the DB (an infrastructure/auth misconfiguration), not an untrusted client probing for
  a resource ID.
- **No new external I/O** introduced by the render clause itself.
- **No secret material** in either detail string.

---

## §5 AC4 Disposition

`lib/letflow/design/req389-attachment-content-type-allowlist.md` **does not exist on disk**
(confirmed: file absent from `lib/letflow/design/`). ISS-0788 AC4 states:

> Correct REQ-389's design doc §0, which currently asserts the `:storage_quota_exceeded`
> clause already exists — it does not.

Because the doc does not exist, there is no false claim to correct and no claim to
propagate. **AC4 is trivially satisfied.** This design doc makes no claim about any
prior or existing `:storage_quota_exceeded` clause — none exists.

---

## §6 AC Traceability

| AC (from ISS-0788 suggested_fix / WF03 task) | Design element |
|---|---|
| AC1: Both new function head signatures specified | §1.1 and §1.2 — exact `defp` signatures with pattern |
| AC2: HTTP codes and response body convention stated | §1.1 (409, `Response.conflict/2`, detail text) and §1.2 (422, `Response.unprocessable/2`, detail text) |
| AC3: Clause ordering addressed | §2 — full ordered list, positioning rationale, catch-all preservation |
| AC4: req389 design doc false-claim disposition stated | §5 — doc absent, AC trivially satisfied, no claim made here |

---

## §7 Open Questions

None. Both HTTP codes are unambiguous given the existing set (§1 rationale). Message
text follows established conventions; the §1.2 wording deviation from admin_services
is minor (field-name accuracy) and does not affect status code or builder choice.
