import { ActorAvatar } from './ActorAvatar'
import {
  getRelativeTime,
  getTimelineActorDisplayName,
  getTimelineDotColour,
  getTimelineSecondaryContext,
} from '@/pages/instances/timelineUtils'
import type { TimelineEntry } from '@/types/api'

interface TimelineFeedItemProps {
  entry: TimelineEntry
}

export function TimelineFeedItem({ entry }: TimelineFeedItemProps) {
  const actorDisplay = getTimelineActorDisplayName(entry.actor_display_name)
  const secondaryContext = getTimelineSecondaryContext(entry)
  const dotColor = getTimelineDotColour(entry.event_type)
  const absoluteTime = new Date(entry.timestamp).toLocaleString()

  return (
    <article style={{ position: 'relative', display: 'flex', gap: '.75rem' }}>
      <div style={{ position: 'relative' }}>
        <ActorAvatar displayName={entry.actor_display_name} size={34} />
        <span
          aria-hidden
          style={{
            position: 'absolute',
            right: '-3px',
            bottom: '-3px',
            width: '10px',
            height: '10px',
            borderRadius: '9999px',
            border: '2px solid var(--surface-card)',
            background: dotColor,
          }}
        />
      </div>

      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', gap: '.75rem', flexWrap: 'wrap' }}>
          <strong style={{ color: 'var(--text-primary)', fontSize: '.92rem' }}>{entry.description}</strong>
          <time dateTime={entry.timestamp} title={absoluteTime} style={{ color: 'var(--color-neutral-700)', fontSize: '.8rem' }}>
            {getRelativeTime(entry.timestamp)}
          </time>
        </div>

        <div style={{ color: 'var(--color-neutral-700)', fontSize: '.8rem', marginTop: '.22rem' }}>
          {entry.event_type} • {actorDisplay} • seq {entry.sequence_num}
        </div>

        {secondaryContext && (
          <div style={{ color: 'var(--text-secondary)', fontSize: '.8rem', marginTop: '.15rem' }}>
            {secondaryContext}
          </div>
        )}

        {Object.keys(entry.metadata ?? {}).length > 0 && (
          <details style={{ marginTop: '.42rem' }}>
            <summary style={{ color: 'var(--color-neutral-700)', fontSize: '.8rem', cursor: 'pointer' }}>Metadata</summary>
            <pre
              style={{
                marginTop: '.3rem',
                background: 'var(--surface-page)',
                border: '1px solid var(--border-default)',
                borderRadius: '4px',
                padding: '.65rem',
                fontSize: '.75rem',
                overflow: 'auto',
                maxHeight: '300px',
              }}
            >
              {JSON.stringify(entry.metadata, null, 2)}
            </pre>
          </details>
        )}
      </div>
    </article>
  )
}
