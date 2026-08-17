defmodule Letflow.Definitions do
  @moduledoc """
  Context module for definition-related read/compute functions. See
  `lib/letflow/design/req041-pack-update-diff-schema.md` §5.3 for
  `compute_pack_update_plan/5`'s full reasoning.

  **This file did not exist before REQ-041.** The design (§5.3) names
  `Letflow.Definitions` as "the existing context module this batch's
  functions all attach to," citing `req035` §5.1 as having already
  established it as the expected home for `compute_pack_update_plan/5` by
  name — but no `lib/letflow/definitions.ex` context-module file was actually
  present in this codebase prior to this requirement (only schema submodules
  under `lib/letflow/definitions/`, e.g. `ProcessDefinition`,
  `PromotionReview`). REQ-036, whose `compute_promotion_plan/5` would have
  been this module's first function, is still `status: pending`
  (`docs/requirements.yaml`). REQ-041 creates this file; noted here as a
  deviation-from-assumption worth flagging honestly, not a silent one — the
  module name, namespace and this function's placement all match the design
  exactly, only the file's prior existence was assumed incorrectly.

  ## Scope

  `compute_pack_update_plan/5` and `classify_artefact/3` (REQ-041), `create/2`,
  `get_by_id/2`, `get_active_by_name/2`, `list/2`, `activate/2`, `deprecate/2`,
  `archive/2` (REQ-030), and `search/2` (REQ-042) together make up this module's
  current public API. See `lib/letflow/design/req030-definition-store-crud.md` for
  the full design the REQ-030 functions implement, and
  `lib/letflow/design/search.md` for `search/2`'s.

  ## `tenant_id` is always derived, never accepted (REQ-030)

  `create/2`'s `attrs` never accepts a `:tenant_id` (or `"tenant_id"`) key -- a caller
  supplying one gets `{:error, :tenant_id_not_accepted}`, not a silently-overridden value.
  `tenant_id` is always derived from `opts[:prefix]` via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`, mirroring
  `Letflow.EventStore.append/2`'s identical contract (see
  `lib/letflow/design/req025-event-append.md` and
  `docs/migration/decisions/0003-ecto-schema-strategy.md`'s 2026-08-17 addendum).

  ## `activate/2`'s `service_scope_validator` option -- the SVC-03 integration point (REQ-031)

  `activate/2` accepts an optional `:service_scope_validator` key in its `opts`, a 2-arity
  function `(Letflow.Definitions.Graph.t(), tenant_id) -> :ok | {:error, term()}` or `nil`
  (the default). When present, it is called once, only when the target definition's current
  status is `:draft` (never on the already-active no-op path, never on a rejected
  non-draft transition), after the row lock is acquired and before either of the two
  transition UPDATEs run. A `{:error, reason}` return aborts the whole activation with
  `{:error, {:service_scope_violation, reason}}` and writes nothing. **This module builds
  only the injection point** -- the hook's own logic (walking SERVICE_TASK nodes, checking
  tenant/service/plugin scope) is REQ-031's job, not implemented here.

  ## `search/2` -- full-text search over `name`/`description` (REQ-042)

  `search/2` (REQ-042) adds definition full-text search over `process_definitions`'
  `name`/`description` columns via `ILIKE` ranking, ported from `store.zig`'s
  `Store.search()` per `src/design/definition.md`'s PD-10 section. **PD-10 states
  explicitly that search lives inside the existing store -- no new Zig source file or SQL
  migration is required**, and this port adds zero new `priv/repo/migrations/` files and
  zero new indexes (no `idx_def_name`, no GIN/`tsvector` index) -- the query runs against
  `process_definitions` exactly as REQ-027 shipped it.
  """

  import Ecto.Query

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.PackUpdateResolution
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Definitions.PromotionReviewStore
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @type artefact_key :: %{artefact_type: String.t(), artefact_id: String.t()}
  @type artefact_input :: %{
          artefact_type: String.t(),
          artefact_id: String.t(),
          # canonical-JSON text, caller's responsibility -- see
          # classify_artefact/3's @doc and design §5.4/OQ-1.
          content: String.t()
        }
  @type classification :: :unchanged | :clean_update | :local_only | :conflict

  @type plan_entry :: %{
          artefact_type: String.t(),
          artefact_id: String.t(),
          classification: classification(),
          # nil iff no solution_pack_artefact_bases row -- AC2.
          base: String.t() | nil,
          # nil iff artefact absent from theirs_artefacts.
          theirs: String.t() | nil,
          # nil iff artefact absent from incoming_artefacts.
          incoming: String.t() | nil,
          # only meaningful when classification == :conflict; true iff a
          # matching pack_update_resolutions row exists (AC4) -- always false
          # for non-conflict entries.
          resolved: boolean()
        }

  @type plan :: %{
          tenant_id: Ecto.UUID.t(),
          pack_id: String.t(),
          incoming_version: String.t(),
          entries: [plan_entry()],
          has_unresolved_conflicts: boolean()
        }

  # ---------------------------------------------------------------------------------
  # REQ-030 types -- lib/letflow/design/req030-definition-store-crud.md §4.0
  # ---------------------------------------------------------------------------------

  @type opts :: [prefix: String.t()]

  @type status :: ProcessDefinition.status()

  @type service_scope_validator_fun ::
          (Graph.t(), tenant_id :: Ecto.UUID.t() -> :ok | {:error, term()})

  @type activate_opts :: [
          prefix: String.t(),
          service_scope_validator: service_scope_validator_fun() | nil
        ]

  @type common_error ::
          {:error, :invalid_schema_name}
          | {:error, {:transaction_failed, term()}}

  @type create_attrs :: %{
          required(:name) => String.t(),
          required(:version) => String.t(),
          optional(:description) => String.t() | nil,
          required(:graph) => map(),
          required(:created_by) => Ecto.UUID.t(),
          optional(:stage) => String.t() | nil
        }

  @type create_error ::
          {:error, :tenant_id_not_accepted}
          | {:error, :initial_status_not_draft}
          | {:error, :name_invalid}
          | {:error, :version_empty}
          | {:error, :graph_structure_invalid}
          | {:error, {:graph_validation_failed, [Graph.Violation.t()]}}
          | {:error, :duplicate_name_version}
          | {:error, Ecto.Changeset.t()}
          | common_error()

  @type list_filters :: %{
          optional(:name) => String.t() | nil,
          optional(:status) => status() | nil,
          optional(:stage) => String.t() | nil,
          optional(:after_created) => DateTime.t() | nil,
          optional(:limit) => pos_integer() | nil
        }

  # ---------------------------------------------------------------------------------
  # REQ-042 types -- lib/letflow/design/search.md §3
  # ---------------------------------------------------------------------------------

  @type search_opts :: [
          prefix: String.t(),
          limit: pos_integer() | nil,
          offset: non_neg_integer() | nil
        ]

  @type search_result :: %{
          definition: ProcessDefinition.t(),
          # 3.0 (exact name match), 2.0 (partial name match) or 1.0
          # (description-only match) -- see search/2's @doc, never any other value.
          rank: float()
        }

  @type search_error ::
          {:error, :query_empty}
          | {:error, :query_too_long}
          | common_error()

  @doc """
  Computes a solution-pack update three-way diff plan for one tenant's
  install of one pack against an offered incoming version, per
  `lib/letflow/design/req041-pack-update-diff-schema.md` §5.3.

  Read-only — performs no mutation (INV-PU-5). Queries
  `solution_pack_artefact_bases` (the `base` lookup, by `(tenant_id, pack_id,
  artefact_type, artefact_id)`) and `pack_update_resolutions` (the
  `has_unresolved_conflicts` lookup, by `(tenant_id, pack_id, target_version:
  incoming_version, artefact_type, artefact_id)`) but writes neither those nor
  `solution_pack_installs`.

  `theirs_artefacts`/`incoming_artefacts` are caller-supplied — no real
  install/export path exists yet to source them from (SOL-01/02/03, unscoped).
  `base` is never caller-supplied: it is always looked up from
  `solution_pack_artefact_bases` by this function itself, because AC2's core
  assertion (an artefact with no matching base row classifies `:conflict`) is
  a statement about this function's own DB-lookup behavior, not about a value
  a caller chooses to omit.

  The artefact set processed is the union of `theirs_artefacts`' and
  `incoming_artefacts`' `{artefact_type, artefact_id}` keys, in first-seen
  order (theirs first, then incoming) — an artefact named in neither list is
  not represented in the returned plan at all.

  Returns `{:error, :empty_artefact_set}` when both `theirs_artefacts` and
  `incoming_artefacts` are `[]` — an empty result would otherwise be
  ambiguous between "nothing changed" and "caller passed no data by
  mistake" (mirrors REQ-036's `compute_promotion_plan/5`'s empty-plan error;
  design §5.3, flagged there as this design's own addition, not a literal
  REQ-041 acceptance-criterion mandate).
  """
  @spec compute_pack_update_plan(
          tenant_id :: Ecto.UUID.t(),
          pack_id :: String.t(),
          incoming_version :: String.t(),
          theirs_artefacts :: [artefact_input()],
          incoming_artefacts :: [artefact_input()]
        ) :: {:ok, plan()} | {:error, :empty_artefact_set}
  def compute_pack_update_plan(_tenant_id, _pack_id, _incoming_version, [], []) do
    {:error, :empty_artefact_set}
  end

  def compute_pack_update_plan(
        tenant_id,
        pack_id,
        incoming_version,
        theirs_artefacts,
        incoming_artefacts
      ) do
    theirs_by_key = index_by_key(theirs_artefacts)
    incoming_by_key = index_by_key(incoming_artefacts)

    keys =
      (theirs_artefacts ++ incoming_artefacts)
      |> Enum.map(&{&1.artefact_type, &1.artefact_id})
      |> Enum.uniq()

    entries =
      Enum.map(keys, fn {artefact_type, artefact_id} = key ->
        base = fetch_base(tenant_id, pack_id, artefact_type, artefact_id)
        theirs = Map.get(theirs_by_key, key)
        incoming = Map.get(incoming_by_key, key)
        classification = classify_artefact(base, theirs, incoming)

        resolved =
          classification == :conflict and
            resolution_exists?(tenant_id, pack_id, incoming_version, artefact_type, artefact_id)

        %{
          artefact_type: artefact_type,
          artefact_id: artefact_id,
          classification: classification,
          base: base,
          theirs: theirs,
          incoming: incoming,
          resolved: resolved
        }
      end)

    has_unresolved_conflicts =
      Enum.any?(entries, &(&1.classification == :conflict and not &1.resolved))

    {:ok,
     %{
       tenant_id: tenant_id,
       pack_id: pack_id,
       incoming_version: incoming_version,
       entries: entries,
       has_unresolved_conflicts: has_unresolved_conflicts
     }}
  end

  @doc """
  Classifies one artefact's three-way diff, per
  `lib/letflow/design/req041-pack-update-diff-schema.md` §5.3's truth table.
  Pure — no I/O, independently testable without DB fixtures or the full
  5-argument `compute_pack_update_plan/5` orchestration.

  `base`/`theirs`/`incoming` are compared by **byte-level string equality**
  over content that MUST already be canonical-JSON text by the time it
  reaches this function (sorted keys, no insignificant whitespace) —
  REQ-041's own description says this comparison uses "same normalization as
  REQ-036's plan digest," but REQ-036's `compute_plan_digest/1` is
  `status: pending` and has no shared canonicalization helper to call yet
  (design §5.4, OQ-1). This function does not parse, re-serialize, or
  normalize anything itself, and does not reimplement REQ-036's
  canonicalization as a private duplicate — that would risk drifting from
  REQ-036's real implementation once it ships.

  `nil` is never treated as equal to any other value, including another
  `nil` compared against a third non-nil value. A `nil` `base` (no matching
  `solution_pack_artefact_bases` row) always classifies `:conflict`,
  regardless of `theirs`/`incoming` — REQ-041 acceptance criterion 2 /
  INV-PU-2, "cannot prove no modification" (PRM-09 AC5).

  | `base` | `base == theirs` | `base == incoming` | Result |
  |---|---|---|---|
  | non-nil | true | true | `:unchanged` |
  | non-nil | true | false | `:clean_update` |
  | non-nil | false | true | `:local_only` |
  | non-nil | false | false | `:conflict` |
  | `nil` | — | — | `:conflict` (always) |
  """
  @spec classify_artefact(
          base :: String.t() | nil,
          theirs :: String.t() | nil,
          incoming :: String.t() | nil
        ) :: classification()
  def classify_artefact(nil, _theirs, _incoming), do: :conflict
  def classify_artefact(base, base, base), do: :unchanged
  def classify_artefact(base, base, _incoming), do: :clean_update
  def classify_artefact(base, _theirs, base), do: :local_only
  def classify_artefact(_base, _theirs, _incoming), do: :conflict

  defp index_by_key(artefacts) do
    Map.new(artefacts, fn %{artefact_type: type, artefact_id: id, content: content} ->
      {{type, id}, content}
    end)
  end

  defp fetch_base(tenant_id, pack_id, artefact_type, artefact_id) do
    SolutionPackArtefactBase
    |> Repo.get_by(
      tenant_id: tenant_id,
      pack_id: pack_id,
      artefact_type: artefact_type,
      artefact_id: artefact_id
    )
    |> case do
      nil -> nil
      %SolutionPackArtefactBase{base_content: base_content} -> base_content
    end
  end

  defp resolution_exists?(tenant_id, pack_id, target_version, artefact_type, artefact_id) do
    not is_nil(
      Repo.get_by(PackUpdateResolution,
        tenant_id: tenant_id,
        pack_id: pack_id,
        target_version: target_version,
        artefact_type: artefact_type,
        artefact_id: artefact_id
      )
    )
  end

  # ===================================================================================
  # REQ-030 -- Definition store CRUD
  # lib/letflow/design/req030-definition-store-crud.md
  # ===================================================================================

  @doc """
  Creates a new DRAFT process definition, per PD-01/PD-02/PD-05/PD-06.

  `tenant_id` is never accepted in `attrs` -- it is always derived from
  `opts[:prefix]` (see this module's moduledoc). `attrs[:graph]` must pass all three
  of `Letflow.Definitions.Graph.validate_graph/1`, `validate_node_attributes/1` and
  `validate_edge_conditions/1` before anything is written (INV-DS-3): on the first
  failing phase, returns `{:error, {:graph_validation_failed, violations}}` and writes
  zero rows.

  Two concurrent calls with an identical `(name, version)` never both succeed: the
  `uq_definition_version` unique index is the targeted `ON CONFLICT` arbiter, and the
  loser gets `{:error, :duplicate_name_version}` -- neither caller is told which one
  "won" (design §4.1 P11/P12).
  """
  @spec create(attrs :: create_attrs(), opts :: opts()) ::
          {:ok, ProcessDefinition.t()} | create_error()
  def create(attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with :ok <- reject_key(attrs, :tenant_id, "tenant_id", :tenant_id_not_accepted),
         :ok <- reject_key(attrs, :status, "status", :initial_status_not_draft),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, _name} <- fetch_name(attrs),
         {:ok, _version} <- fetch_version(attrs),
         {:ok, graph_map} <- fetch_graph_map(attrs),
         {:ok, graph} <- convert_graph(graph_map),
         :ok <- check_graph_result(Graph.validate_graph(graph)),
         :ok <- check_graph_result(Graph.validate_node_attributes(graph)),
         :ok <- check_graph_result(Graph.validate_edge_conditions(graph)) do
      insert_definition(attrs, tenant_id, prefix)
    end
  end

  @doc """
  Fetches one process definition by `id`, within the tenant schema named by
  `opts[:prefix]`. `{:error, :not_found}` both for a missing row and for an `id` that
  isn't a well-formed UUID (design §4.2 step 2).
  """
  @spec get_by_id(id :: Ecto.UUID.t(), opts :: opts()) ::
          {:ok, ProcessDefinition.t()} | {:error, :not_found} | common_error()
  def get_by_id(id, opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, uuid} <- cast_uuid(id) do
      case Repo.get(ProcessDefinition, uuid, prefix: prefix) do
        nil -> {:error, :not_found}
        %ProcessDefinition{} = found -> {:ok, found}
      end
    end
  end

  @doc """
  Fetches the single ACTIVE process definition for `name`, per PD-07. A `name` whose
  only rows are DRAFT/DEPRECATED/ARCHIVED returns `{:error, :not_found}` -- there is no
  fallback to "the most recent non-active row" (design §4.3, AC7).
  """
  @spec get_active_by_name(name :: String.t(), opts :: opts()) ::
          {:ok, ProcessDefinition.t()} | {:error, :not_found} | common_error()
  def get_active_by_name(name, opts) when is_binary(name) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      ProcessDefinition
      |> where([d], d.name == ^name and d.status == :active)
      |> Repo.all(prefix: prefix)
      |> case do
        [] -> {:error, :not_found}
        [found | _rest] -> {:ok, found}
      end
    end
  end

  @doc """
  Lists process definitions, newest first, filtered by any combination of `:name`
  (substring, `ILIKE`), `:status` (exact), `:stage` (exact -- AC8) and `:after_created`
  (strictly-after cursor, ported skip-risk and all -- design §4.4/§9 OQ-2), each an
  independent `AND`-joined predicate. Always `{:ok, list}`, an empty list on no matches,
  never an error.
  """
  @spec list(filters :: list_filters(), opts :: opts()) ::
          {:ok, [ProcessDefinition.t()]} | common_error()
  def list(filters, opts) when is_map(filters) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      effective_limit = effective_limit(Map.get(filters, :limit))

      query =
        ProcessDefinition
        |> where_name(Map.get(filters, :name))
        |> where_status(Map.get(filters, :status))
        |> where_stage(Map.get(filters, :stage))
        |> where_after_created(Map.get(filters, :after_created))
        |> order_by([d], desc: d.created_at)
        |> limit(^effective_limit)

      {:ok, Repo.all(query, prefix: prefix)}
    end
  end

  @doc """
  Activates a DRAFT process definition (PD-03), atomically deprecating any prior
  ACTIVE definition sharing the same `name` in the same transaction (AC3). Called on
  an already-ACTIVE definition, this is a no-op that returns
  `{:ok, %{definition: ..., already_active: true}}` -- never an error, on every call
  (AC4). Rejects every other current status as `{:error, :not_draft}` (PD-04).

  `opts[:service_scope_validator]` is the SVC-03 integration point -- see this
  module's moduledoc.
  """
  @spec activate(id :: Ecto.UUID.t(), opts :: activate_opts()) ::
          {:ok, %{definition: ProcessDefinition.t(), already_active: boolean()}}
          | {:error, :not_found}
          | {:error, :not_draft}
          | {:error, :graph_structure_invalid}
          | {:error, {:service_scope_violation, reason :: term()}}
          | common_error()
  def activate(id, opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix)
    validator = Keyword.get(opts, :service_scope_validator)

    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      try do
        id
        |> run_activate_transaction(prefix, tenant_id, validator)
        |> interpret_activate_result()
      rescue
        exception -> {:error, {:transaction_failed, exception}}
      end
    end
  end

  @doc """
  Transitions an ACTIVE process definition to DEPRECATED (PD-04). Every other current
  status is rejected as `{:error, :invalid_status_transition}`; a missing `id` is
  `{:error, :not_found}`.
  """
  @spec deprecate(id :: Ecto.UUID.t(), opts :: opts()) ::
          {:ok, ProcessDefinition.t()}
          | {:error, :not_found}
          | {:error, :invalid_status_transition}
          | common_error()
  def deprecate(id, opts) when is_list(opts) do
    transition(id, opts, :active, :deprecated)
  end

  @doc """
  Transitions a DEPRECATED process definition to ARCHIVED (PD-04), stamping
  `archived_at`. Every other current status is rejected as
  `{:error, :invalid_status_transition}`; a missing `id` is `{:error, :not_found}`.
  """
  @spec archive(id :: Ecto.UUID.t(), opts :: opts()) ::
          {:ok, ProcessDefinition.t()}
          | {:error, :not_found}
          | {:error, :invalid_status_transition}
          | common_error()
  def archive(id, opts) when is_list(opts) do
    transition(id, opts, :deprecated, :archived)
  end

  @doc """
  Searches process definitions by `name`/`description` substring, ranked, per PD-10 --
  see `lib/letflow/design/search.md`. A row matches iff `name` or `description`
  case-insensitively contains `query` (`ILIKE '%query%'`, `%` composed into the bound
  parameter value, never spliced into the query text -- INV-SR-2). Ranked `3.0` for an
  exact case-insensitive `name` match, `2.0` for a partial `name` match, `1.0` for a
  match found only via `description`; ordered `rank DESC, created_at DESC`.

  `query` is validated before any DB access: an empty string is `{:error, :query_empty}`
  (no trimming -- a whitespace-only query is not treated as empty, it simply matches
  nothing), and a query longer than 512 bytes is `{:error, :query_too_long}` (byte
  length, matching this module's other manual checks -- design §4/OQ-1).

  `limit` (default 20) / `offset` (default 0) paginate the ranked result, applied
  unclamped -- unlike `list/2`'s `effective_limit/1`, this function does not cap
  `:limit` to any maximum; rejecting an out-of-range `limit` is the S4 HTTP handler's
  job (design §7). Always `{:ok, list}`, an empty list on no match, never an error for
  that case.
  """
  @spec search(query :: String.t(), opts :: search_opts()) ::
          {:ok, [search_result()]} | search_error()
  def search(query, opts) when is_binary(query) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with :ok <- check_query_not_empty(query),
         :ok <- check_query_not_too_long(query),
         {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      pattern = "%" <> query <> "%"
      effective_limit = Keyword.get(opts, :limit) || 20
      effective_offset = Keyword.get(opts, :offset) || 0

      ecto_query =
        ProcessDefinition
        |> where_search_match(pattern)
        |> select_with_rank(query, pattern)
        |> order_by_rank(query, pattern)
        |> limit(^effective_limit)
        |> offset(^effective_offset)

      {:ok, Repo.all(ecto_query, prefix: prefix)}
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-038 types -- lib/letflow/design/req038-promotion-rollback.md §2
  # ---------------------------------------------------------------------------------

  @type permission_checker_fun ::
          (actor_id :: Ecto.UUID.t(), tenant_id :: Ecto.UUID.t() -> boolean())

  @type event_appender_fun ::
          (event_attrs :: map(), prefix :: String.t() ->
             {:ok, %{event_id: Ecto.UUID.t()}} | {:error, term()})

  @type rollback_opts :: [
          prefix: String.t(),
          permission_checker: permission_checker_fun(),
          event_appender: event_appender_fun()
        ]

  @type rollback_result :: %{
          definition_id: Ecto.UUID.t(),
          version: String.t(),
          rolled_back_from_version: String.t(),
          superseded_review_id: Ecto.UUID.t() | nil,
          event_id: Ecto.UUID.t()
        }

  @type rollback_error ::
          {:error, :forbidden}
          | {:error, :process_key_not_found}
          | {:error, :version_never_active}
          | {:error, :already_active}
          | {:error, term()}
          | common_error()

  @doc """
  Rolls back `process_key` to `target_version`, per
  `lib/letflow/design/req038-promotion-rollback.md` (ported from R-Co's
  `src/definition/rollback.zig`, PRM-08).

  `tenant_id` is never a separate argument -- derived from `opts[:prefix]`, same as
  every other function in this module (design §2 arity note). `opts[:permission_checker]`
  and `opts[:event_appender]` are both `Keyword.fetch!/2`'d -- no built-in default for
  either, raises `KeyError` if omitted, same no-default stance `Promotion.promote_definition/3`
  already established (design §4).

  `opts[:permission_checker].(actor_id, tenant_id)` is checked before any row is read or
  locked (AC5, INV-RB-1): a `false` result returns `{:error, :forbidden}` immediately, no
  transaction opened.

  The pointer swap runs inside one `Repo.transaction/1` that locks every
  `process_definitions` row for `(tenant_id, process_key)` `FOR UPDATE` (design §5 step
  2a). Three guard cases, checked in this order, each writing zero rows
  (INV-RB-5):

    * no row currently `:active` for this `process_key` -> `{:error, :process_key_not_found}`
      (covers both "process_key never existed" and "every version already
      deprecated/archived" -- design §5 step 2b, a faithful port of `rollback.zig`'s own
      unification).
    * `target_version` already the active version -> `{:error, :already_active}` (checked
      before the target-row lookup, design §5 step 2c).
    * no row matching `target_version` with status in `[:active, :deprecated]` (R-Co's
      `SUPERSEDED` maps onto Letflow's `:deprecated` -- design §3) -> `{:error, :version_never_active}`.

  On success, the previously-active row moves `:active -> :deprecated` and the target row
  moves to `:active` (both `updated_at`-stamped), matching `activate_draft/2`'s own
  deprecate-then-activate swap shape.

  After the transaction commits, `opts[:event_appender]` is called exactly once
  (INV-RB-6) with a `DEFINITION_VERSION_ROLLED_BACK`-shaped payload
  (`process_key`/`from_version`/`to_version`/`actor_id`) -- deliberately outside the
  transaction, same divergence from R-Co's literal "single serializable transaction"
  framing that `promote_definition/3` already established (design §4.2/§8 OQ-3). A
  `{:error, reason}` here propagates unchanged as this function's own result; the pointer
  swap has already durably committed by this point.

  On a successful event-append, any `promotion_reviews` row for `(tenant_id,
  process_key)` with status `:applied` or `:approved` is looked up and, **only when
  exactly one such row matches**, superseded via `PromotionReviewStore.supersede_review/3`
  (INV-RB-10). Zero matches or more than one ambiguous match both resolve to
  `superseded_review_id: nil`, never a guess among several candidates and never a
  blanket-supersede of every match -- design §6 states in full why a naive `def_id`-only
  lookup cannot disambiguate which review corresponds to the specific former-active
  definition, and why guessing would risk corrupting unrelated audit rows (this was the
  defect CODE-DESIGN-VALIDATOR's Rework 1 blocked on). A per-row `supersede_review/3` race
  (`{:error, :invalid_transition}`) is absorbed the same way (design §6/§7, OQ-6) -- never
  fatal to an otherwise-successful rollback, since the pointer swap and event-append have
  already committed by that point.
  """
  @spec rollback_definition_version(
          process_key :: String.t(),
          target_version :: String.t(),
          actor_id :: Ecto.UUID.t(),
          opts :: rollback_opts()
        ) :: {:ok, rollback_result()} | rollback_error()
  def rollback_definition_version(process_key, target_version, actor_id, opts)
      when is_binary(process_key) and is_binary(target_version) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)
    permission_checker = Keyword.fetch!(opts, :permission_checker)
    event_appender = Keyword.fetch!(opts, :event_appender)

    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      if permission_checker.(actor_id, tenant_id) do
        do_rollback(process_key, target_version, actor_id, tenant_id, prefix, event_appender)
      else
        {:error, :forbidden}
      end
    end
  end

  # -----------------------------------------------------------------------------------
  # create/2 helpers (design §4.1)
  # -----------------------------------------------------------------------------------

  defp reject_key(attrs, atom_key, string_key, error) do
    if Map.has_key?(attrs, atom_key) or Map.has_key?(attrs, string_key) do
      {:error, error}
    else
      :ok
    end
  end

  defp fetch_name(attrs) do
    case Map.get(attrs, :name) do
      name when is_binary(name) and byte_size(name) > 0 and byte_size(name) <= 255 ->
        {:ok, name}

      _ ->
        {:error, :name_invalid}
    end
  end

  defp fetch_version(attrs) do
    case Map.get(attrs, :version) do
      version when is_binary(version) and byte_size(version) > 0 -> {:ok, version}
      _ -> {:error, :version_empty}
    end
  end

  defp fetch_graph_map(attrs) do
    case Map.get(attrs, :graph) do
      graph when is_map(graph) and not is_struct(graph) -> {:ok, graph}
      _ -> {:error, :graph_structure_invalid}
    end
  end

  defp convert_graph(graph_map) do
    case graph_struct_from_map(graph_map) do
      {:ok, graph} -> {:ok, graph}
      :error -> {:error, :graph_structure_invalid}
    end
  end

  defp check_graph_result(%{valid: true}), do: :ok

  defp check_graph_result(%{valid: false, violations: violations}) do
    {:error, {:graph_validation_failed, violations}}
  end

  # `attrs` is deliberately accessed by atom key only here (not the design's literal
  # "attrs[:name] (or attrs[\"name\"])" phrasing) -- matching create_attrs()'s own
  # atom-keyed @type and the EventStore.append/2 precedent this design cites, whose
  # own field fetchers (fetch_uuid/3, fetch_payload/1, ...) are atom-only; only the
  # tenant_id/status *rejection* checks (reject_key/4 above) check both forms, mirroring
  # EventStore's reject_tenant_id/1 exactly. Merging a string-keyed attrs map with the
  # atom-keyed :tenant_id (insert_definition/3 below) would otherwise raise
  # Ecto.CastError via Ecto.Changeset.convert_params/1's mixed-key guard (confirmed
  # directly: deps/ecto/lib/ecto/changeset.ex:949-964) -- flagged here as a deliberate,
  # reasoned divergence from the design's literal fallback text, not a silent one.
  defp insert_definition(attrs, tenant_id, prefix) do
    merged_attrs = Map.put(attrs, :tenant_id, tenant_id)
    changeset = ProcessDefinition.create_changeset(%ProcessDefinition{}, merged_attrs)

    try do
      changeset
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:name, :version],
        returning: true,
        prefix: prefix
      )
      |> case do
        {:ok, %ProcessDefinition{id: id}} ->
          case Repo.get(ProcessDefinition, id, prefix: prefix) do
            %ProcessDefinition{} = found -> {:ok, found}
            nil -> {:error, :duplicate_name_version}
          end

        {:error, %Ecto.Changeset{}} = error ->
          error
      end
    rescue
      exception -> {:error, {:transaction_failed, exception}}
    end
  end

  # -----------------------------------------------------------------------------------
  # get_by_id/2 helper
  # -----------------------------------------------------------------------------------

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  # -----------------------------------------------------------------------------------
  # list/2 helpers (design §4.4)
  # -----------------------------------------------------------------------------------

  defp effective_limit(nil), do: 50
  defp effective_limit(0), do: 50
  defp effective_limit(limit) when is_integer(limit) and limit > 200, do: 200
  defp effective_limit(limit) when is_integer(limit) and limit > 0, do: limit

  defp where_name(query, nil), do: query

  defp where_name(query, name) when is_binary(name) do
    pattern = "%" <> name <> "%"
    where(query, [d], fragment("? ILIKE ?", d.name, ^pattern))
  end

  defp where_status(query, nil), do: query
  defp where_status(query, status), do: where(query, [d], d.status == ^status)

  defp where_stage(query, nil), do: query
  defp where_stage(query, stage), do: where(query, [d], d.stage == ^stage)

  defp where_after_created(query, nil), do: query

  defp where_after_created(query, after_created) do
    where(query, [d], d.created_at > ^after_created)
  end

  # -----------------------------------------------------------------------------------
  # search/2 helpers (design §4/§5/§7)
  # -----------------------------------------------------------------------------------

  defp check_query_not_empty(query) do
    if byte_size(query) == 0, do: {:error, :query_empty}, else: :ok
  end

  defp check_query_not_too_long(query) do
    if byte_size(query) > 512, do: {:error, :query_too_long}, else: :ok
  end

  # `pattern` (the "%query%" value) matches on `name` OR `description`, both
  # ILIKE'd against the same bound value (design §5/§6, INV-SR-2). `description` is
  # nullable; a NULL ILIKE comparison evaluates to NULL, which the surrounding OR
  # simply doesn't treat as a match -- no explicit `IS NOT NULL` guard needed.
  defp where_search_match(queryable, pattern) do
    where(
      queryable,
      [d],
      fragment("? ILIKE ? OR ? ILIKE ?", d.name, ^pattern, d.description, ^pattern)
    )
  end

  # `search_query` and `pattern` are the same two bound values used in the WHERE
  # clause above, reused unchanged here so the ranking CASE and the matching WHERE
  # can never disagree about what counts as a "name match" (design §5). The CASE
  # expression's SQL shape is a fixed compile-time string literal, shared via the
  # `@rank_case_sql` module attribute below so both call sites can never drift out
  # of sync -- only the `?`-placeholder values (d.name, ^search_query, d.name,
  # ^pattern) vary per call, each compiled by Ecto to a genuine bound Postgres
  # parameter (design §6). A module attribute is inlined as a literal at
  # compile time before Ecto's fragment/1 macro-expansion SQL-injection guard
  # runs, so `fragment(@rank_case_sql, ...)` compiles cleanly here, unlike
  # `fragment(^helper_fun(), ...)` which Ecto's guard rejects even when the
  # helper always returns the same fixed string (confirmed against
  # deps/ecto/lib/ecto/query/builder.ex). WHEN branches evaluated in order:
  # exact case-insensitive name match (3.0), else partial name ILIKE match
  # (2.0), else -- since the surrounding WHERE clause already restricts every
  # row here to a name-or-description match -- the row matched via description
  # alone (1.0), per design §5's "safe unconditional ELSE" rationale. Cast to
  # float8 explicitly (ISS-0038/GH#120): Postgres infers an untyped numeric-literal
  # CASE expression as `numeric`, which Postgrex/Ecto decode as `Decimal.t()`, not
  # the `float()` this module's `@type search_result` and `search/2`'s @doc both
  # promise -- the cast makes the wire type match the documented Elixir type.
  @rank_case_sql "(CASE WHEN lower(?) = lower(?) THEN 3.0 WHEN ? ILIKE ? THEN 2.0 ELSE 1.0 END)::float8"

  defp select_with_rank(queryable, search_query, pattern) do
    select(queryable, [d], %{
      definition: d,
      rank:
        fragment(
          @rank_case_sql,
          d.name,
          ^search_query,
          d.name,
          ^pattern
        )
    })
  end

  defp order_by_rank(queryable, search_query, pattern) do
    order_by(
      queryable,
      [d],
      desc:
        fragment(
          @rank_case_sql,
          d.name,
          ^search_query,
          d.name,
          ^pattern
        ),
      desc: d.created_at
    )
  end

  # -----------------------------------------------------------------------------------
  # activate/2 helpers (design §6.2)
  # -----------------------------------------------------------------------------------

  defp run_activate_transaction(id, prefix, tenant_id, validator) do
    Repo.transaction(fn ->
      ProcessDefinition
      |> where([d], d.id == ^id)
      |> lock("FOR UPDATE")
      |> Repo.one(prefix: prefix)
      |> case do
        nil ->
          Repo.rollback(:not_found)

        %ProcessDefinition{status: :active} = definition ->
          {:already_active, definition}

        %ProcessDefinition{status: status} when status in [:deprecated, :archived] ->
          Repo.rollback(:not_draft)

        %ProcessDefinition{status: :draft} = definition ->
          case run_service_scope_validator(definition, tenant_id, validator) do
            :ok -> activate_draft(definition, prefix)
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  defp run_service_scope_validator(_definition, _tenant_id, nil), do: :ok

  defp run_service_scope_validator(%ProcessDefinition{graph: graph_map}, tenant_id, validator)
       when is_function(validator, 2) do
    case graph_struct_from_map(graph_map) do
      {:ok, graph} ->
        case validator.(graph, tenant_id) do
          :ok -> :ok
          {:error, reason} -> {:error, {:service_scope_violation, reason}}
        end

      :error ->
        {:error, :graph_structure_invalid}
    end
  end

  defp activate_draft(%ProcessDefinition{id: id, name: name}, prefix) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    ProcessDefinition
    |> where([d], d.name == ^name and d.status == :active)
    |> select([d], d)
    |> Repo.update_all([set: [status: :deprecated, updated_at: now]], prefix: prefix)

    {1, [updated]} =
      ProcessDefinition
      |> where([d], d.id == ^id and d.status == :draft)
      |> select([d], d)
      |> Repo.update_all([set: [status: :active, updated_at: now]], prefix: prefix)

    {:activated, updated}
  end

  defp interpret_activate_result({:ok, {:already_active, definition}}) do
    {:ok, %{definition: definition, already_active: true}}
  end

  defp interpret_activate_result({:ok, {:activated, definition}}) do
    {:ok, %{definition: definition, already_active: false}}
  end

  defp interpret_activate_result({:error, :not_found}), do: {:error, :not_found}
  defp interpret_activate_result({:error, :not_draft}), do: {:error, :not_draft}

  defp interpret_activate_result({:error, :graph_structure_invalid}) do
    {:error, :graph_structure_invalid}
  end

  defp interpret_activate_result({:error, {:service_scope_violation, _reason}} = error), do: error

  # -----------------------------------------------------------------------------------
  # deprecate/2 & archive/2 helpers (design §6.3) -- identical shape, different
  # from-status/to-status pair; archive/2 additionally stamps archived_at.
  # -----------------------------------------------------------------------------------

  defp transition(id, opts, from_status, to_status) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      try do
        run_transition(id, prefix, from_status, to_status)
      rescue
        exception -> {:error, {:transaction_failed, exception}}
      end
    end
  end

  defp run_transition(id, prefix, from_status, to_status) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    set = transition_set(to_status, now)

    Repo.transaction(fn ->
      ProcessDefinition
      |> where([d], d.id == ^id and d.status == ^from_status)
      |> select([d], d)
      |> Repo.update_all([set: set], prefix: prefix)
      |> case do
        {1, [updated]} -> updated
        {0, _count_and_rows} -> fallback_lookup(id, prefix)
      end
    end)
  end

  defp transition_set(:archived, now), do: [status: :archived, updated_at: now, archived_at: now]
  defp transition_set(status, now), do: [status: status, updated_at: now]

  defp fallback_lookup(id, prefix) do
    case Repo.get(ProcessDefinition, id, prefix: prefix) do
      nil -> Repo.rollback(:not_found)
      %ProcessDefinition{} -> Repo.rollback(:invalid_status_transition)
    end
  end

  # -----------------------------------------------------------------------------------
  # graph_struct_from_map/1 -- resolves req027-…md OQ-3 (design §5). Used by both
  # create/2 (via convert_graph/1) and activate/2 (via run_service_scope_validator/3,
  # only when a service_scope_validator hook is supplied).
  # -----------------------------------------------------------------------------------

  @node_type_map %{
    "START" => :START,
    "END" => :END,
    "HUMAN_TASK" => :HUMAN_TASK,
    "SERVICE_TASK" => :SERVICE_TASK,
    "EXCLUSIVE_GATEWAY" => :EXCLUSIVE_GATEWAY,
    "PARALLEL_GATEWAY" => :PARALLEL_GATEWAY,
    "TIMER" => :TIMER
  }

  @spec graph_struct_from_map(graph_map :: map()) :: {:ok, Graph.t()} | :error
  defp graph_struct_from_map(graph_map) do
    with {:ok, nodes_raw} <- fetch_list(graph_map, "nodes"),
         {:ok, edges_raw} <- fetch_list(graph_map, "edges"),
         {:ok, nodes} <- build_nodes(nodes_raw),
         {:ok, edges} <- build_edges(edges_raw) do
      {:ok, %Graph{nodes: nodes, edges: edges}}
    else
      _ -> :error
    end
  end

  defp fetch_list(map, key) do
    case Map.get(map, key) do
      list when is_list(list) -> {:ok, list}
      _ -> :error
    end
  end

  defp build_nodes(nodes_raw) do
    nodes_raw
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, acc} ->
      case build_node(node) do
        {:ok, built} -> {:cont, {:ok, [built | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> finish_build()
  end

  defp build_node(%{} = node) when not is_struct(node) do
    with id when is_binary(id) <- Map.get(node, "id"),
         node_type_str when is_binary(node_type_str) <- Map.get(node, "node_type") do
      {:ok,
       %Graph.Node{
         id: id,
         node_type: Map.get(@node_type_map, node_type_str, :unknown_node_type),
         label: Map.get(node, "label"),
         attributes: Map.get(node, "attributes")
       }}
    else
      _ -> :error
    end
  end

  defp build_node(_not_a_map), do: :error

  defp build_edges(edges_raw) do
    edges_raw
    |> Enum.reduce_while({:ok, []}, fn edge, {:ok, acc} ->
      case build_edge(edge) do
        {:ok, built} -> {:cont, {:ok, [built | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> finish_build()
  end

  defp build_edge(%{} = edge) when not is_struct(edge) do
    with id when is_binary(id) <- Map.get(edge, "id"),
         source when is_binary(source) <- Map.get(edge, "source"),
         target when is_binary(target) <- Map.get(edge, "target") do
      {:ok,
       %Graph.Edge{
         id: id,
         source: source,
         target: target,
         condition: Map.get(edge, "condition"),
         is_default: Map.get(edge, "is_default", false)
       }}
    else
      _ -> :error
    end
  end

  defp build_edge(_not_a_map), do: :error

  defp finish_build({:ok, reversed_acc}), do: {:ok, Enum.reverse(reversed_acc)}
  defp finish_build(:error), do: :error

  # -----------------------------------------------------------------------------------
  # rollback_definition_version/4 helpers (design §5, §6, §7)
  # -----------------------------------------------------------------------------------

  # Design §5, "Exception safety": the try/rescue wraps only the pointer-swap
  # transaction (Step 2), mirroring activate/2's own try/rescue -> {:transaction_failed,
  # _} shape. Steps 3/4 (event-append, promotion_reviews supersede) run afterward, own
  # errors, and are never folded into :transaction_failed.
  defp do_rollback(process_key, target_version, actor_id, tenant_id, prefix, event_appender) do
    transaction_result =
      try do
        run_rollback_transaction(process_key, target_version, tenant_id, prefix)
      rescue
        exception -> {:error, {:transaction_failed, exception}}
      end

    with {:ok,
          %{activated_row: activated_row, rolled_back_from_version: rolled_back_from_version}} <-
           transaction_result do
      finish_rollback(
        process_key,
        target_version,
        actor_id,
        tenant_id,
        prefix,
        event_appender,
        activated_row,
        rolled_back_from_version
      )
    end
  end

  # Design §5 step 2: locks every version row for (tenant_id, process_key) FOR UPDATE in
  # one statement (generalizes run_activate_transaction/4's single-row lock to the whole
  # set), then the three guard cases in R-Co's own literal order (already_active checked
  # before the target-row lookup -- §5 step 2c's note on why this ordering can never
  # disagree with checking version_never_active first).
  defp run_rollback_transaction(process_key, target_version, tenant_id, prefix) do
    Repo.transaction(fn ->
      rows =
        ProcessDefinition
        |> where([d], d.tenant_id == ^tenant_id and d.name == ^process_key)
        |> lock("FOR UPDATE")
        |> Repo.all(prefix: prefix)

      current_active = Enum.find(rows, &(&1.status == :active))

      cond do
        is_nil(current_active) ->
          Repo.rollback(:process_key_not_found)

        current_active.version == target_version ->
          Repo.rollback(:already_active)

        true ->
          # :active | :deprecated per design §3's SUPERSEDED -> :deprecated mapping;
          # :archived deliberately excluded (INV-RB-4).
          target_row =
            Enum.find(
              rows,
              &(&1.version == target_version and &1.status in [:active, :deprecated])
            )

          if is_nil(target_row) do
            Repo.rollback(:version_never_active)
          else
            swap_active_pointer(current_active, target_row, prefix)
          end
      end
    end)
  end

  # Design §5 step 2e -- mirrors activate_draft/2's exact two-Repo.update_all swap shape,
  # generalized to the specific already-locked row ids (current_active.id/target_row.id)
  # rather than a fresh WHERE name = ... AND status = :active re-match, avoiding a
  # theoretically-possible TOCTOU gap between this transaction's own row-lock and the
  # write. Both rows were locked at the FOR UPDATE read above, so both updates are
  # guaranteed to affect exactly 1 row.
  defp swap_active_pointer(current_active, target_row, prefix) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    ProcessDefinition
    |> where([d], d.id == ^current_active.id)
    |> select([d], d)
    |> Repo.update_all([set: [status: :deprecated, updated_at: now]], prefix: prefix)

    {1, [activated_row]} =
      ProcessDefinition
      |> where([d], d.id == ^target_row.id)
      |> select([d], d)
      |> Repo.update_all([set: [status: :active, updated_at: now]], prefix: prefix)

    %{activated_row: activated_row, rolled_back_from_version: current_active.version}
  end

  # Design §5 step 3/4, §4.2: called after TX1 commits, never nested inside it -- this
  # function does not assume anything about opts[:event_appender]'s own transactionality
  # (same stance Promotion.promote_definition/3 already established). A {:error, reason}
  # here propagates unchanged; the pointer swap has already durably committed.
  defp finish_rollback(
         process_key,
         target_version,
         actor_id,
         tenant_id,
         prefix,
         event_appender,
         activated_row,
         rolled_back_from_version
       ) do
    event_attrs = %{
      event_type: "DEFINITION_VERSION_ROLLED_BACK",
      process_key: process_key,
      from_version: rolled_back_from_version,
      to_version: target_version,
      actor_id: actor_id
    }

    case event_appender.(event_attrs, prefix) do
      {:ok, %{event_id: event_id}} ->
        superseded_review_id = supersede_matching_review(tenant_id, process_key, event_id, prefix)

        {:ok,
         %{
           definition_id: activated_row.id,
           version: target_version,
           rolled_back_from_version: rolled_back_from_version,
           superseded_review_id: superseded_review_id,
           event_id: event_id
         }}

      {:error, _reason} = error ->
        error
    end
  end

  # Design §6/§7 -- the cardinality-branched promotion_reviews supersede-lookup. Do not
  # "simplify" this into blanket-superseding every match: promotion_reviews.def_id stores
  # plan.process_key (a string), not a process_definitions.id, so there is no way to
  # correlate a review to the *specific* former-active definition once more than one
  # applied/approved review has accumulated for the same process_key (the ordinary state
  # of the table for any process_key promoted more than once, not a rare edge case). This
  # asymmetric handling -- zero matches -> nil, exactly one -> supersede it, more than one
  # -> nil, mutate nothing -- is exactly the fix for the data-integrity defect
  # CODE-DESIGN-VALIDATOR's Rework 1 blocked on (design §0, §6, INV-RB-10).
  defp supersede_matching_review(tenant_id, process_key, event_id, prefix) do
    matching_reviews =
      PromotionReview
      |> where(
        [r],
        r.tenant_id == ^tenant_id and r.def_id == ^process_key and
          r.status in [:applied, :approved]
      )
      |> Repo.all(prefix: prefix)

    case matching_reviews do
      [] ->
        nil

      [single_review] ->
        case PromotionReviewStore.supersede_review(single_review.id, event_id, prefix: prefix) do
          {:ok, %PromotionReview{id: id}} -> id
          # A genuine optimistic-lock race, or (in practice unreachable, since the row
          # was just read above) a since-deleted row -- design §6's own resolution:
          # non-fatal to the overall rollback, since TX1 and the event-append have
          # already durably committed by this point (OQ-6).
          {:error, _reason} -> nil
        end

      [_, _ | _] ->
        # Ambiguous -- more than one applied/approved review exists for this
        # process_key and no genuine version-scoped correlation is recoverable from
        # this schema (design §0's Rework-1 evidence, §6). Mutate nothing rather than
        # heuristically guess among several candidates.
        nil
    end
  end
end
