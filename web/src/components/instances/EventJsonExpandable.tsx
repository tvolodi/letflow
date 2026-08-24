interface EventJsonExpandableProps {
  payload: Record<string, unknown>
}

export function EventJsonExpandable({ payload }: EventJsonExpandableProps) {
  return (
    <details>
      <summary style={{ cursor: 'pointer', color: 'var(--color-neutral-700)', fontSize: '.8rem' }}>
        Payload
      </summary>
      <pre
        style={{
          marginTop: '.4rem',
          background: 'var(--surface-page)',
          border: '1px solid var(--border-default)',
          borderRadius: '4px',
          padding: '.65rem',
          fontSize: '.75rem',
          overflow: 'auto',
          maxHeight: '400px',
        }}
      >
        {JSON.stringify(payload, null, 2)}
      </pre>
    </details>
  )
}
