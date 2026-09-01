defmodule Letflow.Repository.Attachments do
  @moduledoc """
  Context module for the `instance_attachments` table's core lifecycle:
  `upload/2`, `list/2`, `get/2`, `delete/2`. See
  `lib/letflow/design/req211-instance-attachments-core.md` for the full
  design this module implements. Plain Ecto context module, no process --
  same shape as `Letflow.Dlq`/`Letflow.Webhooks`.

  **Scope boundary (design §4.0 item 1):** this module covers only the
  `instance_attachments` schema/migration and these four functions. No
  route, no controller, no Plug module -- that is REQ-212.

  ## Tenant scoping (INV-1, design §4.0 item 2)

  Every function below takes `opts :: [prefix: String.t()]`, `prefix` always
  supplied by the caller -- this module never itself decides tenant scope,
  matching every REQ-072+ context module's own precedent
  (`Letflow.Dlq`/`Letflow.Webhooks`). `tenant_id` is never accepted from
  caller-supplied attrs -- it is always derived from `opts[:prefix]` via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`.

  ## INV-a -- `content_type` is caller-supplied metadata, never a validated
  ## fact (design §4.0 item 3)

  Nothing in this module, and nothing any caller of this module may assume,
  treats the stored `content_type` value as verified against the actual byte
  content -- no magic-byte/MIME-sniffing check is performed anywhere here. A
  caller declaring `content_type: "application/pdf"` for a file that is not
  actually a PDF is accepted and stored exactly as declared. Any future
  consumer that needs a *trusted* content-type determination must not read
  this field as if it were one.

  ## INV-b -- `byte_size` is independently measured, never caller-trusted
  ## (design §4.0 item 4)

  `upload/2` computes `byte_size` via `byte_size/1` (Elixir's own function),
  over the actual `raw_bytes` binary parameter -- this computed value is what
  both `repository_artifacts` (if a new row) and `instance_attachments`
  store. `upload_attrs()` has no parameter for a caller-declared size at
  all -- there is structurally nothing to ignore, which is a stronger
  guarantee than "ignores it if present."

  ## Decision B cross-tenant statement (AC8, design §4.0 item 6)

  `repository_artifacts` is per-tenant-schema-scoped (Decision B,
  `docs/migration/decisions/0003-ecto-schema-strategy.md`), so `content_hash`
  dedup happens only within one tenant's own schema. Two different tenants
  uploading byte-identical file content each get their own
  `repository_artifacts` row, in their own Postgres schema -- never one
  shared row. This module deliberately does not, and cannot by construction,
  share content-hash rows across tenants.

  ## No-canonicalisation statement (AC8, design §4.0 item 7)

  No canonicalisation is applied to attachment bytes before hashing --
  byte-identity hashing only, per REQ-202's existing binary-content rule
  (`Letflow.Repository.Canonicaliser`'s byte-identity branch for non-JSON
  content). This applies regardless of an attachment's declared
  `content_type` -- even an attachment declared `application/json` is hashed
  byte-identically here, NOT run through `Letflow.Repository.Canonicaliser`'s
  JSON canonicalization branch, because an attachment is an opaque
  user-uploaded document, not a versioned configuration artifact subject to
  REQ-202's dedup-by-canonical-form semantics.

  ## Content-scanning deferral (AC9, design §4.0 item 8)

  No antivirus/content-scanning pipeline exists for uploaded attachment
  bytes. This is a deliberately deferred follow-up, not an oversight --
  flag it for a future issue if malicious-upload risk becomes a concrete
  concern before S8.

  ## `delete/2`'s metadata-only-delete rationale (design §4.0 item 9)

  `delete/2` removes the `instance_attachments` row only; the underlying
  `repository_artifacts` content row is never deleted by this module, both
  because REQ-202's own immutability rule and `ON DELETE RESTRICT` FK
  already forbid deleting a referenced content row, and because another
  attachment (or a REQ-202 `artifact_versions` row) could independently
  share the same `content_hash`.
  """

  import Ecto.Query

  alias Letflow.Api.Pagination
  alias Letflow.Repo
  alias Letflow.Repository
  alias Letflow.Repository.Attachment
  alias Letflow.TenantProvisioning

  @typedoc "Threaded into every `Repo` call below -- `:prefix` derived by the caller from `Letflow.Api.Context.scoped_repo_opts/1`, never from request data."
  @type opts :: [prefix: String.t()]

  @list_cursor_prefix "IA:"

  # Letflow's own choice (design §4.4), not ported from R-Co -- no existing
  # precedent in this codebase or in docs/migration/decisions/ fixes a
  # file-attachment size limit. 25 MiB: a round, conservative number for a
  # document-attachment use case (delivery notes, signed forms, scanned
  # receipts) -- large enough for the motivating scenario (REQ-206's
  # swiftroute-shipment-attach-delivery-note), small enough to bound
  # per-request memory pressure meaningfully above the existing 2 MB JSON
  # Plug.Parsers cap (lib/letflow/plugs/api_pipeline.ex) without adopting an
  # arbitrarily large ceiling. Independent of, and not derived from, that
  # existing JSON body-size cap -- flagged for REVIEWER as a judgement-based
  # number with no requirement-stated value (design §4.4).
  @max_upload_bytes 26_214_400

  # ===========================================================================
  # upload/2 (design §4.1)
  # ===========================================================================

  @type upload_attrs :: %{
          required(:instance_id) => Ecto.UUID.t(),
          required(:raw_bytes) => binary(),
          required(:file_name) => String.t(),
          required(:content_type) => String.t(),
          required(:uploaded_by) => Ecto.UUID.t(),
          optional(:description) => String.t() | nil
        }

  @doc """
  Uploads an attachment: hashes `raw_bytes` independently (byte-identity
  only, no canonicalisation), upserts a `repository_artifacts` row keyed by
  that hash (creating or reusing it, including the real bytes into its
  `content` column), and inserts one `instance_attachments` row referencing
  it.

  Steps (design §4.1):

    1. Computes `byte_size = byte_size(raw_bytes)` -- never a caller-supplied
       field. If it exceeds `#{@max_upload_bytes}` bytes (25 MiB,
       `@max_upload_bytes`), returns `{:error, :file_too_large}`
       immediately, before any hashing, upsert, or insert is attempted --
       neither a `repository_artifacts` row nor an `instance_attachments`
       row is created.
    2. Computes `content_hash = :crypto.hash(:sha256, raw_bytes)` --
       byte-identity hashing only, unconditionally, regardless of
       `content_type` (see moduledoc's no-canonicalisation statement).
    3. Upserts the `repository_artifacts` row via
       `Letflow.Repository.upsert_content/6`, in the same tenant's schema.
    4. Derives `tenant_id` from `opts[:prefix]`.
    5. Inserts the `instance_attachments` row.

  Uploading byte-identical content twice (same or different `instance_id`)
  reuses the same `repository_artifacts` row (step 3's upsert) while step 5
  always inserts a fresh `instance_attachments` row -- so two calls
  necessarily produce one `repository_artifacts` row and two
  `instance_attachments` rows, by construction, not by a special-cased
  check (AC2).
  """
  @spec upload(upload_attrs(), opts()) ::
          {:ok, Attachment.t()}
          | {:error, :file_too_large}
          | {:error, Ecto.Changeset.t()}
  def upload(attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    raw_bytes = Map.fetch!(attrs, :raw_bytes)
    measured_byte_size = byte_size(raw_bytes)

    if measured_byte_size > @max_upload_bytes do
      {:error, :file_too_large}
    else
      content_hash = :crypto.hash(:sha256, raw_bytes)
      content_type = Map.fetch!(attrs, :content_type)

      with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
        Repo.transaction(fn ->
          Repository.upsert_content(
            prefix,
            tenant_id,
            content_hash,
            content_type,
            measured_byte_size,
            raw_bytes
          )

          insert_attrs = %{
            tenant_id: tenant_id,
            instance_id: Map.fetch!(attrs, :instance_id),
            content_hash: content_hash,
            file_name: Map.fetch!(attrs, :file_name),
            content_type: content_type,
            byte_size: measured_byte_size,
            uploaded_by: Map.fetch!(attrs, :uploaded_by),
            description: Map.get(attrs, :description)
          }

          %Attachment{}
          |> Attachment.changeset(insert_attrs)
          |> Repo.insert(prefix: prefix)
          |> case do
            {:ok, attachment} -> attachment
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)
        |> case do
          {:ok, attachment} -> {:ok, attachment}
          {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        end
      end
    end
  end

  # ===========================================================================
  # list/2 (design §4.2)
  # ===========================================================================

  @type list_params :: %{
          required(:instance_id) => Ecto.UUID.t(),
          cursor: String.t() | nil,
          page_size: pos_integer()
        }

  @doc """
  Cursor-paginated listing of `instance_attachments`, tenant-scoped
  (`opts[:prefix]`) and filtered by `instance_id` (required, always scopes
  to one instance). Ordered `(created_at desc, id desc)`, matching the
  migration's own index shape, `page_size + 1` fetch-and-drop-extra exactly
  as `Letflow.Dlq.list/2` does, per REQ-067's cursor contract.

  **Tenant scoping (AC5's first clause):** `opts[:prefix]` alone scopes the
  query to one tenant's Postgres schema -- structurally, a `list/2` call
  scoped to tenant B's prefix cannot return any row physically stored in
  tenant A's schema. **Instance scoping (AC5's second clause):** the
  `instance_id` filter is a `WHERE` predicate within that already-tenant-
  scoped query -- an attachment uploaded under `instance_id X` is absent
  from a `list/2` call for the same tenant's `instance_id Y`.
  """
  @spec list(list_params(), opts()) ::
          {:ok, %{items: [Attachment.t()], next_cursor: String.t() | nil}}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired | :page_size_too_large}
  def list(params, opts) when is_map(params) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    instance_id = Map.fetch!(params, :instance_id)

    with {:ok, page_size} <- Pagination.validate_page_size(Map.get(params, :page_size)),
         {:ok, cursor_seek} <- decode_list_cursor(Map.get(params, :cursor)) do
      rows =
        Attachment
        |> where([a], a.instance_id == ^instance_id)
        |> filter_by_list_cursor(cursor_seek)
        |> order_by([a], desc: a.created_at, desc: a.id)
        |> limit(^(page_size + 1))
        |> Repo.all(prefix: prefix)

      {page, next_cursor} = split_list_page(rows, page_size)

      {:ok, %{items: page, next_cursor: next_cursor}}
    end
  end

  # ===========================================================================
  # get/2 (design §4.3)
  # ===========================================================================

  @doc """
  Tenant-scoped fetch of one attachment's metadata (not byte content),
  mirroring `Letflow.Dlq.get/2`/`Letflow.Webhooks.get/2`'s shared idiom
  exactly: `Ecto.UUID.cast/1` first (`{:error, :invalid_id}`, no DB
  round-trip), then a prefix-scoped fetch (`{:error, :not_found}` for both
  "does not exist" and "exists in another tenant's schema").

  A future REQ-212 route handler retrieves an attachment's bytes by calling
  this function (or `list/2`) to obtain `attachment.content_hash`, then
  performing a second, separate lookup against `repository_artifacts`'s own
  `content` column (design §4.3) -- this module never reads
  `repository_artifacts` itself, keeping this call cheap and single-table.
  """
  @spec get(id :: String.t(), opts()) ::
          {:ok, Attachment.t()} | {:error, :invalid_id | :not_found}
  def get(id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Ecto.UUID.cast(id) do
      :error ->
        {:error, :invalid_id}

      {:ok, id} ->
        case Repo.get(Attachment, id, prefix: prefix) do
          nil -> {:error, :not_found}
          %Attachment{} = attachment -> {:ok, attachment}
        end
    end
  end

  # ===========================================================================
  # delete/2 (design §4.5)
  # ===========================================================================

  @doc """
  Tenant-scoped hard delete of the `instance_attachments` row **only** --
  mirrors `Letflow.Webhooks.delete/2`'s shape exactly: reuses `get/2` for
  id-validation/tenant-scoped-existence, then `Repo.delete/2` on the fetched
  struct. The underlying `repository_artifacts` row referenced by
  `content_hash` is never deleted by this function -- no code path here
  calls `Repo.delete/2` (or any other mutation) against
  `Letflow.Repository.Artifact` (see moduledoc's metadata-only-delete
  rationale).
  """
  @spec delete(id :: String.t(), opts()) ::
          {:ok, Attachment.t()} | {:error, :invalid_id | :not_found}
  def delete(id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, attachment} <- get(id, opts) do
      Repo.delete(attachment, prefix: prefix)
    end
  end

  # ── list/2 private helpers ──────────────────────────────────────────────

  defp filter_by_list_cursor(query, nil), do: query

  defp filter_by_list_cursor(query, {created_at_us, id}) do
    ts = DateTime.from_unix!(created_at_us, :microsecond)
    from(a in query, where: {a.created_at, a.id} < {^ts, ^id})
  end

  @spec decode_list_cursor(String.t() | nil) ::
          {:ok, {non_neg_integer(), String.t()} | nil}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired}
  defp decode_list_cursor(nil), do: {:ok, nil}

  defp decode_list_cursor(raw) when is_binary(raw) do
    case Pagination.decode_cursor(raw, @list_cursor_prefix, byte_size(@list_cursor_prefix)) do
      {:ok, %Pagination.Cursor{} = cursor} -> {:ok, decode_seek(cursor)}
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  defp decode_seek(%Pagination.Cursor{inner: inner}) do
    prefix_len = byte_size(@list_cursor_prefix)
    rest = binary_part(inner, prefix_len, byte_size(inner) - prefix_len)
    [ts_str, id_str] = String.split(rest, ":", parts: 2)
    {String.to_integer(ts_str), id_str}
  end

  defp split_list_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_list_next_cursor(List.last(page))}
  end

  defp split_list_page(rows, _page_size), do: {rows, nil}

  defp build_list_next_cursor(%Attachment{id: id, created_at: created_at}) do
    created_at_us = DateTime.to_unix(created_at, :microsecond)

    @list_cursor_prefix
    |> Pagination.build_raw_cursor(created_at_us, id)
    |> Pagination.encode_cursor()
  end
end
