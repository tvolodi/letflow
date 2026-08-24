function formatValue(value: unknown): string {
  if (value === null) return 'null'
  if (value === undefined) return '—'
  if (typeof value === 'string') return value
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  try {
    return JSON.stringify(value)
  } catch {
    return '[unserializable]'
  }
}

export function JsonDiffView(props: {
  before: Record<string, unknown> | null | undefined
  after: Record<string, unknown> | null | undefined
}): React.ReactElement {
  const before = props.before ?? {}
  const after = props.after ?? {}
  const keys = Array.from(new Set([...Object.keys(before), ...Object.keys(after)])).sort()

  if (keys.length === 0) {
    return <div style={{ color: 'var(--text-secondary)', fontSize: '.85rem' }}>No structured field changes for this entry.</div>
  }

  return (
    <div style={{ overflowX: 'auto' }}>
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.82rem' }}>
        <thead>
          <tr style={{ textAlign: 'left', background: 'var(--surface-page)' }}>
            <th style={{ padding: '.4rem .5rem', borderBottom: '1px solid var(--border-default)' }}>Field</th>
            <th style={{ padding: '.4rem .5rem', borderBottom: '1px solid var(--border-default)' }}>Before</th>
            <th style={{ padding: '.4rem .5rem', borderBottom: '1px solid var(--border-default)' }}>After</th>
          </tr>
        </thead>
        <tbody>
          {keys.map((key) => {
            const beforeValue = before[key]
            const afterValue = after[key]
            const changed = JSON.stringify(beforeValue) !== JSON.stringify(afterValue)

            return (
              <tr key={key} style={{ background: changed ? 'var(--color-warning-light)' : 'transparent' }}>
                <td style={{ padding: '.35rem .5rem', borderBottom: '1px solid var(--color-neutral-100)', fontFamily: 'monospace' }}>{key}</td>
                <td style={{ padding: '.35rem .5rem', borderBottom: '1px solid var(--color-neutral-100)', fontFamily: 'monospace' }}>{formatValue(beforeValue)}</td>
                <td style={{ padding: '.35rem .5rem', borderBottom: '1px solid var(--color-neutral-100)', fontFamily: 'monospace' }}>{formatValue(afterValue)}</td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}
