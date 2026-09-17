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
  # a resolved link/image destination (see moduledoc).
  @numeric_entity_pattern ~r/&#(x[0-9a-fA-F]+|[0-9]+);/

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
        {:ok, ast, _messages} = EarmarkParser.as_ast(value)

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
  defp walk(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &walk/1)

  defp walk({tag, attrs, children, meta}) do
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

  # Plain, unparsed text leaf -- design §5.4.2 assumed all raw HTML becomes a
  # `verbatim: true` node; verified against real `earmark_parser` output that inline raw
  # HTML mixed with surrounding text on the same line does not (see moduledoc's "verified
  # gaps" section). This is the fallback that still satisfies design §5.1's "reject any
  # raw angle-bracket tag construct" requirement for that shape.
  defp walk(text) when is_binary(text) do
    if Regex.match?(@raw_html_tag_pattern, text), do: [:raw_html], else: []
  end

  defp walk(_other), do: []

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
