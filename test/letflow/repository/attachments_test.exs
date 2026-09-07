defmodule Letflow.Repository.AttachmentsTest do
  @moduledoc """
  Basic sanity tests for REQ-211's `Letflow.Repository.Attachments` context
  module, written by ELIXIR-DEV at Step 2a to exercise the implementation
  against a real Postgres tenant schema. Not full 11-AC coverage --
  TEST-DESIGNER writes that later in this pipeline (WF-02 Step 2d+). See
  `lib/letflow/design/req211-instance-attachments-core.md` for the design
  these tests spot-check.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repository
  alias Letflow.Repository.Artifact
  alias Letflow.Repository.Attachment
  alias Letflow.Repository.Attachments

  defp provisioned_tenant(slug_prefix \\ "req211-attach") do
    Letflow.TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-211 Attachments Test Tenant"
    )
  end

  defp upload_attrs(overrides \\ []) do
    Map.merge(
      %{
        instance_id: Ecto.UUID.generate(),
        raw_bytes: "hello attachment bytes",
        file_name: "note.txt",
        content_type: "text/plain",
        uploaded_by: Ecto.UUID.generate(),
        description: nil
      },
      Map.new(overrides)
    )
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- instance_attachments lives inside the tenant's own Postgres schema,
  # with tenant_id retained and instance_id required (not nullable) -- matching
  # decision 0003 Decision B's pattern (dlq_test.exs's AC1 test is the idiom
  # copied here). ELIXIR-DEV's own 15 sanity tests exercised upload/2 (which
  # always supplies instance_id) but never demonstrated the column-level
  # NOT NULL constraint itself, nor that the table is absent from `public` --
  # gap closed here.
  # ---------------------------------------------------------------------------------

  describe "AC1: instance_attachments migration -- schema-per-tenant, tenant_id retained, instance_id required" do
    test "the table exists in the tenant's own schema, carries tenant_id/instance_id columns (both NOT NULL), and is absent from public" do
      %{schema_name: schema_name} = provisioned_tenant("req211-ac1")

      %{rows: tenant_columns} =
        Repo.query!(
          "SELECT column_name, is_nullable FROM information_schema.columns " <>
            "WHERE table_schema = $1 AND table_name = 'instance_attachments'",
          [schema_name]
        )

      columns = Map.new(tenant_columns, fn [name, nullable] -> {name, nullable} end)

      assert columns["tenant_id"] == "NO"
      assert columns["instance_id"] == "NO"
      assert columns["content_hash"] == "NO"
      assert columns["id"] == "NO"

      # The isolation boundary is the Postgres schema itself (design §1.1) --
      # confirmed by there being no instance_attachments table in `public` at
      # all, matching Letflow.Dlq's own AC1 test idiom.
      %{rows: public_rows} =
        Repo.query!(
          "SELECT 1 FROM information_schema.tables " <>
            "WHERE table_schema = 'public' AND table_name = 'instance_attachments'"
        )

      assert public_rows == []
    end

    test "attempting to insert a row with instance_id = NULL is rejected at the database level" do
      %{schema_name: schema} = provisioned_tenant("req211-ac1-null")

      assert {:ok, %Attachment{}} = Attachments.upload(upload_attrs(), prefix: schema)

      # Bypass the context module's own changeset validation (which also
      # requires instance_id) to prove the NOT NULL constraint is real at the
      # DB layer, not merely application-level -- a raw insert with
      # instance_id omitted must be rejected by Postgres itself.
      hash_hex = Base.encode16(:crypto.hash(:sha256, "no-instance-id"))

      sql = """
      INSERT INTO "#{schema}".instance_attachments
        (id, tenant_id, content_hash, file_name, content_type, byte_size, uploaded_by, created_at)
      VALUES (gen_random_uuid(), gen_random_uuid(),
              decode('#{hash_hex}', 'hex'),
              'x.txt', 'text/plain', 1, gen_random_uuid(), now())
      """

      assert_raise Postgrex.Error, ~r/null value in column "instance_id"/, fn ->
        Repo.query!(sql, [])
      end
    end
  end

  describe "upload/2" do
    test "hashes bytes independently, upserts repository_artifacts (with real content), and creates one instance_attachments row" do
      %{schema_name: schema} = provisioned_tenant()

      assert {:ok, %Attachment{} = attachment} =
               Attachments.upload(upload_attrs(), prefix: schema)

      assert attachment.file_name == "note.txt"
      assert attachment.content_type == "text/plain"
      assert attachment.byte_size == byte_size("hello attachment bytes")

      expected_hash = :crypto.hash(:sha256, "hello attachment bytes")
      assert attachment.content_hash == expected_hash

      stored_artifact = Repo.get!(Artifact, expected_hash, prefix: schema)
      assert stored_artifact.content == "hello attachment bytes"
      assert stored_artifact.content_type == "text/plain"
    end

    test "byte-identical content under two different instance_id values reuses one repository_artifacts row but creates two instance_attachments rows (AC2)" do
      %{schema_name: schema} = provisioned_tenant()

      instance_a = Ecto.UUID.generate()
      instance_b = Ecto.UUID.generate()
      shared_bytes = "shared delivery note content"

      assert {:ok, attachment_a} =
               Attachments.upload(
                 upload_attrs(instance_id: instance_a, raw_bytes: shared_bytes),
                 prefix: schema
               )

      assert {:ok, attachment_b} =
               Attachments.upload(
                 upload_attrs(instance_id: instance_b, raw_bytes: shared_bytes),
                 prefix: schema
               )

      assert attachment_a.content_hash == attachment_b.content_hash
      refute attachment_a.id == attachment_b.id

      assert Repo.aggregate(Artifact, :count, prefix: schema) == 1
      assert Repo.aggregate(Attachment, :count, prefix: schema) == 2
    end

    test "byte_size is independently measured from the actual bytes, not any caller-supplied field (AC3 -- upload_attrs has no such field)" do
      %{schema_name: schema} = provisioned_tenant()

      raw_bytes = :binary.copy("x", 777)

      assert {:ok, attachment} =
               Attachments.upload(upload_attrs(raw_bytes: raw_bytes), prefix: schema)

      assert attachment.byte_size == 777
    end

    test "a caller-supplied byte_size-shaped value that mismatches the real byte count is ignored -- stored byte_size always reflects the actual bytes (AC3, gap-closing mutation test)" do
      %{schema_name: schema} = provisioned_tenant()

      raw_bytes = :binary.copy("y", 42)

      # upload_attrs() intentionally has no :byte_size key in its @type
      # (design §4.0 item 4 -- "there is structurally nothing to ignore").
      # This test proves that guarantee holds even when a caller smuggles a
      # mismatched byte_size-shaped value into the attrs map -- upload/2 must
      # not accidentally read it via Map.get/2 with a fallback, or any other
      # path that would let a caller-declared size win. A mutation that
      # introduces exactly that (e.g. `Map.get(attrs, :byte_size,
      # byte_size(raw_bytes))`) is caught here even though it survives the
      # other upload/2 tests, none of which ever pass a :byte_size key.
      attrs = Map.put(upload_attrs(raw_bytes: raw_bytes), :byte_size, 999_999)

      assert {:ok, attachment} = Attachments.upload(attrs, prefix: schema)

      assert attachment.byte_size == 42
      refute attachment.byte_size == 999_999

      stored_artifact = Repo.get!(Artifact, attachment.content_hash, prefix: schema)
      assert stored_artifact.byte_size == 42
    end

    test "an upload exceeding the 25 MiB ceiling is rejected before any persistence, with neither row created (AC4)" do
      %{schema_name: schema} = provisioned_tenant()

      oversized = :binary.copy("a", 26_214_401)

      assert Attachments.upload(upload_attrs(raw_bytes: oversized), prefix: schema) ==
               {:error, :file_too_large}

      assert Repo.aggregate(Artifact, :count, prefix: schema) == 0
      assert Repo.aggregate(Attachment, :count, prefix: schema) == 0
    end

    test "does not canonicalise attachment bytes even when content_type is application/json" do
      %{schema_name: schema} = provisioned_tenant()

      # Not canonical JSON (unsorted keys, extra whitespace) -- if this module
      # ran it through Canonicaliser, the hash would differ from a plain
      # byte-identity hash of these exact bytes.
      raw_bytes = ~s({ "b": 2, "a": 1 })

      assert {:ok, attachment} =
               Attachments.upload(
                 upload_attrs(raw_bytes: raw_bytes, content_type: "application/json"),
                 prefix: schema
               )

      assert attachment.content_hash == :crypto.hash(:sha256, raw_bytes)
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0399 -- content-scanning pipeline (lib/letflow/design/iss0399-attachment-
  # content-scanning.md). Four traps this fix exists to close, each with its own
  # test: (1) infected content must not be persisted; (2) a scanner exception must
  # not become a false-clean; (3) a pre-existing/pending row must not be servable;
  # (4) an infected-upload attempt must be audit-logged without leaking raw bytes.
  # ---------------------------------------------------------------------------------

  describe "ISS-0399: clean upload is scanned, marked :clean, and servable" do
    test "a non-EICAR upload gets scan_status: :clean and its content is fetchable via get_content/2" do
      %{schema_name: schema} = provisioned_tenant("iss0399-clean")

      assert {:ok, attachment} = Attachments.upload(upload_attrs(), prefix: schema)
      assert attachment.scan_status == :clean

      assert {:ok, ^attachment, artifact} = Attachments.get_content(attachment.id, prefix: schema)
      assert artifact.content == "hello attachment bytes"
    end
  end

  describe "ISS-0399: EICAR-signature upload is rejected and nothing is persisted" do
    test "upload/2 returns {:error, :infected, verdict} and creates neither an instance_attachments nor a repository_artifacts row" do
      %{schema_name: schema} = provisioned_tenant("iss0399-eicar")

      eicar =
        "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"

      assert {:error, :infected, verdict} =
               Attachments.upload(upload_attrs(raw_bytes: eicar), prefix: schema)

      assert verdict == "eicar-test-signature"

      # Nothing persisted -- asserted directly via DB counts, not inference
      # (Mutant A target: infected branch must short-circuit before any
      # upsert/insert).
      assert Repo.aggregate(Attachment, :count, prefix: schema) == 0
      assert Repo.aggregate(Artifact, :count, prefix: schema) == 0
    end

    test "an EICAR upload rejection is audit-logged with tenant/actor/hash metadata but never the raw bytes" do
      %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant("iss0399-audit")

      eicar =
        "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"

      uploaded_by = Ecto.UUID.generate()
      instance_id = Ecto.UUID.generate()

      log =
        ExUnit.CaptureLog.capture_log([metadata: :all], fn ->
          assert {:error, :infected, _verdict} =
                   Attachments.upload(
                     upload_attrs(
                       raw_bytes: eicar,
                       instance_id: instance_id,
                       uploaded_by: uploaded_by
                     ),
                     prefix: schema
                   )
        end)

      assert log =~ "attachment upload rejected: infected content"
      assert log =~ tenant_id
      assert log =~ instance_id
      assert log =~ uploaded_by
      assert log =~ Base.encode16(:crypto.hash(:sha256, eicar), case: :lower)

      # The raw bytes/EICAR signature itself must never appear in the log line.
      refute log =~ "EICAR-STANDARD-ANTIVIRUS-TEST-FILE"
    end
  end

  describe "ISS-0399: a scanner adapter exception fails closed, never a false-clean" do
    defmodule RaisingScanner do
      @moduledoc false
      @behaviour Letflow.Repository.AttachmentScanner

      @impl true
      def scan(_raw_bytes, _content_type) do
        raise "simulated scanner crash"
      end
    end

    defp put_attachment_scanner!(module) do
      previous = Application.get_env(:letflow, :attachment_scanner)
      Application.put_env(:letflow, :attachment_scanner, module)

      on_exit(fn ->
        if previous do
          Application.put_env(:letflow, :attachment_scanner, previous)
        else
          Application.delete_env(:letflow, :attachment_scanner)
        end
      end)

      :ok
    end

    test "an adapter that raises returns {:error, :scan_unavailable}, not a false {:ok, :clean}, and nothing is persisted" do
      %{schema_name: schema} = provisioned_tenant("iss0399-raise")
      put_attachment_scanner!(RaisingScanner)

      assert Attachments.upload(upload_attrs(), prefix: schema) == {:error, :scan_unavailable}

      # Mutant B target: the rescue clause must return an error tuple, not
      # {:ok, :clean} -- asserted here by proving nothing was persisted, which
      # is only possible if the scan step genuinely fails closed.
      assert Repo.aggregate(Attachment, :count, prefix: schema) == 0
      assert Repo.aggregate(Artifact, :count, prefix: schema) == 0
    end
  end

  describe "ISS-0399: a non-:clean attachment's content is never servable via get_content/2" do
    test "a :pending row (pre-existing/backfilled shape) is rejected with {:error, :not_available}" do
      %{schema_name: schema} = provisioned_tenant("iss0399-pending")

      # upload/2 itself can never produce a :pending row (only :clean is ever
      # written on the write path) -- simulate the ONE way a :pending row can
      # exist: a pre-existing row from before this migration shipped
      # (design §1.1's DB-level default). Constructed directly via the
      # schema's own changeset/Repo.insert, bypassing upload/2 entirely, the
      # same way this codebase's other "simulate a pre-existing row" fixtures
      # work.
      tenant_id = Ecto.UUID.generate()
      content_hash = :crypto.hash(:sha256, "pending row content")

      {:ok, _artifact} =
        Repository.upsert_content(
          schema,
          tenant_id,
          content_hash,
          "text/plain",
          20,
          "pending row content"
        )

      pending_attrs = %{
        tenant_id: tenant_id,
        instance_id: Ecto.UUID.generate(),
        content_hash: content_hash,
        file_name: "pending.txt",
        content_type: "text/plain",
        byte_size: 20,
        uploaded_by: Ecto.UUID.generate(),
        scan_status: :pending
      }

      {:ok, pending_attachment} =
        %Attachment{}
        |> Attachment.changeset(pending_attrs)
        |> Repo.insert(prefix: schema)

      assert pending_attachment.scan_status == :pending

      # Mutant C target: the scan_status != :clean gate in get_content/2 must
      # reject this, not just :infected/:error.
      assert Attachments.get_content(pending_attachment.id, prefix: schema) ==
               {:error, :not_available}

      # Metadata is still readable -- only byte-serving is gated (design §4.2).
      assert {:ok, %Attachment{scan_status: :pending}} =
               Attachments.get(pending_attachment.id, prefix: schema)
    end

    test "an :infected row (not reachable via upload/2, simulated directly) is rejected with {:error, :not_available}" do
      %{schema_name: schema} = provisioned_tenant("iss0399-infected-row")

      tenant_id = Ecto.UUID.generate()
      content_hash = :crypto.hash(:sha256, "infected row content")

      {:ok, _artifact} =
        Repository.upsert_content(
          schema,
          tenant_id,
          content_hash,
          "text/plain",
          22,
          "infected row content"
        )

      infected_attrs = %{
        tenant_id: tenant_id,
        instance_id: Ecto.UUID.generate(),
        content_hash: content_hash,
        file_name: "infected.txt",
        content_type: "text/plain",
        byte_size: 22,
        uploaded_by: Ecto.UUID.generate(),
        scan_status: :infected
      }

      {:ok, infected_attachment} =
        %Attachment{}
        |> Attachment.changeset(infected_attrs)
        |> Repo.insert(prefix: schema)

      assert Attachments.get_content(infected_attachment.id, prefix: schema) ==
               {:error, :not_available}
    end
  end

  describe "list/2" do
    test "tenant-scoped and filtered by instance_id (AC5)" do
      %{schema_name: schema_a} = provisioned_tenant("req211-list-a")
      %{schema_name: schema_b} = provisioned_tenant("req211-list-b")

      instance_x = Ecto.UUID.generate()
      instance_y = Ecto.UUID.generate()

      assert {:ok, _} =
               Attachments.upload(upload_attrs(instance_id: instance_x), prefix: schema_a)

      assert {:ok, %{items: items_b}} =
               Attachments.list(%{instance_id: instance_x, cursor: nil, page_size: 10},
                 prefix: schema_b
               )

      assert items_b == []

      assert {:ok, %{items: items_wrong_instance}} =
               Attachments.list(%{instance_id: instance_y, cursor: nil, page_size: 10},
                 prefix: schema_a
               )

      assert items_wrong_instance == []

      assert {:ok, %{items: items_a}} =
               Attachments.list(%{instance_id: instance_x, cursor: nil, page_size: 10},
                 prefix: schema_a
               )

      assert length(items_a) == 1
    end

    test "cursor pagination returns the next distinct page with no repeated or skipped ids (AC6)" do
      %{schema_name: schema} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()

      for n <- 1..5 do
        assert {:ok, _} =
                 Attachments.upload(
                   upload_attrs(instance_id: instance_id, raw_bytes: "content-#{n}"),
                   prefix: schema
                 )
      end

      assert {:ok, page_1} =
               Attachments.list(%{instance_id: instance_id, cursor: nil, page_size: 2},
                 prefix: schema
               )

      assert length(page_1.items) == 2
      assert is_binary(page_1.next_cursor)

      assert {:ok, page_2} =
               Attachments.list(
                 %{instance_id: instance_id, cursor: page_1.next_cursor, page_size: 2},
                 prefix: schema
               )

      assert length(page_2.items) == 2

      ids_1 = Enum.map(page_1.items, & &1.id)
      ids_2 = Enum.map(page_2.items, & &1.id)
      refute Enum.any?(ids_2, &(&1 in ids_1))
    end
  end

  describe "get/2" do
    test "invalid id returns :invalid_id without a DB round-trip" do
      %{schema_name: schema} = provisioned_tenant()
      assert Attachments.get("not-a-uuid", prefix: schema) == {:error, :invalid_id}
    end

    test "nonexistent id in a real tenant schema returns :not_found" do
      %{schema_name: schema} = provisioned_tenant()
      assert Attachments.get(Ecto.UUID.generate(), prefix: schema) == {:error, :not_found}
    end
  end

  describe "delete/2 (AC7)" do
    test "removes the instance_attachments row only -- repository_artifacts row and a sibling attachment sharing the hash both survive" do
      %{schema_name: schema} = provisioned_tenant()

      shared_bytes = "shared for delete test"
      instance_id = Ecto.UUID.generate()

      assert {:ok, attachment_1} =
               Attachments.upload(
                 upload_attrs(instance_id: instance_id, raw_bytes: shared_bytes),
                 prefix: schema
               )

      assert {:ok, attachment_2} =
               Attachments.upload(
                 upload_attrs(instance_id: instance_id, raw_bytes: shared_bytes),
                 prefix: schema
               )

      assert {:ok, _deleted} = Attachments.delete(attachment_1.id, prefix: schema)

      assert Attachments.get(attachment_1.id, prefix: schema) == {:error, :not_found}
      assert {:ok, _} = Attachments.get(attachment_2.id, prefix: schema)

      assert Repo.get!(Artifact, attachment_2.content_hash, prefix: schema)
      assert Repo.aggregate(Artifact, :count, prefix: schema) == 1
    end
  end

  describe "cross-tenant isolation" do
    test "an attachment uploaded in tenant A's schema is not reachable from tenant B's schema" do
      %{schema_name: schema_a} = provisioned_tenant("req211-iso-a")
      %{schema_name: schema_b} = provisioned_tenant("req211-iso-b")

      assert {:ok, attachment} = Attachments.upload(upload_attrs(), prefix: schema_a)

      assert Attachments.get(attachment.id, prefix: schema_b) == {:error, :not_found}
      assert {:ok, _} = Attachments.get(attachment.id, prefix: schema_a)
    end

    test "two different tenants uploading byte-identical content produce two independent repository_artifacts rows, not one shared row (AC8)" do
      %{schema_name: schema_a} = provisioned_tenant("req211-dedup-a")
      %{schema_name: schema_b} = provisioned_tenant("req211-dedup-b")

      shared_bytes = "identical bytes across tenants"

      assert {:ok, attachment_a} =
               Attachments.upload(upload_attrs(raw_bytes: shared_bytes), prefix: schema_a)

      assert {:ok, attachment_b} =
               Attachments.upload(upload_attrs(raw_bytes: shared_bytes), prefix: schema_b)

      assert attachment_a.content_hash == attachment_b.content_hash

      # Each tenant's own schema independently holds a row for this hash --
      # not one shared row. Each schema has exactly one repository_artifacts
      # row of its own (not zero, not two) -- physically separate rows in
      # physically separate Postgres schemas, never a cross-tenant-shared row.
      row_in_a = Repo.get!(Artifact, attachment_a.content_hash, prefix: schema_a)
      row_in_b = Repo.get!(Artifact, attachment_b.content_hash, prefix: schema_b)

      assert row_in_a.content == shared_bytes
      assert row_in_b.content == shared_bytes
      assert Repo.aggregate(Artifact, :count, prefix: schema_a) == 1
      assert Repo.aggregate(Artifact, :count, prefix: schema_b) == 1
    end
  end

  describe "moduledoc content statements" do
    test "states per-tenant dedup boundary, no-canonicalisation, and the real content-scanning mechanism (ISS-0399)" do
      {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(Attachments)

      normalized = String.replace(moduledoc, ~r/\s+/, " ")

      assert normalized =~ "Decision B"
      assert normalized =~ "never one shared row"
      assert normalized =~ "No canonicalisation is applied to attachment bytes"

      # ISS-0399 design §4.3: the old "Content-scanning deferral" section
      # (which said this was a "deliberately deferred follow-up") is REPLACED,
      # not appended to, by a statement of the mechanism actually shipped --
      # the deferral is now resolved, so asserting deferral language would
      # assert something no longer true. This is the corrected assertion:
      # the moduledoc must document the real synchronous scan step, its
      # reject-before-persist guarantee, and the default adapter, and must
      # NOT still claim the scan is deferred.
      refute normalized =~ "deliberately deferred follow-up"
      assert normalized =~ "synchronous"
      assert normalized =~ "reject-before-persist"
      assert normalized =~ "Letflow.Repository.AttachmentScanner.SignatureHeuristic"
    end
  end

  # AC10's original test ("no lib/letflow/routers/*.ex file references
  # Letflow.Repository.Attachments") asserted REQ-211's OWN scope boundary
  # at the time it was written -- REQ-211's own description states the
  # route/controller layer is explicitly out of REQ-211's scope and belongs
  # to a future requirement (REQ-212). That guard was a temporal statement
  # ("not yet, and not by this requirement"), not a permanent invariant that
  # instance_attachments must never have a route surface at all. REQ-212 has
  # now shipped `lib/letflow/routers/instances.ex`'s four
  # `/instances/:id/attachments...` routes atop this exact context module,
  # per design `lib/letflow/design/req212-instance-attachments-routes.md` --
  # removed rather than kept failing, since a permanently-red test asserting
  # the wrong thing is worse than no test. See
  # `test/letflow/routers/req212_attachments_routes_test.exs` for the route
  # layer's own coverage.

  describe "Repository.upsert_content/6 (option (a) shared upsert path)" do
    test "is a public function on Letflow.Repository" do
      # function_exported?/3 checks the loaded-module table, not the compiled
      # .beam on disk -- Repository may not yet be loaded if no earlier test
      # in this run has touched it (ISS-0401).
      Code.ensure_loaded?(Repository)
      assert function_exported?(Repository, :upsert_content, 6)
    end
  end
end
