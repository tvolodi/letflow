defmodule Letflow.Definitions.PromotionReviewMigrationTest do
  @moduledoc """
  Integration tests for REQ-035's
  `priv/repo/migrations/20260816200001_create_promotion_reviews.exs` migration, run
  against real Postgres through REQ-022's provision-then-replay mechanism. See
  `test/specs/REQ-035.md` for the full test-case rationale and the WF-02 Step 3
  scope-test verdict.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file.

  Like `test/letflow/definitions/migrations_test.exs` and
  `test/letflow/event_store/migrations_test.exs`, and for the same empirically
  established reason, the describe block below does NOT run inside DataCase's normal
  rolled-back sandbox transaction: `Ecto.Migrator` needs a second, genuinely
  independent database connection beyond the one this process has checked out (it
  takes a lock on `schema_migrations`), which a sandboxed pool will not hand out --
  the call fails with `DBConnection.ConnectionError ... :queue_timeout`. It therefore
  switches `Letflow.Repo` to `Ecto.Adapters.SQL.Sandbox` `:auto` mode and cleans up the
  real schemas and rows it creates in `on_exit/1` instead of relying on rollback. The
  `on_exit/1` is registered BEFORE anything that can fail, so every tenant schema this
  file creates is dropped on the failure path as well as the passing one.

  `async: false` for the whole module (ExUnit's `async` setting is module-wide, not
  per-test): ExUnit fully drains every `async: true` module before starting any sync
  module and runs sync modules strictly one at a time, so the `:auto`-mode switch has
  no other test's connection to disturb. The pure, no-I/O half of REQ-035's coverage
  lives in `test/letflow/definitions/promotion_review_test.exs`, which is
  `async: true`.

  Every structural claim below is read from the LIVE system catalog (`pg_indexes`,
  `information_schema.columns`) after the migration has actually run -- never from the
  migration source text, matching REQ-027's/REQ-023's established discipline.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions.PromotionReview
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  # oidc_mode: :disabled avoids Tenant.create_changeset/3's idp_realm_id requirement --
  # irrelevant to anything this file tests, matching every other provisioning test in
  # this project's own use of :disabled.
  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: "req035-#{System.unique_integer([:positive, :monotonic])}",
        display_name: "REQ-035 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp table_exists_in_schema?(schema_name, table_name) do
    %{rows: [[exists?]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2)",
        [schema_name, table_name]
      )

    exists?
  end

  defp columns_in(schema_name, table_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2",
        [schema_name, table_name]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  # {index_name, index_definition} for every index on a table. pg_indexes, not
  # information_schema.table_constraints: Ecto's `create unique_index(...)` emits
  # CREATE UNIQUE INDEX, not ALTER TABLE ... ADD CONSTRAINT UNIQUE, so the constraint
  # views do not list it at all and a test written against them would pass vacuously.
  defp indexes_on(schema_name, table_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = $1 AND tablename = $2",
        [schema_name, table_name]
      )

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end

  # The btree column list of an index definition, e.g. "tenant_id, plan_digest".
  defp indexed_columns(definition) do
    [_, columns] = Regex.run(~r/USING btree \(([^)]*)\)/, definition)
    columns
  end

  # Everything after the first " WHERE " in an index definition, or nil for a total
  # index. Postgres renders the predicate in its own normalised form, so assertions
  # are made against this substring rather than against the migration's source text.
  defp index_predicate(definition) do
    case String.split(definition, " WHERE ", parts: 2) do
      [_definition] -> nil
      [_definition, predicate] -> predicate
    end
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  # 64 lowercase hex characters, deterministic given the counter -- never
  # :rand/:crypto.strong_rand_bytes/1.
  defp unique_plan_digest do
    :crypto.hash(:sha256, "req035-plan-#{System.unique_integer([:positive, :monotonic])}")
    |> Base.encode16(case: :lower)
  end

  defp valid_review_attrs(overrides) do
    Map.merge(
      %{
        tenant_id: Ecto.UUID.generate(),
        plan_digest: unique_plan_digest(),
        def_id: "req035-proc-#{System.unique_integer([:positive, :monotonic])}",
        serialised_plan: ~s({"nodes":[],"edges":[]}),
        requested_by: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp insert_review!(schema_name, attrs) do
    %PromotionReview{}
    |> PromotionReview.insert_changeset(attrs)
    |> Repo.insert(prefix: schema_name)
  end

  defp insert_review_ok!(schema_name, attrs) do
    {:ok, review} = insert_review!(schema_name, attrs)
    review
  end

  # A guarded, single-statement UPDATE -- deliberately raw Repo.update_all/2 and not a
  # changeset, because insert_changeset/2 never casts :status (design INV-PR-3) and
  # REQ-037's own transition functions don't exist yet at this point in the project's
  # history. Mirrors design section 4.3's specified demonstration method exactly.
  defp move_status!(schema_name, id, new_status) do
    {1, nil} =
      from(r in PromotionReview, prefix: ^schema_name, where: r.id == ^id)
      |> Repo.update_all(set: [status: new_status])
  end

  # A raw INSERT that supplies only the NOT NULL columns with no default, so
  # row_version and status are filled by the DATABASE -- a changeset insert would send
  # the schema module's own literals and could never detect a disagreement between the
  # migration's DB default and the schema's struct default.
  defp raw_insert_minimal_review!(schema_name) do
    id = Ecto.UUID.generate()

    Repo.query!(
      ~s(INSERT INTO "#{schema_name}"."promotion_reviews" ) <>
        "(id, tenant_id, plan_digest, def_id, serialised_plan, requested_by, inserted_at, updated_at) " <>
        "VALUES ($1, $2, $3, $4, $5, $6, $7, $7)",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        unique_plan_digest(),
        "req035-raw-proc",
        ~s({"nodes":[],"edges":[]}),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        ~N[2026-01-02 03:04:05.000000]
      ]
    )

    id
  end

  # A raw INSERT with an out-of-enum status string, proving the DB itself carries no
  # CHECK constraint over the status column (test 6 / "What is and isn't DB-enforced").
  defp raw_insert_with_arbitrary_status!(schema_name, status_text) do
    id = Ecto.UUID.generate()

    Repo.query!(
      ~s(INSERT INTO "#{schema_name}"."promotion_reviews" ) <>
        "(id, tenant_id, plan_digest, def_id, serialised_plan, requested_by, status, inserted_at, updated_at) " <>
        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8)",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        unique_plan_digest(),
        "req035-raw-proc",
        ~s({"nodes":[],"edges":[]}),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        status_text,
        ~N[2026-01-02 03:04:05.000000]
      ]
    )
  end

  # ---------------------------------------------------------------------------------
  # Each test gets its own tenant, its own physical schema and its own Registration
  # row -- no identifier is shared between tests, and on_exit drops everything, because
  # these tests genuinely commit (see this module's moduledoc).
  # ---------------------------------------------------------------------------------

  describe "REQ-035's promotion_reviews migration replayed into a provisioned tenant schema" do
    setup do
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      tenant = insert_tenant!()

      assert {:ok, %Registration{schema_name: schema_name}} =
               TenantProvisioning.provision_tenant_schema(tenant.id)

      # Registered before replay_migrations/2 runs, so a migration that raises still
      # gets its schema dropped -- this database is shared with a concurrently running
      # worktree and must not accumulate strays.
      on_exit(fn ->
        drop_schema!(schema_name)
        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
      end)

      assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

      %{tenant: tenant, schema_name: schema_name}
    end

    # -------------------------------------------------------------------------------
    # Acceptance criterion 1: "priv/repo/migrations gains a promotion_reviews
    # migration (schema-per-tenant per REQ-022) applying cleanly, with status as an
    # Ecto.Enum over exactly the 6 named values"
    # -------------------------------------------------------------------------------

    test "replay_migrations/2 applies the REQ-035 migration and promotion_reviews lands in the tenant's own schema, never in public",
         %{schema_name: schema_name} do
      assert table_exists_in_schema?(schema_name, "promotion_reviews"),
             "promotion_reviews is missing from tenant schema #{schema_name}"

      # This half is what proves :prefix is doing the work: a migration that ignored
      # :prefix and wrote to the default schema would still satisfy a naive "does the
      # table exist" check.
      refute table_exists_in_schema?("public", "promotion_reviews"),
             "promotion_reviews leaked into the public schema -- the :prefix guard is not working"
    end

    test "CreatePromotionReviews is registered in tenant_scoped_migrations/0" do
      # REQ-022 section 4: registration and guarding are two independent mandatory
      # halves. A guarded-but-unregistered migration is inert forever -- no tenant
      # schema ever gets the table -- and no other test in this file would notice,
      # because they all run through replay_migrations/2, which only sees registered
      # entries.
      registered_modules =
        TenantProvisioning.tenant_scoped_migrations() |> Enum.map(&elem(&1, 1))

      assert Letflow.Repo.Migrations.CreatePromotionReviews in registered_modules,
             "CreatePromotionReviews is not registered in tenant_scoped_migrations/0 -- it would never reach any tenant schema"
    end

    test "promotion_reviews' real column set matches PromotionReview.__schema__(:fields) exactly",
         %{schema_name: schema_name} do
      expected =
        PromotionReview.__schema__(:fields) |> Enum.map(&Atom.to_string/1) |> Enum.sort()

      assert columns_in(schema_name, "promotion_reviews") == expected,
             "promotion_reviews' columns disagree with PromotionReview.__schema__(:fields)"
    end

    test "status carries no DB-level CHECK constraint -- a raw SQL write of an out-of-enum string succeeds",
         %{schema_name: schema_name} do
      # AC1's enum guarantee is application-level only (Ecto.Enum's cast/1, exercised
      # in promotion_review_test.exs). This is the negative control: nothing in the
      # live schema stops a value outside the 6 named atoms from being written by a
      # path that bypasses the Ecto.Schema layer entirely. Exists so this suite does
      # not silently overclaim DB-level enforcement that isn't actually there.
      assert %Postgrex.Result{num_rows: 1} =
               raw_insert_with_arbitrary_status!(schema_name, "not_a_real_status")
    end

    # -------------------------------------------------------------------------------
    # Acceptance criterion 2: partial unique index on (tenant_id, plan_digest) WHERE
    # status IN ('pending_review', 'approved')
    # -------------------------------------------------------------------------------

    test "uq_promotion_review_active_digest is a PARTIAL unique index over (tenant_id, plan_digest) predicated on status IN (pending_review, approved)",
         %{schema_name: schema_name} do
      indexes = indexes_on(schema_name, "promotion_reviews")

      assert Map.has_key?(indexes, "uq_promotion_review_active_digest"),
             "uq_promotion_review_active_digest is missing, found: #{inspect(Map.keys(indexes))}"

      definition = Map.fetch!(indexes, "uq_promotion_review_active_digest")

      assert String.starts_with?(definition, "CREATE UNIQUE INDEX"),
             "uq_promotion_review_active_digest is not UNIQUE: #{definition}"

      assert indexed_columns(definition) == "tenant_id, plan_digest",
             "uq_promotion_review_active_digest does not cover exactly (tenant_id, plan_digest): #{definition}"

      predicate = index_predicate(definition)

      refute is_nil(predicate),
             "uq_promotion_review_active_digest carries no WHERE clause -- it would forbid ever re-submitting a superseded/rejected digest: #{definition}"

      assert predicate =~ "status",
             "uq_promotion_review_active_digest's predicate does not name status: #{definition}"

      for status <- Ecto.Enum.dump_values(PromotionReview, :status) do
        expected? = status in ["pending_review", "approved"]

        assert predicate =~ status == expected?,
               "uq_promotion_review_active_digest's predicate #{if expected?, do: "should", else: "should NOT"} mention #{status}: #{predicate}"
      end
    end

    test "idx_promotion_review_rollback_lookup is a non-unique PARTIAL index over (tenant_id, status) predicated on status IN (applied, superseded)",
         %{schema_name: schema_name} do
      indexes = indexes_on(schema_name, "promotion_reviews")

      assert Map.has_key?(indexes, "idx_promotion_review_rollback_lookup"),
             "idx_promotion_review_rollback_lookup is missing, found: #{inspect(Map.keys(indexes))}"

      definition = Map.fetch!(indexes, "idx_promotion_review_rollback_lookup")

      refute String.starts_with?(definition, "CREATE UNIQUE INDEX"),
             "idx_promotion_review_rollback_lookup must be non-unique: #{definition}"

      assert indexed_columns(definition) == "tenant_id, status",
             "idx_promotion_review_rollback_lookup does not cover exactly (tenant_id, status): #{definition}"

      predicate = index_predicate(definition)

      refute is_nil(predicate),
             "idx_promotion_review_rollback_lookup carries no WHERE clause: #{definition}"

      assert predicate =~ "applied"
      assert predicate =~ "superseded"
    end

    test "a second pending_review insert with the same (tenant_id, plan_digest) is rejected while the first is still pending_review",
         %{schema_name: schema_name} do
      tenant_id = Ecto.UUID.generate()
      plan_digest = unique_plan_digest()

      assert {:ok, %PromotionReview{}} =
               insert_review!(
                 schema_name,
                 valid_review_attrs(%{tenant_id: tenant_id, plan_digest: plan_digest})
               )

      # The error SHAPE matters: if insert_changeset/2's declared constraint name and
      # the real index name ever drift apart, this raises Ecto.ConstraintError instead
      # of returning {:error, changeset} -- exactly the error contract REQ-037's
      # insert_review/1 will depend on.
      assert {:error, changeset} =
               insert_review!(
                 schema_name,
                 valid_review_attrs(%{tenant_id: tenant_id, plan_digest: plan_digest})
               )

      refute changeset.valid?

      assert Enum.any?(changeset.errors, fn
               {:tenant_id, {_, opts}} ->
                 opts[:constraint_name] == "uq_promotion_review_active_digest"

               _ ->
                 false
             end),
             "expected a uq_promotion_review_active_digest constraint error, got #{inspect(changeset.errors)}"
    end

    test "a second insert with the same (tenant_id, plan_digest) is also rejected while the first is approved",
         %{schema_name: schema_name} do
      tenant_id = Ecto.UUID.generate()
      plan_digest = unique_plan_digest()

      first =
        insert_review_ok!(
          schema_name,
          valid_review_attrs(%{tenant_id: tenant_id, plan_digest: plan_digest})
        )

      move_status!(schema_name, first.id, "approved")

      assert {:error, _changeset} =
               insert_review!(
                 schema_name,
                 valid_review_attrs(%{tenant_id: tenant_id, plan_digest: plan_digest})
               )
    end

    test "a second insert with the same (tenant_id, plan_digest) succeeds once the first review is no longer pending_review or approved",
         %{schema_name: schema_name} do
      tenant_id = Ecto.UUID.generate()
      plan_digest = unique_plan_digest()

      first =
        insert_review_ok!(
          schema_name,
          valid_review_attrs(%{tenant_id: tenant_id, plan_digest: plan_digest})
        )

      # Moves the first row outside {pending_review, approved} via Repo.update_all,
      # exactly as design section 4.3 specifies, since REQ-037's transition functions
      # don't exist yet. Proves the index's WHERE predicate is doing real work, not a
      # bare unconditional unique index -- without this case, test 8/9 above would
      # pass just as happily against the wrong (unconditional) index.
      move_status!(schema_name, first.id, "rejected")

      assert {:ok, %PromotionReview{}} =
               insert_review!(
                 schema_name,
                 valid_review_attrs(%{tenant_id: tenant_id, plan_digest: plan_digest})
               )
    end

    test "a second pending_review insert with a different plan_digest for the same tenant succeeds",
         %{schema_name: schema_name} do
      tenant_id = Ecto.UUID.generate()

      assert {:ok, %PromotionReview{}} =
               insert_review!(schema_name, valid_review_attrs(%{tenant_id: tenant_id}))

      # Different plan_digest, same tenant -- proves plan_digest is really part of the
      # uniqueness scope, not just tenant_id alone.
      assert {:ok, %PromotionReview{}} =
               insert_review!(schema_name, valid_review_attrs(%{tenant_id: tenant_id}))
    end

    # -------------------------------------------------------------------------------
    # Acceptance criterion 3: "row_version defaults to 1"
    # -------------------------------------------------------------------------------

    test "the DB column default for row_version is 1, from a raw insert that omits it",
         %{schema_name: schema_name} do
      id = raw_insert_minimal_review!(schema_name)

      review = Repo.get(PromotionReview, id, prefix: schema_name)

      assert review.row_version == 1,
             "the DATABASE default for row_version is not 1 -- disagrees with PromotionReview's struct default"
    end
  end
end
