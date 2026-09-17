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

  ## Write-path sanitization (design §5, this requirement's own scope — not deferred)

  `create_changeset/2` and `update_changeset/2` both run `validate_no_raw_html/2` and
  `validate_no_unsafe_link_scheme/2` against `:title` and `:body`, rejecting the changeset
  (`add_error/3` — never a raised exception) rather than silently stripping content. This
  is design §5.3's option 1 (regex/pattern-based validation, no new dependency) — the
  design's own recommended mechanism, since `mix.exs` carries no markdown/HTML-sanitization
  library today and adding one would need REVIEWER sign-off design §5.3 does not grant
  itself. Flagged (design OQ-4) for REVIEWER to confirm at this requirement's gate.
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

  # design §5.1 -- any raw angle-bracket tag construct, opening or closing, for any
  # tagname. Not a denylist of "known-dangerous" tags (design's own stated reasoning: a
  # denylist is incomplete by construction and markdown's own syntax needs no raw HTML
  # tag). Matches `<script>`, `</script>`, `<img onerror=...>`, etc. — every construct
  # design §5.1 names explicitly is a raw-HTML-tag construct and is covered by this one
  # pattern.
  @raw_html_tag_pattern ~r/<\/?[a-zA-Z][^<>]*>/

  # design §5.1 -- markdown link/image URL component, checked for a disallowed scheme.
  # Matches both `[text](url)` and `![alt](url)`.
  @markdown_link_pattern ~r/!?\[[^\]]*\]\(([^)]+)\)/

  @disallowed_url_schemes ~w(javascript data vbscript)

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
    |> validate_no_raw_html(:title)
    |> validate_no_raw_html(:body)
    |> validate_no_unsafe_link_scheme(:title)
    |> validate_no_unsafe_link_scheme(:body)
  end

  defp validate_no_raw_html(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and Regex.match?(@raw_html_tag_pattern, strip_code_regions(value)) do
        [{field, "must not contain raw HTML tags"}]
      else
        []
      end
    end)
  end

  defp validate_no_unsafe_link_scheme(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and contains_unsafe_link_scheme?(value) do
        [{field, "must not contain javascript:/data:/vbscript: link or image URLs"}]
      else
        []
      end
    end)
  end

  defp contains_unsafe_link_scheme?(value) do
    @markdown_link_pattern
    |> Regex.scan(strip_code_regions(value), capture: :all_but_first)
    |> Enum.any?(fn [url] -> unsafe_scheme?(url) end)
  end

  defp unsafe_scheme?(url) do
    case String.split(url, ":", parts: 2) do
      [scheme, _rest] -> String.downcase(String.trim(scheme)) in @disallowed_url_schemes
      _ -> false
    end
  end

  # design §5.2 -- "fenced-block content is treated as literal text, never re-parsed for
  # further markdown or HTML." Blanks out fenced (``` ... ```) and inline (`...`) code
  # spans before either raw-HTML-tag or link-scheme scanning runs, so a legitimate code
  # example containing literal angle brackets (e.g. documenting HTML syntax, or a
  # generic-type example like `Vector<Int>`) is not rejected as if it were live markup.
  # Blanking (not deleting) preserves the surrounding text's byte offsets, though no
  # caller here depends on that -- it is simply the simplest correct transform.
  defp strip_code_regions(value) do
    value
    |> String.replace(~r/```.*?```/s, "")
    |> String.replace(~r/`[^`\n]*`/, "")
  end
end
