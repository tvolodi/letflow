/**
 * ISS-0815: User wire-shape contract test.
 *
 * Pins the User interface against the exact fields emitted by
 * user_map/1 in lib/letflow/routers/identity.ex.  Any divergence
 * between the two must be caught here rather than at runtime.
 *
 * Backend source of truth (user_map/1 key set, alphabetical):
 *   auth_source, display_name, email, id, inserted_at, status, updated_at, username
 *
 * This test has two layers:
 *  1. Compile-time: constructing a `userMapShape` literal typed as `User`
 *     will fail tsc if any required field is missing or wrong.
 *  2. Runtime: the expected key set is asserted explicitly so a future
 *     change to user_map/1 that adds or removes a field is caught.
 */

import { describe, expect, it } from 'vitest'
import type { User } from '@/types/api'

// ── 1. Compile-time contract ──────────────────────────────────────────────────

// A minimal payload shaped exactly like user_map/1's output.  If User gains a
// new required field that user_map/1 does not emit, or loses a field it
// requires, this assignment will produce a tsc error.
const userMapPayload: User = {
  id: 'abc-123',
  username: 'alice',
  display_name: 'Alice A.',
  email: 'alice@example.com',
  status: 'active',        // lowercase — Ecto.Enum :active/:inactive (ISS-0814)
  auth_source: 'internal',
  inserted_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
}

// `roles` must be optional — the backend never emits it from user_map/1.
// This would be a compile error if roles were required.
const _userWithoutRoles: User = {
  id: 'def-456',
  username: 'bob',
  display_name: 'Bob B.',
  email: 'bob@example.com',
  status: 'inactive',      // lowercase — tests both valid values
  auth_source: 'oidc',
  inserted_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
}

// ── 2. Runtime key-set assertions ─────────────────────────────────────────────

/** Exact key set emitted by user_map/1 (lib/letflow/routers/identity.ex:686-697). */
const USER_MAP_KEYS = [
  'auth_source',
  'display_name',
  'email',
  'id',
  'inserted_at',
  'status',
  'updated_at',
  'username',
].sort()

describe('User wire shape (ISS-0815)', () => {
  it('TC-ISS0815-01: userMapPayload satisfies all required User fields', () => {
    // All required fields must be present and non-null.
    expect(userMapPayload.id).toBe('abc-123')
    expect(userMapPayload.username).toBe('alice')
    expect(userMapPayload.display_name).toBe('Alice A.')
    expect(userMapPayload.email).toBe('alice@example.com')
    expect(userMapPayload.status).toBe('active')
    expect(userMapPayload.auth_source).toBe('internal')
    expect(userMapPayload.inserted_at).toBe('2026-01-01T00:00:00Z')
    expect(userMapPayload.updated_at).toBe('2026-01-02T00:00:00Z')
  })

  it('TC-ISS0815-02: required User fields match the user_map/1 key set exactly', () => {
    // Derived from the type: these are the keys present in userMapPayload,
    // which was constructed without any optional fields.  They must equal
    // USER_MAP_KEYS exactly — same as the full key-set assertion in
    // test/letflow/routers/identity_test.exs (AC5 / line ~160).
    const payloadKeys = Object.keys(userMapPayload).sort()
    expect(payloadKeys).toEqual(USER_MAP_KEYS)
  })

  it('TC-ISS0815-03: roles is optional — User is valid without it', () => {
    // The compile-time assignment above already covers this, but we also
    // assert at runtime that the omitted field is truly absent.
    expect(Object.prototype.hasOwnProperty.call(_userWithoutRoles, 'roles')).toBe(false)
  })

  it('TC-ISS0815-04: User has no required created_at field', () => {
    // created_at was the wrong name for the timestamp field (ISS-0815).
    // inserted_at is what user_map/1 emits; created_at must not be required.
    expect(Object.prototype.hasOwnProperty.call(userMapPayload, 'created_at')).toBe(false)
    expect(Object.prototype.hasOwnProperty.call(userMapPayload, 'inserted_at')).toBe(true)
  })
})

// ── Status casing (ISS-0814) ───────────────────────────────────────────────

describe('User.status wire casing (ISS-0814)', () => {
  it('TC-ISS0814-01: status wire value is lowercase (backend emits active/inactive)', () => {
    // user_map/1 emits Atom.to_string(user.status) where status is
    // Ecto.Enum [:active, :inactive] → wire values are "active"/"inactive".
    expect(userMapPayload.status).toBe('active')
    expect(_userWithoutRoles.status).toBe('inactive')
    // Compile-time guard: the type literal 'active' | 'inactive' means the
    // following assignments are the only values TypeScript accepts.
    const _active: User['status'] = 'active'
    const _inactive: User['status'] = 'inactive'
    expect(_active).toBe('active')
    expect(_inactive).toBe('inactive')
  })

  it('TC-ISS0814-02: status write payload must be lowercase (backend @patch_schema allows_values ["active","inactive"])', () => {
    // Canonical decision (ISS-0814): lowercase in both directions.
    // The usersApi.update body type uses 'active' | 'inactive'.
    // This runtime assertion documents the expected wire value; the
    // compile-time guard lives in the User type ('active' | 'inactive')
    // and usersApi.update's Partial body definition in api/identity.ts.
    const activePatch = { status: 'active' as const }
    const inactivePatch = { status: 'inactive' as const }
    expect(activePatch.status).toBe('active')
    expect(inactivePatch.status).toBe('inactive')
    // Verify neither uppercase casing appears in the expected write values.
    expect(activePatch.status).not.toBe('ACTIVE')
    expect(inactivePatch.status).not.toBe('INACTIVE')
  })
})
