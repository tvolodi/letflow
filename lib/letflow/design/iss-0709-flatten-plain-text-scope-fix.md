# ISS-0709 — Bound `flatten_plain_text/1`'s projection to one block's own children

**Module:** `lib/letflow/help/help_content.ex`
**Route to:** ELIXIR-DEV (Elixir library code, no migration/schema change)
**Related:** REQ-364 (introduced the mechanism being fixed), `docs/issues/ISS-0709.yaml`,
`docs/migration/decisions/0036-earmark-parser-markdown-sanitization-dependency.md`

## 0. Root cause, restated precisely against the current call graph

This section is derived by tracing the actual current code (read in full before writing
this design), not re-asserted from the issue text alone — confirming the issue's own
diagnosis holds against the real call graph before prescribing a fix.

`validate_markdown_safety/2` calls `walk(ast)` exactly once, where `ast` is
`EarmarkParser.as_ast/2`'s **top-level list of block-level sibling nodes** (e.g.
`[{"p",...}, {"h2",...}, {"ul",...}, {"p",...}]` for a multi-paragraph document).

`walk/1(nodes)` does two things with that same `nodes` list at *every* level of
recursion it is called at:

1. A structural pass over each node in the list (`walk_node/1`'s per-node checks —
   `raw_html_node?/2`, `destination_violation/2`), and, for any node whose tag is not
   `"code"`, a recursive call back into `walk/1` with that node's own `children` as the
   new list — i.e. `walk/1` recurses into every node's own children, one call per node.
2. A single flattened text projection built from the **entire current `nodes` list** by
   `flatten_plain_text/1`, then scanned once by `walk_text/1` for the raw-tag pattern.
   `flatten_plain_text/1` recurses into **every element node's children,
   unconditionally, all the way down**, except for `"code"`/`"pre"` nodes (which
   contribute an empty string instead of recursing).

The defect: `flatten_plain_text/1`'s general per-node clause (the one that recurses
into an element's own `children`) has no tag guard other than the existing `"code"`/
`"pre"` exclusion. So step 2's call at the **outermost**
`walk(ast)` invocation (`nodes` = the whole document's top-level block siblings) does
not stop at each block's own boundary — it recurses straight through every `"p"`,
`"h2"`, `"li"`, etc. node into their own children and concatenates the *entire
document's* prose into one string before `walk_text/1` ever runs the
`@raw_html_tag_pattern` regex against it. That is what lets a `<` at the end of one
paragraph and a `>` at the start of the next combine into a false tag match.

The **inner** recursive calls (the ones fired once per block node from inside
`walk_node/1`, calling `walk/1` again on that node's own children) are not the problem
— when reached, they already operate on one block's own children only. The over-broad projection specifically happens at the
outermost call, because that call's `nodes` list itself contains multiple block-level
siblings, and `flatten_plain_text/1`'s current recursion has nothing that stops it from
tunnelling through a block node's own boundary to reach its content anyway.

**Conclusion:** the fix does not require moving *where* `walk/1`/`flatten_plain_text/1`
are invoked in the AST walk — the existing recursive call graph (`walk/1` → `walk_node/1`
→ `walk/1` on children → …) already produces one call per block's own children, at the
right place, for free. The fix is to stop `flatten_plain_text/1`'s own recursion from
crossing a block-element boundary, the same way it already stops at `"code"`/`"pre"`.

## 1. Fix shape: extend `flatten_plain_text/1`'s exclusion set

### 1.1 New module attribute

- **Name:** `@block_boundary_tags`
- **Type:** a `MapSet.t(String.t())` or a plain list of strings (either is acceptable;
  ELIXIR-DEV's choice — a `MapSet` avoids `Enum.member?/2`'s linear scan since this
  predicate runs once per AST node during the walk, but the list is short enough that
  correctness, not performance, should decide which one reads more clearly against the
  existing `@disallowed_url_schemes`-style attribute in this same module).
- **Members (block-level tags that earmark_parser's CommonMark/GFM AST can emit, whose
  own children must not be flattened together with a sibling block's children):**
  `"p"`, `"h1"`, `"h2"`, `"h3"`, `"h4"`, `"h5"`, `"h6"`, `"li"`, `"blockquote"`,
  `"td"`, `"th"`.
  - `"code"` and `"pre"` are **not** added to this set — they keep their existing,
    separate clause (see §1.3's rationale for keeping them distinct).
  - `"tr"`, `"table"`, `"thead"`, `"tbody"`, `"ul"`, `"ol"` are **not required** members
    — see §1.2's cascade argument — but MAY be added defensively for readability/self-
    documentation at ELIXIR-DEV's discretion; their omission or inclusion changes no
    observable behavior (the cascade through `"li"`/`"td"`/`"th"` already stops
    projection at those containers' own boundary before it would reach these outer
    wrapper tags' text, since a wrapper tag's only children are the block-boundary
    tags already listed).

### 1.2 Why the shorter list (`p`/`h1`-`h6`/`li`/`blockquote`/`td`/`th`) is provably
sufficient — the cascade argument

`flatten_plain_text/1` is invoked bottom-up as one call per AST level, but each call
still recurses fully through whatever `flatten_plain_text/1` itself does not exclude. A
container tag never listed directly (e.g. `"ul"`) is not a problem **as long as every
tag that can appear as its child *is* listed**, because the exclusion clause fires the
moment recursion reaches that child node — the parent's own call already stops there,
one level earlier than the parent tag itself would need to be named. Concretely: a
`"ul"` node's children are `"li"` nodes; `"li"` is excluded; so `flatten_plain_text`
called on a `"ul"` node's children already yields `""` for each item, with no need to
special-case `"ul"` itself. The same argument applies transitively to `"table"` →
`"tr"`/`"thead"`/`"tbody"` → `"td"`/`"th"` (excluded) and to `"blockquote"` → nested
`"p"` (excluded).

### 1.3 Keep the existing `"code"`/`"pre"` clause separate, do not merge

The existing clause that matches an element node whose tag is `"code"` or `"pre"` and
returns an empty string (instead of recursing into that node's children) exists for a
different invariant than the one this fix protects: it is what keeps
§5.2's "fenced/inline code content is literal, never scanned as prose" guarantee true
(referenced by name in three places in the current moduledoc and in `walk_node/1`'s own
comment). The new `@block_boundary_tags` clause exists to keep *unrelated prose in
different blocks* from being concatenated — a distinct invariant (this issue's fix).
Keep them as two separate guard clauses (both contributing `""`, functionally
overlapping in outcome but not in *reason*) rather than folding `"code"`/`"pre"` into
`@block_boundary_tags`, so a future reader (or a future regression) can trace each
exclusion back to the specific guarantee it protects, matching this module's existing
practice of one comment per invariant next to the code that enforces it.

### 1.4 `flatten_plain_text/1` clause ordering (shape, not code)

Three element-matching clauses, in this order (order matters only in that the two `""`-
producing clauses must both be checked before the catch-all recursive clause; their
relative order with respect to each other does not matter since the tag sets are
disjoint):

1. A plain-text (binary) leaf: returns that text unchanged (existing, unchanged).
2. An element node tagged `"code"` or `"pre"`: returns an empty string instead of
   recursing into its children (existing, unchanged — §5.2 guarantee).
3. **(new)** An element node whose tag is a member of `@block_boundary_tags`: returns
   an empty string instead of recursing into its children.
4. Any other element node (the general/catch-all element clause, now only reached for
   genuinely inline-level tags — bold/italic emphasis, links, and any other inline-
   formatting node earmark_parser produces): recurses into that node's own children
   and concatenates their projections (existing, unchanged).
5. Anything else not matched above (e.g. a comment node): returns an empty string
   (existing, unchanged).

No change to `flatten_plain_text/1`'s arity, its call sites (unchanged inside `walk/1`),
or its private visibility. `walk/1`, `walk_node/1`, `walk_text/1`, `raw_html_node?/2`,
`destination_violation/2`, and every scheme/entity-decoding function are **unchanged**
— this fix is scoped to `flatten_plain_text/1`'s own element-matching clauses only.

## 2. Why this does not reopen the round-3 bypass (split tag within one block)

Trace the reproducing case from REQ-364 round 3's own fix comment: the text
`x<img on**err**="x()">y` inside a single paragraph parses to a paragraph node whose
three children are, in order: the plain text before the emphasis, a `"strong"` element
wrapping the single word "err", and the plain text after it.

- `walk_node/1` on that paragraph node recurses into its three-item children list.
- `flatten_plain_text/1` on that list: the two plain-text children contribute their own
  text unchanged (clause 1). The `"strong"` node's tag is **not** in
  `@block_boundary_tags` (§1.1's list has no inline-formatting tags), so it falls to the
  catch-all clause 4 and recurses into its own single child, contributing "err".
- The concatenated projection reassembles the full raw tag exactly as it did before this
  fix, so it still matches `@raw_html_tag_pattern`. **Detection is preserved** — this
  fix only changes behavior when a *block-boundary* tag is present in the sibling list
  being flattened, which never happens for a single paragraph's own inline children.

## 3. Reproducing cases from the issue, traced against the fix

**Case 1** — two adjacent paragraphs, "Configure with a&lt;" followed by "b&gt;c or
make it safe": the top-level AST list has two sibling elements, both tagged `"p"`. The
outermost `flatten_plain_text/1` call over that top-level list now finds both tags in
`@block_boundary_tags`, so each contributes an empty string and the projection at that
level is empty — no match. Each paragraph is then visited by `walk_node/1`
independently; each one's own recursive call flattens only that paragraph's own,
single-text child — the first paragraph's text alone, and the second paragraph's text
alone — and neither one, alone, matches `@raw_html_tag_pattern`. **No false rejection**,
matching the issue's expected fix outcome.

**Case 2** — "if a&lt;b and *count* &gt;d then continue" (single paragraph, `<`/`>`
used as comparison operators, split by one emphasis node): this is a **single**
paragraph node, so the top-level flatten already contributes an empty string for it (as
in every case), and the real scan happens at that paragraph's own recursive call, whose
projection reassembles the full sentence with the emphasis markers removed (emphasis is
an inline tag, not excluded) — i.e. the same text as if the emphasis markers were never
there. Whether that reassembled text matches `@raw_html_tag_pattern` depends only on the
pattern and that string, neither of which this fix touches — this fix's job is only to
ensure the scan is bounded to one paragraph rather than the whole document, which it now
is; it does not change how the pattern itself evaluates a given projected string. **Flag
for TEST-DESIGNER:** write both reproducing cases as regression tests and assert the
actual pass/fail of case 2 by running it against the real regex, rather than trusting
a hand-trace of the pattern in this design document.

## 4. Invariants preserved (explicit mapping to REQ-364's existing guarantees)

- §5.2 "fenced/inline code content is literal, never scanned" — untouched; `"code"`/
  `"pre"` clause unchanged, still checked, still first among the `""`-producing clauses.
- Round-3 fix ("raw tag split across inline-formatting nodes within the same block must
  still be detected") — preserved, traced in §2 above.
- `walk_node/1`'s independent structural checks (`meta[:verbatim]`, `meta[:comment]`,
  `"a"`/`"img"` destination scheme checks) — entirely unchanged; this fix touches only
  the plain-text fallback scan's projection, never the structural AST walk, matching
  the issue's own "confirmed one-directional (never under-restrictive)" framing — that
  framing continues to hold after this fix since nothing about the structural checks
  changes.

## 5. Open questions (explicitly flagged, not silently resolved)

1. **Cross-adjacent-block detection gap, now intentional.** After this fix, a raw tag's
   `<`/`>` split across two *different* block-level siblings — two adjacent list items
   (`"li"` boundary), two adjacent paragraphs (as in issue Case 1, now explicitly
   treated as **not** a violation), a heading immediately followed by a paragraph, or
   two adjacent table cells — is **no longer detected** by the plain-text fallback scan.
   This is the fix's entire point for the paragraph case (that's the false positive
   being fixed), but the same narrowing applies uniformly to list items and table cells
   too, which the issue's own routing note anticipated ("if bounding to 'one paragraph'
   would still miss a tag split across two adjacent list-item nodes or similar — decide
   whether that's in scope or should be explicitly deferred"). **Recommendation:**
   defer — do not attempt to special-case "detect across adjacent same-type siblings
   but not across different-type siblings," since that reintroduces exactly the
   ambiguity (where is the boundary?) this fix removes, for a construct (an author
   deliberately splitting a raw HTML tag's `<`/`>` across two separate list items or
   table cells to evade detection) that is significantly less plausible as an actual
   bypass attempt than the single-paragraph case round 3 fixed, and which
   SECURITY-REVIEWER's own routing note on this issue already characterizes the whole
   class as MINOR / non-gating. **This needs REVIEWER's explicit sign-off** that
   deferring is acceptable scope for this fix, rather than CODE-DESIGNER silently
   deciding it — surfacing it here rather than resolving it is this design's obligation
   per the CODE-DESIGNER role's own "don't silently resolve an open question" rule.
2. **Exact `@block_boundary_tags` membership vs. real earmark_parser output.** §1.1's
   tag list (`p`, `h1`-`h6`, `li`, `blockquote`, `td`, `th`) is derived from CommonMark/
   GFM's standard block-element vocabulary, not from re-reading `earmark_parser`
   1.4.46's source the way this module's existing moduledoc explicitly did for the two
   verified gaps it documents (raw-HTML-inline-with-text, numeric entity decoding).
   ELIXIR-DEV should confirm the exact tag strings this resolved parser version emits
   for headings, list items, and table cells (in case of, e.g., a GFM-table dialect
   detail this design didn't anticipate) before finalizing `@block_boundary_tags`,
   mirroring this module's own stated practice of verifying against the real resolved
   dependency rather than assuming from the spec.
3. **Moduledoc/comment consistency (documentation-only, not a design ambiguity).** The
   existing moduledoc's round-3 section and `flatten_plain_text/1`'s own leading
   comment currently describe the projection as being built "at each list-of-children
   level" / "of a list of sibling AST nodes" without qualifying that block-boundary
   tags now stop that recursion. ELIXIR-DEV implementing this fix should update those
   comments (and add a round-4/ISS-0709 entry to the moduledoc, matching this module's
   existing practice of recording each review round's fix inline) so the comments
   accurately describe the bounded behavior — flagged here so it isn't missed, not
   because it changes the design itself.

## 6. Acceptance-criteria mapping

| Acceptance criterion (from ISS-0709 fix direction) | Design element |
|---|---|
| Two unrelated `<`/`>` in separate paragraphs must not falsely combine | §1 new `@block_boundary_tags` clause (incl. `"p"`); traced in §3 Case 1 |
| A raw tag split across `**strong**`/`` `code` ``/`*em*` within the SAME block must still be detected | §1.4 catch-all clause unchanged for inline tags; traced in §2 |
| Fix must not require changing where `walk/1`/`flatten_plain_text/1` are invoked | §0's conclusion — confirmed via full call-graph trace; only the element-clause guard inside `flatten_plain_text/1` changes |
| Fenced/inline code content must stay excluded (§5.2) | §1.3 — kept as its own distinct clause, unchanged |
| Adjacent list-item / table-cell scope decision | §5 open question 1 — explicitly deferred, routed to REVIEWER for sign-off rather than silently resolved |
