// @vitest-environment jsdom
/**
 * REQ-366 §2.3/§5 — HelpPanel
 *
 * TC-REQ366-11: renders title, then markdown body, then media, then the
 *   staleness badge, in that order (design §2.3's exact render order).
 * TC-REQ366-12: content.media === [] renders no media block at all (§5.1).
 * TC-REQ366-13: a { type: 'image', url } media item renders an <img> with
 *   that src.
 * TC-REQ366-14: an unrecognised media item shape is skipped silently — no
 *   crash, no placeholder (§5.1).
 * TC-REQ366-15: a javascript:-scheme media url is rejected, never reaches
 *   an <img src> (§5.2's scheme check).
 * TC-REQ366-16: Escape and the close button both call onClose.
 */
import { describe, it, expect, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
import { afterEach } from 'vitest'
import { HelpPanel } from '../HelpPanel'
import type { ResolvedHelpContent } from '@/types/help'

expect.extend(jestDomMatchers)

afterEach(cleanup)

function baseContent(overrides: Partial<ResolvedHelpContent> = {}): ResolvedHelpContent {
  return {
    id: 'help-1',
    screenId: 'exam-list',
    processDefinitionId: null,
    title: 'Exam list help',
    body: 'Some **markdown** body',
    status: 'live',
    confirmedAt: '2026-09-01T00:00:00Z',
    confirmedForDefinitionVersion: null,
    media: [],
    scope: 'tenant',
    stale: false,
    ...overrides,
  }
}

describe('HelpPanel', () => {
  it('TC-REQ366-11: renders title, body, and staleness badge in order', () => {
    render(<HelpPanel content={baseContent()} onClose={vi.fn()} />)
    const panel = screen.getByTestId('help-panel')
    const title = screen.getByTestId('help-panel-title')
    const body = screen.getByTestId('help-panel-body')
    const badge = screen.getByTestId('help-staleness-badge')

    expect(title).toHaveTextContent('Exam list help')
    expect(body).toHaveTextContent('markdown')

    const position = (a: Node, b: Node) =>
      a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING

    expect(panel.contains(title)).toBe(true)
    expect(position(title, body)).toBeTruthy()
    expect(position(body, badge)).toBeTruthy()
  })

  it('TC-REQ366-12: empty media renders no media block', () => {
    render(<HelpPanel content={baseContent({ media: [] })} onClose={vi.fn()} />)
    expect(screen.queryByTestId('help-panel-media')).toBeNull()
  })

  it('TC-REQ366-13: a recognised image media item renders an <img>', () => {
    render(
      <HelpPanel
        content={baseContent({ media: [{ type: 'image', url: 'https://example.com/pic.png' }] })}
        onClose={vi.fn()}
      />,
    )
    const media = screen.getByTestId('help-panel-media')
    const img = media.querySelector('img')
    expect(img).not.toBeNull()
    expect(img).toHaveAttribute('src', 'https://example.com/pic.png')
  })

  it('TC-REQ366-14: an unrecognised media item shape is skipped without crashing', () => {
    expect(() =>
      render(
        <HelpPanel
          content={baseContent({ media: [{ kind: 'unknown-shape' }] })}
          onClose={vi.fn()}
        />,
      ),
    ).not.toThrow()
    expect(screen.queryByTestId('help-panel-media')).toBeNull()
  })

  it('TC-REQ366-15: a javascript: media url is rejected, not rendered as <img src>', () => {
    render(
      <HelpPanel
        content={baseContent({ media: [{ type: 'image', url: 'javascript:alert(1)' }] })}
        onClose={vi.fn()}
      />,
    )
    expect(screen.queryByTestId('help-panel-media')).toBeNull()
  })

  it('TC-REQ366-16: Escape and the close button both call onClose', () => {
    const onClose = vi.fn()
    render(<HelpPanel content={baseContent()} onClose={onClose} />)

    fireEvent.click(screen.getByTestId('help-panel-close'))
    expect(onClose).toHaveBeenCalledTimes(1)

    fireEvent.keyDown(window, { key: 'Escape' })
    expect(onClose).toHaveBeenCalledTimes(2)
  })
})
