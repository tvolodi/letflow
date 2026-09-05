defmodule Letflow.Routers.Promotions do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Promotion-pipeline sub-router (REQ-077), mounted at `/promotions` by
  `Letflow.Plugs.ApiPipeline`. Ports six R-Co route modules
  (`promotion_review.zig`, `promotions.zig`, `promotion_read.zig`,
  `promotion_assertion.zig`) as eight of this requirement's ten routes — R9
  (rollback) lives in `Letflow.Routers.Definitions` and R10 (ENV-03 promote)
  lives in `Letflow.Routers.Tenants`, each for the one-forward-per-prefix
  reason stated in their own moduledocs. See
  `lib/letflow/design/req077-promotion-pipeline-routes.md` for the full
  gate-approved design this module implements.

  ## Route table (design §1)

  | # | Method | Path | Handler | Context call(s) | Success |
  |---|---|---|---|---|---|
  | R1 | POST | `/` | `handle_submit/2` | `PromotionPlan.compute_promotion_plan/5` -> `PromotionConflict.reject_if_conflicts/4` -> `PromotionDigest.compute_plan_digest/1` -> `PromotionReviewStore.insert_review/2` | 201 |
  | R2 | POST | `/plan` | `handle_plan/2` | `PromotionPlan.compute_promotion_plan/5` | 200 |
  | R3 | GET | `/:id` | `handle_get_assertion_run/2` | `PromotionReviewStore.get_review/2` -> `Definitions.get_latest_assertion_run/2` | 200 |
  | R4 | GET | `/:id/context` | `handle_context/2` | `PromotionReviewStore.get_review/2` | 200 |
  | R5 | POST | `/:id/approve` | `handle_approve/2` | `PromotionReviewStore.approve_review/4` | 200 |
  | R6 | POST | `/:id/reject` | `handle_reject/2` | `PromotionReviewStore.reject_review/3` | 200 |
  | R7 | POST | `/:id/apply` | `handle_apply/2` | `Promotion.apply_review/4` | 200 |
  | R8 | POST | `/:review_id/run-assertions` | `handle_run_assertions/2` | `PromotionArtifact.from_json/1` -> `Definitions.apply_promotion_assertion_rerun/6` | 200/422 |

  ## The `POST /promotions` collision, resolved (F-2, a deliberate divergence from R-Co)

  PROVENANCE (historical, not current decision authority):
  R-Co has two handlers claiming this path: `promotions.zig`'s
  `handleCreatePromotionPlan` (a read-only diff preview, wired at
  `main.zig:1577`) and `promotion_review.zig`'s `handleSubmitPromotion`
  (computes the diff, re-checks conflicts, computes the digest, and inserts
  a `promotion_reviews` row — never wired in R-Co at all, F-1). This module
  assigns `POST /promotions` to **submit** (`handleSubmitPromotion`'s
  semantics, 201, a durable write) and `POST /promotions/plan` to **preview**
  (`handleCreatePromotionPlan`'s semantics, 200, read-only) — the only
  assignment where a `POST` on the collection URI that returns 201 and
  creates a resource lands on the collection URI itself. Nothing outside
  R-Co consumed either contract before this requirement (`web/` has no
  promotion client), so there is no compatibility cost either way.

  ## The `:Unknown` authorization decision (design §4) — deliberate, not an omission

  PROVENANCE (historical, not current decision authority):
  Every route in this module is declared with `Letflow.Api.AuthorizedRouter`'s
  plain `get`/`post` macros (NOT `authz_get`/`authz_post`), so none carries a
  `:policy_key` — `Letflow.Plugs.Authorize` (mounted for every request by
  `use Letflow.Api.AuthorizedRouter`) evaluates every one of them as
  `endpoint == :Unknown`, `Letflow.Api.Authorization.evaluate_access/2`'s own
  catch-all: `Allow` for `PLATFORM_ADMIN` only, `Deny403` for every other
  role, including a caller with no roles at all — the strictest gate this
  codebase has. `required_permission(:Unknown) -> :MetricsRead` exists in
  that module but is dead code on this path (`evaluate_access/2`'s `cond`
  short-circuits on `:Unknown` in its first branch) and is NOT what gates
  these routes. PLATFORM_ADMIN-only access to the promotions resource is a
  considered decision (design §4.2, and R-Co's `main.zig:1571` hardcodes
  the same restriction), not an unhandled fallthrough: no new
  policy key or permission is added to `Letflow.Api.Authorization` by this
  requirement.

  This module intentionally does NOT use `authz_get`/`authz_post` for these
  routes: those macros exist for a route that needs a *specific*,
  independently-registered `endpoint_policy_key/2` clause, which none of
  these routes has (see `lib/letflow/api/authorized_router.ex`'s own
  moduledoc, "A route that must intentionally NOT declare a policy key").

  ## INV-5 — a cross-tenant review id is the SAME response as a nonexistent one (design §5)

  `promotion_reviews` carries no `tenant_id` column at all (REQ-064 /
  Decision 0006 D2) — the per-tenant Postgres schema a row lives in already
  identifies its tenant. So another tenant's review is not "found and then
  filtered" — it is simply not present in the schema `conn.assigns.scoped_opts`
  points at, and the underlying primary-key lookup resolves to nothing for
  that reason through the exact same code path as a review id that was
  never issued to anyone. There is
  deliberately no second, unscoped existence check anywhere in this module —
  one would (a) reintroduce the distinguishability INV-5 forbids, (b) add a
  round-trip on one path and not the other (a timing signal), and (c) itself
  be a cross-tenant read (an INV-1 violation).

  ## The single-atom 409 rule (design §6.1) — approve/reject/apply

  `PromotionReviewStore` returns the same `:invalid_transition` atom for
  every illegal edge AND for a lost optimistic-lock race — it cannot, and
  must not, be asked to distinguish them (a second read to find out would be
  a TOCTOU and an oracle off a failed write). So R5/R6/R7 map
  `:invalid_transition` to exactly one 409 document, `detail: "review is not
  in a state that permits this transition"`, naming the *operation class*,
  never the row's actual status. This is a deliberate 409 upgrade from
  R-Co's 400 `INVALID_REVIEW_TRANSITION` (D-8), required by AC4's own
  wording; the other two 409s (`PLAN_DIGEST_MISMATCH`,
  `DUPLICATE_REVIEW`) needed no such upgrade and carry through unchanged as
  409s here too.

  ## Assertion-run idempotency is preserved by omission (design §8.1, AC2)

  PROVENANCE (historical, not current decision authority):
  `Definitions.apply_promotion_assertion_rerun/6` already derives its own
  idempotency key from `(review_id, plan_digest)` and returns the cached row
  unchanged on a repeat. This module's only obligations are omissions: no
  `Idempotency-Key` header is read or forwarded, and `assertion_rerun_map/1`
  (§7.5) does NOT surface `idempotent_hit` — the one field in
  `assertion_rerun_result/0` that differs between the first call and a
  repeat. Emitting it would make AC2's "two identical successful responses"
  false by construction. R-Co's `ALREADY_RECORDED` 200-with-error-envelope
  repeat path (`promotion_assertion.zig:133`, D-5) is not ported — it breaks
  AC2 outright.

  ## The assertion-run gate condition (design §7.5)

  R8's 200-vs-422 split keys on the returned `assertions_failed == 0`, NOT
  on `status == :passed` — `apply_promotion_assertion_rerun/6`'s own `@doc`
  states this gate condition explicitly (a `status = :teardown_failed`
  result with `assertions_failed == 0` is a green gate). Porting R-Co's
  `result.status != .failed` check would silently disagree with that
  documented contract.

  ## The unknown-field note (design §4.4)

  PROVENANCE (historical, not current decision authority):
  `Letflow.Api.Validation.validate/2` returns `Map.take(body,
  declared_field_names)`, so a caller-injected field not in a route's schema
  (e.g. an `approved_by` trying to override `actor_id`) cannot reach the
  handler's `attrs` at all — structurally, not by a runtime check. R-Co's
  422 `UNKNOWN_FIELD` response (`promotion_review.zig:398-406`) is therefore
  not ported: stronger by construction, weaker in diagnostics only.

  ## The `permission_checker` gap (design §7.9) — the biggest security caveat here

  `PromotionPlan.compute_promotion_plan/5` and `Promotion.promote_definition/3`
  both require a `permission_checker`, and the only implementation that
  exists, `PromotionPlan.default_permission_checker/2`, performs **no real
  enforcement** — it always returns `true`. R1, R2 and R10 all read another
  tenant's process-definition graph by design (a promotion is inherently
  cross-tenant), so under the always-true default any caller reaching them
  can read any tenant's definitions by naming that tenant as
  `source_tenant_id`. This is bounded, not eliminated, by the `:Unknown`
  decision above: only `PLATFORM_ADMIN` can reach R1/R2/R10 today, and that
  role already has legitimate cross-tenant reach via REQ-075's
  `:TenantsManage` routes — so this is a missing enforcement layer, not a
  live escalation, UNLESS a later requirement widens access to these routes
  before this gap is closed. **Escalated to SECURITY-REVIEWER (design §11
  OQ-2), not resolved here.** Every call site below passes
  `permission_checker: &PromotionPlan.default_permission_checker/2`
  explicitly and by name (never an inline `fn _, _ -> true end`), so
  `grep -rn "default_permission_checker" lib/` finds every place this gap is
  live.

  ## The allowlist statement (design §7, AC6)

  Every response body below is a hand-built map with exactly the key set
  named in its own `@doc` — never a `Jason.Encoder` derivation over an Ecto
  struct, never `Map.from_struct/1`, never `Map.drop/2`. This module never
  touches the persistence layer directly — no such call and no such import
  or alias appears anywhere in it — every database-touching call goes
  through a promotion context
  module (`Letflow.Definitions.PromotionPlan`/`PromotionConflict`/
  `PromotionDigest`/`PromotionReviewStore`/`PromotionArtifact`,
  `Letflow.Definitions`, `Letflow.Definitions.Promotion`), each already
  scoped by the `[prefix: ...]` fragment `Letflow.Plugs.Authorize` resolved
  before this router's `:dispatch` ever ran.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Definitions
  alias Letflow.Definitions.Promotion
  alias Letflow.Definitions.PromotionArtifact
  alias Letflow.Definitions.PromotionConflict
  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Definitions.PromotionPlan
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Definitions.PromotionReviewStore
  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.EventStore.PlatformEvents

  # `:Unknown`-gated (see moduledoc) -- plain macros, no policy key.
  # "/plan" is declared before the "/:id/..." two-segment patterns even
  # though it cannot actually collide with any of them (no `post "/:id"`
  # exists in this file) -- the cheap, order-independent-looking form
  # (design §2.2).

  post "/" do
    handle_submit(conn)
  end

  post "/plan" do
    handle_plan(conn)
  end

  get "/:id" do
    handle_get_assertion_run(conn, conn.params["id"])
  end

  get "/:id/context" do
    handle_context(conn, conn.params["id"])
  end

  post "/:id/approve" do
    handle_approve(conn, conn.params["id"])
  end

  post "/:id/reject" do
    handle_reject(conn, conn.params["id"])
  end

  post "/:id/apply" do
    handle_apply(conn, conn.params["id"])
  end

  post "/:review_id/run-assertions" do
    handle_run_assertions(conn, conn.params["review_id"])
  end

  match _ do
    Response.not_found(conn)
  end

  # ── POST /promotions -- R1, submit (design §7.1) ────────────────────────

  @submit_schema [
    %FieldConstraint{
      name: "source_tenant_id",
      required: true,
      type: :uuid,
      reject_empty_string: true
    },
    %FieldConstraint{
      name: "target_tenant_id",
      required: true,
      type: :uuid,
      reject_empty_string: true
    },
    %FieldConstraint{
      name: "process_key",
      required: true,
      type: :string,
      reject_empty_string: true,
      max_length: 255
    },
    %FieldConstraint{
      name: "base_version",
      required: true,
      type: :string,
      reject_empty_string: true,
      max_length: 64
    }
  ]

  defp handle_submit(conn) do
    opts = conn.assigns.scoped_opts
    actor_id = conn.assigns.auth_context.user_id

    case Validation.validate(@submit_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, attrs} ->
        render_submit(conn, do_submit(actor_id, attrs, opts))
    end
  end

  defp do_submit(actor_id, attrs, opts) do
    with {:ok, plan} <-
           PromotionPlan.compute_promotion_plan(
             actor_id,
             attrs["source_tenant_id"],
             attrs["target_tenant_id"],
             attrs["process_key"],
             permission_checker: &PromotionPlan.default_permission_checker/2
           ),
         :ok <-
           PromotionConflict.reject_if_conflicts(
             actor_id,
             attrs["target_tenant_id"],
             [attrs["process_key"]],
             [attrs["base_version"]]
           ) do
      digest = PromotionDigest.compute_plan_digest(plan)

      PromotionReviewStore.insert_review(
        %{plan: plan, digest: digest, requested_by: actor_id},
        opts
      )
    end
  end

  defp render_submit(conn, {:ok, %PromotionReview{} = review}) do
    Response.created(conn, %{"review_id" => review.id, "plan_digest" => review.plan_digest})
  end

  defp render_submit(conn, {:error, :forbidden}),
    do: Response.forbidden(conn, "insufficient permissions")

  defp render_submit(conn, {:error, :invalid_promotion_source}),
    do:
      Response.send_problem(
        conn,
        Error.invalid_promotion_source("source_tenant_id must name a test tenant")
      )

  defp render_submit(conn, {:error, :empty_plan}),
    do:
      Response.send_problem(
        conn,
        Error.empty_promotion_plan("source and target are identical after canonicalisation")
      )

  defp render_submit(conn, {:error, :invalid_tenant_id}),
    do:
      Response.unprocessable(
        conn,
        "source_tenant_id or target_tenant_id does not name a provisioned tenant"
      )

  defp render_submit(conn, {:error, {:conflicts, details}}),
    do:
      Response.send_problem(
        conn,
        Error.promotion_conflict("target tenant has advanced past base_version", details)
      )

  # Route always passes two 1-element lists -- unreachable by construction.
  defp render_submit(conn, {:error, :mismatched_process_key_list}),
    do: Response.internal_error(conn)

  defp render_submit(conn, {:error, :duplicate_review}),
    do: Response.conflict(conn, "a live review for this plan digest already exists")

  # digest computed from the same plan one line earlier -- a mismatch here is
  # internal inconsistency, never caller-caused.
  defp render_submit(conn, {:error, :digest_mismatch}), do: Response.internal_error(conn)
  defp render_submit(conn, {:error, :invalid_schema_name}), do: Response.internal_error(conn)
  defp render_submit(conn, {:error, %Ecto.Changeset{}}), do: Response.internal_error(conn)

  # ── POST /promotions/plan -- R2, plan preview (design §7.2) ─────────────

  @plan_schema [
    %FieldConstraint{
      name: "source_tenant_id",
      required: true,
      type: :uuid,
      reject_empty_string: true
    },
    %FieldConstraint{
      name: "target_tenant_id",
      required: true,
      type: :uuid,
      reject_empty_string: true
    },
    %FieldConstraint{
      name: "process_key",
      required: true,
      type: :string,
      reject_empty_string: true,
      max_length: 255
    }
  ]

  defp handle_plan(conn) do
    opts = conn.assigns.scoped_opts
    actor_id = conn.assigns.auth_context.user_id

    case Validation.validate(@plan_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, attrs} ->
        result =
          PromotionPlan.compute_promotion_plan(
            actor_id,
            attrs["source_tenant_id"],
            attrs["target_tenant_id"],
            attrs["process_key"],
            permission_checker: &PromotionPlan.default_permission_checker/2
          )

        render_plan(conn, result, opts)
    end
  end

  defp render_plan(conn, {:ok, plan}, _opts),
    do: Response.ok(conn, %{"entries" => Enum.map(plan.entries, &plan_entry_map/1)})

  defp render_plan(conn, {:error, :forbidden}, _opts),
    do: Response.forbidden(conn, "insufficient permissions")

  defp render_plan(conn, {:error, :invalid_promotion_source}, _opts),
    do:
      Response.send_problem(
        conn,
        Error.invalid_promotion_source("source_tenant_id must name a test tenant")
      )

  defp render_plan(conn, {:error, :empty_plan}, _opts),
    do:
      Response.send_problem(
        conn,
        Error.empty_promotion_plan("source and target are identical after canonicalisation")
      )

  defp render_plan(conn, {:error, :invalid_tenant_id}, _opts),
    do:
      Response.unprocessable(
        conn,
        "source_tenant_id or target_tenant_id does not name a provisioned tenant"
      )

  # PROVENANCE (historical, not current decision authority):
  # Exactly 5 keys (design §7.2), ported from promotions.zig:145-163.
  # `before`/`after` emitted as-is (object/string/nil) -- not stringified,
  # unlike R-Co (a considered improvement, not a port defect).
  @doc false
  @spec plan_entry_map(PromotionPlan.plan_entry()) :: map()
  defp plan_entry_map(entry) do
    %{
      "type" => Atom.to_string(entry.type),
      "id" => entry.id,
      "change_kind" => Atom.to_string(entry.change_kind),
      "before" => entry.before,
      "after" => entry.after
    }
  end

  # ── GET /promotions/:id -- R3, latest assertion run (design §7.4) ───────

  defp handle_get_assertion_run(conn, raw_id) do
    opts = conn.assigns.scoped_opts

    case PromotionReviewStore.get_review(raw_id, opts) do
      {:error, :review_not_found} ->
        Response.not_found(conn)

      {:ok, %PromotionReview{}} ->
        render_assertion_run(conn, Definitions.get_latest_assertion_run(raw_id, opts))
    end
  end

  defp render_assertion_run(conn, {:error, :not_found}),
    do: Response.ok(conn, %{"assertion_run" => nil})

  defp render_assertion_run(conn, {:ok, run}),
    do: Response.ok(conn, %{"assertion_run" => assertion_run_map(run)})

  # PROVENANCE (historical, not current decision authority):
  # Exactly 7 keys (design §7.4), ported from promotion_read.zig:102-149.
  # `plan_digest` is deliberately excluded -- see design §7.4/§8.3: emitting
  # it here would hand a reader of an assertion run the exact token needed
  # to approve or apply the review it belongs to.
  @doc false
  @spec assertion_run_map(Definitions.PromotionAssertionRun.t()) :: map()
  defp assertion_run_map(run) do
    %{
      "run_id" => run.id,
      "status" => Atom.to_string(run.status),
      "sandbox_id" => run.sandbox_id,
      "teardown_error" => run.teardown_error,
      "assertions_passed" => run.assertions_passed,
      "assertions_failed" => run.assertions_failed,
      "failing_assertion_ids" => run.failing_assertion_ids
    }
  end

  # ── GET /promotions/:id/context -- R4 (design §7.3) ──────────────────────

  defp handle_context(conn, raw_id) do
    opts = conn.assigns.scoped_opts
    render_context(conn, PromotionReviewStore.get_review(raw_id, opts))
  end

  defp render_context(conn, {:error, :review_not_found}), do: Response.not_found(conn)

  defp render_context(conn, {:ok, %PromotionReview{} = review}),
    do: Response.ok(conn, review_context_map(review))

  # PROVENANCE (historical, not current decision authority):
  # Exactly 9 keys (design §7.3), ported from promotion_review.zig:321-337.
  # `serialised_plan` is decoded (real object, not a spliced raw string).
  # `created_at` is real (`iso8601/1` of `inserted_at`) -- R-Co hardcodes
  # "1970-01-01T00:00:00Z" (D-3), not ported. `assertions`/
  # `needs_review_package` are domain logic computed inline by the handler
  # in R-Co and are not ported here (OQ-3, no context module produces either).
  @doc false
  @spec review_context_map(PromotionReview.t()) :: map()
  defp review_context_map(review) do
    %{
      "review_id" => review.id,
      "plan_digest" => review.plan_digest,
      "serialised_plan" => Jason.decode!(review.serialised_plan),
      "status" => Atom.to_string(review.status),
      "requested_by" => review.requested_by,
      "def_type" => review.def_type,
      "def_id" => review.def_id,
      "created_at" => iso8601(review.inserted_at),
      "row_version" => review.row_version
    }
  end

  # ── POST /promotions/:id/approve -- R5 (design §7.5, §5.3, §6) ──────────

  @digest_schema [
    %FieldConstraint{
      name: "plan_digest",
      required: true,
      type: :string,
      reject_empty_string: true,
      min_length: 64,
      max_length: 64
    }
  ]

  defp handle_approve(conn, raw_id) do
    case cast_review_id(raw_id) do
      {:error, :not_uuid} ->
        Response.not_found(conn)

      {:ok, id} ->
        opts = conn.assigns.scoped_opts
        actor_id = conn.assigns.auth_context.user_id

        case Validation.validate(@digest_schema, conn.body_params) do
          {:errors, field_errors} ->
            Response.send_problem(conn, Validation.problem(field_errors))

          {:ok, attrs} ->
            render_approve(
              conn,
              PromotionReviewStore.approve_review(id, actor_id, attrs["plan_digest"], opts)
            )
        end
    end
  end

  defp render_approve(conn, {:ok, review}),
    do: Response.ok(conn, %{"review_id" => review.id, "status" => "approved"})

  defp render_approve(conn, {:error, :review_not_found}), do: Response.not_found(conn)

  defp render_approve(conn, {:error, :self_approval_forbidden}),
    do: Response.forbidden(conn, "a reviewer cannot approve their own promotion request")

  defp render_approve(conn, {:error, :digest_mismatch}),
    do: Response.conflict(conn, "the provided plan_digest does not match the stored digest")

  defp render_approve(conn, {:error, :invalid_transition}), do: invalid_transition_response(conn)

  # ── POST /promotions/:id/reject -- R6 (design §7.5, §5.2, §6) ───────────

  defp handle_reject(conn, raw_id) do
    case cast_review_id(raw_id) do
      {:error, :not_uuid} ->
        Response.not_found(conn)

      {:ok, id} ->
        opts = conn.assigns.scoped_opts
        actor_id = conn.assigns.auth_context.user_id

        case Validation.validate([], conn.body_params) do
          {:errors, field_errors} ->
            Response.send_problem(conn, Validation.problem(field_errors))

          {:ok, _attrs} ->
            render_reject(conn, PromotionReviewStore.reject_review(id, actor_id, opts))
        end
    end
  end

  defp render_reject(conn, {:ok, review}),
    do: Response.ok(conn, %{"review_id" => review.id, "status" => "rejected"})

  defp render_reject(conn, {:error, :review_not_found}), do: Response.not_found(conn)
  defp render_reject(conn, {:error, :invalid_transition}), do: invalid_transition_response(conn)

  # ── POST /promotions/:id/apply -- R7 (design §7.5, §9.3) ────────────────

  defp handle_apply(conn, raw_id) do
    opts = conn.assigns.scoped_opts
    actor_id = conn.assigns.auth_context.user_id

    case Validation.validate(@digest_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, attrs} ->
        result =
          Promotion.apply_review(
            raw_id,
            actor_id,
            attrs["plan_digest"],
            Keyword.merge(opts,
              permission_checker: &PromotionPlan.default_permission_checker/2,
              event_appender: &PlatformEvents.append_definition_promoted/2
            )
          )

        render_apply(conn, result)
    end
  end

  defp render_apply(conn, {:ok, %{review_id: review_id}}),
    do: Response.ok(conn, %{"review_id" => review_id, "status" => "applied"})

  defp render_apply(conn, {:error, :review_not_found}), do: Response.not_found(conn)

  defp render_apply(conn, {:error, :digest_mismatch}),
    do: Response.conflict(conn, "the provided plan_digest does not match the stored digest")

  defp render_apply(conn, {:error, :invalid_transition}), do: invalid_transition_response(conn)

  defp render_apply(conn, {:error, {:promotion_failed, :forbidden}}),
    do: Response.forbidden(conn, "insufficient permissions")

  defp render_apply(conn, {:error, {:promotion_failed, :invalid_promotion_source}}),
    do:
      Response.send_problem(
        conn,
        Error.invalid_promotion_source("source_tenant_id must name a test tenant")
      )

  defp render_apply(conn, {:error, {:promotion_failed, :source_definition_missing}}),
    do: Response.conflict(conn, "the source definition is no longer active")

  defp render_apply(conn, {:error, {:promotion_failed, {:conflicts, details}}}),
    do:
      Response.send_problem(
        conn,
        Error.promotion_conflict("target tenant has advanced past base_version", details)
      )

  defp render_apply(conn, {:error, {:promotion_failed, :duplicate_version}}),
    do: Response.conflict(conn, "the target version already exists in the target tenant")

  defp render_apply(conn, {:error, {:promotion_failed, :invalid_tenant_id}}),
    do: Response.internal_error(conn)

  defp render_apply(conn, {:error, {:promotion_failed, _other}}),
    do: Response.internal_error(conn)

  # ── POST /promotions/:review_id/run-assertions -- R8 (design §7.5) ──────

  @run_assertions_schema [
    %FieldConstraint{
      name: "plan_digest",
      required: true,
      type: :string,
      reject_empty_string: true,
      min_length: 64,
      max_length: 64
    },
    %FieldConstraint{name: "artifact", required: true, type: :object}
  ]

  defp handle_run_assertions(conn, raw_review_id) do
    case cast_review_id(raw_review_id) do
      {:error, :not_uuid} ->
        Response.not_found(conn)

      {:ok, review_id} ->
        opts = conn.assigns.scoped_opts

        case Validation.validate(@run_assertions_schema, conn.body_params) do
          {:errors, field_errors} ->
            Response.send_problem(conn, Validation.problem(field_errors))

          {:ok, attrs} ->
            run_assertions(conn, review_id, attrs, opts)
        end
    end
  end

  defp run_assertions(conn, review_id, attrs, opts) do
    case PromotionArtifact.from_json(attrs["artifact"]) do
      {:error, {:invalid_artifact, _field}} ->
        Response.unprocessable(conn, "artifact is not a well-formed promotion artifact")

      {:ok, artifact} ->
        sandbox_pool =
          Application.get_env(:letflow, :promotion_assertion_pool, Letflow.SandboxPool)

        max_wait_ms = Application.get_env(:letflow, :promotion_assertion_max_wait_ms, 5_000)

        result =
          Definitions.apply_promotion_assertion_rerun(
            review_id,
            attrs["plan_digest"],
            artifact,
            sandbox_pool,
            max_wait_ms,
            Keyword.merge(opts,
              event_appender: &PlatformEvents.append_promotion_assertion_teardown_failed/2
            )
          )

        render_run_assertions(conn, result)
    end
  end

  defp render_run_assertions(conn, {:ok, %{assertions_failed: 0} = r}),
    do: Response.ok(conn, assertion_rerun_map(r))

  # Body is the plain assertion_rerun_map/1 (design §7.5 -- "same body
  # shape" as the 200 case), NOT an RFC 9457 problem document: a
  # not-all-assertions-passed result is structured content the caller needs
  # to read (run_id, failing_assertion_ids, ...), not an error envelope.
  defp render_run_assertions(conn, {:ok, %{assertions_failed: n} = r}) when n > 0,
    do: Response.send_json(conn, 422, assertion_rerun_map(r))

  defp render_run_assertions(conn, {:error, :review_not_found}), do: Response.not_found(conn)

  defp render_run_assertions(conn, {:error, :sandbox_unavailable}),
    do: Response.service_unavailable(conn, "no sandbox free within timeout")

  defp render_run_assertions(conn, {:error, :provision_failed}),
    do: Response.service_unavailable(conn, "sandbox provisioning failed")

  defp render_run_assertions(conn, {:error, :fixture_load_failed}),
    do: Response.unprocessable(conn, "fixture load into sandbox failed")

  defp render_run_assertions(conn, {:error, {:idempotency_lookup_failed, :sidecar_row_missing}}),
    do: Response.internal_error(conn)

  defp render_run_assertions(conn, {:error, _other}), do: Response.internal_error(conn)

  # PROVENANCE (historical, not current decision authority):
  # Exactly 6 keys (design §7.5), ported from promotion_assertion.zig:145-170.
  # `idempotent_hit` is deliberately NOT a key -- see moduledoc, AC2.
  @doc false
  @spec assertion_rerun_map(Definitions.assertion_rerun_result()) :: map()
  defp assertion_rerun_map(r) do
    %{
      "run_id" => r.run_id,
      "status" => Atom.to_string(r.status),
      "assertions_passed" => r.assertions_passed,
      "assertions_failed" => r.assertions_failed,
      "failing_assertion_ids" => r.failing_assertion_ids,
      "sandbox_id" => r.sandbox_id
    }
  end

  # ── Shared helpers ────────────────────────────────────────────────────

  # Single-atom 409 rule (design §6.1) -- one status, one type, one detail,
  # for EVERY illegal state transition on R5/R6/R7 alike. Never names the
  # row's actual status.
  defp invalid_transition_response(conn),
    do: Response.conflict(conn, "review is not in a state that permits this transition")

  # Path-parameter UUID pre-validation (design §3.2) -- required ahead of
  # `PromotionReviewStore.approve_review/4`/`reject_review/3` (whose shared
  # `transition/6` mechanism receives the id as a plain `:binary_id` lookup
  # with no defensive cast of its own) and ahead of
  # `Definitions.apply_promotion_assertion_rerun/6` (design §11 OQ-10 --
  # confirmed here: it takes `review_id` as a plain binary into a changeset
  # with an FK, with no defensive cast either). A non-UUID path segment would
  # otherwise raise `Ecto.Query.CastError`/surface as an FK violation instead
  # of the 404 INV-5 requires -- malformed and nonexistent must be the same
  # fact from the caller's side. `get_review/2` and
  # `get_latest_assertion_run/2` (used by R3/R4/R7) already cast internally,
  # so this helper is not called before those.
  @spec cast_review_id(String.t()) :: {:ok, Ecto.UUID.t()} | {:error, :not_uuid}
  defp cast_review_id(raw_id) do
    case Ecto.UUID.cast(raw_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_uuid}
    end
  end

  # `PromotionReview` (see `Letflow.Definitions.PromotionReview`) declares
  # `timestamps(type: :utc_datetime_usec)`, so `inserted_at`/`updated_at`
  # are `%DateTime{}` at runtime, not `%NaiveDateTime{}` -- unlike
  # `Letflow.Routers.Tenants`' own `iso8601/1`, which only ever sees
  # `%NaiveDateTime{}` because its schema's timestamps aren't UTC-typed.
  # A `%DateTime{}` is already UTC-anchored, so it goes straight to
  # `DateTime.to_iso8601/1` with no naive->UTC conversion step.
  defp iso8601(%DateTime{} = utc), do: DateTime.to_iso8601(utc)

  defp iso8601(%NaiveDateTime{} = naive) do
    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end
end
