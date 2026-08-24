import { useMemo, useState } from 'react'
import { useInstanceEvents, type EventFilters } from '@/hooks/useInstances'
import { EventJsonExpandable } from './EventJsonExpandable'

interface EventHistoryPanelProps {
  instanceId: string
}

function toDatetimeLocal(isoValue: string | undefined): string {
  if (!isoValue) return ''
  const date = new Date(isoValue)
  if (Number.isNaN(date.getTime())) return ''
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000)
  return local.toISOString().slice(0, 16)
}

function toIsoOrUndefined(value: string): string | undefined {
  if (!value) return undefined
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return undefined
  return date.toISOString()
}

function compactFilters(filters: EventFilters): EventFilters {
  const compacted: EventFilters = {}
  if (filters.event_type) compacted.event_type = filters.event_type
  if (filters.from) compacted.from = filters.from
  if (filters.to) compacted.to = filters.to
  return compacted
}

export function EventHistoryPanel({ instanceId }: EventHistoryPanelProps) {
  const [draftEventType, setDraftEventType] = useState('')
  const [draftFrom, setDraftFrom] = useState('')
  const [draftTo, setDraftTo] = useState('')
  const [appliedFilters, setAppliedFilters] = useState<EventFilters>({})

  const eventsQuery = useInstanceEvents(instanceId, appliedFilters)

  const events = useMemo(() => {
    const raw = eventsQuery.data as unknown
    if (Array.isArray(raw)) return raw
    if (raw && typeof raw === 'object') {
      const items = (raw as { items?: unknown }).items
      if (Array.isArray(items)) return items
    }
    return []
  }, [eventsQuery.data])

  const eventTypeOptions = useMemo(() => {
    const values = new Set<string>()
    for (const event of events) {
      if (event.event_type) values.add(event.event_type)
    }
    return Array.from(values).sort()
  }, [events])

  const onApply = () => {
    const filters = compactFilters({
      event_type: draftEventType || undefined,
      from: toIsoOrUndefined(draftFrom),
      to: toIsoOrUndefined(draftTo),
    })
    setAppliedFilters(filters)
  }

  const onClear = () => {
    setDraftEventType('')
    setDraftFrom('')
    setDraftTo('')
    setAppliedFilters({})
  }

  return (
    <section>
      <div
        data-testid="event-history-filter-bar"
        style={{
          display: 'flex',
          gap: '.6rem',
          flexWrap: 'wrap',
          alignItems: 'end',
          marginBottom: '.85rem',
        }}
      >
        <label style={{ display: 'grid', gap: '.2rem', fontSize: '.82rem', color: 'var(--color-neutral-700)' }}>
          Event type
          <select
            value={draftEventType}
            onChange={(e) => setDraftEventType(e.target.value)}
            style={{
              minWidth: '180px',
              border: '1px solid var(--color-neutral-400)',
              borderRadius: '4px',
              padding: '.35rem .45rem',
            }}
          >
            <option value="">All types</option>
            {eventTypeOptions.map((eventType) => (
              <option key={eventType} value={eventType}>
                {eventType}
              </option>
            ))}
          </select>
        </label>

        <label style={{ display: 'grid', gap: '.2rem', fontSize: '.82rem', color: 'var(--color-neutral-700)' }}>
          From
          <input
            type="datetime-local"
            value={draftFrom}
            onChange={(e) => setDraftFrom(e.target.value)}
            style={{
              border: '1px solid var(--color-neutral-400)',
              borderRadius: '4px',
              padding: '.32rem .45rem',
            }}
          />
        </label>

        <label style={{ display: 'grid', gap: '.2rem', fontSize: '.82rem', color: 'var(--color-neutral-700)' }}>
          To
          <input
            type="datetime-local"
            value={draftTo}
            onChange={(e) => setDraftTo(e.target.value)}
            style={{
              border: '1px solid var(--color-neutral-400)',
              borderRadius: '4px',
              padding: '.32rem .45rem',
            }}
          />
        </label>

        <button
          onClick={onApply}
          style={{
            padding: '.35rem .8rem',
            border: 'none',
            borderRadius: '4px',
            background: 'var(--interactive-primary)',
            color: 'var(--text-inverse)',
            cursor: 'pointer',
          }}
        >
          Apply
        </button>

        <button
          onClick={onClear}
          style={{
            padding: '.35rem .8rem',
            border: '1px solid var(--color-neutral-400)',
            borderRadius: '4px',
            background: 'var(--surface-card)',
            cursor: 'pointer',
          }}
        >
          Clear
        </button>
      </div>

      {eventsQuery.isLoading && <p>Loading event history...</p>}
      {eventsQuery.error && (
        <p role="alert" style={{ color: 'var(--color-error-dark)' }}>
          Failed to load events.
        </p>
      )}

      {!eventsQuery.isLoading && !eventsQuery.error && (
        <>
          {events.length > 0 ? (
            <>
              <div style={{ color: 'var(--text-secondary)', fontSize: '.8rem', marginBottom: '.45rem' }}>
                Showing {events.length} events
              </div>
              <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.85rem' }}>
                <thead>
                  <tr style={{ background: 'var(--color-neutral-100)', textAlign: 'left' }}>
                    <th style={{ padding: '.5rem .75rem' }}>#</th>
                    <th style={{ padding: '.5rem .75rem' }}>Type</th>
                    <th style={{ padding: '.5rem .75rem' }}>Actor</th>
                    <th style={{ padding: '.5rem .75rem' }}>Time</th>
                    <th style={{ padding: '.5rem .75rem' }}>Payload</th>
                  </tr>
                </thead>
                <tbody>
                  {events.map((event) => (
                    <tr key={event.event_id} style={{ borderBottom: '1px solid var(--border-default)', verticalAlign: 'top' }}>
                      <td style={{ padding: '.5rem .75rem', color: 'var(--color-neutral-500)', fontFamily: 'monospace' }}>
                        {event.sequence_number}
                      </td>
                      <td style={{ padding: '.5rem .75rem', fontFamily: 'monospace', fontSize: '.8rem' }}>
                        {event.event_type}
                      </td>
                      <td style={{ padding: '.5rem .75rem', color: 'var(--text-secondary)', fontFamily: 'monospace', fontSize: '.8rem' }}>
                        {typeof event.actor_id === 'string' && event.actor_id
                          ? event.actor_id.slice(0, 8)
                          : 'system'}
                      </td>
                      <td style={{ padding: '.5rem .75rem', color: 'var(--text-secondary)' }}>
                        {new Date(event.created_at).toLocaleString()}
                      </td>
                      <td style={{ padding: '.5rem .75rem', minWidth: '180px' }}>
                        <EventJsonExpandable payload={event.payload ?? {}} />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </>
          ) : (
            <p style={{ color: 'var(--text-secondary)', margin: 0 }}>No events match the current filters.</p>
          )}
        </>
      )}

      {(appliedFilters.from || appliedFilters.to) && (
        <div style={{ marginTop: '.6rem', color: 'var(--text-secondary)', fontSize: '.78rem' }}>
          Range: {toDatetimeLocal(appliedFilters.from)} - {toDatetimeLocal(appliedFilters.to)}
        </div>
      )}
    </section>
  )
}
