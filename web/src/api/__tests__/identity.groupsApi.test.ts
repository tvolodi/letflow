// @vitest-environment jsdom
/**
 * ISS-0765 — regression coverage for the `groupsApi` route-prefix and
 * response-shape correction.
 *
 * Authority: lib/letflow/design/iss-0765-groupsapi-route-prefix-audit.md §7
 * (the eleven-row matrix) and §7.1 (the fail-first accounting). Spec:
 * test/specs/ISS-0765.md.
 *
 * Before the fix, six of the eight `groupsApi` functions dialled
 * `/api/v1/admin/groups...`. Nothing is mounted there: lib/letflow/router.ex:130
 * forwards `/api/v1` to Letflow.Plugs.ApiPipeline, whose only `/admin/*` mount is
 * `/admin/services` (lib/letflow/plugs/api_pipeline.ex:154), so every one of those
 * calls reached the pipeline catch-all (:203-205) and 404'd *after* successful
 * authentication — a silent dead end behind a working-looking button. The six real
 * group routes live under `/api/v1/identity/groups`
 * (lib/letflow/routers/identity.ex:178-204).
 *
 * Alongside the prefix, the fix corrected three contract lies:
 *   - `.addMembers(id, userIds[])` -> `.addMember(id, userId)` sending `{ user_id }`,
 *     because resolve_member_user_id/1 (lib/letflow/routers/identity.ex:525-537)
 *     silently discards everything after the first array element.
 *   - `.members(id)` now declares the real `Pagination.Page` envelope
 *     (`{items, next_cursor, count}`) instead of `User[]`, with NO unwrapping shim
 *     inside web/src/api/ (design INV-B, frontend_developer_guide.md §4 rule 1).
 *   - `.get(id)` / `.update(id, body)` are gone: those operations exist at no
 *     prefix and in no context module, so they were unimplemented, not mis-prefixed.
 *
 * Harness: mirrors web/src/api/__tests__/identity.removeMembers.test.ts (ISS-0736)
 * exactly — jsdom, a `window.fetch` spy ASSIGNED from `vi.fn()`, `setToken`/
 * `clearToken` around each case, and assertions on the exact method + path actually
 * requested. The spy is assigned rather than installed through a helper call on
 * purpose: web/tests/guards/source-scan.spec.ts applies
 * web/tests/guards/forbidlist.ts's `raw-fetch-outside-client` pattern to the whole
 * content of every file under web/src/, and permits it only in web/src/api/client.ts.
 * No entry in that forbidlist may be weakened and no allowedPaths exemption may be
 * added for this file (design INV-F).
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { groupsApi } from '../identity'
import { setToken, clearToken } from '../client'

const originalFetch = window.fetch

/** One `user_map/1` object, transcribed key-for-key from
 *  lib/letflow/routers/identity.ex:729-740. Lowercase `status`/`auth_source`
 *  values, because that mapper emits `Atom.to_string/1` over
 *  `Ecto.Enum, values: [:active, :inactive]` / `[:internal, :oidc]`
 *  (lib/letflow/identity/user.ex:41-42) and the router contains no upcase. */
const WIRE_MEMBER = {
  id: 'u-1',
  username: 'alice',
  display_name: 'Alice Example',
  email: 'alice@example.test',
  status: 'active',
  auth_source: 'internal',
  inserted_at: '2026-09-01T00:00:00Z',
  updated_at: '2026-09-02T00:00:00Z',
}

/** The exact `Letflow.Api.Pagination.Page` envelope: `@derive {Jason.Encoder,
 *  only: [:items, :next_cursor, :count]}` (lib/letflow/api/pagination.ex:81).
 *  No `has_more` — Pagination.Page never emits one. */
const WIRE_MEMBER_PAGE = {
  items: [WIRE_MEMBER],
  next_cursor: null,
  count: 1,
}

function jsonResponse(body: unknown, init: { status?: number; headers?: Record<string, string> } = {}) {
  return Promise.resolve(
    new Response(body === undefined ? null : JSON.stringify(body), {
      status: init.status ?? 200,
      headers: { 'Content-Type': 'application/json', ...(init.headers ?? {}) },
    }),
  )
}

/** Assigns a `window.fetch` double that resolves `body`, and returns the spy.
 *  Assignment, never a call to the real thing — see the file header on
 *  `raw-fetch-outside-client`. */
function installSpy(body: unknown, status = 200) {
  const spy = vi.fn().mockImplementation(() => jsonResponse(body, { status }))
  window.fetch = spy as unknown as typeof window.fetch
  return spy
}

/** The request the spy captured, normalised. `client.get` passes no `method`
 *  key at all (web/src/api/client.ts:194 -> request<T>(url) with `{}` options),
 *  so an absent method means GET on the wire. */
function captured(spy: ReturnType<typeof vi.fn>): { url: string; method: string; body: unknown } {
  expect(spy).toHaveBeenCalledTimes(1)
  const [url, init] = spy.mock.calls[0] as [string, RequestInit | undefined]
  const rawBody = init?.body
  return {
    url,
    method: init?.method ?? 'GET',
    body: typeof rawBody === 'string' ? JSON.parse(rawBody) : undefined,
  }
}

beforeEach(() => {
  setToken('test-token')
})

afterEach(() => {
  window.fetch = originalFetch
  clearToken()
  vi.restoreAllMocks()
})

describe('ISS-0765 — groupsApi calls the real /api/v1/identity/groups routes', () => {
  // ── Row 1 ────────────────────────────────────────────────────────────────
  it('T-0765-LIST: list() -> GET /api/v1/identity/groups, not /api/v1/admin/groups', async () => {
    const spy = installSpy({ items: [], total: 0 })

    await groupsApi.list()

    const req = captured(spy)
    expect(req.method).toBe('GET')
    expect(req.url).toContain('/api/v1/identity/groups')
    expect(req.url).not.toContain('/api/v1/admin/groups')
  })

  // ── Row 2 ────────────────────────────────────────────────────────────────
  it('T-0765-CREATE: create(body) -> POST /api/v1/identity/groups with the body verbatim', async () => {
    const spy = installSpy({ id: 'g-1', name: 'ops', display_name: 'Ops', description: 'd', created_at: '2026-09-01T00:00:00Z' })
    const body = { name: 'ops', display_name: 'Ops', description: 'd' }

    await groupsApi.create(body)

    const req = captured(spy)
    expect(req.method).toBe('POST')
    expect(req.url).toContain('/api/v1/identity/groups')
    expect(req.url).not.toContain('/api/v1/admin/groups')
    expect(req.body).toEqual(body)
  })

  // ── Row 3 ────────────────────────────────────────────────────────────────
  it('T-0765-DELETE: delete(id) -> DELETE /api/v1/identity/groups/:id', async () => {
    const spy = installSpy(undefined, 204)

    await groupsApi.delete('g-1')

    const req = captured(spy)
    expect(req.method).toBe('DELETE')
    expect(req.url).toContain('/api/v1/identity/groups/g-1')
    expect(req.url).not.toContain('/api/v1/admin/groups')
  })

  // ── Row 4 ────────────────────────────────────────────────────────────────
  it('T-0765-ADD-PATH: addMember(id, userId) -> POST /api/v1/identity/groups/:id/members', async () => {
    const spy = installSpy({ group_id: 'g-1', user_id: 'u-1', created: true }, 201)

    await groupsApi.addMember('g-1', 'u-1')

    const req = captured(spy)
    expect(req.method).toBe('POST')
    expect(req.url).toContain('/api/v1/identity/groups/g-1/members')
    expect(req.url).not.toContain('/api/v1/admin/')
  })

  // ── Row 5 ────────────────────────────────────────────────────────────────
  it('T-0765-ADD-BODY: that POST sends { user_id }, never a user_ids array', async () => {
    // resolve_member_user_id/1 (lib/letflow/routers/identity.ex:525-537) matches
    // `%{"user_id" => id}` FIRST and, on the `user_ids` clause, returns only the
    // head of the list. A plural client contract can therefore never be honoured;
    // the comment at :483-489 records that as a deliberate R-Co port decision.
    const spy = installSpy({ group_id: 'g-1', user_id: 'u-1', created: true }, 201)

    await groupsApi.addMember('g-1', 'u-1')

    const req = captured(spy)
    expect(req.body).toEqual({ user_id: 'u-1' })
    expect('user_ids' in (req.body as Record<string, unknown>)).toBe(false)
  })

  // ── Row 6 ────────────────────────────────────────────────────────────────
  it('T-0765-ADD-ARITY: the surface exposes addMember/2 and no addMembers', () => {
    expect(typeof groupsApi.addMember).toBe('function')
    expect(groupsApi.addMember.length).toBe(2)
    expect('addMembers' in groupsApi).toBe(false)
  })

  // ── Row 7 ────────────────────────────────────────────────────────────────
  it('T-0765-MEMBERS: members(id) -> GET /api/v1/identity/groups/:id/members, and returns the Pagination.Page envelope unreshaped', async () => {
    const spy = installSpy(WIRE_MEMBER_PAGE)

    const result = await groupsApi.members('g-1')

    // Half (i) — the path. RED pre-fix: the pre-fix literal was
    // `/api/v1/admin/groups/${id}/members`. This is the half that carries row 7's
    // fail-first evidence.
    const req = captured(spy)
    expect(req.method).toBe('GET')
    expect(req.url).toContain('/api/v1/identity/groups/g-1/members')
    expect(req.url).not.toContain('/api/v1/admin/')

    // Half (ii) — the envelope. This half PASSES pre-fix AND post-fix, by design
    // (design §7.1): `request<T>` ends in `return response.json() as Promise<T>`
    // (web/src/api/client.ts:169) and `T` is erased at runtime, so
    // `client.get<User[]>` and `client.get<GroupMemberPage>` are byte-identical
    // against the same spy body. It is NOT fail-first evidence and must not be
    // counted as an eleventh red row. It is a FORWARD REGRESSION GUARD: it goes
    // red the moment anyone reintroduces an `.items` unwrap inside
    // `groupsApi.members`, which is exactly what design INV-B forbids and what
    // decision (b) rejected. The fail-first evidence for decision (b)'s retype is
    // carried by the M-1a/M-1b mutant probes recorded in test/specs/ISS-0765.md,
    // because no runtime assertion can carry it.
    expect(Array.isArray(result)).toBe(false)
    expect(result).toEqual(WIRE_MEMBER_PAGE)
    expect(result.items.length).toBe(1)
    expect(result.count).toBe(1)
    expect(result.next_cursor).toBeNull()
  })

  // ── Row 8 ────────────────────────────────────────────────────────────────
  it('T-0765-NO-GET-UPDATE: .get and .update are gone — those operations exist at no prefix', () => {
    // GET /groups/:id and PATCH|PUT /groups/:id are absent from
    // Letflow.Routers.Identity's route table at every prefix, and
    // lib/letflow/identity.ex has no get_group/2 or update_group/3. Re-prefixing
    // them would only have moved the 404 from the pipeline catch-all to the
    // router's own `match _`; removal is the correction.
    expect('get' in groupsApi).toBe(false)
    expect('update' in groupsApi).toBe(false)
  })

  // ── Row 9 ────────────────────────────────────────────────────────────────
  it('T-0765-SURFACE: the exported surface is exactly the functions with a real route', () => {
    // ISS-0816 T9(i): `listAllMembers` is the seventh function — the bounded
    // drain over the SAME route `members` dials. This assertion is exact
    // equality over the live object's keys, so it went red the moment the
    // function was added; extending it is the correction, never relaxing it.
    expect(Object.keys(groupsApi).sort()).toEqual([
      'addMember',
      'create',
      'delete',
      'list',
      'listAllMembers',
      'members',
      'removeMembers',
    ])
  })

  // ── Row 10 ───────────────────────────────────────────────────────────────
  //
  // The class guard. It must enumerate EVERY surviving function, so that adding a
  // seventh one with a bad prefix is caught without anyone remembering to write a
  // bespoke row for it. One `it.each` case per function, so a failure names the
  // culprit.
  //
  // Scoped deliberately to groupsApi's OWN captured URLs. A whole-file absence
  // assertion over web/src/api/identity.ts would be WRONG: `/api/v1/admin/` still
  // legitimately appears there in `rolesApi` (identity.ts:73-88), which is
  // ISS-0812's scope, not this run's — such an assertion would go red for a
  // reason that has nothing to do with this fix.
  //
  // ISS-0816 T9(ii): this array is HAND-MAINTAINED — `it.each` iterates it, not
  // `Object.keys(groupsApi)`. A seventh function on the object therefore never
  // produces a seventh case on its own: the suite would have stayed green and
  // silently left `listAllMembers` unchecked for the `/api/v1/admin/` prefix.
  // The `listAllMembers` row below was added DELIBERATELY, not in response to a
  // failing test, honouring the intent stated above that this array cannot
  // itself enforce. The row works unmodified: the shared spy resolves
  // WIRE_MEMBER_PAGE, whose `next_cursor` is null, so the drain terminates after
  // exactly one request and `captured()`'s single-call expectation holds.
  const surfaceRows: Array<[string, () => Promise<unknown>]> = [
    ['list', () => groupsApi.list()],
    ['create', () => groupsApi.create({ name: 'ops', display_name: 'Ops' })],
    ['delete', () => groupsApi.delete('g-1')],
    ['addMember', () => groupsApi.addMember('g-1', 'u-1')],
    ['removeMembers', () => groupsApi.removeMembers('g-1', 'u-1')],
    ['members', () => groupsApi.members('g-1')],
    ['listAllMembers', () => groupsApi.listAllMembers('g-1')],
  ]

  it.each(surfaceRows)(
    'T-0765-NO-ADMIN-PREFIX: groupsApi.%s does not dial /api/v1/admin/',
    async (_name, invoke) => {
      const spy = installSpy(WIRE_MEMBER_PAGE)

      await invoke()

      const req = captured(spy)
      expect(req.url).not.toContain('/api/v1/admin/')
      expect(req.url).toContain('/api/v1/identity/groups')
    },
  )

  // ── Row 11 ───────────────────────────────────────────────────────────────
  it('T-0765-REMOVE-UNCHANGED: removeMembers still hits the ISS-0736-corrected route', async () => {
    // PASSES pre-fix and post-fix alike, by design (§7.1). This row is an
    // enumeration row, not fail-first evidence: its job is to prove ISS-0765 did
    // not regress the ISS-0736 correction while rewriting the object literal
    // around it (design INV-C). identity.removeMembers.test.ts is left byte-
    // unchanged; this duplicates its assertion on purpose so the groupsApi table
    // is complete in one place.
    const spy = installSpy(undefined, 204)

    await groupsApi.removeMembers('g-1', 'u-1')

    const req = captured(spy)
    expect(req.method).toBe('DELETE')
    expect(req.url).toContain('/api/v1/identity/groups/g-1/members/u-1')
    expect(req.url).not.toContain('/api/v1/admin/groups')
  })
})
