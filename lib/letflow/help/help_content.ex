defmodule Letflow.Help.HelpContent do
  @moduledoc """
  Ecto schema for the `help_content` table. See
  `lib/letflow/design/req363-help-content-data-model.md` §1 (table shape) and §5
  (write-path sanitization rule this module's changesets enforce).

  ## Scope — this is REQ-364's implementation of REQ-363's already-validated design

  The schema shape (columns, types, defaults) is not this module's own decision — it is
  REQ-363's design §1.1/§1.3, implemented here verbatim. The two-state `:draft | :live`
  lifecycle (§2), the `confirmed_at`/`confirmed_for_definition_version` staleness fields
  (§4), and the `media` reservation column (§6) are all as designed, not reinvented.

  ## No `@schema_prefix` (mirrors `Letflow.Definitions.ProcessDefinition`)

  This table lives in many Postgres schemas, one per tenant, so every read/write passes
  `prefix: schema_name` explicitly at call time (`Letflow.Help`, this schema's only
  caller). `schema_name` comes from a `Letflow.TenantProvisioning.Registration` row.

  ## `status`, `confirmed_at`, and `confirmed_for_definition_version` are never castable
  ## from caller input

  None of the three changesets below cast `:status`, `:confirmed_at`, or
  `:confirmed_for_definition_version`. `status` starts at its `:draft` default and moves
  only through `Letflow.Help.publish/2`'s explicit `Ecto.Changeset.change/2` (never a
  caller-supplied value); `confirmed_at` and `confirmed_for_definition_version` are set
  only by `Letflow.Help.publish/2` and `Letflow.Help.reconfirm/2`, from the real clock and
  the referenced process definition's actual current version, respectively — never from
  caller-supplied attrs (design §4.1/§4.2's own "never caller-supplied" instruction, and
  this requirement's own acceptance criteria).

  ## Write-path sanitization (design §5.4, this requirement's own scope — not deferred)

  `create_changeset/2` and `update_changeset/2` both run `validate_markdown_safety/2`
  against `:title` and `:body`, rejecting the changeset (`add_error/3` — never a raised
  exception) rather than silently stripping content. This is design §5.4's amended,
  AST-based mechanism: `EarmarkParser.as_ast/2` parses each field once into a CommonMark
  AST (decision `docs/migration/decisions/0036-earmark-parser-markdown-sanitization-
  dependency.md`), and the resulting tree is walked for raw-HTML nodes
  (`meta[:verbatim] == true`) and for `"a"`/`"img"` destination nodes with a disallowed
  URL scheme. This replaces the original §5.3 option 1 (regex/pattern-based validation),
  which SECURITY-REVIEWER and REVIEWER found structurally bypassable across three rounds
  (5 confirmed/constructed bypasses — reference-style link definitions, angle-bracket-
  wrapped autolinks, backslash-escaped/entity-encoded/whitespace-embedded scheme
  characters) and explicitly declined to patch further.

  ### Two verified gaps in `earmark_parser`'s real behavior vs. the design's stated claims

  Confirmed directly against `earmark_parser` 1.4.46 (the version this project actually
  resolves, matching decision 0036), not assumed from the design or its own hexdocs
  citations:

  1. **Raw HTML mixed inline with surrounding text on the same line is never tagged
     `verbatim: true` at all** — it is left as plain, unparsed text content (confirmed via
     `earmark_parser`'s own moduledoc: "HTML is not parsed recursively or detected in all
     conditions right now" — only a tag that starts its own line, alone or across
     matching multi-line blocks, becomes a `%{verbatim: true}` node; e.g.
     `"click <div onclick=\\"x()\\">here</div>"` parses to a single literal-text `"p"` child,
     no `"div"` node at all). The design's §5.4.2 step 2 assumed *every* raw-HTML
     construct becomes a `verbatim: true` node; that does not hold for this shape. To
     still satisfy §5.1's actual requirement (reject *any* raw angle-bracket tag
     construct, not only ones the parser recognizes as an HTML block) and to keep the
     pre-existing, still-valid test `"rejects a body containing any other raw HTML tag"`
     passing, the walk also scans each *unparsed plain-text* AST leaf for the same
     tag-shape pattern the superseded §5.3 mechanism used — scoped only to text the
     parser left unstructured (code-span/code-block node content is still structurally
     excluded from this scan, so §5.2's "fenced content is literal" guarantee is
     unaffected).
  2. **HTML numeric character references inside link/image destinations are not decoded**
     by `as_ast/2` (`[x](java&#115;cript:alert(1))` resolves its `href` attribute to the
     literal, still-encoded string `"java&#115;cript:alert(1)"`), and embedded
     whitespace/control characters inside a destination are not always stripped either
     (`[x](java\\tscript:alert(1))` resolves to `href: "java\\tscript:alert(1)"`, tab
     intact) — both contradict §5.4.1's "the parser already handles it correctly"
     reasoning for those two bypass classes specifically. The scheme check below
     decodes decimal/hex numeric character references and keeps only ASCII `a`-`z`
     letters from the pre-colon portion of the (decoded) destination before comparing
     against `@disallowed_url_schemes`, closing both classes without reintroducing a
     scheme-detection regex over raw source bytes (REVIEWER's actual objection to the
     superseded mechanism) — this operates only on the AST's own already-resolved
     destination value, same as §5.4.2 specifies, with one extra normalization step the
     design did not anticipate.

  Both gaps, and the primary-source verification behind them, are flagged in this
  requirement's implementation handoff for REVIEWER to confirm alongside the rest of
  this change.

  ### Round 3 fixes (SECURITY-REVIEWER `step-03b-security-reviewer-rework2.json`)

  1. `@numeric_entity_pattern`'s hex branch now matches `[xX]`, not a bare lowercase
     `x` -- an uppercase hex marker (`&#X73;`, valid per HTML5) previously survived
     undecoded into `scheme_letters/1`, whose downcase-then-filter-a-z step folded the
     entity's own literal `x` syntax character into the extracted scheme
     (`"javaxcript"` instead of `"javascript"`), missing the disallowed-scheme match.
  2. The plain-text fallback scan (gap 1 above) now scans a *flattened text projection*
     of each list of sibling AST nodes (built by `flatten_plain_text/1`) instead of each
     text leaf independently -- a raw tag's `<`/`>` split across two text leaves by an
     intervening inline-formatting node (`**strong**`, `` `code` ``, emphasis, a link,
     ...) is otherwise invisible to a per-leaf scan. `"code"`/`"pre"` nodes still
     contribute nothing to the projection, so §5.2's "fenced content stays literal" is
     unaffected.
  3. `validate_markdown_safety/2` no longer bare-matches `{:ok, ast, _messages} = ...`
     against `EarmarkParser.as_ast/2`'s result -- that call's own documented contract
     returns `{:error, ast, messages}` for any `:warning`-or-worse parse message
     (including ordinary tenant text like an unclosed backtick or an unclosed fenced
     block, not only malicious input), which the bare match let raise `MatchError`
     straight out of `Letflow.Help.create_draft/2`/`update_draft/3` (INV-8). Both
     branches are now handled explicitly; either way the returned `ast` (still real,
     usable structure per the library's own contract) is walked exactly as before.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "help_content" do
    field(:screen_id, :string)
    field(:process_definition_id, Ecto.UUID)
    field(:title, :string)
    field(:body, :string)
    field(:status, Ecto.Enum, values: [:draft, :live], default: :draft)
    field(:confirmed_at, :utc_datetime_usec)
    field(:confirmed_for_definition_version, :string)
    field(:media, {:array, :map}, default: [])
    field(:created_by, Ecto.UUID)

    timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
  @type status :: :draft | :live

  # design §5.4.2 step 2's fallback for the verified gap in earmark_parser's real
  # behavior (see moduledoc): raw HTML mixed inline with surrounding text on the same
  # line is left as unparsed plain text (no `meta[:verbatim] == true` node at all), so
  # this pattern is used only to scan *already-unparsed plain-text AST leaves* -- never
  # the raw source string, and never text the parser structured into a code/pre node
  # (excluded structurally, see `walk/1`'s `"code"` clause). This is not a reintroduction
  # of the superseded §5.3 mechanism: §5.3 scanned the *entire raw source string* for
  # scheme/tag patterns as its *only* detection mechanism; here it is a narrow, bounded
  # supplement to the AST walk, applied only where the parser itself declined to produce
  # structure at all.
  @raw_html_tag_pattern ~r/<\/?[a-zA-Z][^<>]*>/

  @disallowed_url_schemes ~w(javascript data vbscript)

  # Decimal (`&#106;`) and hex (`&#x6a;`/`&#X6A;`) numeric character references --
  # closes the verified gap where `EarmarkParser.as_ast/2` does not decode these inside
  # a resolved link/image destination (see moduledoc). The hex marker (`x`/`X`) is
  # case-insensitive per HTML5's numeric-character-reference grammar (`&#x73;` and
  # `&#X73;` are the same reference) -- `[xX]` here matches `decode_entity_code/1`'s own
  # already-case-insensitive `x in [?x, ?X]` guard below; a bare lowercase `x` in this
  # pattern (SECURITY-REVIEWER round 3, blocker 1) let an uppercase-marker entity survive
  # undecoded into `scheme_letters/1`, where the leftover literal `x` character got
  # folded into the extracted scheme, producing `"javaxcript"` instead of `"javascript"`.
  @numeric_entity_pattern ~r/&#([xX][0-9a-fA-F]+|[0-9]+);/

  @doc """
  Structural changeset for creating a new help content draft. Does no I/O.

  `:status` is never cast -- every new row starts `:draft` (the field's own schema
  default), matching this requirement's "create a draft" scope exactly.
  """
  @spec create_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def create_changeset(help_content, attrs) do
    help_content
    |> cast(attrs, [:screen_id, :process_definition_id, :title, :body, :created_by])
    |> validate_required([:screen_id, :title, :body, :created_by])
    |> validate_common()
  end

  @doc """
  Structural changeset for updating an existing draft's mutable fields. Does no I/O.

  Castable fields intentionally exclude `:status`, `:confirmed_at`,
  `:confirmed_for_definition_version`, and `:created_by` -- status movement and
  confirmation are `Letflow.Help.publish/2`/`reconfirm/2`'s own guarded, non-changeset
  writes (mirrors `Letflow.Definitions.ProcessDefinition.update_changeset/2`'s identical
  exclusion of `:status`), and creator identity is set once at creation.
  """
  @spec update_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def update_changeset(help_content, attrs) do
    help_content
    |> cast(attrs, [:screen_id, :process_definition_id, :title, :body])
    |> validate_required([:screen_id, :title, :body])
    |> validate_common()
  end

  defp validate_common(changeset) do
    changeset
    |> validate_length(:screen_id, min: 1, max: 255)
    |> validate_length(:title, min: 1, max: 255)
    |> validate_markdown_safety(:title)
    |> validate_markdown_safety(:body)
  end

  # design §5.4.2 -- parses the field's value once via `EarmarkParser.as_ast/2` and walks
  # the resulting AST for both raw-HTML nodes and disallowed-scheme link/image
  # destination nodes in the same pass ("the two checks can share one parse per field
  # rather than needing two independent passes" -- design's own words), rather than the
  # superseded §5.3 mechanism's two independent `validate_change/3` calls each re-scanning
  # the raw string. Rejects (`add_error/3`), never silently strips -- same contract as
  # §5.3, same two user-facing messages.
  defp validate_markdown_safety(changeset, field) do
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

  # design §5.4.2 steps 2-3, plus the two verified-gap supplements documented in this
  # module's moduledoc. Every `earmark_parser` AST node is a uniform 4-tuple
  # `{tag, attrs, children, meta}`; plain text leaves are bare binaries.
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
  # (excluded, not merged into prose -- §5.2); any other element contributes its own
  # children's projection recursively (so inline formatting like `**strong**`/`*em*`/
  # links don't break an otherwise-contiguous raw tag apart). This is a projection for
  # the raw-tag-shape scan only -- it never replaces the per-node structural checks in
  # `walk_node/1`, which still run independently against the real AST.
  defp flatten_plain_text(nodes) when is_list(nodes) do
    nodes |> Enum.map(&flatten_plain_text/1) |> Enum.join()
  end

  defp flatten_plain_text(text) when is_binary(text), do: text
  defp flatten_plain_text({tag, _attrs, _children, _meta}) when tag in ["code", "pre"], do: ""
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
  # these from a resolved destination, see moduledoc) without needing a separate
  # allowlist of characters to strip; any non-letter byte in that span (whitespace,
  # control characters, a stray `<`/`>` left over from an angle-bracket destination,
  # etc.) is simply not a letter and is dropped.
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
