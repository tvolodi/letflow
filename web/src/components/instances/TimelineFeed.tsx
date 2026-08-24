import type { TimelineEntry } from '@/types/api'
import { TimelineFeedItem } from './TimelineFeedItem'

interface TimelineFeedProps {
  items: TimelineEntry[]
  isLoading: boolean
  hasMore: boolean
  onLoadMore: () => void
  isFetchingMore: boolean
}

export function TimelineFeed({
  items,
  isLoading,
  hasMore,
  onLoadMore,
  isFetchingMore,
}: TimelineFeedProps) {
  if (isLoading && items.length === 0) {
    return <p>Loading timeline...</p>
  }

  if (items.length === 0) {
    return <p style={{ color: 'var(--text-secondary)' }}>No timeline entries found.</p>
  }

  return (
    <>
      <div style={{ borderLeft: '2px solid var(--color-info-light)', paddingLeft: '1rem', display: 'grid', gap: '1rem' }}>
        {items.map((item) => (
          <TimelineFeedItem key={item.event_id} entry={item} />
        ))}
      </div>

      <div style={{ marginTop: '1rem', display: 'flex', alignItems: 'center', gap: '.75rem' }}>
        <span style={{ color: 'var(--text-secondary)', fontSize: '.8rem' }}>Loaded {items.length} entries</span>
        {hasMore && (
          <button
            onClick={onLoadMore}
            disabled={isFetchingMore}
            style={{
              padding: '.35rem .8rem',
              border: '1px solid var(--color-neutral-400)',
              borderRadius: '4px',
              background: 'var(--surface-card)',
              cursor: 'pointer',
              fontSize: '.85rem',
            }}
          >
            {isFetchingMore ? 'Loading...' : 'Load more'}
          </button>
        )}
      </div>
    </>
  )
}
