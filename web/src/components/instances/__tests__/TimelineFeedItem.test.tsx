// @vitest-environment jsdom
/**
 * REQ-392 AC4 — the instance history/timeline view renders an attach entry
 * and a remove entry with actor names.
 *
 * Design finding (lib/letflow/design/req392-attachment-management-ui.md §6):
 * NO production code changes for this AC. `TimelineFeedItem` already
 * renders any `TimelineEntry`'s `description` + `actor_display_name`
 * generically, with no per-`event_type` switch/allowlist -- and
 * `Letflow.Instances.render_description/3` already has dedicated
 * `ATTACHMENT_ATTACHED`/`ATTACHMENT_REMOVED` clauses (REQ-391) producing
 * `"<file_name> attached by <actor>"` / `"<file_name> removed by <actor>"`.
 * This test proves that already-shipped backend text renders correctly
 * through the already-generic frontend path -- a real coverage gap (no
 * existing test exercised either event type through this component),
 * closed without any implementation change, per AC4's own "verified by a
 * test" wording.
 *
 * Fixture shape matches `render_description/3`'s exact output shape (design
 * §0/§6) rather than inventing new wording.
 */
import { describe, it, expect, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import { TimelineFeedItem } from '@/components/instances/TimelineFeedItem'
import { TimelineFeed } from '@/components/instances/TimelineFeed'
import type { TimelineEntry } from '@/types/api'

expect.extend(jestDomMatchers)

afterEach(() => cleanup())

function attachedEntry(): TimelineEntry {
  return {
    event_type: 'ATTACHMENT_ATTACHED',
    timestamp: '2026-09-24T10:00:00Z',
    actor_display_name: 'lena',
    description: 'delivery-note-hamburg-signed.pdf attached by lena',
    instance_id: 'inst-1',
    event_id: 'evt-1',
    sequence_num: 4,
    task_id: null,
    node_id: null,
    metadata: {},
  }
}

function removedEntry(): TimelineEntry {
  return {
    event_type: 'ATTACHMENT_REMOVED',
    timestamp: '2026-09-24T10:05:00Z',
    actor_display_name: 'lena',
    description: 'delivery-note-hamburg-signed.pdf removed by lena',
    instance_id: 'inst-1',
    event_id: 'evt-2',
    sequence_num: 5,
    task_id: null,
    node_id: null,
    metadata: {},
  }
}

describe('TimelineFeedItem — AC4 attach/remove entries', () => {
  it('renders an ATTACHMENT_ATTACHED entry with the file name and actor', () => {
    render(<TimelineFeedItem entry={attachedEntry()} />)

    expect(
      screen.getByText('delivery-note-hamburg-signed.pdf attached by lena'),
    ).toBeInTheDocument()
    expect(screen.getByText(/ATTACHMENT_ATTACHED/)).toBeInTheDocument()
    expect(screen.getAllByText(/lena/).length).toBeGreaterThan(0)
  })

  it('renders an ATTACHMENT_REMOVED entry with the file name and actor, distinct from the attach entry', () => {
    render(<TimelineFeedItem entry={removedEntry()} />)

    expect(
      screen.getByText('delivery-note-hamburg-signed.pdf removed by lena'),
    ).toBeInTheDocument()
    expect(screen.getByText(/ATTACHMENT_REMOVED/)).toBeInTheDocument()
    expect(screen.queryByText(/attached by lena/)).not.toBeInTheDocument()
  })

  it('renders both entries together in a TimelineFeed, in order, each with actor attribution', () => {
    render(
      <TimelineFeed
        items={[attachedEntry(), removedEntry()]}
        isLoading={false}
        hasMore={false}
        onLoadMore={() => {}}
        isFetchingMore={false}
      />,
    )

    const attached = screen.getByText('delivery-note-hamburg-signed.pdf attached by lena')
    const removed = screen.getByText('delivery-note-hamburg-signed.pdf removed by lena')
    expect(attached).toBeInTheDocument()
    expect(removed).toBeInTheDocument()
    // DOM order matches the array order the feed was given (attach before remove).
    expect(
      attached.compareDocumentPosition(removed) & Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy()
  })
})
