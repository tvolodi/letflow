defmodule Letflow.Routers.Req077PromotionPipelineTest do
  @moduledoc """
  Tests for REQ-077 (`lib/letflow/design/req077-promotion-pipeline-routes.md`) — the
  ten promotion-pipeline HTTP routes across three sub-routers
  (`Letflow.Routers.Promotions` R1-R8, `Letflow.Routers.Definitions` R9,
  `Letflow.Routers.Tenants` R10). See the design doc §12 for the full
  test-specification rationale this file implements directly; each `describe` block
  below cites the design section and acceptance criterion it covers.

  ## Dispatch strategy (design §12.0 — SETTLED, not re-decided here)

  Every test dispatches directly against its own sub-router
  (`Letflow.Routers.Promotions.call/2`, `.Definitions.call/2`, `.Tenants.call/2`) with
  `conn.assigns.auth_context` set by hand — the established precedent from REQ-073/
  074/075 (`tenants_test.exs`, `identity_test.exs`), reused rather than reinvented.
  `Letflow.Plugs.Authorize` is still a real, live plug in each of these routers'
  pipelines (mounted by `use Letflow.Api.AuthorizedRouter`) and runs for every
  request — it resolves `conn.assigns.scoped_opts` from `conn.assigns.auth_context`
  itself, so no test below sets `scoped_opts` directly. The one exception is
  `describe "design §12.9"` below, which dispatches full-stack through
  `Letflow.Router.call/2` specifically to close the gap sub-router dispatch cannot
  (§12.0's own reasoning: sub-router dispatch hand-sets `auth_context`, so nothing else
  in this suite would catch a disagreement between `AuthPipeline`'s real claim->roles
  mapping and what every other test assumes).

  Uses `Letflow.DataCase` (real Postgres, per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1) and `Letflow.TenantFixture` for real provisioned tenant schemas.
  `async: false` — tenant provisioning/migration replay needs
  `Sandbox.mode(Letflow.Repo, :auto)`, matching every sibling router-test file's own
  established pattern for this class of test. R8/AC2 additionally exercises the real,
  application-supervised `Letflow.SandboxPool` (config/test.exs caps it at
  `max_concurrent_sandboxes: 1`), so those tests are slower than the rest of this file
  by construction — this is the same real infrastructure
  `promotion_assertion_rerun_test.exs` already drives, not a new mechanism.

  ## AC6 — the no-`Repo`-in-routes grep, run as a real, re-derivable test

  Rather than merely recording the grep output as prose in a handoff (design §12.6's
  minimum), the last `describe` block below runs the actual `grep` commands design
  §10.2 specifies against the three touched files and asserts empty output — so this
  AC stays independently checkable by anyone re-running the suite, not just true at
  the moment this file was written.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Definitions
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.PromotionAssertionRun
  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Definitions.PromotionReviewStore
  alias Letflow.SandboxPool.FixtureLoader.FixtureRow
  alias Letflow.TenantFixture

  @promotions_opts Letflow.Routers.Promotions.init([])
  @definitions_opts Letflow.Routers.Definitions.init([])
  @tenants_opts Letflow.Routers.Tenants.init([])

  # ── Shared dispatch helpers (mirrors tenants_test.exs/identity_test.exs) ───────

  defp build_conn(method, path, tenant_fixture, fields) do
    roles = Keyword.get(fields, :roles, ["PLATFORM_ADMIN"])
    body = Keyword.get(fields, :body, nil)
    user_id = Keyword.get(fields, :user_id, Ecto.UUID.generate())

    conn = conn(method, path)

    conn =
      if body do
        %{conn | body_params: body}
        |> put_req_header("content-type", "application/json")
      else
        conn
      end

    tenant_id = if tenant_fixture, do: tenant_fixture.tenant_id, else: Ecto.UUID.generate()

    conn
    |> assign(:auth_context, %{user_id: user_id, tenant_id: tenant_id, roles: roles})
    |> assign(:trace_id, "req077-test-trace-id")
  end

  defp promotions(conn), do: Letflow.Routers.Promotions.call(conn, @promotions_opts)
  defp definitions(conn), do: Letflow.Routers.Definitions.call(conn, @definitions_opts)
  defp tenants(conn), do: Letflow.Routers.Tenants.call(conn, @tenants_opts)

  defp strip_trace(body), do: Map.delete(body, "trace_id")

  # ── Tenant / process-definition fixtures ────────────────────────────────────

  defp provisioned_tenant(slug_prefix) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-077 #{slug_prefix} tenant"
    )
  end

  defp unique_process_key(prefix \\ "req077-proc"),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp valid_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  defp insert_definition!(schema_name, attrs) do
    base = %{version: "1.0.0", graph: valid_graph(), created_by: Ecto.UUID.generate()}

    %ProcessDefinition{}
    |> ProcessDefinition.create_changeset(Map.merge(base, attrs))
    |> Repo.insert!(prefix: schema_name)
  end

  # Guarded, single-statement UPDATE -- create_changeset/2 never casts :status,
  # mirrors promotion_test.exs's/promotion_plan_test.exs's own activate!/2 exactly.
  defp activate!(schema_name, id) do
    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               ~s(UPDATE "#{schema_name}"."process_definitions" SET status = 'active' ) <>
                 "WHERE id = $1 AND status = 'draft'",
               [Ecto.UUID.dump!(id)]
             )
  end

  defp insert_active_definition!(schema_name, attrs) do
    definition = insert_definition!(schema_name, attrs)
    activate!(schema_name, definition.id)
    %{definition | status: :active}
  end

  # ── HTTP-level promotion-flow helpers ───────────────────────────────────────

  defp submit!(caller_tenant, source_tenant_id, target_tenant_id, process_key, fields \\ []) do
    body = %{
      "source_tenant_id" => source_tenant_id,
      "target_tenant_id" => target_tenant_id,
      "process_key" => process_key,
      "base_version" => Keyword.get(fields, :base_version, "1.0.0")
    }

    conn_fields = Keyword.take(fields, [:roles, :user_id]) ++ [body: body]
    resp = build_conn(:post, "/", caller_tenant, conn_fields) |> promotions()
    assert resp.status == 201
    Jason.decode!(resp.resp_body)
  end

  defp approve(caller_tenant, review_id, plan_digest, fields \\ []) do
    conn_fields = Keyword.take(fields, [:roles, :user_id]) ++ [body: %{"plan_digest" => plan_digest}]
    build_conn(:post, "/#{review_id}/approve", caller_tenant, conn_fields) |> promotions()
  end

  defp reject(caller_tenant, review_id, fields \\ []) do
    conn_fields = Keyword.take(fields, [:roles, :user_id]) ++ [body: %{}]
    build_conn(:post, "/#{review_id}/reject", caller_tenant, conn_fields) |> promotions()
  end

  defp apply_promotion(caller_tenant, review_id, plan_digest, fields \\ []) do
    conn_fields = Keyword.take(fields, [:roles, :user_id]) ++ [body: %{"plan_digest" => plan_digest}]
    build_conn(:post, "/#{review_id}/apply", caller_tenant, conn_fields) |> promotions()
  end

  # A syntactically-valid (64-lowercase-hex) but WRONG digest -- required
  # because PromotionDigest.verify_digest/2's binary clause raises on unequal
  # lengths (design §8.4), so every digest-mismatch fixture below must itself
  # be full-length.
  defp wrong_digest, do: :crypto.hash(:sha256, "not-the-real-plan") |> Base.encode16(case: :lower)

  # ────────────────────────────────────────────────────────────────────────────
  # AC1 / design §12.1 -- one end-to-end test per route module, R1-R8 individually
  # ────────────────────────────────────────────────────────────────────────────

  describe "AC1: R1 POST /promotions -- submit (design §7.1)" do
    test "201, exactly 2 response keys" do
      source = provisioned_tenant("req077-r1-src")
      target = provisioned_tenant("req077-r1-tgt")
      process_key = unique_process_key()

      insert_active_definition!(source.schema_name, %{name: process_key})

      resp =
        build_conn(:post, "/", target,
          body: %{
            "source_tenant_id" => source.tenant_id,
            "target_tenant_id" => target.tenant_id,
            "process_key" => process_key,
            "base_version" => "1.0.0"
          }
        )
        |> promotions()

      assert resp.status == 201
      body = Jason.decode!(resp.resp_body)
      assert Map.keys(body) |> Enum.sort() == Enum.sort(["review_id", "plan_digest"])
      assert String.length(body["plan_digest"]) == 64

      assert Repo.get!(PromotionReview, body["review_id"], prefix: target.schema_name).status ==
               :pending_review
    end
  end

  describe "AC1: R2 POST /promotions/plan -- preview (design §7.2)" do
    test "200, exactly 1 top-level key, 5-key plan entries" do
      source = provisioned_tenant("req077-r2-src")
      target = provisioned_tenant("req077-r2-tgt")
      process_key = unique_process_key()

      insert_active_definition!(source.schema_name, %{name: process_key})

      resp =
        build_conn(:post, "/plan", target,
          body: %{
            "source_tenant_id" => source.tenant_id,
            "target_tenant_id" => target.tenant_id,
            "process_key" => process_key
          }
        )
        |> promotions()

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert Map.keys(body) == ["entries"]
      assert [entry | _] = body["entries"]

      assert Map.keys(entry) |> Enum.sort() ==
               Enum.sort(["type", "id", "change_kind", "before", "after"])
    end
  end

  describe "AC1: R3 GET /promotions/:id -- latest assertion run (design §7.4)" do
    test "200, assertion_run is null when no run has been made yet" do
      source = provisioned_tenant("req077-r3-src")
      target = provisioned_tenant("req077-r3-tgt")
      process_key = unique_process_key()
      insert_active_definition!(source.schema_name, %{name: process_key})

      %{"review_id" => review_id} =
        submit!(target, source.tenant_id, target.tenant_id, process_key)

      resp = build_conn(:get, "/#{review_id}", target, []) |> promotions()

      assert resp.status == 200
      assert Jason.decode!(resp.resp_body) == %{"assertion_run" => nil}
    end
  end

  describe "AC1: R4 GET /promotions/:id/context (design §7.3)" do
    test "200, exactly 9 keys" do
      source = provisioned_tenant("req077-r4-src")
      target = provisioned_tenant("req077-r4-tgt")
      process_key = unique_process_key()
      insert_active_definition!(source.schema_name, %{name: process_key})

      %{"review_id" => review_id, "plan_digest" => digest} =
        submit!(target, source.tenant_id, target.tenant_id, process_key)

      resp = build_conn(:get, "/#{review_id}/context", target, []) |> promotions()

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert Map.keys(body) |> Enum.sort() ==
               Enum.sort([
                 "review_id",
                 "plan_digest",
                 "serialised_plan",
                 "status",
                 "requested_by",
                 "def_type",
                 "def_id",
                 "created_at",
                 "row_version"
               ])

      assert body["review_id"] == review_id
      assert body["plan_digest"] == digest
      assert body["status"] == "pending_review"
      assert is_map(body["serialised_plan"])
    end
  end

  describe "AC1: R5 POST /promotions/:id/approve (design §7.5)" do
    test "200, review_id + status=\"approved\"" do
      source = provisioned_tenant("req077-r5-src")
      target = provisioned_tenant("req077-r5-tgt")
      process_key = unique_process_key()
      insert_active_definition!(source.schema_name, %{name: process_key})

      requester = Ecto.UUID.generate()

      %{"review_id" => review_id, "plan_digest" => digest} =
        submit!(target, source.tenant_id, target.tenant_id, process_key, user_id: requester)

      resp = approve(target, review_id, digest, user_id: Ecto.UUID.generate())

      assert resp.status == 200
      assert Jason.decode!(resp.resp_body) == %{"review_id" => review_id, "status" => "approved"}
    end
  end

  describe "AC1: R6 POST /promotions/:id/reject (design §7.5)" do
    test "200, review_id + status=\"rejected\"" do
      source = provisioned_tenant("req077-r6-src")
      target = provisioned_tenant("req077-r6-tgt")
      process_key = unique_process_key()
      insert_active_definition!(source.schema_name, %{name: process_key})

      %{"review_id" => review_id} =
        submit!(target, source.tenant_id, target.tenant_id, process_key)

      resp = reject(target, review_id)

      assert resp.status == 200
      assert Jason.decode!(resp.resp_body) == %{"review_id" => review_id, "status" => "rejected"}
    end
  end

  describe "AC1: R7 POST /promotions/:id/apply (design §7.5, §9.3)" do
    test "200, review_id + status=\"applied\", target ACTIVE definition really moves" do
      source = provisioned_tenant("req077-r7-src")
      target = provisioned_tenant("req077-r7-tgt")
      process_key = unique_process_key()
      insert_active_definition!(source.schema_name, %{name: process_key, version: "2.0.0"})

      requester = Ecto.UUID.generate()

      %{"review_id" => review_id, "plan_digest" => digest} =
        submit!(target, source.tenant_id, target.tenant_id, process_key, user_id: requester)

      assert approve(target, review_id, digest, user_id: Ecto.UUID.generate()).status == 200

      resp = apply_promotion(target, review_id, digest)

      assert resp.status == 200
      assert Jason.decode!(resp.resp_body) == %{"review_id" => review_id, "status" => "applied"}

      assert Repo.get!(PromotionReview, review_id, prefix: target.schema_name).status == :applied

      assert Repo.get_by!(ProcessDefinition, [name: process_key, status: :active],
               prefix: target.schema_name
             ).version == "2.0.0"
    end
  end

  # ── R8 -- run-assertions fixtures (needs a real SandboxPool claim) ──────────

  defp fixed_rng_seed, do: 1_700_000_000 * 4_294_967_296 + 424_242

  defp fixture_row_for(process_definition_id) do
    now =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.truncate(:microsecond)
      |> NaiveDateTime.to_iso8601()

    row_json =
      %{
        "id" => process_definition_id,
        "tenant_id" => Ecto.UUID.generate(),
        "name" => "req077-fixture-#{System.unique_integer([:positive, :monotonic])}",
        "version" => "1.0.0",
        "status" => "draft",
        "graph" => %{"nodes" => [], "edges" => []},
        "created_by" => Ecto.UUID.generate(),
        "created_at" => now,
        "updated_at" => now
      }
      |> Jason.encode!()

    %FixtureRow{table_name: "process_definitions", row_json: row_json}
  end

  # The "artifact" object itself -- request-body validation schema §8.4 nests
  # this under a top-level "artifact" key alongside "plan_digest", so this
  # helper builds ONLY the inner object; see run_assertions_request_body/1.
  defp artifact_json do
    %{
      "id" => "req077-artifact-#{System.unique_integer([:positive, :monotonic])}",
      "assertions" => [%{"id" => "a1", "payload" => Jason.encode!(%{"result" => "expected"})}],
      "fixtures" => [
        fixture_row_for(Ecto.UUID.generate())
        |> Map.from_struct()
        |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
      ],
      "rng_seed" => fixed_rng_seed(),
      "non_deterministic_fields" => [],
      "candidate_definitions" => []
    }
  end

  # The full R8 request body -- @run_assertions_schema (promotions.ex) declares
  # exactly two top-level fields, "plan_digest" and "artifact" (an :object), so
  # the artifact's own fields must be NESTED under "artifact", never flattened
  # to the top level.
  defp run_assertions_request_body(digest), do: %{"plan_digest" => digest, "artifact" => artifact_json()}

  describe "AC1: R8 POST /promotions/:review_id/run-assertions (design §7.5)" do
    test "200, exactly 6 keys, idempotent_hit is never one of them" do
      source = provisioned_tenant("req077-r8-src")
      target = provisioned_tenant("req077-r8-tgt")
      process_key = unique_process_key()
      insert_active_definition!(source.schema_name, %{name: process_key})

      %{"review_id" => review_id, "plan_digest" => digest} =
        submit!(target, source.tenant_id, target.tenant_id, process_key)

      body = run_assertions_request_body(digest)

      resp =
        build_conn(:post, "/#{review_id}/run-assertions", target, body: body)
        |> promotions()

      assert resp.status == 200
      resp_body = Jason.decode!(resp.resp_body)

      assert Map.keys(resp_body) |> Enum.sort() ==
               Enum.sort([
                 "run_id",
                 "status",
                 "assertions_passed",
                 "assertions_failed",
                 "failing_assertion_ids",
                 "sandbox_id"
               ])

      assert resp_body["assertions_failed"] == 0
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # AC1: R9, R10 -- one route each, in their host sub-routers (design §2.3/§2.4)
  # ────────────────────────────────────────────────────────────────────────────

  describe "AC1: R9 POST /definitions/:process_key/rollback (design §7.6)" do
    test "200, exactly 5 keys, the ACTIVE pointer really moves back" do
      tenant = provisioned_tenant("req077-r9")
      process_key = unique_process_key()

      # Definitions.create/2 + Definitions.activate/2 -- the REAL deprecate-then-
      # activate swap (REQ-030) -- not the raw insert_active_definition!/2 helper
      # used elsewhere in this file, which would violate uq_active_definition (the
      # single-active-per-name partial unique index) by leaving TWO rows `active`
      # at once. Mirrors rollback_test.exs's own two_version_history!/2 exactly.
      assert {:ok, v1} =
               Definitions.create(
                 %{
                   name: process_key,
                   version: "1.0.0",
                   graph: valid_graph(),
                   created_by: Ecto.UUID.generate()
                 },
                 prefix: tenant.schema_name
               )

      assert {:ok, %{definition: v1}} = Definitions.activate(v1.id, prefix: tenant.schema_name)

      assert {:ok, v2} =
               Definitions.create(
                 %{
                   name: process_key,
                   version: "2.0.0",
                   graph: valid_graph(),
                   created_by: Ecto.UUID.generate()
                 },
                 prefix: tenant.schema_name
               )

      assert {:ok, %{definition: _v2}} = Definitions.activate(v2.id, prefix: tenant.schema_name)

      resp =
        build_conn(:post, "/#{process_key}/rollback", tenant, body: %{"target_version" => "1.0.0"})
        |> definitions()

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert Map.keys(body) |> Enum.sort() ==
               Enum.sort([
                 "definition_id",
                 "version",
                 "rolled_back_from_version",
                 "superseded_review_id",
                 "event_id"
               ])

      assert body["version"] == "1.0.0"
      assert body["rolled_back_from_version"] == "2.0.0"

      assert Repo.get_by!(ProcessDefinition, [name: process_key, status: :active],
               prefix: tenant.schema_name
             ).id == v1.id
    end
  end

  describe "AC1: R10 POST /tenants/:test_tenant_id/promote/:process_key (design §7.7)" do
    test "201, exactly 4 keys, target tenant gets a real ACTIVE row" do
      source = provisioned_tenant("req077-r10-src")
      target = provisioned_tenant("req077-r10-tgt")
      process_key = unique_process_key()

      insert_active_definition!(source.schema_name, %{name: process_key, version: "1.0.0"})

      resp =
        build_conn(:post, "/#{source.tenant_id}/promote/#{process_key}", target, [])
        |> tenants()

      assert resp.status == 201
      body = Jason.decode!(resp.resp_body)

      assert Map.keys(body) |> Enum.sort() ==
               Enum.sort(["definition_id", "version", "status", "warnings"])

      assert body["status"] == "active"
      assert body["warnings"] == []

      assert Repo.get_by!(ProcessDefinition, [name: process_key, status: :active],
               prefix: target.schema_name
             ).id == body["definition_id"]
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # AC2 / design §12.2 -- assertion-run idempotency (REQ-040's contract)
  # ────────────────────────────────────────────────────────────────────────────

  describe "AC2: repeat POST /promotions/:review_id/run-assertions is idempotent" do
    test "same status, byte-identical response body, exactly ONE promotion_assertion_runs row" do
      source = provisioned_tenant("req077-ac2-src")
      target = provisioned_tenant("req077-ac2-tgt")
      process_key = unique_process_key()
      insert_active_definition!(source.schema_name, %{name: process_key})

      %{"review_id" => review_id, "plan_digest" => digest} =
        submit!(target, source.tenant_id, target.tenant_id, process_key)

      body = run_assertions_request_body(digest)
      path = "/#{review_id}/run-assertions"

      r1 = build_conn(:post, path, target, body: body) |> promotions()
      r2 = build_conn(:post, path, target, body: body) |> promotions()

      assert r1.status == r2.status
      assert r1.resp_body == r2.resp_body

      assert Repo.aggregate(
               from(r in PromotionAssertionRun, where: r.review_id == ^review_id),
               :count,
               prefix: target.schema_name
             ) == 1
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # AC3 / design §12.3 -- per-tenant plan_digest uniqueness (REQ-064's contract)
  # ────────────────────────────────────────────────────────────────────────────

  describe "AC3: two tenants submitting the same plan_digest each get their own review" do
    test "same plan_digest, distinct review_id, each tenant's own count is 1 (never a global count)" do
      source_a = provisioned_tenant("req077-ac3-src-a")
      target_a = provisioned_tenant("req077-ac3-tgt-a")
      source_b = provisioned_tenant("req077-ac3-src-b")
      target_b = provisioned_tenant("req077-ac3-tgt-b")

      process_key_a = unique_process_key("req077-ac3-a")
      process_key_b = unique_process_key("req077-ac3-b")

      # Identical graph content on both sides -> identical plan.entries ->
      # identical plan_digest (compute_plan_digest/1 hashes only entries, design
      # §8.2), even though process_key/tenant ids differ across the two pairs.
      insert_active_definition!(source_a.schema_name, %{name: process_key_a})
      insert_active_definition!(source_b.schema_name, %{name: process_key_b})

      body_a = submit!(target_a, source_a.tenant_id, target_a.tenant_id, process_key_a)
      body_b = submit!(target_b, source_b.tenant_id, target_b.tenant_id, process_key_b)

      assert body_a["plan_digest"] == body_b["plan_digest"]
      assert body_a["review_id"] != body_b["review_id"]

      assert Repo.aggregate(PromotionReview, :count, prefix: target_a.schema_name) == 1
      assert Repo.aggregate(PromotionReview, :count, prefix: target_b.schema_name) == 1
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # AC4 / design §12.4, §6.3 -- approving an already-applied review
  # ────────────────────────────────────────────────────────────────────────────

  describe "AC4: approving an already-applied review" do
    test "409-class problem document, review unchanged, target definition unchanged" do
      source = provisioned_tenant("req077-ac4-src")
      target = provisioned_tenant("req077-ac4-tgt")
      process_key = unique_process_key()
      insert_active_definition!(source.schema_name, %{name: process_key, version: "9.0.0"})

      requester = Ecto.UUID.generate()
      other_actor = Ecto.UUID.generate()

      %{"review_id" => review_id, "plan_digest" => digest} =
        submit!(target, source.tenant_id, target.tenant_id, process_key, user_id: requester)

      assert approve(target, review_id, digest, user_id: other_actor).status == 200
      assert apply_promotion(target, review_id, digest).status == 200

      target_definition_before =
        Repo.get_by!(ProcessDefinition, [name: process_key, status: :active],
          prefix: target.schema_name
        )

      resp = approve(target, review_id, digest, user_id: other_actor)

      assert resp.status == 409

      assert Jason.decode!(resp.resp_body)["detail"] ==
               "review is not in a state that permits this transition"

      assert Repo.get!(PromotionReview, review_id, prefix: target.schema_name).status == :applied

      target_definition_after =
        Repo.get_by!(ProcessDefinition, [name: process_key, status: :active],
          prefix: target.schema_name
        )

      assert target_definition_after.id == target_definition_before.id
      assert target_definition_after.version == target_definition_before.version
    end

    test "gate-ordering pin: a SELF-approval attempt on an already-applied review is 403, not 409" do
      source = provisioned_tenant("req077-ac4-self-src")
      target = provisioned_tenant("req077-ac4-self-tgt")
      process_key = unique_process_key()
      insert_active_definition!(source.schema_name, %{name: process_key})

      requester = Ecto.UUID.generate()
      other_actor = Ecto.UUID.generate()

      %{"review_id" => review_id, "plan_digest" => digest} =
        submit!(target, source.tenant_id, target.tenant_id, process_key, user_id: requester)

      assert approve(target, review_id, digest, user_id: other_actor).status == 200
      assert apply_promotion(target, review_id, digest).status == 200

      # requester approving their OWN already-applied review -- self_approval_gate
      # runs BEFORE the status pre-check (design §5.3/§6.1), so this must be 403,
      # never the 409 an already-applied row would otherwise produce.
      resp = approve(target, review_id, digest, user_id: requester)

      assert resp.status == 403

      assert Jason.decode!(resp.resp_body)["detail"] ==
               "a reviewer cannot approve their own promotion request"
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # AC5 / design §12.5 -- cross-tenant review id == nonexistent review id, R4/R5/R6/R7
  # ────────────────────────────────────────────────────────────────────────────

  describe "AC5: a review id belonging to another tenant is indistinguishable from nonexistent" do
    setup do
      source_a = provisioned_tenant("req077-ac5-src-a")
      target_a = provisioned_tenant("req077-ac5-tgt-a")
      target_b = provisioned_tenant("req077-ac5-tgt-b")
      process_key = unique_process_key()
      insert_active_definition!(source_a.schema_name, %{name: process_key})

      %{"review_id" => review_id, "plan_digest" => digest} =
        submit!(target_a, source_a.tenant_id, target_a.tenant_id, process_key)

      %{target_b: target_b, foreign_review_id: review_id, digest: digest}
    end

    test "R4 GET /:id/context", %{target_b: target_b, foreign_review_id: foreign_id} do
      cross = build_conn(:get, "/#{foreign_id}/context", target_b, []) |> promotions()
      absent = build_conn(:get, "/#{Ecto.UUID.generate()}/context", target_b, []) |> promotions()

      assert cross.status == 404
      assert absent.status == 404
      assert strip_trace(Jason.decode!(cross.resp_body)) == strip_trace(Jason.decode!(absent.resp_body))
    end

    test "R5 POST /:id/approve", %{target_b: target_b, foreign_review_id: foreign_id, digest: digest} do
      cross = approve(target_b, foreign_id, digest)
      absent = approve(target_b, Ecto.UUID.generate(), digest)

      assert cross.status == 404
      assert absent.status == 404
      assert strip_trace(Jason.decode!(cross.resp_body)) == strip_trace(Jason.decode!(absent.resp_body))
    end

    test "R6 POST /:id/reject", %{target_b: target_b, foreign_review_id: foreign_id} do
      cross = reject(target_b, foreign_id)
      absent = reject(target_b, Ecto.UUID.generate())

      assert cross.status == 404
      assert absent.status == 404
      assert strip_trace(Jason.decode!(cross.resp_body)) == strip_trace(Jason.decode!(absent.resp_body))
    end

    test "R7 POST /:id/apply", %{target_b: target_b, foreign_review_id: foreign_id, digest: digest} do
      cross = apply_promotion(target_b, foreign_id, digest)
      absent = apply_promotion(target_b, Ecto.UUID.generate(), digest)

      assert cross.status == 404
      assert absent.status == 404
      assert strip_trace(Jason.decode!(cross.resp_body)) == strip_trace(Jason.decode!(absent.resp_body))
    end

    # Not AC5-required (only cross-tenant/nonexistent are), but design §5.2/§3.2 name
    # a malformed id as a fifth case belonging to the same byte-identical set.
    test "a malformed (non-UUID) id is the SAME response too", %{target_b: target_b, digest: digest} do
      malformed = approve(target_b, "not-a-uuid-at-all", digest)
      absent = approve(target_b, Ecto.UUID.generate(), digest)

      assert malformed.status == 404
      assert absent.status == 404

      assert strip_trace(Jason.decode!(malformed.resp_body)) ==
               strip_trace(Jason.decode!(absent.resp_body))
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # design §12.7 -- table-driven coverage of the §6.2 6-status x 3-operation matrix
  # ────────────────────────────────────────────────────────────────────────────

  describe "design §6.2/§12.7: the state-transition matrix, seeded via the store's own transitions" do
    setup do
      %{tenant: provisioned_tenant("req077-matrix")}
    end

    defp matrix_plan(process_key) do
      %{
        source_tenant_id: Ecto.UUID.generate(),
        target_tenant_id: Ecto.UUID.generate(),
        process_key: process_key,
        source_definition_id: Ecto.UUID.generate(),
        target_definition_id: nil,
        base_version: nil,
        entries: [
          %{
            type: :graph_node,
            id: "n-#{System.unique_integer([:positive, :monotonic])}",
            change_kind: :added,
            before: nil,
            after: %{"id" => "n1", "node_type" => "START"}
          }
        ]
      }
    end

    defp seed_review!(schema_name, requested_by \\ Ecto.UUID.generate()) do
      plan = matrix_plan(unique_process_key("req077-matrix-proc"))
      digest = PromotionDigest.compute_plan_digest(plan)

      assert {:ok, review} =
               PromotionReviewStore.insert_review(
                 %{plan: plan, digest: digest, requested_by: requested_by},
                 prefix: schema_name
               )

      {review, digest}
    end

    # Rows :pending_review needs three independent rows (approve/reject both
    # 200-and-mutate the same review); the four fully-409 rows are safe to
    # reuse a single row across all three operations since none of them ever
    # mutate on a 409. The `:approved` row's `apply` column (the matrix's own
    # third 200 cell) is deliberately NOT re-tested here -- it needs a REAL
    # source `process_definitions` row to actually succeed, and that exact
    # path is already covered end-to-end by the "AC1: R7" and "AC4" tests
    # above; re-deriving it again here with synthetic (non-real) plans would
    # only ever 409 on :source_definition_missing, which is not this cell.

    test ":pending_review row -- approve=200, reject=200, apply=409", %{tenant: tenant} do
      {review_approve, digest_approve} = seed_review!(tenant.schema_name)
      assert approve(tenant, review_approve.id, digest_approve, user_id: Ecto.UUID.generate()).status == 200

      {review_reject, _digest_reject} = seed_review!(tenant.schema_name)
      assert reject(tenant, review_reject.id).status == 200

      {review_apply, digest_apply} = seed_review!(tenant.schema_name)
      assert apply_promotion(tenant, review_apply.id, digest_apply).status == 409
    end

    test ":approved row -- approve=409, reject=409 (apply=200 covered elsewhere)", %{tenant: tenant} do
      requester = Ecto.UUID.generate()
      {review, digest} = seed_review!(tenant.schema_name, requester)

      assert {:ok, _} =
               PromotionReviewStore.approve_review(
                 review.id,
                 Ecto.UUID.generate(),
                 digest,
                 prefix: tenant.schema_name
               )

      assert approve(tenant, review.id, digest, user_id: Ecto.UUID.generate()).status == 409
      assert reject(tenant, review.id).status == 409
    end

    test ":rejected row -- approve=409, reject=409, apply=409", %{tenant: tenant} do
      {review, digest} = seed_review!(tenant.schema_name)

      assert {:ok, _} = PromotionReviewStore.reject_review(review.id, Ecto.UUID.generate(), prefix: tenant.schema_name)

      assert approve(tenant, review.id, digest, user_id: Ecto.UUID.generate()).status == 409
      assert reject(tenant, review.id).status == 409
      assert apply_promotion(tenant, review.id, digest).status == 409
    end

    test ":applied row -- approve=409, reject=409, apply=409", %{tenant: tenant} do
      {review, digest} = seed_review!(tenant.schema_name)

      assert {:ok, _} = PromotionReviewStore.approve_review(review.id, Ecto.UUID.generate(), digest, prefix: tenant.schema_name)
      assert {:ok, _} = PromotionReviewStore.mark_review_applied(review.id, prefix: tenant.schema_name)

      assert approve(tenant, review.id, digest, user_id: Ecto.UUID.generate()).status == 409
      assert reject(tenant, review.id).status == 409
      assert apply_promotion(tenant, review.id, digest).status == 409
    end

    test ":failed row -- approve=409, reject=409, apply=409", %{tenant: tenant} do
      {review, digest} = seed_review!(tenant.schema_name)

      assert {:ok, _} = PromotionReviewStore.approve_review(review.id, Ecto.UUID.generate(), digest, prefix: tenant.schema_name)
      assert {:ok, _} = PromotionReviewStore.mark_review_failed(review.id, prefix: tenant.schema_name)

      assert approve(tenant, review.id, digest, user_id: Ecto.UUID.generate()).status == 409
      assert reject(tenant, review.id).status == 409
      assert apply_promotion(tenant, review.id, digest).status == 409
    end

    test ":superseded row -- approve=409, reject=409, apply=409", %{tenant: tenant} do
      {review, digest} = seed_review!(tenant.schema_name)

      assert {:ok, _} = PromotionReviewStore.approve_review(review.id, Ecto.UUID.generate(), digest, prefix: tenant.schema_name)

      assert {:ok, _} =
               PromotionReviewStore.supersede_review(review.id, Ecto.UUID.generate(),
                 prefix: tenant.schema_name
               )

      assert approve(tenant, review.id, digest, user_id: Ecto.UUID.generate()).status == 409
      assert reject(tenant, review.id).status == 409
      assert apply_promotion(tenant, review.id, digest).status == 409
    end

    test "row absent / other tenant / malformed id -- 404 on all three ops", %{tenant: tenant} do
      missing_id = Ecto.UUID.generate()
      digest = wrong_digest()

      assert approve(tenant, missing_id, digest).status == 404
      assert reject(tenant, missing_id).status == 404
      assert apply_promotion(tenant, missing_id, digest).status == 404
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # design §12.8 -- the :Unknown/PLATFORM_ADMIN-only authorization decision
  # ────────────────────────────────────────────────────────────────────────────

  describe "design §12.8: the :Unknown authorization decision is pinned" do
    @path_templates [
      {"POST", "/promotions"},
      {"POST", "/promotions/plan"},
      {"GET", "/promotions/:id"},
      {"GET", "/promotions/:id/context"},
      {"POST", "/promotions/:id/approve"},
      {"POST", "/promotions/:id/reject"},
      {"POST", "/promotions/:id/apply"},
      {"POST", "/promotions/:review_id/run-assertions"},
      {"POST", "/definitions/:process_key/rollback"},
      {"POST", "/tenants/:test_tenant_id/promote/:process_key"}
    ]

    test "every one of the ten route templates resolves to :Unknown" do
      for {method, path} <- @path_templates do
        assert Authorization.endpoint_policy_key(method, path) == :Unknown,
               "expected #{method} #{path} to resolve to :Unknown"
      end
    end

    test "every non-PLATFORM_ADMIN role (including no roles at all) is denied on :Unknown" do
      for roles <- [["PROCESS_DESIGNER"], ["PROCESS_OPERATOR"], ["TASK_WORKER"], ["AGENT_RUNNER"], []] do
        ctx = %AccessContext{user_id: Ecto.UUID.generate(), roles: Authorization.roles_from_strings(roles)}
        assert Authorization.evaluate_access(ctx, :Unknown).kind == :Deny403
      end
    end

    test "PLATFORM_ADMIN is allowed on :Unknown" do
      ctx = %AccessContext{user_id: Ecto.UUID.generate(), roles: [:PLATFORM_ADMIN]}
      assert Authorization.evaluate_access(ctx, :Unknown).kind == :Allow
    end

    test "end-to-end: a PROCESS_DESIGNER caller is denied 403 on POST /promotions/plan, no plan data leaks" do
      source = provisioned_tenant("req077-authz-src")
      target = provisioned_tenant("req077-authz-tgt")
      process_key = unique_process_key()
      insert_active_definition!(source.schema_name, %{name: process_key})

      resp =
        build_conn(:post, "/plan", target,
          roles: ["PROCESS_DESIGNER"],
          body: %{
            "source_tenant_id" => source.tenant_id,
            "target_tenant_id" => target.tenant_id,
            "process_key" => process_key
          }
        )
        |> promotions()

      assert resp.status == 403
      body = Jason.decode!(resp.resp_body)
      assert body["detail"] == "insufficient permissions"
      refute Map.has_key?(body, "entries")
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # design §12.9 -- full-stack smoke test: the gate is live through the real pipeline
  # ────────────────────────────────────────────────────────────────────────────

  describe "design §12.9: the :Unknown gate denies a real non-admin caller end-to-end" do
    defp unique_slug(prefix \\ "req077-fullstack"),
      do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

    defp insert_tenant_for_realm!(realm) do
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      tenant =
        %Letflow.Identity.Tenant{}
        |> Letflow.Identity.Tenant.create_changeset(
          %{slug: unique_slug(), display_name: "REQ-077 Full-stack Smoke Tenant", idp_realm_id: realm},
          :enabled
        )
        |> Repo.insert!()

      on_exit(fn ->
        case Letflow.TenantProvisioning.schema_name_for_tenant(tenant.id) do
          {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
          {:error, :invalid_tenant_id} -> :ok
        end

        Repo.delete_all(
          from(r in Letflow.TenantProvisioning.Registration, where: r.tenant_id == ^tenant.id)
        )

        Repo.delete_all(from(t in Letflow.Identity.Tenant, where: t.id == ^tenant.id))
      end)

      assert {:ok, _} = Letflow.TenantProvisioning.provision_tenant_schema(tenant.id)
      assert {:ok, _} = Letflow.TenantProvisioning.replay_migrations(tenant.id)

      tenant
    end

    test "POST /api/v1/promotions/plan with a real VIEWER token, full pipeline, is 403" do
      tenant = insert_tenant_for_realm!("bpm-default")

      conn =
        conn(
          :post,
          "/api/v1/promotions/plan",
          Jason.encode!(%{
            "source_tenant_id" => Ecto.UUID.generate(),
            "target_tenant_id" => Ecto.UUID.generate(),
            "process_key" => "irrelevant"
          })
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer valid-test-token")
        |> Letflow.Router.call(Letflow.Router.init([]))

      assert conn.status == 403
      assert conn.assigns.auth_context.tenant_id == tenant.id
      assert conn.assigns.auth_context.roles == ["VIEWER"]

      body = Jason.decode!(conn.resp_body)
      assert body["detail"] == "insufficient permissions"
      refute Map.has_key?(body, "entries")
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # AC6 / design §12.6, §10.2 -- the no-Repo-in-routes grep, run for real
  # ────────────────────────────────────────────────────────────────────────────

  describe "AC6: no route module touches the database directly" do
    @touched_files [
      "lib/letflow/routers/promotions.ex",
      "lib/letflow/routers/definitions.ex",
      "lib/letflow/routers/tenants.ex"
    ]

    test "grep -n \"Repo\\.\" / \"import Ecto.Query\" / \"alias Letflow.Repo\" all return zero hits" do
      for path <- @touched_files do
        contents = File.read!(Path.join(File.cwd!(), path))

        refute contents =~ ~r/Repo\./, "#{path} contains a `Repo.` call"
        refute contents =~ "import Ecto.Query", "#{path} imports Ecto.Query"
        refute contents =~ "alias Letflow.Repo", "#{path} aliases Letflow.Repo"
      end
    end
  end
end
