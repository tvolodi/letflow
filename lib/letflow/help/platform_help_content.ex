defmodule Letflow.Help.PlatformHelpContent do
  @moduledoc """
  Ecto schema for the `platform_help_content` table. See
  `lib/letflow/design/req365-platform-help-authoring.md` §1 (table shape) and §2
  (this schema).

  ## Scope — this is REQ-365's implementation of its own already-validated design

  Same field list as `Letflow.Help.HelpContent` (req363 §1.1), backed by
  `platform_help_content` instead of `help_content` — identical column shape, a
  physically separate table (req363 §3), no cross-referencing between the two.

  ## No `@schema_prefix` — a different rationale than `HelpContent`'s

  Not for the same reason `HelpContent` omits it (many per-tenant Postgres schemas,
  one `prefix:` passed per call), but for the *opposite* reason: `platform_help_content`
  lives in exactly **one** schema, the connection's default (`public`), so no caller
  ever needs to pass a `prefix:` option for this schema at all — every `Repo` call
  against this schema is a plain call with no `prefix:` keyword.

  ## `status`/`confirmed_at`/`confirmed_for_definition_version` are never castable
  ## from caller input

  Same "never caller-supplied" rule as `HelpContent` (req363 §4.1/§4.2, design §2.1):
  neither changeset below casts these three fields. `status` starts at its `:draft`
  default and moves only through `Letflow.Help.Platform.publish/1`'s explicit
  `Ecto.Changeset.change/2`; `confirmed_at`/`confirmed_for_definition_version` are set
  only by `Letflow.Help.Platform.publish/1`/`reconfirm/1`.

  ## Write-path sanitization — reused, not reinvented (design §5)

  Both changesets call `Letflow.Help.MarkdownSafety.validate/2` against `:title` and
  `:body` — the same shared validator `Letflow.Help.HelpContent` calls, not a second
  implementation. See `Letflow.Help.MarkdownSafety`'s own moduledoc for the mechanism.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Letflow.Help.MarkdownSafety

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "platform_help_content" do
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
  Structural changeset for creating a new platform help content draft. Does no I/O.

  `:status` is never cast -- every new row starts `:draft` (the field's own schema
  default). `:process_definition_id` is castable at the schema/changeset level (kept
  for shape-parity with `HelpContent`, design §1.1) but `Letflow.Help.Platform`'s
  `create_draft/1` rejects any attrs map carrying it before this changeset ever runs
  (design §3.3) -- this changeset itself does not enforce that rejection.
  """
  @spec create_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def create_changeset(platform_help_content, attrs) do
    platform_help_content
    |> cast(attrs, [:screen_id, :process_definition_id, :title, :body, :created_by])
    |> validate_required([:screen_id, :title, :body, :created_by])
    |> validate_common()
  end

  @doc """
  Structural changeset for updating an existing platform draft's mutable fields. Does
  no I/O.

  Castable fields intentionally exclude `:status`, `:confirmed_at`,
  `:confirmed_for_definition_version`, and `:created_by` -- status movement and
  confirmation are `Letflow.Help.Platform.publish/1`/`reconfirm/1`'s own guarded,
  non-changeset writes, and creator identity is set once at creation.
  """
  @spec update_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def update_changeset(platform_help_content, attrs) do
    platform_help_content
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
