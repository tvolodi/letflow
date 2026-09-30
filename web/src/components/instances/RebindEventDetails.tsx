/** RebindEventDetails — explicit-field rendering for an `INSTANCE_PINS_REBOUND`
 *  history row (REQ-432 design §4, EO-005).
 *
 *  Replaces the generic `EventJsonExpandable` payload dump for this one
 *  event type only — every other event type keeps the generic renderer
 *  unchanged (EventHistoryPanel.tsx).
 */

interface RebindEventDetailsEntry {
  kind?: string
  ref?: string
  prior_version?: string
  new_version?: string
}

interface RebindEventPayloadShape {
  entries?: RebindEventDetailsEntry[]
  reason?: string
  actor?: string
}

export interface RebindEventDetailsProps {
  // Kept as the same `Record<string, unknown>` shape EventJsonExpandable
  // already accepts (the wire shape is asserted from source reading, not a
  // JSON-schema contract — design §4) rather than the narrower shape this
  // component actually expects, so no cast is needed at the call site.
  payload: Record<string, unknown>
  resolvedActorName: string | null
}

export function RebindEventDetails({ payload, resolvedActorName }: RebindEventDetailsProps) {
  const typedPayload = payload as RebindEventPayloadShape
  const entries = typedPayload?.entries ?? []
  const reason = typedPayload?.reason ?? ''

  return (
    <div data-testid="rebind-event-details" style={{ fontSize: '.82rem' }}>
      {resolvedActorName && (
        <div style={{ color: 'var(--text-secondary)', marginBottom: '.25rem' }}>
          By: {resolvedActorName}
        </div>
      )}
      {entries.map((entry, index) => (
        <div key={`${entry.ref ?? 'entry'}-${index}`}>
          {entry.ref}: {entry.prior_version} {'->'} {entry.new_version}
        </div>
      ))}
      <div style={{ marginTop: '.25rem', color: 'var(--text-secondary)' }}>
        Reason: &ldquo;{reason}&rdquo;
      </div>
    </div>
  )
}
