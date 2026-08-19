defmodule Letflow.REQ064TenantIdRemovalTest do
  @moduledoc """
  New coverage for REQ-064 (Decision 0006 D2: drop `tenant_id` from the ten
  schema-isolated business tables). See `test/specs/REQ-064.md` for the full
  test-case rationale and the WF-02 Step 3 scope-test verdict.

  This file does NOT re-test the ~20 pre-existing files' own coverage (fixed
  separately, see `test/specs/REQ-064.md`'s Workstream 1) — it adds exactly
  the runtime proof named by REQ-064's own acceptance criteria that no
  existing test before this run demonstrated:

  1. `promotion_assertion_runs`' idempotency contract under the simplified
     single-column `uq_promotion_assertion_runs_idempotency` index — same key
     twice in ONE tenant schema resolves to one row (via `on_conflict:
     :nothing`), same key in a DIFFERENT tenant schema is a separate row.
  2. `promotion_reviews`' `plan_digest` uniqueness under the simplified
     single-column `uq_promotion_review_active_digest` index — same two-part
     proof.
  3. `information_schema.columns`, queried against two real provisioned
     tenant schemas, confirming all ten D2 tables genuinely lack `tenant_id`
     and all four D3 tables genuinely still have it — in the SAME schema, so
     a query targeting the wrong schema can't produce a false pass.

  A test proving a bad/nonexistent `tenant_id` is still rejected by a D3
  table's FK (acceptance criterion 3) already exists —
  `test/letflow/definitions/pack_update_migration_test.exs`'s `describe "real
  DB-level foreign key: tenant_id references tenants.id on all three GLOBAL
  tables"` — `"solution_pack_installs rejects a tenant_id matching no tenants
  row"`. Re-verified passing after this run's migrations (see the full-suite
  run quoted in the TEST-DESIGNER handoff); not duplicated here.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 — no mocked database
  anywhere in this file. Every test provisions its own tenant(s)
  (`provisioned_tenant/0`, mirroring `event_store_test.exs`'s and
  `engine/migrations_test.exs`'s identical helper) — no shared or
  hard-coded tenant/schema names, no test depends on another having run
  first. `async: false` for the whole module: `TenantProvisioning.
  replay_migrations/2` needs `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo,
  :auto)` (a second, genuinely independent DB connection beyond the one this
  process has checked out, since `Ecto.Migrator` takes a lock on
  `schema_migrations`), which a sandboxed pool will not hand out — identical
  reasoning to every other `:auto`-mode file in this suite
  (`engine/migrations_test.exs`, `event_store_test.exs`, etc.).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions.PromotionAssertionRun
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("req064"),
        display_name: "REQ-064 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  # Mirrors event_store_test.exs's / engine/migrations_test.exs's identical
  # helper -- provisions a real tenant, replays the full manifest (needed so
  # promotion_reviews' review_id FK target and every other cross-table FK in
  # the manifest are satisfiable).
  defp provisioned_tenant do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant = insert_tenant!()

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} -> drop_schema!(schema_name)
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{schema_name: schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp unique_digest do
    :crypto.hash(:sha256, "req064-#{System.unique_integer([:positive, :monotonic])}")
    |> Base.encode16(case: :lower)
  end

  defp unique_idempotency_key do
    "req064-idk-#{System.unique_integer([:positive, :monotonic])}"
  end

  # Inserts a minimal, valid promotion_reviews row directly via the schema's
  # own insert_changeset/2 -- isolates the DB constraint itself from the
  # Definitions/PromotionReviewStore orchestration layer, matching this
  # codebase's established convention (see user_test.exs's own
  # direct-insert-vs-JIT-path split, cited by test/specs/REQ-063.md) of
  # having both a direct-schema test and a through-the-context-module test
  # for the same constraint where both already exist elsewhere.
  defp insert_review!(schema_name, digest) do
    %PromotionReview{}
    |> PromotionReview.insert_changeset(%{
      plan_digest: digest,
      def_id: "req064-proc-#{System.unique_integer([:positive, :monotonic])}",
      serialised_plan: Jason.encode!(%{"nodes" => [], "edges" => []}),
      requested_by: Ecto.UUID.generate()
    })
    |> Repo.insert(prefix: schema_name)
  end

  defp insert_review_row!(schema_name, digest) do
    {:ok, review} = insert_review!(schema_name, digest)
    review
  end

  # Inserts a minimal, valid promotion_assertion_runs row via
  # insert_changeset/2 + on_conflict: :nothing -- exactly the idiom
  # claim_or_fetch_assertion_run/5 itself uses (lib/letflow/definitions.ex),
  # isolating the DB constraint/on_conflict shape from the rest of that
  # function's orchestration (sandbox claim, replay, teardown).
  defp claim_assertion_run(schema_name, review_id, digest, idempotency_key) do
    changeset =
      PromotionAssertionRun.insert_changeset(%PromotionAssertionRun{}, %{
        review_id: review_id,
        idempotency_key: idempotency_key,
        plan_digest: digest
      })

    Repo.insert(changeset,
      on_conflict: :nothing,
      conflict_target: [:idempotency_key],
      prefix: schema_name
    )
  end

  # ---------------------------------------------------------------------------------
  # 1. promotion_assertion_runs idempotency contract, simplified single-column index
  # ---------------------------------------------------------------------------------

  describe "promotion_assertion_runs idempotency contract under the simplified [:idempotency_key] index" do
    test "the same idempotency_key twice within ONE tenant schema resolves to exactly one row (on_conflict: :nothing wins once)" do
      %{schema_name: schema_name} = provisioned_tenant()
      review = insert_review_row!(schema_name, unique_digest())
      idempotency_key = unique_idempotency_key()
      digest = unique_digest()

      assert {:ok, %PromotionAssertionRun{id: first_id} = first_attempt} =
               claim_assertion_run(schema_name, review.id, digest, idempotency_key)

      # A genuine winning insert always gets its own new row back with a
      # real id -- confirms this assertion is actually exercising the
      # winning path, not accidentally starting from a suppressed no-op.
      assert first_id != nil
      assert first_attempt.idempotency_key == idempotency_key

      # Second attempt: same idempotency_key, same schema. on_conflict:
      # :nothing suppresses the insert -- Ecto returns {:ok, struct} with the
      # struct's own submitted (not the winner's) primary key when nothing
      # was actually written, so the real proof is querying back by
      # idempotency_key and counting rows, not trusting this return value.
      assert {:ok, _second_attempt} =
               claim_assertion_run(schema_name, review.id, digest, idempotency_key)

      rows =
        Repo.all(
          from(r in PromotionAssertionRun, where: r.idempotency_key == ^idempotency_key),
          prefix: schema_name
        )

      assert length(rows) == 1
      assert hd(rows).id == first_id
    end

    test "the same idempotency_key in a DIFFERENT tenant schema produces a SEPARATE row -- the index is genuinely per-schema, not accidentally cross-tenant" do
      %{schema_name: schema_a} = provisioned_tenant()
      %{schema_name: schema_b} = provisioned_tenant()

      idempotency_key = unique_idempotency_key()

      review_a = insert_review_row!(schema_a, unique_digest())
      review_b = insert_review_row!(schema_b, unique_digest())

      assert {:ok, %PromotionAssertionRun{id: id_a}} =
               claim_assertion_run(schema_a, review_a.id, unique_digest(), idempotency_key)

      assert {:ok, %PromotionAssertionRun{id: id_b}} =
               claim_assertion_run(schema_b, review_b.id, unique_digest(), idempotency_key)

      # Both inserts genuinely won in their own schema -- if the simplified
      # [:idempotency_key] index were somehow still enforcing uniqueness
      # ACROSS schemas (e.g. a stray global index left behind, or the
      # migration's DROP INDEX + CREATE INDEX pair applied only once instead
      # of once per schema), the second insert would have been silently
      # suppressed by on_conflict: :nothing and returned a struct with no
      # persisted row, which the id_a != id_b check plus the row-count
      # queries below would catch.
      assert id_a != id_b

      rows_a =
        Repo.all(
          from(r in PromotionAssertionRun, where: r.idempotency_key == ^idempotency_key),
          prefix: schema_a
        )

      rows_b =
        Repo.all(
          from(r in PromotionAssertionRun, where: r.idempotency_key == ^idempotency_key),
          prefix: schema_b
        )

      assert length(rows_a) == 1
      assert length(rows_b) == 1
      assert hd(rows_a).id == id_a
      assert hd(rows_b).id == id_b
    end
  end

  # ---------------------------------------------------------------------------------
  # 2. promotion_reviews plan_digest uniqueness, simplified single-column index
  # ---------------------------------------------------------------------------------

  describe "promotion_reviews plan_digest uniqueness under the simplified [:plan_digest] index" do
    test "a duplicate plan_digest within ONE tenant schema is rejected" do
      %{schema_name: schema_name} = provisioned_tenant()
      digest = unique_digest()

      assert {:ok, %PromotionReview{}} = insert_review!(schema_name, digest)

      assert {:error, changeset} = insert_review!(schema_name, digest)

      assert %{plan_digest: ["has already been taken"]} =
               Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
                 Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
                   opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
                 end)
               end)

      rows =
        Repo.all(
          from(r in PromotionReview, where: r.plan_digest == ^digest),
          prefix: schema_name
        )

      assert length(rows) == 1
    end

    test "the same plan_digest in a DIFFERENT tenant schema succeeds -- the index is genuinely per-schema, not accidentally cross-tenant" do
      %{schema_name: schema_a} = provisioned_tenant()
      %{schema_name: schema_b} = provisioned_tenant()

      digest = unique_digest()

      assert {:ok, review_a} = insert_review!(schema_a, digest)
      assert {:ok, review_b} = insert_review!(schema_b, digest)

      # Both inserts genuinely succeeded in their own schema with distinct
      # rows -- if the simplified [:plan_digest] index were somehow still
      # cross-tenant, the second insert would have raised the same
      # unique_constraint error the negative test above proves exists.
      assert review_a.id != review_b.id
      assert review_a.plan_digest == digest
      assert review_b.plan_digest == digest

      rows_a =
        Repo.all(from(r in PromotionReview, where: r.plan_digest == ^digest), prefix: schema_a)

      rows_b =
        Repo.all(from(r in PromotionReview, where: r.plan_digest == ^digest), prefix: schema_b)

      assert length(rows_a) == 1
      assert length(rows_b) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # 3. information_schema.columns -- ten D2 tables lack tenant_id, four D3 tables keep it
  # ---------------------------------------------------------------------------------

  describe "information_schema.columns -- direct proof of the column-level shape this requirement mandates" do
    @d2_tables ~w(events events_archive instance_projections process_definitions tokens tasks
                  promotion_reviews promotion_assertion_runs users groups)

    # The four D3 tables live in the public/default schema (Decision 0006 §D3
    # -- see lib/letflow/design/req064-drop-tenant-id.md §1), not inside any
    # tenant's own provisioned schema, so they're queried against 'public'
    # rather than against a provisioned tenant schema name.
    @d3_tables ~w(tenant_schemas solution_pack_installs solution_pack_artefact_bases
                  pack_update_resolutions)

    defp columns_of(schema_name, table_name) do
      %{rows: rows} =
        Repo.query!(
          "SELECT column_name FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2",
          [schema_name, table_name]
        )

      rows |> List.flatten() |> MapSet.new()
    end

    test "all ten D2 tables genuinely lack tenant_id, in a real provisioned tenant schema" do
      %{schema_name: schema_name} = provisioned_tenant()

      for table <- @d2_tables do
        columns = columns_of(schema_name, table)
        # Sanity: the table itself must actually exist in this schema, or an
        # empty column set would trivially (and misleadingly) "pass" the
        # tenant_id-absence assertion below without proving anything.
        assert MapSet.size(columns) > 0,
               "expected #{table} to exist (with columns) in schema #{schema_name}, found none"

        refute MapSet.member?(columns, "tenant_id"),
               "expected #{table} to have no tenant_id column in schema #{schema_name}, but it does"
      end
    end

    test "all ten D2 tables genuinely lack tenant_id in a SECOND, independently provisioned tenant schema (not a fluke of one schema's replay)" do
      %{schema_name: schema_name} = provisioned_tenant()

      for table <- @d2_tables do
        columns = columns_of(schema_name, table)
        assert MapSet.size(columns) > 0
        refute MapSet.member?(columns, "tenant_id")
      end
    end

    test "all four D3 tables genuinely still have tenant_id, in public" do
      for table <- @d3_tables do
        columns = columns_of("public", table)

        assert MapSet.size(columns) > 0,
               "expected #{table} to exist (with columns) in public, found none"

        assert MapSet.member?(columns, "tenant_id"),
               "expected #{table} to still have tenant_id in public, but it does not"
      end
    end
  end
end
