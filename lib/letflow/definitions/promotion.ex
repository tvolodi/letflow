defmodule Letflow.Definitions.Promotion do
  @moduledoc """
  `promote_definition/3` — the version-pointer-move + event-append operation
  `Letflow.Definitions.PromotionReviewStore.mark_review_applied/2`'s *caller*
  invokes (some future orchestrator, REQ-040 or later, calls this function
  first, then `mark_review_applied/2` on success or `mark_review_failed/2` on
  failure). Ported from R-Co's `src/definition/promotion.zig` (ENV-03). See
  `lib/letflow/design/promotion_review_state_machine.md` §3 for the full
  gate-approved design this module implements; this moduledoc restates the
  invariants that design requires to be stated here verbatim in substance.

  ## Reuse, not reinvention (INV-PRM04-5)

  `promote_opts()`'s `permission_checker`/`tenant_classifier` are the exact
  same shape as `Letflow.Definitions.PromotionPlan.promotion_opts()`'s —
  same arities, same semantics. `permission_checker` has **no built-in
  default** (`Keyword.fetch!/2`, raises `KeyError` if omitted — there is no
  data path from `actor_id` to a real permission today, so silently
  defaulting to "allowed" would be worse than crashing). `tenant_classifier`
  defaults by **delegating** to
  `Letflow.Definitions.PromotionPlan.default_tenant_classifier/1` — not a
  duplicated copy of the same one-line function, so the two modules can never
  silently drift apart on what "test tenant" means. `variable_schema_fetcher`
  is not carried over — it has no meaning here.

  ## `opts[:event_appender]` — a new opt, deliberately with no built-in
  default (design §3.2 step 9, OQ-1)

  There is no data path from this function to a working
  `Letflow.EventStore.append/2` call today: no `DEFINITION_PROMOTED`-shaped
  event type is registered in any tenant's `event_type_registry`, and
  `append/2`'s `instance_id` guard has no non-instance-scoped path (even the
  `platform_instance_id/0` sentinel doesn't resolve to a real
  `instance_projections` row). This function does not paper over that gap
  with a silently-no-op or a silently-always-failing default —
  `opts[:event_appender]` is `Keyword.fetch!/2`'d, raises `KeyError` if
  omitted, same reasoning as `permission_checker`. The caller supplies
  whatever mechanism is actually wired up by the time this function is
  really invoked. Step 9 (the event-append) runs *after* the transaction in
  steps 7/8 commits, not nested inside it — this function does not assume
  anything about how an arbitrary injected `event_appender` manages its own
  transactionality, and it does not roll back the already-committed
  version-pointer move if the event-append fails. That is a real gap, stated
  here rather than hidden.

  ## Algorithm, in order (each step short-circuits on failure)

    1. `Jason.decode!/1` `review.serialised_plan` — a plain string-keyed map,
       never re-hydrated into the atom-keyed `PromotionPlan.t()` shape.
       Extracts `source_tenant_id`, `process_key`, `base_version`,
       `target_tenant_id` from it. **Post-Decision-0006-D2 note (REQ-064):**
       `target_tenant_id` used to be read from `review.tenant_id` directly
       (already a trusted, typed value on the struct); `promotion_reviews.tenant_id`
       no longer exists as a column (D2 dropped it — the per-tenant Postgres
       schema the row lives in already identifies the tenant), so this now reads
       `plan["target_tenant_id"]` instead — the same trusted value, already
       present in `serialised_plan` via `PromotionPlan.t().target_tenant_id`
       (`compute_promotion_plan/5`'s own output), not a new or less-trusted
       source.
    2. `opts[:permission_checker].(actor_id, source_tenant_id)` -> `false` ->
       `{:error, :forbidden}`.
    3. `opts[:tenant_classifier].(source_tenant_id) == :production` ->
       `{:error, :invalid_promotion_source}`.
    4. `Letflow.TenantProvisioning.schema_name_for_tenant/1` on both
       `source_tenant_id` and `target_tenant_id` -> `{:error,
       :invalid_tenant_id}` on either failure.
    5. Fresh plain read of the source's ACTIVE `process_definitions` row.
       `nil` -> `{:error, :source_definition_missing}` — a hard failure (this
       function has nothing to copy if the source has since been
       deactivated/archived between plan-compute time and approval time).
    6. **Conflict re-check** — resolves REQ-036's own forward-reference
       (`base_version` fed verbatim into
       `Letflow.Definitions.PromotionConflict.reject_if_conflicts/4`'s
       `base_version` argument at approval time): `{:error, {:conflicts,
       list}}` propagates unchanged. Deliberately placed here, not in
       `approve_review/4` — REQ-037's own text names only 3 gates for
       `approve_review/4`.
    7. Build the new target row's attrs from the freshly-read source row,
       via `ProcessDefinition.create_changeset/2`, inside one
       `Repo.transaction/1` together with step 8's swap. A
       `uq_definition_version` unique-constraint violation ->
       `{:error, :duplicate_version}` (mapped explicitly, never a leaked
       changeset for this one case).
    8. Two-step swap, inside the same transaction as step 7 (PD-03
       ordering — deprecate before activate): (a) guarded `UPDATE` deprecates
       whatever row is currently `active` for this `(target_tenant_id,
       process_key)`; (b) guarded `UPDATE` activates the row this function
       itself just inserted (still `:draft`, since `create_changeset/2`
       never casts `:status`). Inlined here rather than delegated to a real
       `activate/1` — REQ-030 (that function's owner) is not a dependency of
       REQ-037 and has not shipped (see moduledoc OQ-5 in the design doc).
    9. Event-append, after the transaction commits:
       `opts[:event_appender].(event_attrs, target_prefix)`.
    10. `{:ok, promote_result()}` if step 9 succeeds; step 9's own error
        propagates unchanged otherwise.
  """

  import Ecto.Query

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.PromotionConflict
  alias Letflow.Definitions.PromotionPlan
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @type promote_opts :: [
          permission_checker: (Ecto.UUID.t(), Ecto.UUID.t() -> boolean()),
          tenant_classifier: (Ecto.UUID.t() -> :production | :test),
          event_appender: (map(), String.t() -> {:ok, term()} | {:error, term()})
        ]

  @type promote_result :: %{
          source_definition_id: Ecto.UUID.t(),
          target_definition_id: Ecto.UUID.t(),
          process_key: String.t()
        }

  @type promote_error ::
          :forbidden
          | :invalid_promotion_source
          | :invalid_tenant_id
          | :source_definition_missing
          | :duplicate_version
          | {:conflicts, [PromotionConflict.conflict_detail()]}
          | Ecto.Changeset.t()
          | term()

  @doc """
  Performs the version-pointer move (deprecate current active, activate the
  newly-copied target row) plus event-append for `review`'s already-approved
  promotion plan. See moduledoc for the full 10-step algorithm and the
  `opts[:event_appender]` gap this function deliberately does not paper over.
  """
  @spec promote_definition(
          actor_id :: Ecto.UUID.t(),
          review :: PromotionReview.t(),
          opts :: promote_opts()
        ) :: {:ok, promote_result()} | {:error, promote_error()}
  def promote_definition(actor_id, %PromotionReview{} = review, opts) do
    permission_checker = Keyword.fetch!(opts, :permission_checker)

    tenant_classifier =
      Keyword.get(opts, :tenant_classifier, &PromotionPlan.default_tenant_classifier/1)

    event_appender = Keyword.fetch!(opts, :event_appender)

    plan = Jason.decode!(review.serialised_plan)
    source_tenant_id = plan["source_tenant_id"]
    process_key = plan["process_key"]
    base_version = plan["base_version"]
    # Post-Decision-0006-D2 (REQ-064): was `review.tenant_id` -- that column no
    # longer exists on `promotion_reviews`. `plan["target_tenant_id"]` is the
    # same trusted value (PromotionPlan.t().target_tenant_id, already
    # serialised into this review at insert_review/2 time), not a new source.
    target_tenant_id = plan["target_tenant_id"]

    cond do
      not permission_checker.(actor_id, source_tenant_id) ->
        {:error, :forbidden}

      tenant_classifier.(source_tenant_id) == :production ->
        {:error, :invalid_promotion_source}

      true ->
        do_promote_definition(
          actor_id,
          review,
          source_tenant_id,
          target_tenant_id,
          process_key,
          base_version,
          event_appender
        )
    end
  end

  defp do_promote_definition(
         actor_id,
         review,
         source_tenant_id,
         target_tenant_id,
         process_key,
         base_version,
         event_appender
       ) do
    with {:ok, source_prefix} <- TenantProvisioning.schema_name_for_tenant(source_tenant_id),
         {:ok, target_prefix} <- TenantProvisioning.schema_name_for_tenant(target_tenant_id),
         {:ok, source_row} <- fetch_source_definition(process_key, source_prefix),
         :ok <-
           PromotionConflict.reject_if_conflicts(actor_id, target_tenant_id, [process_key], [
             base_version
           ]),
         {:ok, new_row} <-
           write_target_definition(
             source_row,
             process_key,
             actor_id,
             target_prefix
           ) do
      append_promotion_event(
        event_appender,
        target_prefix,
        actor_id,
        review,
        source_tenant_id,
        target_tenant_id,
        source_row,
        new_row,
        process_key
      )
    end
  end

  @spec fetch_source_definition(String.t(), String.t()) ::
          {:ok, ProcessDefinition.t()} | {:error, :source_definition_missing}
  defp fetch_source_definition(process_key, source_prefix) do
    case Repo.get_by(ProcessDefinition, [name: process_key, status: :active],
           prefix: source_prefix
         ) do
      nil -> {:error, :source_definition_missing}
      %ProcessDefinition{} = row -> {:ok, row}
    end
  end

  # Design §3.2 steps 7-8, both inside one Repo.transaction/1: insert the
  # target row (still :draft, uq_definition_version mapped to
  # :duplicate_version), then the guarded deprecate-then-activate swap
  # (PD-03 ordering). No longer takes target_tenant_id (Decision 0006 D2,
  # REQ-064) -- it was only ever forwarded to deprecate_previous_active/3's
  # now-removed tenant_id filter; target_prefix alone already scopes every
  # write in this function to the correct tenant schema.
  @spec write_target_definition(
          ProcessDefinition.t(),
          String.t(),
          Ecto.UUID.t(),
          String.t()
        ) :: {:ok, ProcessDefinition.t()} | {:error, :duplicate_version | Ecto.Changeset.t()}
  defp write_target_definition(source_row, process_key, actor_id, target_prefix) do
    attrs = %{
      name: process_key,
      version: source_row.version,
      description: source_row.description,
      stage: source_row.stage,
      graph: source_row.graph,
      created_by: actor_id
    }

    Repo.transaction(fn ->
      %ProcessDefinition{}
      |> ProcessDefinition.create_changeset(attrs)
      |> Repo.insert(prefix: target_prefix)
      |> case do
        {:ok, new_row} ->
          deprecate_previous_active(process_key, target_prefix)
          activate_new_definition(new_row, target_prefix)

        {:error, %Ecto.Changeset{} = changeset} ->
          if duplicate_version_error?(changeset) do
            Repo.rollback(:duplicate_version)
          else
            Repo.rollback(changeset)
          end
      end
    end)
  end

  # Step 8(a) -- deprecate whatever row is currently active for this
  # process_key, within target_prefix's own tenant schema. 0 or 1 row, never
  # more -- uq_active_definition guarantees at most one. Post-Decision-0006-D2
  # (REQ-064): was additionally filtered on `d.tenant_id == ^target_tenant_id`;
  # that column no longer exists on `process_definitions` -- `target_prefix`
  # (the schema this Repo.update_all/3 call is scoped to via `prefix:`) already
  # confines this query to exactly one tenant, so the extra predicate was
  # redundant with the schema boundary and is dropped along with the column.
  defp deprecate_previous_active(process_key, target_prefix) do
    from(d in ProcessDefinition,
      where: d.name == ^process_key and d.status == :active
    )
    |> Repo.update_all([set: [status: :deprecated]], prefix: target_prefix)
  end

  # Step 8(b) -- activate the row this function itself just inserted, still
  # :draft (create_changeset/2 never casts :status). Exactly 1 row, always --
  # this is the same transaction that inserted it, nothing else can have
  # touched it yet.
  defp activate_new_definition(new_row, target_prefix) do
    query =
      from(d in ProcessDefinition, where: d.id == ^new_row.id and d.status == :draft, select: d)

    {1, [activated_row]} = Repo.update_all(query, [set: [status: :active]], prefix: target_prefix)
    activated_row
  end

  @spec duplicate_version_error?(Ecto.Changeset.t()) :: boolean()
  defp duplicate_version_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        Keyword.get(opts, :constraint_name) == "uq_definition_version"
    end)
  end

  # Step 9 -- after the transaction commits (design §3.2 step 9, OQ-1: no
  # built-in default, no nesting inside the transaction above).
  defp append_promotion_event(
         event_appender,
         target_prefix,
         actor_id,
         review,
         source_tenant_id,
         target_tenant_id,
         source_row,
         new_row,
         process_key
       ) do
    event_attrs = %{
      event_type: "DEFINITION_PROMOTED",
      actor_id: actor_id,
      review_id: review.id,
      source_tenant_id: source_tenant_id,
      target_tenant_id: target_tenant_id,
      source_definition_id: source_row.id,
      target_definition_id: new_row.id,
      process_key: process_key
    }

    case event_appender.(event_attrs, target_prefix) do
      {:ok, _} ->
        {:ok,
         %{
           source_definition_id: source_row.id,
           target_definition_id: new_row.id,
           process_key: process_key
         }}

      {:error, _reason} = error ->
        error
    end
  end
end
