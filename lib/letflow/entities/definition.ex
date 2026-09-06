defmodule Letflow.Entities.Definition do
  @moduledoc """
  The `entity_definition()` document shape and its nested
  `field_def()`/`index_def()`/`fk_def()`/`constraint_def()` shapes (REQ-225).
  See `lib/letflow/design/req225-entity-definition-schema-validation.md` §2
  for the full design this module implements.

  This is a **document shape**, not an `Ecto.Schema` -- REQ-226 owns the
  persisted `entity_definitions` table; this module only describes the
  shape of the JSON blob that becomes that table's `definition_json`
  column. No persistence, no CRUD, no migration lives here (REQ-226's job).

  ## Entity-type ownership model: tenant-scoped (design §1)

  An `entity_definition()` belongs to exactly one tenant. This module itself
  takes no `tenant_id` and performs no cross-definition/cross-tenant
  lookups -- tenant scoping is enforced by REQ-226's context module, the
  same division of responsibility `Letflow.Repository.Canonicaliser` already
  has relative to `Letflow.Repository`.
  """

  @typedoc "Top-level entity definition document. See moduledoc for the tenant-scoping decision."
  @type t :: %{
          required(:name) => String.t(),
          required(:display_name) => String.t(),
          optional(:description) => String.t(),
          required(:fields) => [field_def()],
          optional(:indexes) => [index_def()],
          optional(:foreign_keys) => [fk_def()],
          optional(:constraints) => [constraint_def()]
        }

  @typedoc "One field in an entity definition's `fields` list."
  @type field_def :: %{
          required(:name) => String.t(),
          required(:type) => field_type(),
          optional(:required) => boolean(),
          optional(:queried) => boolean(),
          optional(:enum_values) => [String.t()],
          optional(:decimal_precision) => pos_integer(),
          optional(:decimal_scale) => non_neg_integer(),
          optional(:default) => term()
        }

  @typedoc """
  The closed set of field types this slice supports. `:json` is the one type
  that Rule 3 (`Letflow.Entities.Definition.Validator`) treats specially: a
  `:json` field may never also be `queried: true`.
  """
  @type field_type :: :string | :integer | :decimal | :boolean | :date | :datetime | :enum | :json

  @typedoc "One entry in an entity definition's `indexes` list."
  @type index_def :: %{
          required(:name) => String.t(),
          required(:fields) => [String.t(), ...],
          optional(:unique) => boolean()
        }

  @typedoc "One entry in an entity definition's `foreign_keys` list."
  @type fk_def :: %{
          required(:name) => String.t(),
          required(:field) => String.t(),
          required(:references_entity) => String.t(),
          optional(:references_field) => String.t()
        }

  @typedoc "One entry in an entity definition's `constraints` list."
  @type constraint_def :: %{
          required(:name) => String.t(),
          required(:type) => :unique,
          required(:fields) => [String.t(), ...]
        }
end
