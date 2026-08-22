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

  ## `apply_promotion_assertion_rerun/6`'s gate condition and crash-safety scope (REQ-040)

  The apply pipeline (REQ-037's `mark_review_applied/2` path) gates on this function's
  recorded `assertions_failed == 0` -- NOT on `status == "passed"`. These are not the same
  check: a passing assertion replay whose sandbox teardown itself fails is recorded as
  `status = :teardown_failed` with `assertions_failed` still `0` (the real replay found
  zero failures; only the *teardown* failed, tracked separately via a
  `PROMOTION_ASSERTION_TEARDOWN_FAILED` event, never folded into the assertion counts). A
  `teardown_failed` row is therefore a **green gate** -- a caller that checks
  `status == :passed` instead of `assertions_failed == 0` will read this outcome
  backwards and incorrectly block a promotion that should proceed.

  Crash safety: the claim -> load-fixtures -> replay -> release -> record-outcome span is
  wrapped in a single `try/rescue`. This covers three exit classes -- normal completion,
  a typed error return from any step, and a raised exception anywhere in that span -- and
  on all three, `SandboxPool.release/2` is attempted and the `promotion_assertion_runs`
  row is written with fail-closed accounting (`assertions_failed >= 1`) rather than left
  stuck at `status = :running`. It does **not** cover a hard process kill
  (`Process.exit(pid, :kill)`), a BEAM node crash, or `System.halt/0` -- none of these run
  a `rescue` clause, so a sandbox claimed and a row left `:running` at the moment one of
  those events fires is neither released nor updated by this function. This residual gap
  is a disclosed, deferred limitation, not an oversight: the concrete mitigation (a
  background reaper sweeping stale `:running` rows and orphaned sandbox schemas, mirroring
  R-Co's `reclaimLeakedSandboxes`) is not built here and is left to a dedicated follow-up
  requirement -- the same deferral `Letflow.SandboxPool`'s own moduledoc already carries
  for the analogous owner-crash-detection gap on an already-claimed sandbox.

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
  import Bitwise

  alias Ecto.Multi
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.JsonSchemaShape
  alias Letflow.Definitions.PackUpdateResolution
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.PromotionArtifact
  alias Letflow.Definitions.PromotionAssertionRun
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Definitions.PromotionReviewStore
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Engine.VariableSchema
  alias Letflow.Repo
  alias Letflow.SandboxPool
  alias Letflow.SandboxPool.FixtureLoader
  alias Letflow.SandboxPool.SandboxClaim
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
         {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, _name} <- fetch_name(attrs),
         {:ok, _version} <- fetch_version(attrs),
         {:ok, graph_map} <- fetch_graph_map(attrs),
         {:ok, graph} <- convert_graph(graph_map),
         :ok <- check_graph_result(Graph.validate_graph(graph)),
         :ok <- check_graph_result(Graph.validate_node_attributes(graph)),
         :ok <- check_graph_result(Graph.validate_edge_conditions(graph)) do
      insert_definition(attrs, prefix)
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

    with {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
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

    with {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
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

    with {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
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
         {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
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

  # ---------------------------------------------------------------------------------
  # REQ-040 types -- lib/letflow/design/req040-promotion-assertion-rerun.md §3
  # ---------------------------------------------------------------------------------

  @type assertion_rerun_status :: :passed | :failed | :teardown_failed

  @type assertion_evaluator_fun ::
          (assertion :: PromotionArtifact.Assertion.t(),
           injection :: %{frozen_clock_ms: integer(), rng_seed: non_neg_integer()} ->
             {:ok, result_json :: String.t()} | {:error, term()})

  @type assertion_rerun_opts :: [
          prefix: String.t(),
          # REUSED from §0/REQ-038 -- already defined above, not redefined here.
          event_appender: event_appender_fun(),
          # Optional; defaults to default_assertion_evaluator/2 when omitted or nil --
          # a deliberate divergence from the permission_checker/event_appender
          # no-default precedent (design §3), justified because R-Co's own canonical
          # implementation ships a working (if placeholder) default.
          assertion_evaluator: assertion_evaluator_fun() | nil
        ]

  @type assertion_rerun_result :: %{
          run_id: Ecto.UUID.t(),
          status: assertion_rerun_status(),
          assertions_total: non_neg_integer(),
          assertions_passed: non_neg_integer(),
          assertions_failed: non_neg_integer(),
          failing_assertion_ids: [String.t()],
          # nil only on the sandbox-claim-failure path (design §7.2).
          sandbox_id: Ecto.UUID.t() | nil,
          teardown_error: String.t() | nil,
          # true iff this call returned a cached row (AC1) and claimed no sandbox.
          idempotent_hit: boolean(),
          # true when no teardown failure occurred (nothing to append) OR the append
          # succeeded; false only when a teardown failure occurred AND
          # opts[:event_appender] itself also failed (design §7.5).
          teardown_event_appended: boolean()
        }

  @type assertion_rerun_error ::
          {:error, :sandbox_unavailable}
          | {:error, :provision_failed}
          | {:error, :fixture_load_failed}
          # FK violation on review_id, mapped (design §4, §7.1).
          | {:error, :review_not_found}
          # Mirrors Letflow.EventStore.claim_idempotency/3's own defensive fallback
          # for the same class of case (the ON CONFLICT DO NOTHING re-fetch finding
          # neither "won the insert" nor "an existing row" -- in practice unreachable,
          # since Postgres's unique-index conflict handling blocks a concurrent
          # inserter until the winner's row is visible, but typed rather than left an
          # undeclared crash). Not present in design §3's literal type list -- flagged
          # in this requirement's own handoff as a small, reasoned addition matching
          # established precedent, not a silent deviation.
          | {:error, {:idempotency_lookup_failed, :sidecar_row_missing}}
          # Unexpected insert_changeset/2 validation failure.
          | {:error, Ecto.Changeset.t()}
          | common_error()

  @doc """
  Ports `src/definition/assertion_rerun.zig`'s `applyPromotionAssertionRerun` (PRM-06/07)
  -- idempotent assertion replay against an ephemeral REQ-039 sandbox, keyed by
  `(review_id, plan_digest)`.

  Returns the cached `{:ok, result}` with `idempotent_hit: true` on a second call for the
  same `(review_id, plan_digest)` pair, claiming no sandbox. On a fresh call: claims a
  sandbox (`Letflow.SandboxPool.claim/2`), loads only `artifact.fixtures[]` into it
  (`Letflow.SandboxPool.FixtureLoader.load_fixtures_only/3` -- never organic tenant data),
  replays each assertion twice under a frozen clock and a seeded, reset-between-runs RNG,
  and records `status` + `assertions_total`/`assertions_passed`/`assertions_failed` +
  `failing_assertion_ids` in `promotion_assertion_runs`.

  **Gate condition -- read before wiring this into the apply pipeline:** callers must gate
  on the returned `assertions_failed == 0`, NOT on `status == :passed`. A
  `status = :teardown_failed` result with `assertions_failed == 0` is a green gate -- see
  this module's moduledoc, "`apply_promotion_assertion_rerun/6`'s gate condition and
  crash-safety scope".

  **Crash safety -- also see this module's moduledoc:** the claim-through-release span is
  wrapped in `try/rescue`, covering normal completion, typed errors, and raised
  exceptions. It does NOT cover a hard process kill or a BEAM crash mid-replay -- that
  residual gap is disclosed, not resolved, and left to a deferred reaper follow-up.

  `tenant_id` is never a separate argument -- derived from `opts[:prefix]`, same as every
  other function in this module. `opts[:event_appender]` is `Keyword.fetch!/2`'d -- no
  built-in default, raises `KeyError` if omitted, same no-default stance
  `rollback_definition_version/4` already established. `opts[:assertion_evaluator]` DOES
  have a built-in default (`default_assertion_evaluator/2`, design §3/§6) -- a deliberate
  divergence, since R-Co's own canonical implementation ships a working placeholder rather
  than having no data path to a real one.
  """
  @spec apply_promotion_assertion_rerun(
          review_id :: Ecto.UUID.t(),
          plan_digest :: String.t(),
          artifact :: PromotionArtifact.t(),
          sandbox_pool :: GenServer.server(),
          max_wait_ms :: non_neg_integer(),
          opts :: assertion_rerun_opts()
        ) :: {:ok, assertion_rerun_result()} | assertion_rerun_error()
  def apply_promotion_assertion_rerun(
        review_id,
        plan_digest,
        artifact,
        sandbox_pool,
        max_wait_ms,
        opts
      )
      when is_binary(review_id) and is_binary(plan_digest) and is_list(opts) and
             is_integer(max_wait_ms) and max_wait_ms >= 0 do
    prefix = Keyword.get(opts, :prefix)
    event_appender = Keyword.fetch!(opts, :event_appender)

    assertion_evaluator =
      Keyword.get(opts, :assertion_evaluator) || (&default_assertion_evaluator/2)

    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      idempotency_key = build_idempotency_key(review_id, plan_digest)

      case claim_or_fetch_assertion_run(
             tenant_id,
             review_id,
             plan_digest,
             idempotency_key,
             prefix
           ) do
        {:ok, {:idempotent_hit, run}} ->
          {:ok, build_result(run, true, true)}

        {:ok, {:claimed, run}} ->
          claim_sandbox_and_proceed(
            run,
            artifact,
            sandbox_pool,
            max_wait_ms,
            tenant_id,
            prefix,
            event_appender,
            assertion_evaluator
          )

        {:error, _reason} = error ->
          error
      end
    end
  end

  # ===================================================================================
  # REQ-078 -- definition-graph validation endpoint backing (design §7.2)
  # ===================================================================================

  @typedoc "The merged outcome of REQ-028/029's three graph validators over one stored definition."
  @type graph_validation_result :: %{
          definition_id: Ecto.UUID.t(),
          valid: boolean(),
          violations: [Graph.Violation.t()]
        }

  @doc """
  Runs REQ-028/029's three graph validators over one **stored** definition's
  graph and merges their outcomes. Backs
  `POST /api/v1/definitions/:id/validate` (`Letflow.Routers.Definitions`).

  **The composition lives here, not in the route, and that is the point.**
  REQ-078's AC4 requires the endpoint to produce the same outcome as calling
  REQ-028/029's validators directly on the same graph. That is only
  *structurally* guaranteed if the route contains no validation logic at all —
  so it contains none, and this function contains no rule of its own either.

  Behaviour:

    1. `get_by_id/2` — prefix-scoped. `{:error, :not_found}` propagates
       unchanged; that is also the cross-tenant case (INV-5 — the route
       renders it as a detail-free 404, byte-identical to a genuinely absent
       id, on the same code path and with the same query count).
    2. `Letflow.Definitions.Graph.from_map/1`. `:error` ->
       `{:error, :graph_structure_invalid}` — a stored graph that will not
       even parse.
    3. Exactly these three, in this order:
       `Graph.validate_graph/1` (REQ-028 structural),
       `Graph.validate_node_attributes/1` (REQ-029 node attributes),
       `Graph.validate_edge_conditions/1` (REQ-029 edge conditions).
    4. The three `:violations` lists are concatenated in that order.
       Duplicates are **not** deduplicated: the three validators produce
       disjoint `Graph.Violation.code()` sets. `valid` is `violations == []`.

  **Adds no rule of its own, and calls no other validator.** In particular it
  does **not** call
  `Letflow.Definitions.ServiceScopeValidator.validate/3`, which `activate/2`
  does call. Service-scope validation needs an injected `Lookup.t()` this
  endpoint has no source for, and including it would break AC4's equality with
  "REQ-028/029's validators directly". That exclusion is deliberate, and
  `activate/2` remains its owning path.

  Issues exactly one query (`get_by_id/2`); everything after step 1 is pure.
  """
  @spec validate_definition_graph(id :: Ecto.UUID.t(), opts :: opts()) ::
          {:ok, graph_validation_result()}
          | {:error, :not_found}
          | {:error, :graph_structure_invalid}
          | common_error()
  def validate_definition_graph(id, opts) when is_list(opts) do
    with {:ok, %ProcessDefinition{} = definition} <- get_by_id(id, opts),
         {:ok, graph} <- convert_graph(definition.graph) do
      violations =
        Graph.validate_graph(graph).violations ++
          Graph.validate_node_attributes(graph).violations ++
          Graph.validate_edge_conditions(graph).violations

      {:ok,
       %{
         definition_id: definition.id,
         valid: violations == [],
         violations: violations
       }}
    end
  end

  # ===================================================================================
  # REQ-078 -- metrics counters (design §11.4)
  # ===================================================================================

  # The closed enum from ProcessDefinition's own `status` field. Declared
  # before its only reader, since a module attribute is read at expansion
  # time.
  @definition_status_zero_fill %{draft: 0, active: 0, deprecated: 0, archived: 0}

  @doc """
  Counts `process_definitions` rows by `status`, scoped to `opts[:prefix]`.
  One query. Backs `GET /api/v1/metrics` (`Letflow.Routers.Metrics`).

  Every status in the closed enum is present in the returned map,
  zero-valued if unseen, so the response shape is stable.

  The `group_by`/`select` is composed over the **schema field**, never the raw
  column, so Ecto's enum loader maps stored values back to atoms before the
  zero-fill sees them. `process_definitions.status` is a bare-atom enum where
  the distinction would not bite, but
  `Letflow.Engine.count_instances_by_status/1` and `count_tasks_by_status/1`
  operate on keyword-mapped enums where it very much does — all three are
  written the same way on purpose.

  `opts[:prefix]` is validated via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` **before** the
  query is constructed, the same guard `Letflow.EventStore.read_global/1`
  uses. Composed with `Ecto.Query` and bound parameters only (INV-7).
  """
  @spec count_definitions_by_status(opts :: opts()) ::
          {:ok, %{status() => non_neg_integer()}} | common_error()
  def count_definitions_by_status(opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      counts =
        ProcessDefinition
        |> group_by([d], d.status)
        |> select([d], {d.status, count(d.id)})
        |> Repo.all(prefix: prefix)
        |> Map.new()

      {:ok, Map.merge(@definition_status_zero_fill, counts)}
    end
  end

  # ===================================================================================
  # REQ-078 -- the SINGLE shared `variable_schemas` registration path
  # lib/letflow/design/req078-supporting-routes.md §9
  # ===================================================================================

  @typedoc """
  One variable-schema registration input. `json_schema` is the ALREADY-DECODED
  document (a `map()` if well formed). Callers that hold JSON text -- the
  solution-pack install path, whose wire format carries `schema_content` as a
  string (R-Co `src/api/routes/solution_packs.zig:299-315`) -- decode it before
  calling and map a decode failure onto their own error, never onto a
  half-decoded value passed through here.
  """
  @type variable_schema_input :: %{
          required(:variable_key) => String.t(),
          required(:json_schema) => term(),
          optional(:description) => String.t() | nil
        }

  @typedoc "Every distinct, pattern-matchable failure of the registration path."
  @type variable_schema_error ::
          :missing_prefix
          | :invalid_definition_id
          | {:duplicate_variable_key, String.t()}
          | {:blank_variable_key, non_neg_integer()}
          | {:not_well_formed, variable_key :: String.t(), path :: [String.t()]}
          | {:schema_too_deep, variable_key :: String.t()}

  @doc """
  The SINGLE insert path into the tenant-scoped `variable_schemas` table
  (`Letflow.Engine.VariableSchema`, REQ-109). REQ-078's solution-pack install
  and REQ-082's definition import both call THIS function; neither adds a
  second insert path.

  The invariant is about INSERT PATHS, not about text: the only `Repo` insert
  against `Letflow.Engine.VariableSchema` anywhere in `lib/` is the one inside
  this function, and no module under `lib/letflow/routers/` performs a `Repo`
  call of any kind. Documentation that NAMES this table or this function is
  not a second insert path -- route moduledocs are required to name both, so
  they point a reader here. See `lib/letflow/design/req078-supporting-routes.md`
  §18.1 for the three mechanical checks that verify this, and INV-VS-1.

  Behaviour, in this exact order (steps 1-5 issue **zero** queries, so a
  malformed request never reaches the database):

    1. `opts[:prefix]` missing/nil/empty -> `{:error, :missing_prefix}`;
       `definition_id` not UUID-shaped -> `{:error, :invalid_definition_id}`.
    2. `entries == []` -> `{:ok, 0}`. (A pack with no `variable_schemas` array
       is normal, not an error.)
    3. A blank or whitespace-only `variable_key` at index `i` ->
       `{:error, {:blank_variable_key, i}}`.
    4. A `variable_key` duplicated **within `entries`** ->
       `{:error, {:duplicate_variable_key, key}}`, checked before any insert --
       the database's `uq_variable_schema_definition_key` would otherwise
       surface it as an opaque changeset error mid-transaction.
    5. Well-formedness of every entry's `json_schema`, via
       `Letflow.Definitions.JsonSchemaShape.check/1` -- the same predicate
       `Letflow.Engine.VariableSchema.changeset/2` itself applies. The first
       failure aborts and nothing is written:
       `{:error, {:not_well_formed, variable_key, path}}` or
       `{:error, {:schema_too_deep, variable_key}}`.
    6. Insert via `Letflow.Engine.VariableSchema.changeset/2` -- REQ-109's
       changeset, not a second one -- with `prefix: opts[:prefix]` and
       `on_conflict: :nothing, conflict_target: [:definition_id,
       :variable_key]`, porting R-Co's
       `ON CONFLICT (definition_id, variable_key) DO NOTHING`
       (`src/solution/store.zig:485`) exactly.

  All inserts run in one `Ecto.Multi`, so the function is all-or-nothing.
  `Letflow.Repo.transaction/1` **joins an already-open transaction** rather
  than opening a nested one, so when the solution-pack install calls this
  inside its own transaction, the schema registration and the definitions that
  install created commit or roll back together (design OQ-5's fixed
  guarantee). Called outside a transaction, the same call wraps the inserts in
  one of their own.

  Returns `{:ok, count}`, where `count` counts rows **actually inserted** --
  a row absorbed by `ON CONFLICT DO NOTHING` is not counted. The mechanism is
  `created_at`, a `read_after_writes: true` column: a skipped insert returns no
  row from `RETURNING`, so the field stays `nil`.

  **Row scoping (INV-VS-3).** Rows are keyed to the `definition_id` argument. A
  pack carrying N definitions calls this function N times with N distinct ids,
  so the row sets are disjoint and cannot collide with REQ-082 importing a
  different definition.
  """
  @spec register_variable_schemas(
          definition_id :: Ecto.UUID.t(),
          entries :: [variable_schema_input()],
          opts :: opts()
        ) :: {:ok, non_neg_integer()} | {:error, variable_schema_error()}
  def register_variable_schemas(definition_id, entries, opts)
      when is_list(entries) and is_list(opts) do
    with {:ok, prefix} <- fetch_registration_prefix(opts),
         {:ok, definition_id} <- cast_registration_definition_id(definition_id),
         :ok <- check_registration_entries(entries) do
      insert_variable_schema_rows(definition_id, entries, prefix)
    end
  end

  @spec fetch_registration_prefix(opts()) :: {:ok, String.t()} | {:error, :missing_prefix}
  defp fetch_registration_prefix(opts) do
    case Keyword.get(opts, :prefix) do
      prefix when is_binary(prefix) and byte_size(prefix) > 0 -> {:ok, prefix}
      _missing_or_empty -> {:error, :missing_prefix}
    end
  end

  @spec cast_registration_definition_id(term()) ::
          {:ok, Ecto.UUID.t()} | {:error, :invalid_definition_id}
  defp cast_registration_definition_id(definition_id) do
    case Ecto.UUID.cast(definition_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_definition_id}
    end
  end

  # Steps 3-5. Pure -- no query is constructed, let alone issued, until every
  # entry has passed all three.
  @spec check_registration_entries([variable_schema_input()]) ::
          :ok | {:error, variable_schema_error()}
  defp check_registration_entries(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while(MapSet.new(), fn {entry, index}, seen ->
      key = Map.get(entry, :variable_key)

      cond do
        not is_binary(key) or String.trim(key) == "" ->
          {:halt, {:error, {:blank_variable_key, index}}}

        MapSet.member?(seen, key) ->
          {:halt, {:error, {:duplicate_variable_key, key}}}

        true ->
          case JsonSchemaShape.check(Map.get(entry, :json_schema)) do
            :ok -> {:cont, MapSet.put(seen, key)}
            {:error, {:not_well_formed, path}} -> {:halt, {:error, {:not_well_formed, key, path}}}
            {:error, :too_deep} -> {:halt, {:error, {:schema_too_deep, key}}}
          end
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      %MapSet{} -> :ok
    end
  end

  # Step 6. The one and only Repo insert against Letflow.Engine.VariableSchema
  # in all of lib/ (INV-VS-1).
  @spec insert_variable_schema_rows(Ecto.UUID.t(), [variable_schema_input()], String.t()) ::
          {:ok, non_neg_integer()}
  defp insert_variable_schema_rows(_definition_id, [], _prefix), do: {:ok, 0}

  defp insert_variable_schema_rows(definition_id, entries, prefix) do
    multi =
      entries
      |> Enum.with_index()
      |> Enum.reduce(Multi.new(), fn {entry, index}, multi ->
        changeset =
          VariableSchema.changeset(%VariableSchema{}, %{
            definition_id: definition_id,
            variable_key: Map.get(entry, :variable_key),
            json_schema: Map.get(entry, :json_schema),
            description: Map.get(entry, :description)
          })

        Multi.insert(multi, {:variable_schema, index}, changeset,
          prefix: prefix,
          on_conflict: :nothing,
          conflict_target: [:definition_id, :variable_key]
        )
      end)

    # Strict match, deliberately: after steps 1-5 the multi cannot return
    # {:error, _, _, _}. `validate_required/2` is satisfied by construction
    # (definition_id was cast, variable_key is non-blank, json_schema is a
    # map), `validate_change(:json_schema, ...)` applies the same predicate
    # step 5 already ran, and `unique_constraint/3` cannot fire because
    # `on_conflict: :nothing` suppresses it. A genuine database failure
    # (missing table, dead connection) raises rather than returning an error
    # tuple, and belongs on the caller's 500 path.
    {:ok, changes} = Repo.transaction(multi)

    inserted =
      Enum.count(changes, fn {_name, %VariableSchema{created_at: created_at}} ->
        not is_nil(created_at)
      end)

    {:ok, inserted}
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
    case Graph.from_map(graph_map) do
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
  # EventStore's reject_tenant_id/1 exactly.
  #
  # Post-Decision-0006-D2 (REQ-064): this function no longer merges a
  # caller-derived :tenant_id into attrs before building the changeset --
  # process_definitions.tenant_id no longer exists as a column (the per-tenant
  # Postgres schema, written via `prefix:` in Repo.insert/2 below, already
  # identifies the tenant). tenant_id_for_schema_name/1 is still called at this
  # function's own call site (create/2) purely to validate `prefix` resolves to
  # a real, provisioned tenant before any row is written -- its result is no
  # longer threaded into this function at all.
  defp insert_definition(attrs, prefix) do
    changeset = ProcessDefinition.create_changeset(%ProcessDefinition{}, attrs)

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
    case Graph.from_map(graph_map) do
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

    with {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
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
  # graph_struct_from_map/1 -- moved to Letflow.Definitions.Graph.from_map/1
  # (lib/letflow/design/req045-instance-start-engine-shell.md §8, REQ-045):
  # Letflow.Engine.create/2 needs the identical conversion and cannot call a
  # private function across module boundaries, so this logic now lives once,
  # on the struct's own module, rather than being duplicated a second time in
  # Letflow.Engine. convert_graph/1 and run_service_scope_validator/3 above
  # call Graph.from_map/1 directly; behavior is unchanged.
  # -----------------------------------------------------------------------------------

  # -----------------------------------------------------------------------------------
  # rollback_definition_version/4 helpers (design §5, §6, §7)
  # -----------------------------------------------------------------------------------

  # Design §5, "Exception safety": the try/rescue wraps only the pointer-swap
  # transaction (Step 2), mirroring activate/2's own try/rescue -> {:transaction_failed,
  # _} shape. Steps 3/4 (event-append, promotion_reviews supersede) run afterward, own
  # errors, and are never folded into :transaction_failed.
  # tenant_id is accepted (and left as a real, non-underscored parameter name in
  # the @spec-less signature below only for symmetry with its call site,
  # rollback_definition_version/4, which the design's §3.1 explicitly keeps
  # unchanged since permission_checker.(actor_id, tenant_id) there is a genuine
  # functional consumer, not stamping) but is no longer used inside this
  # function's own body post-Decision-0006-D2 (REQ-064) -- both
  # run_rollback_transaction/3 and finish_rollback/7 dropped their tenant_id
  # parameters once process_definitions.tenant_id/promotion_reviews.tenant_id
  # stopped existing. Prefixed _tenant_id to avoid an unused-variable warning
  # without changing rollback_definition_version/4's own call shape.
  defp do_rollback(process_key, target_version, actor_id, _tenant_id, prefix, event_appender) do
    transaction_result =
      try do
        run_rollback_transaction(process_key, target_version, prefix)
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
        prefix,
        event_appender,
        activated_row,
        rolled_back_from_version
      )
    end
  end

  # Design §5 step 2: locks every version row for process_key FOR UPDATE in one
  # statement (generalizes run_activate_transaction/4's single-row lock to the whole
  # set), then the three guard cases in R-Co's own literal order (already_active checked
  # before the target-row lookup -- §5 step 2c's note on why this ordering can never
  # disagree with checking version_never_active first).
  #
  # Post-Decision-0006-D2 (REQ-064): the row-selection predicate below was
  # `d.tenant_id == ^tenant_id and d.name == ^process_key`; process_definitions.tenant_id
  # no longer exists as a column, so the predicate is now `d.name == ^process_key`
  # alone -- `prefix` (passed to Repo.all/2 below) already confines this query to
  # exactly one tenant's schema, so the dropped tenant_id filter was redundant with
  # that schema boundary, not an independent safety check. tenant_id is no longer
  # needed by this function at all -- dropped from its parameter list.
  defp run_rollback_transaction(process_key, target_version, prefix) do
    Repo.transaction(fn ->
      rows =
        ProcessDefinition
        |> where([d], d.name == ^process_key)
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
  #
  # Post-Decision-0006-D2 (REQ-064): no longer takes tenant_id -- it was only
  # ever forwarded to supersede_matching_review/4's now-removed tenant_id
  # filter (see that function's own comment).
  defp finish_rollback(
         process_key,
         target_version,
         actor_id,
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
        superseded_review_id = supersede_matching_review(process_key, event_id, prefix)

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
  #
  # Post-Decision-0006-D2 (REQ-064): the lookup predicate below was
  # `r.tenant_id == ^tenant_id and r.def_id == ^process_key and ...`;
  # promotion_reviews.tenant_id no longer exists as a column, so the predicate is
  # now `r.def_id == ^process_key and ...` alone -- `prefix` (passed to Repo.all/2
  # below) already confines this query to exactly one tenant's schema. tenant_id
  # is no longer needed by this function at all -- dropped from its parameter list.
  defp supersede_matching_review(process_key, event_id, prefix) do
    matching_reviews =
      PromotionReview
      |> where(
        [r],
        r.def_id == ^process_key and r.status in [:applied, :approved]
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

  # -----------------------------------------------------------------------------------
  # apply_promotion_assertion_rerun/6 helpers (design §6, §7)
  # -----------------------------------------------------------------------------------

  # Design §7.1 -- direct port of buildIdempotencyKey (assertion_rerun.zig:120-122).
  defp build_idempotency_key(review_id, plan_digest) do
    "promotion_rerun:" <> review_id <> ":" <> plan_digest
  end

  # Design §7.1 steps 1-3: reuses the exact "attempt an insert with on_conflict:
  # :nothing, then re-fetch by the client-generated id to disambiguate
  # real-insert-vs-suppressed" idiom already shipped in
  # Letflow.EventStore.claim_idempotency/3 and insert_definition/3 above -- not raw
  # SQL, not a new idiom. status/assertions_*/failing_assertion_ids are never cast
  # here -- a winning insert starts at its column defaults (:running, 0, []).
  # Post-Decision-0006-D2 (REQ-064): tenant_id is still accepted as a
  # parameter (its caller, apply_promotion_assertion_rerun/6, still resolves
  # and threads a real tenant_id -- see that function's own note), but is no
  # longer stamped into attrs or used as an on_conflict/get_by scoping key
  # below -- promotion_assertion_runs.tenant_id no longer exists as a column,
  # and prefix already scopes every one of these calls to exactly one
  # tenant's schema. See PromotionAssertionRun's own moduledoc/migration
  # header for the restated idempotency contract this shape change preserves.
  defp claim_or_fetch_assertion_run(_tenant_id, review_id, plan_digest, idempotency_key, prefix) do
    attrs = %{
      review_id: review_id,
      idempotency_key: idempotency_key,
      plan_digest: plan_digest
    }

    changeset = PromotionAssertionRun.insert_changeset(%PromotionAssertionRun{}, attrs)

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:idempotency_key],
           prefix: prefix
         ) do
      {:ok, %PromotionAssertionRun{id: attempted_id}} ->
        case Repo.get(PromotionAssertionRun, attempted_id, prefix: prefix) do
          %PromotionAssertionRun{} = won ->
            # Found -- this call genuinely won the insert (a fresh :running row it
            # now owns exclusively -- ON CONFLICT DO NOTHING guarantees exactly one
            # winner for this idempotency_key, within this tenant's schema).
            {:ok, {:claimed, won}}

          nil ->
            fetch_existing_assertion_run(idempotency_key, prefix)
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        if review_not_found_error?(changeset) do
          {:error, :review_not_found}
        else
          {:error, changeset}
        end
    end
  end

  # Not found (suppressed by the unique-index conflict) -- fetch the real existing
  # row. No sandbox is claimed on this path (AC1's own literal wording, INV-AR-4).
  #
  # Post-Decision-0006-D2 (REQ-064): dropped the tenant_id parameter --
  # promotion_assertion_runs.tenant_id no longer exists as a column, so this
  # Repo.get_by/3 filters on idempotency_key alone; prefix already scopes the
  # lookup to one tenant's schema.
  defp fetch_existing_assertion_run(idempotency_key, prefix) do
    case Repo.get_by(
           PromotionAssertionRun,
           [idempotency_key: idempotency_key],
           prefix: prefix
         ) do
      %PromotionAssertionRun{} = existing -> {:ok, {:idempotent_hit, existing}}
      nil -> {:error, {:idempotency_lookup_failed, :sidecar_row_missing}}
    end
  end

  defp review_not_found_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :foreign and
        Keyword.get(opts, :constraint_name) == "promotion_assertion_runs_review_id_fkey"
    end)
  end

  # Design §7.2 -- SandboxPool.claim/2's own shipped implementation only ever
  # returns these two named error atoms (traced directly, sandbox_pool.ex); no
  # sandbox was ever claimed on either, so no release is needed or possible --
  # write a fail-closed final UPDATE directly (no try needed, nothing here can
  # leak a sandbox), then return the error unchanged (design §7.2, a deliberate
  # improvement over R-Co's own literal stuck-`running` behavior, §7.4).
  defp claim_sandbox_and_proceed(
         run,
         artifact,
         sandbox_pool,
         max_wait_ms,
         tenant_id,
         prefix,
         event_appender,
         assertion_evaluator
       ) do
    case SandboxPool.claim(max_wait_ms, sandbox_pool) do
      {:ok, %SandboxClaim{} = claim} ->
        run_replay_span(
          run,
          artifact,
          claim,
          sandbox_pool,
          tenant_id,
          prefix,
          event_appender,
          assertion_evaluator
        )

      {:error, reason} when reason in [:sandbox_unavailable, :provision_failed] ->
        %{assertions_total: total, assertions_failed: failed, failing_assertion_ids: failing_ids} =
          fail_closed_counts(artifact)

        _ =
          finalize_and_write(
            run,
            tenant_id,
            prefix,
            nil,
            :not_attempted,
            total,
            0,
            failed,
            failing_ids,
            event_appender
          )

        {:error, reason}
    end
  end

  # Design §7.6 -- the try/rescue crash-safety wrapper (§2.3). Wraps Steps 3-6
  # (fixture load, replay, teardown+precedence+eventing, the final UPDATE) --
  # NOT Step 2's claim itself (a claim failure needs no release, matching
  # rollback_definition_version/4's own "try/rescue wraps only the step that can
  # leak a resource" scoping note).
  defp run_replay_span(
         run,
         artifact,
         %SandboxClaim{sandbox_id: sandbox_id, schema_name: schema_name},
         sandbox_pool,
         tenant_id,
         prefix,
         event_appender,
         assertion_evaluator
       ) do
    try do
      case FixtureLoader.load_fixtures_only(schema_name, artifact.fixtures, []) do
        :ok ->
          finish_replay(
            run,
            artifact,
            sandbox_id,
            sandbox_pool,
            tenant_id,
            prefix,
            event_appender,
            assertion_evaluator
          )

        {:error, _reason} ->
          handle_fixture_load_failure(
            run,
            artifact,
            sandbox_id,
            sandbox_pool,
            tenant_id,
            prefix,
            event_appender
          )
      end
    rescue
      exception ->
        # Best-effort release attempt -- may be redundant if teardown already ran
        # and succeeded before the exception fired (e.g. the exception originated
        # in the final UPDATE itself) -- SandboxPool.release/2 on an
        # already-released sandbox_id returns {:error, :not_found}, itself
        # swallowed here, matching provision_sandbox/0's own "cleanup, not the
        # primary error path" stance.
        safe_release(sandbox_id, sandbox_pool)
        # Best-effort fail-closed row update -- swallows its OWN failure too (the
        # DB itself may be unreachable, which is presumably why an exception fired
        # in the first place).
        safe_fail_closed_update(run, artifact, sandbox_id, prefix, exception)
        {:error, {:transaction_failed, exception}}
    end
  end

  # Design §7.3 -- fixtures[] failed to load: the sandbox WAS claimed and must be
  # released. This is a typed return, not a raised exception, so it's handled by
  # ordinary pattern matching inside run_replay_span/8's own try body (still
  # covered by that try's rescue if release or the write itself unexpectedly
  # raises). The underlying FixtureLoader error is deliberately not surfaced
  # verbatim -- :fixture_load_failed is this function's own, coarser, stable
  # error tag, matching R-Co's own FixtureLoadFailed collapsing all three
  # FixtureLoadError variants into one.
  defp handle_fixture_load_failure(
         run,
         artifact,
         sandbox_id,
         sandbox_pool,
         tenant_id,
         prefix,
         event_appender
       ) do
    release_outcome = SandboxPool.release(sandbox_id, sandbox_pool)

    %{assertions_total: total, assertions_failed: failed, failing_assertion_ids: failing_ids} =
      fail_closed_counts(artifact)

    _ =
      finalize_and_write(
        run,
        tenant_id,
        prefix,
        sandbox_id,
        release_outcome,
        total,
        0,
        failed,
        failing_ids,
        event_appender
      )

    {:error, :fixture_load_failed}
  end

  # Design §6/§7.5 -- fixtures loaded successfully: replay every assertion twice
  # under the frozen-clock/seeded-RNG injection, release the sandbox, then apply
  # the teardown precedence rule and write the single final UPDATE.
  defp finish_replay(
         run,
         artifact,
         sandbox_id,
         sandbox_pool,
         tenant_id,
         prefix,
         event_appender,
         assertion_evaluator
       ) do
    %{
      assertions_total: total,
      assertions_passed: passed,
      assertions_failed: failed,
      failing_assertion_ids: failing_ids
    } = replay_assertions(artifact, assertion_evaluator)

    release_outcome = SandboxPool.release(sandbox_id, sandbox_pool)

    finalize_and_write(
      run,
      tenant_id,
      prefix,
      sandbox_id,
      release_outcome,
      total,
      passed,
      failed,
      failing_ids,
      event_appender
    )
  end

  # Design §7.4/§7.5 unified: pre_teardown_status is derived from assertions_failed
  # the same way on every path (real replay counts, or fail-closed counts on an
  # infrastructure-failure path -- fail_closed_counts/1 guarantees assertions_failed
  # is never 0, so pre_teardown_status is always :failed on those paths, which is
  # exactly design §7.4's own literal "status is set to :failed" rule, derived here
  # rather than special-cased). release_outcome is one of :not_attempted (no
  # sandbox was ever claimed, §7.2), :ok, or {:error, reason} -- the single shared
  # precedence + eventing rule (recordTeardownFailure's own CASE WHEN, §7.5)
  # handles all three uniformly.
  defp finalize_and_write(
         run,
         tenant_id,
         prefix,
         sandbox_id,
         release_outcome,
         assertions_total,
         assertions_passed,
         assertions_failed,
         failing_assertion_ids,
         event_appender
       ) do
    pre_teardown_status = if assertions_failed == 0, do: :passed, else: :failed

    {final_status, teardown_error, teardown_event_appended} =
      apply_teardown_precedence(
        run,
        tenant_id,
        sandbox_id,
        prefix,
        pre_teardown_status,
        release_outcome,
        event_appender
      )

    attrs = %{
      status: final_status,
      sandbox_id: sandbox_id,
      assertions_total: assertions_total,
      assertions_passed: assertions_passed,
      assertions_failed: assertions_failed,
      failing_assertion_ids: failing_assertion_ids,
      teardown_error: teardown_error,
      completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    case run |> PromotionAssertionRun.update_changeset(attrs) |> Repo.update(prefix: prefix) do
      {:ok, %PromotionAssertionRun{} = updated_run} ->
        {:ok, build_result(updated_run, false, teardown_event_appended)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  # No sandbox was ever claimed (§7.2) -- nothing to release, nothing to append.
  defp apply_teardown_precedence(
         _run,
         _tenant_id,
         _sandbox_id,
         _prefix,
         pre_teardown_status,
         :not_attempted,
         _event_appender
       ) do
    {pre_teardown_status, nil, true}
  end

  # Teardown succeeded -- final_status is exactly the pre-teardown status, nothing
  # to append (design §7.5's :ok branch).
  defp apply_teardown_precedence(
         _run,
         _tenant_id,
         _sandbox_id,
         _prefix,
         pre_teardown_status,
         :ok,
         _event_appender
       ) do
    {pre_teardown_status, nil, true}
  end

  # Teardown (release) failed -- the recordTeardownFailure precedence rule
  # (assertion_rerun.zig:620-631, quoted in design §0/§7.5): a teardown failure
  # never demotes an already-failed run, and only ever demotes a passed run into
  # :teardown_failed (PRM-07 AC2's green-gate case, INV-AR-6). The
  # PROMOTION_ASSERTION_TEARDOWN_FAILED event is appended exactly once, regardless
  # of which branch pre_teardown_status took (design §7.5) -- INV-AR-8: a failure
  # here never alters final_status/assertions_failed, only teardown_event_appended.
  defp apply_teardown_precedence(
         run,
         tenant_id,
         sandbox_id,
         prefix,
         pre_teardown_status,
         {:error, release_reason},
         event_appender
       ) do
    final_status = if pre_teardown_status == :failed, do: :failed, else: :teardown_failed
    teardown_error = describe_release_failure(release_reason)

    teardown_event_appended =
      append_teardown_failure_event(
        event_appender,
        run,
        sandbox_id,
        tenant_id,
        prefix,
        teardown_error
      )

    {final_status, teardown_error, teardown_event_appended}
  end

  defp describe_release_failure(release_reason) do
    "sandbox release failed: " <> to_string(release_reason)
  end

  defp append_teardown_failure_event(
         event_appender,
         run,
         sandbox_id,
         tenant_id,
         prefix,
         teardown_error
       ) do
    event_attrs = %{
      event_type: "PROMOTION_ASSERTION_TEARDOWN_FAILED",
      run_id: run.id,
      sandbox_id: sandbox_id,
      tenant_id: tenant_id,
      error: teardown_error
    }

    case event_appender.(event_attrs, prefix) do
      {:ok, _} -> true
      # Absorbed, never propagated as this function's own error (design §7.5,
      # INV-AR-8) -- the same "don't let a side-effect's own failure corrupt an
      # already-computed, already-durable-once-written outcome" resolution
      # finish_rollback/8's own OQ-6 already established for an analogous tension.
      {:error, _reason} -> false
    end
  end

  # Design §7.4 -- a deliberate, disclosed improvement over R-Co's own traced
  # behavior (which leaves a claim/fixture-load-failure row stuck at :running
  # forever, so a naive future reader checking assertions_failed == 0 without also
  # checking status would misread an infrastructure failure as a green gate).
  # Every assertion is conservatively treated as failed; max(assertions_total, 1)
  # guarantees assertions_failed is never 0 even for a zero-assertion artifact
  # (INV-AR-7).
  defp fail_closed_counts(%PromotionArtifact{assertions: assertions}) do
    assertions_total = length(assertions)
    assertions_failed = max(assertions_total, 1)

    failing_assertion_ids =
      if assertions_total > 0 do
        Enum.map(assertions, & &1.id)
      else
        ["__infrastructure_failure__"]
      end

    %{
      assertions_total: assertions_total,
      assertions_failed: assertions_failed,
      failing_assertion_ids: failing_assertion_ids
    }
  end

  # Best-effort release attempt for the rescue clause only (run_replay_span/8) --
  # swallows any exception SandboxPool.release/2 itself might raise, since this
  # runs OUTSIDE the try that would otherwise catch it. Its return value is
  # deliberately discarded by the caller (best-effort, not the primary error path).
  defp safe_release(sandbox_id, sandbox_pool) do
    SandboxPool.release(sandbox_id, sandbox_pool)
  rescue
    _exception -> {:error, :release_failed}
  end

  # Best-effort fail-closed row update for the rescue clause only -- swallows its
  # own failure too (design §7.6: "the DB itself may be unreachable, which is
  # presumably why an exception fired in the first place"). Does not attempt to
  # call event_appender -- an external call inside an already-degraded,
  # exception-recovery path would add another thing that could itself raise.
  defp safe_fail_closed_update(run, artifact, sandbox_id, prefix, exception) do
    %{assertions_total: total, assertions_failed: failed, failing_assertion_ids: failing_ids} =
      fail_closed_counts(artifact)

    attrs = %{
      status: :failed,
      sandbox_id: sandbox_id,
      assertions_total: total,
      assertions_passed: 0,
      assertions_failed: failed,
      failing_assertion_ids: failing_ids,
      teardown_error: "assertion rerun crashed: " <> Exception.message(exception),
      completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    run
    |> PromotionAssertionRun.update_changeset(attrs)
    |> Repo.update(prefix: prefix)

    :ok
  rescue
    _exception -> :ok
  end

  defp build_result(%PromotionAssertionRun{} = run, idempotent_hit, teardown_event_appended) do
    %{
      run_id: run.id,
      status: run.status,
      assertions_total: run.assertions_total,
      assertions_passed: run.assertions_passed,
      assertions_failed: run.assertions_failed,
      failing_assertion_ids: run.failing_assertion_ids,
      sandbox_id: run.sandbox_id,
      teardown_error: run.teardown_error,
      idempotent_hit: idempotent_hit,
      teardown_event_appended: teardown_event_appended
    }
  end

  # Design §6 -- frozen_clock_ms is derived once per call (not per assertion, not
  # per replay-run), as the upper 32 bits of rng_seed treated as Unix epoch-seconds
  # multiplied to milliseconds (prm-batch1's FrozenClockProvider note, R-Co's own
  # Open question 1, restated in this design's §11 OQ-3 -- not resolved here).
  defp frozen_clock_ms(rng_seed) do
    (rng_seed >>> 32) * 1000
  end

  # Design §6.1 -- ports replayAssertions faithfully: for each assertion, in order,
  # run the evaluator twice under the same reset RNG seed, strip
  # non_deterministic_fields from both results, and byte-compare.
  defp replay_assertions(%PromotionArtifact{} = artifact, assertion_evaluator) do
    frozen_clock_ms = frozen_clock_ms(artifact.rng_seed)
    injection = %{frozen_clock_ms: frozen_clock_ms, rng_seed: artifact.rng_seed}

    {passed, failed, failing_ids_rev} =
      Enum.reduce(artifact.assertions, {0, 0, []}, fn assertion, {passed, failed, failing_ids} ->
        case replay_single_assertion(
               assertion,
               injection,
               artifact.rng_seed,
               artifact.non_deterministic_fields,
               assertion_evaluator
             ) do
          :passed -> {passed + 1, failed, failing_ids}
          :failed -> {passed, failed + 1, [assertion.id | failing_ids]}
        end
      end)

    %{
      assertions_total: length(artifact.assertions),
      assertions_passed: passed,
      assertions_failed: failed,
      failing_assertion_ids: Enum.reverse(failing_ids_rev)
    }
  end

  # Design §6.1 steps a-e: :rand.seed/2 immediately before each of the two replay
  # passes (matching Zig's own prng reset before each of its two runs) -- process-
  # scoped Erlang/OTP state, so concurrent calls never interfere with each other's
  # RNG state. Either evaluator call returning {:error, _} counts this assertion as
  # failed (fail-closed) -- an evaluator that cannot produce a result is not
  # silently treated as a pass.
  defp replay_single_assertion(
         assertion,
         injection,
         rng_seed,
         non_deterministic_fields,
         assertion_evaluator
       ) do
    seed_rng(rng_seed)
    result1 = assertion_evaluator.(assertion, injection)

    seed_rng(rng_seed)
    result2 = assertion_evaluator.(assertion, injection)

    with {:ok, result1_json} <- result1,
         {:ok, result2_json} <- result2 do
      compare_replay_results(assertion, result1_json, result2_json, non_deterministic_fields)
    else
      _ -> :failed
    end
  end

  # Splits the 64-bit rng_seed into :exsss's expected 3-integer tuple, matching
  # Zig's own std.Random.DefaultPrng.init(artifact.rng_seed) reset before each run
  # (design §6).
  defp seed_rng(rng_seed) do
    :rand.seed(:exsss, {band(rng_seed, 0xFFFFFFFF), rng_seed >>> 32, 0})
  end

  # Design §6.1 steps f-h: strip non_deterministic_fields from both results, then
  # byte-compare the re-encoded canonical JSON text (Jason.encode!/1 on Elixir maps
  # of identical content always iterates in the same order, so this comparison is
  # equivalent to Zig's own std.mem.eql(u8, ...) on the stripped, re-encoded text --
  # arguably more robust than a literal text diff, since it is insensitive to the
  # two results' original key ordering). A mismatch means this assertion is
  # non-deterministic (AC3's own idempotency check); on a match, assertion.payload's
  # own emptiness decides pass/fail (R-Co's own placeholder rule).
  defp compare_replay_results(assertion, result1_json, result2_json, non_deterministic_fields) do
    stripped1 = strip_non_deterministic_fields(result1_json, non_deterministic_fields)
    stripped2 = strip_non_deterministic_fields(result2_json, non_deterministic_fields)

    cond do
      stripped1 != stripped2 -> :failed
      byte_size(assertion.payload) == 0 -> :failed
      true -> :passed
    end
  end

  # Design §6.1 step f -- a direct port of stripDotPath's recursive
  # descend-then-remove-leaf-key algorithm (assertion_rerun.zig:589-601): parse as
  # JSON, for each dot-path descend into nested objects by "."-separated segments
  # and remove the final segment's key if present, re-encode to canonical JSON
  # text. A Jason.DecodeError here (result_json not valid JSON text) propagates as
  # a raised exception, caught by run_replay_span/8's own enclosing try/rescue --
  # this function does not swallow it, matching design §2's "exception anywhere in
  # this span" framing.
  defp strip_non_deterministic_fields(json_text, dot_paths) do
    decoded = Jason.decode!(json_text)

    stripped =
      Enum.reduce(dot_paths, decoded, fn dot_path, acc ->
        strip_dot_path(acc, String.split(dot_path, "."))
      end)

    Jason.encode!(stripped)
  end

  # A path that doesn't exist (missing key, or descends into a non-map value) is
  # silently skipped -- matches Zig's own stripDotPath exactly.
  defp strip_dot_path(value, [last_segment]) when is_map(value) do
    Map.delete(value, last_segment)
  end

  defp strip_dot_path(value, [segment | rest]) when is_map(value) do
    case Map.fetch(value, segment) do
      {:ok, nested} -> Map.put(value, segment, strip_dot_path(nested, rest))
      :error -> value
    end
  end

  defp strip_dot_path(value, _segments), do: value

  # Design §6.1 -- default assertion_evaluator when opts[:assertion_evaluator] is
  # omitted or nil: a direct, literal port of R-Co's own placeholder
  # (assertion_rerun.zig:500-501, 513-514), not a richer "real" evaluator this
  # codebase has no engine to justify. frozen_clock_ms/rng_seed are accepted but
  # unused, exactly as Zig's own placeholder computes and discards them.
  defp default_assertion_evaluator(%PromotionArtifact.Assertion{payload: payload}, _injection) do
    if byte_size(payload) > 0 do
      {:ok, payload}
    else
      {:ok, "{}"}
    end
  end
end
