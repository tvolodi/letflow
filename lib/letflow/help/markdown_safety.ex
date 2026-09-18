defmodule Letflow.Help.MarkdownSafety do
  @moduledoc """
  Shared markdown-safety validator for help-content changesets. Extracted from
  `Letflow.Help.HelpContent` per `lib/letflow/design/req365-platform-help-authoring.md`
  §5: REQ-365's own acceptance criterion is "the write path enforces the same
  sanitization rule REQ-363/364 established for tenant-scoped content — no separate,
  weaker validation for the platform path," and design §5 is explicit this must be
  satisfied by **extraction, not duplication** — one implementation, called from both
  `Letflow.Help.HelpContent` (tenant-scoped, REQ-364) and
  `Letflow.Help.PlatformHelpContent` (platform-scope, REQ-365).

  This module's behavior is unchanged from where it previously lived
  (`Letflow.Help.HelpContent`'s private `validate_markdown_safety/2` and its full call
  graph) — see `Letflow.Help.HelpContent`'s moduledoc for the full history of how this
  mechanism reached its current shape (design §5.4's amended, AST-based mechanism;
  decision `docs/migration/decisions/0036-earmark-parser-markdown-sanitization-
  dependency.md`; the two verified `earmark_parser` gaps and their supplements; the
  three SECURITY-REVIEWER/REVIEWER rounds that produced the current form). Only the
  *location* of this code moved; nothing about what it does, how it's tested, or its
  `add_error/3`-never-a-raised-exception contract changed.

  ## Public API

  `validate/2` takes an `Ecto.Changeset.t()` and a `field :: atom()` and returns the
  changeset, with an error added via `add_error/3` if the field's (already-cast) string
  value contains raw HTML or a `javascript:`/`data:`/`vbscript:` link/image destination.
  Non-binary field values (e.g. `nil`, or a field never cast) are left untouched — same
  as the original `is_binary(value)` guard.
  """

  import Ecto.Changeset

  # design §5.4.2 step 2's fallback for a verified gap in earmark_parser's real
  # behavior (see Letflow.Help.HelpContent's moduledoc): raw HTML mixed inline with
  # surrounding text on the same line is left as unparsed plain text (no
  # `meta[:verbatim] == true` node at all), so this pattern is used only to scan
  # *already-unparsed plain-text AST leaves* -- never the raw source string, and never
  # text the parser structured into a code/pre node (excluded structurally, see
  # `walk/1`'s `"code"` clause). This is not a reintroduction of the superseded §5.3
  # mechanism: §5.3 scanned the *entire raw source string* for scheme/tag patterns as
  # its *only* detection mechanism; here it is a narrow, bounded supplement to the AST
  # walk, applied only where the parser itself declined to produce structure at all.
  @raw_html_tag_pattern ~r/<\/?[a-zA-Z][^<>]*>/

  @disallowed_url_schemes ~w(javascript data vbscript)

  # Decimal (`&#106;`) and hex (`&#x6a;`/`&#X6A;`) numeric character references --
  # closes the verified gap where `EarmarkParser.as_ast/2` does not decode these inside
  # a resolved link/image destination (see Letflow.Help.HelpContent's moduledoc). The
  # hex marker (`x`/`X`) is case-insensitive per HTML5's numeric-character-reference
  # grammar (`&#x73;` and `&#X73;` are the same reference) -- `[xX]` here matches
  # `decode_entity_code/1`'s own already-case-insensitive `x in [?x, ?X]` guard below;
  # a bare lowercase `x` in this pattern (SECURITY-REVIEWER round 3, blocker 1) let an
  # uppercase-marker entity survive undecoded into `scheme_letters/1`, where the
  # leftover literal `x` character got folded into the extracted scheme, producing
  # `"javaxcript"` instead of `"javascript"`.
  @numeric_entity_pattern ~r/&#([xX][0-9a-fA-F]+|[0-9]+);/

  # ISS-0709 fix (round 4, ported here from Letflow.Help.HelpContent during REQ-365's
  # extraction — see that module's moduledoc for the full incident): block-level tags
  # whose own children must never be concatenated with a sibling block's children by
  # `flatten_plain_text/1`'s projection. Verified against `earmark_parser` 1.4.46's real
  # CommonMark/GFM AST output (design
  # `lib/letflow/design/iss-0709-flatten-plain-text-scope-fix.md` §1.1), not merely
  # assumed from the spec. Only the tags that can *directly* hold inline/text content
  # need listing -- container tags like `"ul"`/`"ol"`/`"table"`/`"tr"` never need their
  # own entry because the cascade already stops one level lower, at their `"li"`/`"td"`/
  # `"th"` children (design §1.2's cascade argument). Deliberately excludes
  # `"code"`/`"pre"`, which keep their own separate clause below for a different
  # invariant (§5.2's "fenced content is literal", not this block-boundary invariant --
  # design §1.3).
  @block_boundary_tags ~w(p h1 h2 h3 h4 h5 h6 li blockquote td th)

  @doc """
  Validates `field` on `changeset` for raw HTML and disallowed-scheme link/image
  destinations, per `lib/letflow/design/req363-help-content-data-model.md` §5.4 /
  `lib/letflow/design/req365-platform-help-authoring.md` §5. Rejects
  (`add_error/3`), never silently strips.
  """
  @spec validate(changeset :: Ecto.Changeset.t(), field :: atom()) :: Ecto.Changeset.t()
  def validate(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) do
        # `EarmarkParser.as_ast/2`'s documented contract is `{:ok, ast, []} | {:error,
        # ast, errors()}` -- the `:error` branch fires for ANY :warning-or-worse parse
        # message (SECURITY-REVIEWER round 3, blocker 3), which includes ordinary,
        # non-adversarial tenant-authored content such as a stray unclosed backtick or
        # an unclosed fenced code block, not only malicious input. A bare `{:ok, ast,
        # _messages} = ...` match crashed (`MatchError`) on that branch. Per the
        # library's own contract, the `:error` branch's `ast` is still real, usable
        # parsed structure (just with parse warnings) -- both branches are handled the
        # same way here: walk whatever AST was produced. This never loses detection of
        # unsafe content (the walk still runs), it only stops a parse-quality warning
        # from crashing the write path outright (INV-8).
        ast =
          case EarmarkParser.as_ast(value) do
            {:ok, ast, _messages} -> ast
            {:error, ast, _messages} -> ast
          end

        ast
        |> walk()
        |> Enum.uniq()
        |> Enum.map(&{field, violation_message(&1)})
      else
        []
      end
    end)
  end

  defp violation_message(:raw_html), do: "must not contain raw HTML tags"

  defp violation_message(:unsafe_scheme),
    do: "must not contain javascript:/data:/vbscript: link or image URLs"

  # design §5.4.2 steps 2-3, plus the two verified-gap supplements documented in
  # Letflow.Help.HelpContent's moduledoc. Every `earmark_parser` AST node is a uniform
  # 4-tuple `{tag, attrs, children, meta}`; plain text leaves are bare binaries.
  #
  # SECURITY-REVIEWER round 3, blocker 2: a raw tag's own `<`/`>` can land in two
  # different plain-text AST leaves when an inline-formatting node (`**strong**`,
  # `` `code` ``, emphasis, a link, ...) interrupts the tag's own attribute area --
  # e.g. `x<img on**err**="x()">y` parses to three siblings, `"x<img on"`,
  # `{"strong", [], ["err"], %{}}`, `"=\"x()\">y"`, and neither text sibling alone
  # contains a complete `<...>` span. Scanning each leaf independently (as the previous
  # round did) misses this. The fix: at each list-of-children level, build one flattened
  # text projection of that level (in AST order) -- plain-text leaves contribute their
  # own text, and any non-code/pre element contributes its own inner text recursively
  # (so `**err**`'s "err" is treated as contiguous with its neighbours, closing the
  # split) -- then scan that single projection once for the raw-tag pattern, alongside
  # (not instead of) the existing per-node structural checks. `"code"`/`"pre"` nodes
  # contribute nothing to the projection (empty string, not their literal content), so
  # fenced/inline code text is never concatenated into surrounding prose -- §5.2's
  # "fenced content stays literal/excluded" guarantee holds exactly as before; this is
  # the same exclusion `nested` below already applies for the structural recursion.
  # ISS-0709 (round 4): a `@block_boundary_tags` node (`"p"`, headings, `"li"`,
  # `"blockquote"`, `"td"`/`"th"`) likewise contributes nothing at THIS level, so the
  # projection at any given list-of-children level never tunnels through one of its own
  # block-element children into a *sibling* block's content -- it stays bounded to one
  # block's own children, since the recursive call into that block's own children (fired
  # from `walk_node/1` below) is where that block's own projection is built instead. See
  # `Letflow.Help.HelpContent`'s moduledoc for the false-positive this closes.
  defp walk(nodes) when is_list(nodes) do
    structural = Enum.flat_map(nodes, &walk_node/1)
    text_scan = nodes |> flatten_plain_text() |> walk_text()
    structural ++ text_scan
  end

  defp walk_node({tag, attrs, children, meta}) do
    raw_html_violation = if raw_html_node?(tag, meta), do: [:raw_html], else: []
    scheme_violation = destination_violation(tag, attrs)

    # design §5.4.2 step 4: fenced/inline code node content is never visited by either
    # check -- `"code"` nodes (both standalone inline and nested inside `"pre"` for
    # fenced blocks) are excluded from recursion entirely, which is what makes §5.2's
    # "fenced-block content is literal" guarantee hold for both the AST-structural check
    # and this module's plain-text fallback scan alike.
    nested = if tag == "code", do: [], else: walk(children)

    raw_html_violation ++ scheme_violation ++ nested
  end

  # Plain-text leaves are handled entirely by the flattened-projection scan in
  # `walk/1` above now (so a split-by-formatting tag is still caught) -- nothing
  # additional to do for a bare binary at the structural-node level.
  defp walk_node(text) when is_binary(text), do: []
  defp walk_node(_other), do: []

  defp walk_text(text) when is_binary(text) do
    if Regex.match?(@raw_html_tag_pattern, text), do: [:raw_html], else: []
  end

  # Builds one contiguous text projection of a list of sibling AST nodes, in order:
  # binaries contribute their own text; `"code"`/`"pre"` nodes contribute nothing
  # (excluded, not merged into prose -- §5.2); any node tagged with a
  # `@block_boundary_tags` member (`"p"`, `"h1"`-`"h6"`, `"li"`, `"blockquote"`, `"td"`,
  # `"th"`) also contributes nothing -- ISS-0709 (round 4): the projection must not
  # tunnel through a block element's own boundary and concatenate its content with a
  # *sibling* block's content, or an unrelated `<`/`>` at the edge of two adjacent blocks
  # (two paragraphs, two list items, a heading followed by a paragraph, ...) can combine
  # into a false raw-tag match. Any other element (genuinely inline-level: emphasis,
  # `"strong"`, links, ...) contributes its own children's projection recursively, so
  # inline formatting within the SAME block still doesn't break an otherwise-contiguous
  # raw tag apart. This is a projection for the raw-tag-shape scan only -- it never
  # replaces the per-node structural checks in `walk_node/1`, which still run
  # independently against the real AST. Note this projection is bounded to one block's
  # own children at a time (not the whole list of sibling AST nodes at every level) --
  # see `Letflow.Help.HelpContent`'s moduledoc's ISS-0709 entry and `walk/1`'s own
  # comment above.
  defp flatten_plain_text(nodes) when is_list(nodes) do
    nodes |> Enum.map(&flatten_plain_text/1) |> Enum.join()
  end

  defp flatten_plain_text(text) when is_binary(text), do: text
  defp flatten_plain_text({tag, _attrs, _children, _meta}) when tag in ["code", "pre"], do: ""

  defp flatten_plain_text({tag, _attrs, _children, _meta}) when tag in @block_boundary_tags,
    do: ""

  defp flatten_plain_text({_tag, _attrs, children, _meta}), do: flatten_plain_text(children)
  defp flatten_plain_text(_other), do: ""

  # `meta[:verbatim] == true` per design §5.4.2 step 2. HTML comment nodes
  # (`{:comment, [], [...], %{comment: true}}`) are also raw, non-markdown-subset content
  # per design §5.2 ("no raw HTML of any kind"), so `meta[:comment] == true` is treated
  # the same way.
  defp raw_html_node?(_tag, meta), do: meta[:verbatim] == true or meta[:comment] == true

  # design §5.4.2 step 3 -- unconditional on `meta[:verbatim]`, since a markdown-syntax
  # `[text](url)` link (`meta == %{}`) is only ever visited here, never by the raw-HTML
  # check above.
  defp destination_violation("a", attrs), do: scheme_violation_for(attrs, "href")
  defp destination_violation("img", attrs), do: scheme_violation_for(attrs, "src")
  defp destination_violation(_tag, _attrs), do: []

  defp scheme_violation_for(attrs, attr_name) do
    case List.keyfind(attrs, attr_name, 0) do
      {^attr_name, destination} when is_binary(destination) ->
        if unsafe_scheme?(destination), do: [:unsafe_scheme], else: []

      _ ->
        []
    end
  end

  defp unsafe_scheme?(destination) do
    destination
    |> decode_numeric_entities()
    |> scheme_letters()
    |> then(&(&1 in @disallowed_url_schemes))
  end

  # Keeps only ASCII a-z letters (after decoding numeric entities and lower-casing) from
  # the portion of the destination before its first `:` -- closes the embedded-
  # whitespace/control-character bypass class (verified: `as_ast/2` does not always strip
  # these from a resolved destination, see Letflow.Help.HelpContent's moduledoc) without
  # needing a separate allowlist of characters to strip; any non-letter byte in that span
  # (whitespace, control characters, a stray `<`/`>` left over from an angle-bracket
  # destination, etc.) is simply not a letter and is dropped.
  defp scheme_letters(destination) do
    case String.split(destination, ":", parts: 2) do
      [maybe_scheme, _rest] ->
        maybe_scheme
        |> String.downcase()
        |> String.to_charlist()
        |> Enum.filter(&(&1 in ?a..?z))
        |> List.to_string()

      _ ->
        ""
    end
  end

  defp decode_numeric_entities(string) do
    Regex.replace(@numeric_entity_pattern, string, fn _whole, code -> decode_entity_code(code) end)
  end

  defp decode_entity_code(<<x, rest::binary>>) when x in [?x, ?X],
    do: codepoint_to_binary(rest, 16)

  defp decode_entity_code(decimal), do: codepoint_to_binary(decimal, 10)

  defp codepoint_to_binary(digits, base) do
    case Integer.parse(digits, base) do
      {codepoint, ""} -> safe_codepoint(codepoint)
      _ -> ""
    end
  end

  # Valid Unicode scalar values only (excludes the surrogate range) -- an out-of-range or
  # surrogate reference decodes to nothing rather than raising, since a malformed entity
  # is not this validator's concern beyond not crashing on it.
  defp safe_codepoint(cp) when cp in 0..0xD7FF, do: <<cp::utf8>>
  defp safe_codepoint(cp) when cp in 0xE000..0x10FFFF, do: <<cp::utf8>>
  defp safe_codepoint(_cp), do: ""
end
