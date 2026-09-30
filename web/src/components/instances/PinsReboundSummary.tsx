/** PinsReboundSummary — readable rendering of an INSTANCE_PINS_REBOUND event
 *  payload (REQ-432 §6.3, EO-005): per-entry prior -> new version, reason,
 *  and who changed it. Rendered above the raw JSON, which is kept for audit.
 */
interface PinsReboundSummaryProps {
  payload: Record<string, unknown>
  actorLabel?: string
}

interface ParsedEntry {
  kind: string | null
  ref: string
  prior: string
  next: string
}

function str(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

function parseEntries(raw: unknown): ParsedEntry[] | null {
  if (!Array.isArray(raw)) return null
  const out: ParsedEntry[] = []
  for (const item of raw) {
    if (!item || typeof item !== 'object') return null
    const e = item as Record<string, unknown>
    const ref = str(e.ref)
    const prior = str(e.prior_version)
    const next = str(e.new_version)
    if (ref === null || prior === null || next === null) return null
    out.push({ kind: str(e.kind), ref, prior, next })
  }
  return out
}

export function PinsReboundSummary({ payload, actorLabel }: PinsReboundSummaryProps) {
  const entries = parseEntries(payload?.entries)
  if (entries === null) return null

  const reason = str(payload.reason) ?? '—'
  const actor = actorLabel ?? str(payload.actor) ?? 'unknown'

  return (
    <div data-testid="pins-rebound-summary" style={{ marginBottom: '.4rem', fontSize: '.85rem' }}>
      {entries.length === 0 ? (
        <div>No version changed</div>
      ) : (
        entries.map((entry) => (
          <div key={`${entry.kind ?? ''}:${entry.ref}`} data-testid={`pins-rebound-entry-${entry.ref}`}>
            {entry.ref}: {entry.prior} {'->'} {entry.next}
            {entry.kind && (
              <span style={{ color: 'var(--text-secondary)' }}> ({entry.kind})</span>
            )}
          </div>
        ))
      )}
      <div data-testid="pins-rebound-reason">Reason: {reason}</div>
      <div>
        Changed by: <span data-testid="pins-rebound-actor">{actor}</span>
      </div>
    </div>
  )
}
