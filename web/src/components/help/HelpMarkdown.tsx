/** HelpMarkdown — REQ-366 §3
 *
 *  Sanitizing markdown-to-React pipeline: `react-markdown` (never produces
 *  an HTML string, never reaches for React's raw-HTML injection escape
 *  hatch internally — a structural property of the library, not a rule
 *  enforced here) + `remark-gfm`
 *  (GitHub-flavoured markdown syntax) + `rehype-sanitize` (allowlist
 *  enforcement on the parsed AST, before anything renders). Library choice
 *  and allowlist rationale: design §3.1/§3.2.
 *
 *  `helpContentSchema` (§3.2) starts from `hast-util-sanitize`'s own
 *  `defaultSchema` but is narrowed, not widened: only the tags/attributes a
 *  help-content author needs are allowed through, matching REQ-363 design
 *  §5.2's write-side closed list for consistency between what is accepted
 *  and what is trusted at render time (defense in depth — render-time
 *  sanitization holds regardless of what was actually written).
 */

import type React from 'react'
import { defaultSchema } from 'rehype-sanitize'
import type { Schema } from 'hast-util-sanitize'
import ReactMarkdown from 'react-markdown'
import rehypeSanitize from 'rehype-sanitize'
import remarkGfm from 'remark-gfm'

/** Design §3.2's exact allowlist — no `img` (media is a separate structured
 *  field rendered by `HelpPanel` directly, §5.2, never through this
 *  markdown pipeline), no raw HTML passthrough of anything else. */
export const helpContentSchema: Schema = {
  ...defaultSchema,
  tagNames: [
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'p', 'strong', 'em',
    'ul', 'ol', 'li',
    'a',
    'code', 'pre', 'blockquote', 'br',
  ],
  attributes: {
    a: ['href'],
  },
  // Scheme allowlist, narrower than defaultSchema's — matches design §3.2's
  // "http/https/mailto only" (rejects javascript:/data:/vbscript: and every
  // other scheme by omission).
  protocols: {
    href: ['http', 'https', 'mailto'],
  },
}

export interface HelpMarkdownProps {
  source: string
}

/** Renders `props.source` (markdown) through the sanitizing pipeline above.
 *  No prop here accepts raw HTML and this component never reaches for
 *  React's raw-HTML injection escape hatch — design §3.3/§8's AC2
 *  obligation (see the test asserting this file's own source is free of
 *  that API name). */
export function HelpMarkdown(props: HelpMarkdownProps): React.ReactElement {
  const { source } = props
  return (
    <div data-testid="help-markdown">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        rehypePlugins={[[rehypeSanitize, helpContentSchema]]}
      >
        {source}
      </ReactMarkdown>
    </div>
  )
}
