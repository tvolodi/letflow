/** REQ-384 §7.3.3 — dedicated transition placeholder shown between
 *  `switchTenant`'s cache-clear step and the remounted shell settling on
 *  real data. Deliberately its own dedicated screen, not a route change to
 *  some default screen that might itself carry stale cache — driven by
 *  `AuthContext`'s own `switchingToTenantSlug` (set for the duration of
 *  `switchTenant`'s in-flight promise), not a heuristic like `isFetching`.
 */
export function TenantSwitchTransitionScreen({ targetSlug }: { targetSlug: string }): JSX.Element {
  return (
    <div
      data-testid="tenant-switch-transition"
      style={{
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        height: '100vh',
        gap: '.75rem',
        color: 'var(--text-secondary)',
      }}
    >
      <div>Switching to {targetSlug}…</div>
    </div>
  )
}
