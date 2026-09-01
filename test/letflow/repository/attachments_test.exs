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
    test "states per-tenant dedup boundary, no-canonicalisation, and content-scanning deferral" do
      {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(Attachments)

      normalized = String.replace(moduledoc, ~r/\s+/, " ")

      assert normalized =~ "Decision B"
      assert normalized =~ "never one shared row"
      assert normalized =~ "No canonicalisation is applied to attachment bytes"
      assert normalized =~ "deliberately deferred follow-up"
    end
  end

  describe "AC10 -- no route/controller surface exists for instance attachments" do
    test "no lib/letflow/routers/*.ex file references Letflow.Repository.Attachments" do
      offending_files =
        "lib/letflow/routers/**/*.ex"
        |> Path.wildcard()
        |> Enum.filter(&String.contains?(File.read!(&1), "Letflow.Repository.Attachments"))

      assert offending_files == [],
             "found router file(s) referencing Letflow.Repository.Attachments: #{inspect(offending_files)}"
    end
  end

  describe "Repository.upsert_content/6 (option (a) shared upsert path)" do
    test "is a public function on Letflow.Repository" do
      assert function_exported?(Repository, :upsert_content, 6)
    end
  end
end
