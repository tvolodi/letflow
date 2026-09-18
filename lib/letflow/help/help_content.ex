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

  `create_changeset/2` and `update_changeset/2` both run
  `Letflow.Help.MarkdownSafety.validate/2` against `:title` and `:body`, rejecting the
  changeset (`add_error/3` — never a raised exception) rather than silently stripping
  content. This is design §5.4's amended, AST-based mechanism: `EarmarkParser.as_ast/2`
  parses each field once into a CommonMark AST (decision
  `docs/migration/decisions/0036-earmark-parser-markdown-sanitization-dependency.md`),
  and the resulting tree is walked for raw-HTML nodes (`meta[:verbatim] == true`) and for
  `"a"`/`"img"` destination nodes with a disallowed URL scheme. This replaces the
  original §5.3 option 1 (regex/pattern-based validation), which SECURITY-REVIEWER and
  REVIEWER found structurally bypassable across three rounds (5 confirmed/constructed
  bypasses — reference-style link definitions, angle-bracket-wrapped autolinks,
  backslash-escaped/entity-encoded/whitespace-embedded scheme characters) and explicitly
  declined to patch further.

  ## Extraction into `Letflow.Help.MarkdownSafety` (REQ-365, design §5)

  The validator described below (and everything it calls — the AST walk, the
  numeric-entity decoding, the plain-text fallback scan) used to live here as a private
  `validate_markdown_safety/2` and its call graph. REQ-365's platform-scope write path
  needs the exact same sanitization rule — its own acceptance criterion is "no separate,
  weaker validation for the platform path" — so this logic moved to a new shared module,
  `Letflow.Help.MarkdownSafety`, exposing one public `validate/2` function. This module
  now calls that shared function from `validate_common/1` below instead of housing the
  implementation itself. **Same behavior, moved location** — nothing about detection
  logic, error messages, or the `add_error/3`-never-a-raised-exception contract changed;
  see `Letflow.Help.MarkdownSafety`'s own moduledoc for the mechanism itself.

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

  ### Round 4 fix (ISS-0709 -- `lib/letflow/design/iss-0709-flatten-plain-text-scope-fix.md`)

  Round 3's `flatten_plain_text/1` projection (see round 3 item 2 above) was built from
  **the entire current list of sibling AST nodes at every level of recursion**,
  including the outermost call over a whole document's top-level block siblings (e.g.
  `[{"p",...}, {"h2",...}, {"p",...}]`). Nothing stopped that projection from tunnelling
  through a block element's own boundary into its children and concatenating it with a
  *different* block's content -- so an unrelated `<` at the end of one paragraph and a
  `>` at the start of the next combined into a false raw-tag match (and likewise for two
  adjacent list items, a heading followed by a paragraph, or two adjacent table cells).

  Fix: `flatten_plain_text/1` now also excludes (contributes `""`, does not recurse into)
  any node whose tag is a member of `@block_boundary_tags` (`"p"`, `"h1"`-`"h6"`, `"li"`,
  `"blockquote"`, `"td"`, `"th"`), as its own clause alongside -- not merged with -- the
  existing `"code"`/`"pre"` exclusion. This bounds the projection to one block's own
  children at a time, matching what `walk_node/1`'s own recursive call into that block's
  children already does structurally. No change to where `walk/1`/`walk_node/1`/
  `flatten_plain_text/1` are invoked -- the existing recursive call graph already
  produces one call bounded to each block's own children; only the guard inside
  `flatten_plain_text/1` changed. Inline-level tags (`"strong"`, `"em"`, links, ...) are
  deliberately not in `@block_boundary_tags`, so a raw tag split across inline-formatting
  nodes *within the same block* (round 3's own fix target) is still detected.

  This intentionally narrows detection: a raw tag's `<`/`>` split across two different
  block-level siblings is no longer flagged by this fallback scan (deferred per the
  design's open question 1 -- SECURITY-REVIEWER's routing note already characterizes this
  class as MINOR / non-gating).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Letflow.Help.MarkdownSafety

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
    |> MarkdownSafety.validate(:title)
    |> MarkdownSafety.validate(:body)
  end
end
