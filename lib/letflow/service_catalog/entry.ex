defmodule Letflow.ServiceCatalog.Entry do
  @moduledoc """
  Ecto schema for the `service_catalog` table. See
  `lib/letflow/design/req191-service-catalog-core.md` §2. Ordinary
  `Ecto.Schema`, no process — matches `Letflow.Dlq.Entry`'s plain-CRUD-table
  precedent.

  ## `service_id` — a caller-supplied string primary key (deliberate divergence)

  `@primary_key {:service_id, :string, autogenerate: false}` — the first
  schema in this codebase whose primary key is a caller-supplied string
  rather than a `binary_id`. Justified by SVC-01's own global-uniqueness
  rule making `service_id` the natural key: there is no separate surrogate
  id anywhere in the requirement text, R-Co's migration, or the wire
  contract. This also gives global `service_id` uniqueness across every
  tenant and both scopes for free, via the PK's own DB-level uniqueness --
  no separate unique index needed.

  ## GLOBAL table — divergence from decision 0003 Decision B

  This table lives in the default/public schema, not behind any tenant
  schema prefix (see the migration's own header comment and
  `Letflow.ServiceCatalog`'s moduledoc for the full R-Co-grounded reasoning
  and REVIEWER-sign-off flag). No `@schema_prefix` is declared, and no
  function in `Letflow.ServiceCatalog` accepts an `opts[:prefix]` — unlike
  every other S6 context module, this one's backing table has no per-tenant
  schema to scope into.

  ## `created_at`/`updated_at`, not `timestamps/1`

  Same reasoning as `Letflow.Dlq.Entry`'s own moduledoc section: the wire
  contract (`web/src/types/api.ts`'s `ServiceRecord.created_at`/`updated_at`)
  fixes these column names, which don't match `timestamps/1`'s default
  `inserted_at`/`updated_at` pair, so both fields are declared explicitly
  and stamped by `Letflow.ServiceCatalog` itself (`register/1` stamps both,
  `update_scope/2` stamps `updated_at` only) rather than relying on
  `timestamps/1`'s automatic behaviour.

  ## Changeset-level checks are advisory only

  `insert_changeset/2` and `update_scope_changeset/2` duplicate the
  migration's DB-level `CHECK` constraints (length, enum, range, scope/owner
  consistency) at the changeset level for a fast, friendly pre-flight error
  — but the DB constraint is the one REQ-191's acceptance criteria actually
  test against and is authoritative; these changeset checks never replace
  it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:service_id, :string, autogenerate: false}
  schema "service_catalog" do
    field(:endpoint_url, :string)
    field(:request_schema, :string)
    field(:response_schema, :string)

    field(:required_auth, Ecto.Enum,
      values: [:NONE, :API_KEY, :OAUTH2, :MUTUAL_TLS],
      default: :NONE
    )

    field(:timeout_ms, :integer)
    field(:retry_policy, :string)
    field(:scope, Ecto.Enum, values: [:global, :tenant], default: :global)
    field(:owner_tenant_id, Ecto.UUID)

    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @castable_fields [
    :service_id,
    :endpoint_url,
    :request_schema,
    :response_schema,
    :required_auth,
    :timeout_ms,
    :retry_policy,
    :scope,
    :owner_tenant_id
  ]

  @doc """
  Changeset for `Letflow.ServiceCatalog.register/1`. `created_at`/
  `updated_at` are never castable from caller input -- always stamped by the
  context module, mirroring `process_definitions.status`'s "never castable
  from caller input" discipline for its own timestamp pair.
  """
  @spec insert_changeset(t(), map()) :: Ecto.Changeset.t()
  def insert_changeset(entry, attrs) do
    entry
    |> cast(attrs, @castable_fields)
    |> validate_required([:service_id, :endpoint_url, :required_auth, :timeout_ms, :scope])
    |> validate_length(:service_id, max: 255)
    |> validate_length(:endpoint_url, max: 2048)
    |> validate_number(:timeout_ms,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 3_600_000
    )
    |> unique_constraint(:service_id, name: :service_catalog_pkey)
    |> foreign_key_constraint(:owner_tenant_id)
    |> check_constraint(:owner_tenant_id,
      name: :chk_service_catalog_scope_owner_consistency,
      message: "scope/owner_tenant_id combination is invalid"
    )
  end

  @doc """
  Changeset for `Letflow.ServiceCatalog.update_scope/2` -- casts only
  `scope`/`owner_tenant_id`, per design §2.
  """
  @spec update_scope_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_scope_changeset(entry, attrs) do
    entry
    |> cast(attrs, [:scope, :owner_tenant_id])
    |> validate_required([:scope])
    |> foreign_key_constraint(:owner_tenant_id)
    |> check_constraint(:owner_tenant_id,
      name: :chk_service_catalog_scope_owner_consistency,
      message: "scope/owner_tenant_id combination is invalid"
    )
  end
end
