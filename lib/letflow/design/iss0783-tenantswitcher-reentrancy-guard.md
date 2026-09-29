# Design: ISS-0783 (queue Q-782 / GH-1725) — TenantSwitcher re-entrancy guard

Severity: MINOR. Frontend-only, single file. No design doc was strictly
required by the issue's own `suggested_fix` note ("likely sized for ORCH's
direct-action rule ... no design doc needed"), but WF-03 routed it through
CODE-DESIGNER anyway, so this follows the same convention as other
`iss-*`-prefixed frontend design docs (e.g. `iss0845-frontend-module-
boundary-eslint.md`): state, not implementation.

## 1. Current state (verified against `main` 3fc17582)

`web/src/auth/TenantSwitcher.tsx`, 132 lines. Relevant existing local state:

```
const [open, setOpen] = useState(false)
const [interactionRequiredSlug, setInteractionRequiredSlug] = useState<string | null>(null)
const [errorSlug, setErrorSlug] = useState<string | null>(null)
```

`onSelect` (lines 29-36) clears both sub-UI slugs, closes the menu, awaits
`switchTenant(targetSlug): Promise<SwitchTenantOutcome>` (type from
`AuthContext.tsx`, exported as `switchTenant: (targetSlug: string) =>
Promise<SwitchTenantOutcome>`), then sets `interactionRequiredSlug` on
`'interaction_required'` or `errorSlug` on `'error'`. No branch is taken on
success — the switcher itself just stops showing either sub-UI once
`AuthProvider`'s own session/shell transition takes over.

Three click targets have no `disabled`: the trigger (line 45-63), each
option button inside the `.map` (line 84-99), and the retry button
(line 121-127). `AuthContext.tsx`'s `switchingToTenantSlug` is intentionally
out of scope per the issue and ISSUE-FIXER's diagnosis — it starts only
after a confirmed `silent_ok`, not for the whole `switchTenant` call, so
using it here would under-guard the exact window (the initial silent-OIDC
attempt) where the double-fire happens.

## 2. State shape to add

One new boolean, added alongside the existing three `useState` calls:

```
const [pending, setPending] = useState(false)
```

No other local state changes. Specifically, this must NOT alter:
- `open`'s own semantics — `pending` does not replace or gate `setOpen`
  itself; the menu still closes via the existing `setOpen(false)` at the
  top of `onSelect`, unconditionally, the instant a selection is made
  (before `switchTenant` is even called), same as today.
- `interactionRequiredSlug` / `errorSlug` lifetimes or the conditions under
  which their sub-UI blocks render (lines 105-129) — unchanged.
- `AuthContext.tsx` is not touched by this fix at all — no new prop, no
  new context field, no change to `switchingToTenantSlug`'s own lifetime.

## 3. Elements gaining a `disabled` condition

| Element | Location (current) | New condition |
|---|---|---|
| Trigger button (`tenant-switcher-trigger`) | ~line 45-63 | `disabled={pending}` |
| Each option button (`tenant-switcher-option-${m.tenant_slug}`), inside `.map` | ~line 84-99 | `disabled={pending}` |
| Retry button (`tenant-switcher-retry`) | ~line 121-127 | `disabled={pending}` |
| Sign-in button (`tenant-switcher-sign-in`, interaction-required branch) | ~line 108-114 | **not gated** — see reasoning below |

Reasoning on the sign-in button: `onSignInToTenant` does not call
`switchTenant` at all — it calls `getOrCreateManagerForTenant` then
`manager.signinRedirect(...)`, an OIDC interactive redirect that navigates
the browser away. It is not a second concurrent `switchTenant()` invocation
and cannot race with a pending one (by the time `interactionRequiredSlug` is
set, the `onSelect` that produced it has already resolved — `pending` will
already be back to `false` by the time this button is even rendered, since
`onSelect`'s `finally` runs before the outcome branch sets
`interactionRequiredSlug`). No `disabled` is added to it. This is a
reasoned exclusion, not an oversight; TEST-DESIGNER should not add a
regression test expecting this button to be disabled.

Each `disabled` prop should also get an accompanying cursor/opacity style
consistent with the rest of the file's inline-style convention (visual
detail, not specified further here — FRONTEND-DEV's normal styling
discretion, not a functional requirement of this fix).

## 4. `onSelect` try/finally shape

Current body (for reference, not to be copied verbatim as this is the
"before" shape):

```
const onSelect = async (targetSlug: string) => {
  setInteractionRequiredSlug(null)
  setErrorSlug(null)
  setOpen(false)
  const outcome = await switchTenant(targetSlug)
  if (outcome === 'interaction_required') setInteractionRequiredSlug(targetSlug)
  else if (outcome === 'error') setErrorSlug(targetSlug)
}
```

Required new shape (state transitions only, not literal code):

1. Guard at entry: if `pending` is already `true`, return immediately
   without calling `switchTenant` — this is the actual re-entrancy guard,
   independent of and in addition to the `disabled` attributes (the
   `disabled` attributes prevent the click event from firing in the normal
   DOM/React case; the in-function guard is what a regression test can
   assert directly by invoking `onSelect` twice without relying on
   simulated DOM click-suppression, and is cheap defense-in-depth against
   any way a disabled control's handler could still be invoked, e.g. a
   fake pointer event in a test).
2. Set `pending` to `true` before doing anything else that was already
   there (before clearing `interactionRequiredSlug`/`errorSlug`, before
   `setOpen(false)` — ordering among these does not matter functionally,
   but `pending` must be `true` before the `await switchTenant(...)` call
   starts).
3. Wrap the `await switchTenant(targetSlug)` call and its outcome-branch
   `if`/`else if` in a `try`.
4. `finally` block sets `pending` back to `false`. This must run
   regardless of outcome:
   - `switchTenant` resolves `'interaction_required'` → `pending` reset,
     `interactionRequiredSlug` set (existing behavior).
   - `switchTenant` resolves `'error'` → `pending` reset, `errorSlug` set
     (existing behavior).
   - `switchTenant` resolves any other/success outcome → `pending` reset,
     neither sub-UI slug set (existing behavior — no `else` branch changes).
   - `switchTenant` throws (rejects) → `pending` still resets via
     `finally`. Whether the fix re-throws, swallows, or otherwise handles
     an unexpected rejection is **out of scope** for this issue — today's
     code has no `catch` and none is required by ISS-0783; adding one
     would be scope creep beyond the re-entrancy guard. If FRONTEND-DEV
     judges an uncaught rejection would leave `pending` incorrectly
     `true` without a `finally`, the `finally` alone (no `catch` needed)
     already satisfies that — a bare `try { ... } finally { setPending(false) }`
     with no `catch` still runs `finally` on rejection and simply
     re-propagates the rejection afterward, which is acceptable since
     nothing in this component currently awaits `onSelect`'s own promise
     (it's invoked as `void onSelect(...)`).

`retry` (line 121-127) calls `onSelect(errorSlug)` — same function, so it
automatically inherits the guard; no separate pending-check is needed there
beyond the shared `disabled={pending}`.

## 5. Acceptance criteria a regression test must prove

Test file: extend the existing test file for this component if one exists
(check `web/src/auth/__tests__/` or co-located `*.test.tsx` first: none was
found in this session's checkout — FRONTEND-DEV creates
`web/src/auth/__tests__/TenantSwitcher.test.tsx` if so, following this
repo's existing co-location convention for other `web/src/**/__tests__/`
directories) using a deferred/controllable mock of `switchTenant` (e.g. a
manually-resolved `Promise` held open until the test resolves it).

(a) **Disabled while pending.** With a `switchTenant` mock that returns a
    pending (unresolved) promise, after selecting an option: the trigger
    button, every rendered option button, and (once reached via an
    `'error'`-outcome path) the retry button all have `disabled` truthy /
    the `disabled` DOM attribute present, while the mock promise has not
    yet resolved.

(b) **No double-invocation.** A second click (or direct second `onSelect`
    call) fired while `pending` is `true` does not increase the mock's
    call count beyond 1 — assert via the mock's call-count, not just via
    DOM `disabled` (covers the in-function guard from §4 step 1
    independently of the DOM attribute).

(c) **Resets on settle, both outcomes.** After resolving the held-open
    mock promise:
    - with `'success'`-shaped outcome (whatever non-`'interaction_required'`
      non-`'error'` value `SwitchTenantOutcome` uses for success — read its
      real type definition in `AuthContext.tsx` before writing the test,
      do not assume a literal string not confirmed there): `pending`
      returns to `false`, trigger/options re-enabled, no sub-UI slug set.
    - with `'error'`: `pending` returns to `false`, trigger/options/retry
      re-enabled, `tenant-switcher-error` block renders (existing
      behavior, unaffected).
    - with `'interaction_required'`: `pending` returns to `false`,
      trigger/options re-enabled, `tenant-switcher-interaction-required`
      block renders with its sign-in button **not** disabled (confirms
      §3's reasoned exclusion).

(d) **No regression to existing behavior.** Any test already covering this
    component's menu open/close, `interactionRequiredSlug`/`errorSlug`
    rendering, or `onSignInToTenant` flow continues to assert the exact
    same outcomes as before this change — this fix must not require
    editing the expected result of any pre-existing assertion, only adding
    new ones plus the `disabled` wiring itself. (No pre-existing test file
    was found for this component in this checkout, so in practice this
    means: TEST-DESIGNER's new spec must not encode any behavior change
    beyond the `pending` guard.)

## 6. Cross-module dependencies

- `web/src/auth/TenantSwitcher.tsx` — the only file changed for the fix.
- `web/src/auth/AuthContext.tsx` — read-only dependency (the
  `switchTenant` signature and `SwitchTenantOutcome` type); not modified.
- New/extended test file under `web/src/auth/__tests__/`.

## 7. Invariants

- `pending` is `true` for the entire duration of exactly one in-flight
  `switchTenant` call at a time — never set `true` again while already
  `true` (guarded at `onSelect`'s entry), and always reset to `false`
  before `onSelect` returns or throws.
- The trigger, every option button, and the retry button share the same
  `pending` flag — there is no per-button independent pending state.
- The sign-in button in the interaction-required branch is never gated by
  `pending` (§3).
- No change to `AuthContext.tsx`, `switchingToTenantSlug`'s lifetime, or
  any tenant-isolation-relevant behavior (cache removal, closure-captured
  `outgoingTenantId`) — this fix is purely a UI re-entrancy guard, per
  SECURITY-REVIEWER/REVIEWER's prior confirmation that the underlying
  double-fire is not itself a security defect.

## 8. Open questions

None outstanding for this fix's scope. If FRONTEND-DEV finds an existing
`TenantSwitcher.test.tsx` this session did not locate, it should be
extended in place rather than a second test file created alongside it.
