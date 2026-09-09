import type { TimelineEntry } from '@/types/api'

export function getTimelineActorDisplayName(actorDisplayName: string | null | undefined): string {
  const normalized = (actorDisplayName ?? '').trim()
  return normalized.length > 0 ? normalized : 'system'
}

export function getTimelineSecondaryContext(entry: TimelineEntry): string {
  const parts: string[] = []

  if (entry.node_id) {
    parts.push(`Node ${entry.node_id}`)
  }

  if (entry.task_id) {
    parts.push(`Task ${entry.task_id}`)
  }

  return parts.join(' • ')
}

export function mergeTimelineItems(
  currentItems: TimelineEntry[],
  incomingItems: TimelineEntry[],
  cursor: string | undefined,
): TimelineEntry[] {
  return cursor ? [...currentItems, ...incomingItems] : incomingItems
}

export function getTimelineDotColour(eventType: string): string {
  if (eventType.startsWith('INSTANCE_')) return 'var(--color-info)'
  if (eventType.startsWith('TASK_') || eventType.startsWith('HUMAN_TASK_')) return 'var(--color-success)'
  if (eventType.startsWith('ERROR_')) return 'var(--color-error)'
  if (eventType.startsWith('TIMER_')) return 'var(--color-warning)'
  return 'var(--text-secondary)'
}

export function getRelativeTime(isoTimestamp: string): string {
  const ts = new Date(isoTimestamp)
  if (Number.isNaN(ts.getTime())) return 'unknown time'

  const diffMs = Date.now() - ts.getTime()
  const diffSeconds = Math.floor(diffMs / 1000)
  if (diffSeconds < 60) return 'just now'

  const diffMinutes = Math.floor(diffSeconds / 60)
  if (diffMinutes < 60) return `${diffMinutes} min ago`

  const diffHours = Math.floor(diffMinutes / 60)
  if (diffHours < 24) return `${diffHours} hours ago`

  const diffDays = Math.floor(diffHours / 24)
  if (diffDays < 7) return `${diffDays} days ago`

  return ts.toLocaleDateString()
}
