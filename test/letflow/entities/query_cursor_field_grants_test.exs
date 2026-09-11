defmodule Letflow.Entities.QueryCursorFieldGrantsTest do
  @moduledoc """
  Tests for `Letflow.Entities.Query.Cursor` and
  `Letflow.Entities.Query.FieldGrants` (REQ-231) -- the generalized
  keyset-pagination cursor codec and the per-user, per-field redaction
  loader. See `lib/letflow/design/req231-entity-query-cursor-field-grants.md`
  for the design this file verifies, and REQ-231's own
  `docs/requirements.yaml` entry for the authoritative 5 acceptance
  criteria this file's `describe` blocks are grouped by.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked
  database. Self-contained: provisions its own tenant schema(s), mirroring
  `test/letflow/entities/query_test.exs`'s own hand-rolled tenant-fixture
  pattern (DIRECTIVE T-4).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Api.Pagination
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.Query.Allowlist
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Query.Cursor
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  import Ecto.Query

  # ---------------------------------------------------------------------------------
  # Fixtures -- same shape as test/letflow/entities/query_test.exs's
  # provisioned_tenant/0.
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("req231-cursor-fg"),
        display_name: "REQ-231 Cursor/FieldGrants Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

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
    assert {:ok, _seed_result} = Letflow.Entities.EventTypes.seed!(schema_name)

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp valid_definition(overrides) do
    Map.merge(
      %{
        name: "customer",
        display_name: "Customer",
        fields: [
          %{name: "customer_name", type: :string, required: true, queried: true},
          %{name: "age", type: :integer, queried: true},
          %{name: "ssn", type: :string, queried: true}
        ]
      },
      overrides
    )
  end

  defp create_active_definition!(schema, overrides \\ %{}) do
    definition = valid_definition(overrides)

    assert {:ok, entity_definition} =
             Definitions.create_definition(
               %{definition: definition, created_by: Ecto.UUID.generate()},
               schema
             )

    assert {:ok, activated} =
             Definitions.activate_definition(
               entity_definition.name,
               Ecto.UUID.generate(),
               "go-live",
               schema
             )

    activated
  end

  defp create_record!(schema, field_values) do
    attrs = %{
      entity_type: "customer",
      field_values: field_values,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }

    assert {:ok, %{record: record}} = Records.create_record(attrs, schema)
    record
  end

  defp create_user!(schema, username) do
    assert {:ok, user} =
             Identity.create_user(
               %{
                 "username" => username,
                 "display_name" => username,
                 "email" => "#{username}@example.test"
               },
               prefix: schema
             )

    user
  end

  defp insert_field_restriction!(schema, entity_type, field_name) do
    Repo.insert_all(
      "entity_field_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: entity_type,
          field_name: field_name,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema
    )
  end

  defp insert_user_grant!(schema, user_id, entity_type, field_name) do
    Repo.insert_all(
      "user_entity_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(user_id),
          entity_type: entity_type,
          field_name: field_name,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema
    )
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- a query result set larger than one page returns a next_cursor,
  # and passing that cursor back returns the next distinct page with no
  # repeated or skipped records. Exercised against a GENERIC (multi-field,
  # non-default) sort clause, not the trivial `inserted_at desc, id desc`
  # shape, to prove the codec genuinely generalizes (REQ-230's compiler
  # accepts any allowlisted field/fields).
  # ---------------------------------------------------------------------------------

  describe "AC1 -- keyset pagination over a generic sort clause (Cursor)" do
    test "next_cursor round-trips through every page with no repeated or skipped records" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      # Two customers named "Alice" and "Bob"; multiple ages under "Alice" to
      # exercise the tiebreak between the two sort fields themselves (not
      # just the trailing id tiebreak).
      fixtures = [
        {"Alice", 30},
        {"Alice", 25},
        {"Alice", 20},
        {"Bob", 40},
        {"Bob", 10}
      ]

      for {name, age} <- fixtures do
        create_record!(schema, %{"customer_name" => name, "age" => age})
      end

      # A genuine multi-field, caller-chosen sort: customer_name asc, age
      # desc -- not REQ-067's fixed inserted_at/id shape.
      request = %{
        entity_type: "customer",
        sort: [
          %{field: "customer_name", dir: :asc},
          %{field: "age", dir: :desc}
        ]
      }

      assert {:ok, compiled_query} = Compiler.compile(request, schema)
      assert {:ok, allowlist} = Allowlist.load("customer", schema)

      expected_order = [
        {"Alice", 30},
        {"Alice", 25},
        {"Alice", 20},
        {"Bob", 40},
        {"Bob", 10}
      ]

      {all_items, pages_seen} =
        paginate_all(request, compiled_query, allowlist, schema, page_size: 2)

      # 3 pages of size 2, 2, 1 for 5 total records.
      assert pages_seen == 3

      actual_order =
        Enum.map(all_items, fn item ->
          {Map.fetch!(item.field_values, "customer_name"), Map.fetch!(item.field_values, "age")}
        end)

      assert actual_order == expected_order

      # No repeated or skipped records.
      ids = Enum.map(all_items, & &1.id)
      assert length(ids) == length(fixtures)
      assert length(Enum.uniq(ids)) == length(fixtures)
    end

    test "a page smaller than page_size returns no next_cursor" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      create_record!(schema, %{"customer_name" => "Solo", "age" => 1})

      request = %{entity_type: "customer", sort: [%{field: "age", dir: :asc}]}

      assert {:ok, compiled_query} = Compiler.compile(request, schema)
      assert {:ok, allowlist} = Allowlist.load("customer", schema)

      assert {:ok, page} =
               Cursor.paginate(request, compiled_query, allowlist, %{page_size: 10}, schema)

      assert length(page.items) == 1
      assert page.next_cursor == nil
    end

    test "resending a cursor with a different sort shape than the one that minted it is rejected" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      for age <- [1, 2, 3] do
        create_record!(schema, %{"customer_name" => "X", "age" => age})
      end

      mint_request = %{
        entity_type: "customer",
        sort: [%{field: "customer_name", dir: :asc}, %{field: "age", dir: :asc}]
      }

      assert {:ok, compiled_query} = Compiler.compile(mint_request, schema)
      assert {:ok, allowlist} = Allowlist.load("customer", schema)

      assert {:ok, page} =
               Cursor.paginate(mint_request, compiled_query, allowlist, %{page_size: 1}, schema)

      refute is_nil(page.next_cursor)

      # Resend with only one sort field -- arity no longer matches.
      resume_request = %{entity_type: "customer", sort: [%{field: "age", dir: :asc}]}
      assert {:ok, compiled_query2} = Compiler.compile(resume_request, schema)

      assert Cursor.paginate(
               resume_request,
               compiled_query2,
               allowlist,
               %{page_size: 1, cursor: page.next_cursor},
               schema
             ) == {:error, :resume_key_arity_mismatch}
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0522 (site 2) -- Cursor.paginate/5's id-tiebreaker component must be
  # validated as a real UUID before it reaches maybe_dump/2's unconditional
  # Ecto.UUID.dump!/1, returning {:error, :invalid_cursor} for a malformed
  # component instead of letting an ArgumentError raise. See
  # lib/letflow/design/iss0522-cursor-uuid-cast-guard.md §6 (esp. §6.6) and
  # test/specs/ISS-0522.md's "Site 2" section for the acceptance criteria
  # this describe block covers. Mirrors this issue's own site-1 coverage in
  # test/letflow/entities/definitions_test.exs.
  # ---------------------------------------------------------------------------------

  describe "ISS-0522 (site 2) -- malformed id-component cast guard (Cursor.paginate/5)" do
    setup do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      for age <- [10, 20] do
        create_record!(schema, %{"customer_name" => "Guard", "age" => age})
      end

      request = %{entity_type: "customer", sort: [%{field: "age", dir: :asc}]}
      assert {:ok, compiled_query} = Compiler.compile(request, schema)
      assert {:ok, allowlist} = Allowlist.load("customer", schema)

      %{schema: schema, request: request, compiled_query: compiled_query, allowlist: allowlist}
    end

    # Mints a cursor by hand -- the same "EQ:<mint_time_us>:<resume_key_json>"
    # shape Cursor.build_next_cursor/2 itself produces -- with an
    # attacker/caller-controlled id component, exactly as a real
    # network-facing request body would carry it.
    defp raw_cursor_with_id(sort_values, id_value) do
      resume_key_json = Jason.encode!(sort_values ++ [id_value])
      mint_time_us = System.system_time(:microsecond)

      Cursor.cursor_prefix()
      |> Pagination.build_raw_cursor(mint_time_us, resume_key_json)
      |> Pagination.encode_cursor()
    end

    test "a non-UUID id component returns {:error, :invalid_cursor}, not a raise",
         %{schema: schema, request: request, compiled_query: compiled_query, allowlist: allowlist} do
      encoded = raw_cursor_with_id([15], "not-a-uuid")

      assert Cursor.paginate(
               request,
               compiled_query,
               allowlist,
               %{page_size: 10, cursor: encoded},
               schema
             ) == {:error, :invalid_cursor}
    end

    test "a UUID-length id component with invalid hex/hyphen content is still rejected",
         %{schema: schema, request: request, compiled_query: compiled_query, allowlist: allowlist} do
      # 36 characters, hyphens in the right positions -- proves
      # Ecto.UUID.cast/1's real validation gates this, not a bare length check.
      bogus_uuid_shaped = "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz"
      assert String.length(bogus_uuid_shaped) == 36

      encoded = raw_cursor_with_id([15], bogus_uuid_shaped)

      assert Cursor.paginate(
               request,
               compiled_query,
               allowlist,
               %{page_size: 10, cursor: encoded},
               schema
             ) == {:error, :invalid_cursor}
    end

    test "non-regression: a valid, system-minted cursor (real UUID id component) still paginates cleanly",
         %{schema: schema, request: request, compiled_query: compiled_query, allowlist: allowlist} do
      assert {:ok, first_page} =
               Cursor.paginate(
                 request,
                 compiled_query,
                 allowlist,
                 %{page_size: 1},
                 schema
               )

      assert [%{field_values: %{"age" => 10}}] = first_page.items
      refute is_nil(first_page.next_cursor)

      assert {:ok, second_page} =
               Cursor.paginate(
                 request,
                 compiled_query,
                 allowlist,
                 %{page_size: 1, cursor: first_page.next_cursor},
                 schema
               )

      assert [%{field_values: %{"age" => 20}}] = second_page.items
      assert second_page.next_cursor == nil
    end
  end

  defp paginate_all(request, compiled_query, allowlist, schema, page_size: page_size) do
    do_paginate_all(request, compiled_query, allowlist, schema, page_size, nil, [], 0)
  end

  defp do_paginate_all(request, compiled_query, allowlist, schema, page_size, cursor, acc, pages) do
    opts = %{page_size: page_size, cursor: cursor}

    assert {:ok, page} = Cursor.paginate(request, compiled_query, allowlist, opts, schema)

    acc = acc ++ page.items
    pages = pages + 1

    case page.next_cursor do
      nil ->
        {acc, pages}

      next ->
        do_paginate_all(request, compiled_query, allowlist, schema, page_size, next, acc, pages)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- a user holding a field-level restriction has that field redacted
  # (not the whole row), while a user without that restriction sees the
  # field populated. Two explicit tests, per the requirement's own text.
  # ---------------------------------------------------------------------------------

  describe "AC2 -- per-field, per-user redaction (FieldGrants)" do
    setup do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      record =
        create_record!(schema, %{
          "customer_name" => "Alice",
          "age" => 30,
          "ssn" => "123-45-6789"
        })

      # "ssn" is restricted by default for everyone on this entity type.
      insert_field_restriction!(schema, "customer", "ssn")

      %{schema: schema, record: record}
    end

    test "a user with no matching grant has the restricted field redacted, key retained",
         %{schema: schema, record: record} do
      user_without_grant = create_user!(schema, "no-grant-user")

      assert {:ok, restriction_set} =
               FieldGrants.load_restrictions(user_without_grant.id, "customer", schema)

      redacted = FieldGrants.redact_field_values(record.field_values, restriction_set)

      assert Map.has_key?(redacted, "ssn")
      assert redacted["ssn"] == FieldGrants.redacted_sentinel()
      assert redacted["ssn"] == :__field_redacted__
      # Unrestricted fields pass through unchanged.
      assert redacted["customer_name"] == "Alice"
      assert redacted["age"] == 30
    end

    test "a user holding an explicit grant sees the restricted field populated",
         %{schema: schema, record: record} do
      user_with_grant = create_user!(schema, "granted-user")
      insert_user_grant!(schema, user_with_grant.id, "customer", "ssn")

      assert {:ok, restriction_set} =
               FieldGrants.load_restrictions(user_with_grant.id, "customer", schema)

      redacted = FieldGrants.redact_field_values(record.field_values, restriction_set)

      assert redacted["ssn"] == "123-45-6789"
      assert redacted["customer_name"] == "Alice"
      assert redacted["age"] == 30
    end

    test "redact_page/2 redacts every item's field_values while preserving next_cursor/count",
         %{schema: schema, record: record} do
      user_without_grant = create_user!(schema, "page-no-grant-user")

      assert {:ok, restriction_set} =
               FieldGrants.load_restrictions(user_without_grant.id, "customer", schema)

      page = Letflow.Api.Pagination.page_response([record], "some-next-cursor")
      redacted_page = FieldGrants.redact_page(page, restriction_set)

      assert redacted_page.next_cursor == "some-next-cursor"
      assert redacted_page.count == 1
      [item] = redacted_page.items
      assert item.field_values["ssn"] == :__field_redacted__
    end

    test "an entity type with zero restricted fields yields an empty restriction set, never an error",
         %{schema: schema} do
      user = create_user!(schema, "irrelevant-user")

      assert {:ok, restriction_set} =
               FieldGrants.load_restrictions(user.id, "does-not-exist-entity-type", schema)

      assert MapSet.size(restriction_set) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- no route or controller file added or modified by this
  # requirement. Structural check, RE-DERIVED 2026-09-11 because the
  # feature it was waiting for landed.
  #
  # As originally written this block asserted the NEGATIVE: that no file
  # under lib/letflow/routers/ mentions Query.Cursor or Query.FieldGrants
  # at all. That was never REQ-231's actual acceptance criterion. AC4 reads
  # "no route or controller file is added or modified, confirmed by
  # git diff --stat scoped to THIS REQUIREMENT'S COMMITS" -- a scope
  # constraint on one requirement's own diff, not a standing ban on ever
  # wiring the query subsystem up. REQ-231's description says the same
  # thing in prose ("NOT IN THIS REQUIREMENT: ... no route or controller --
  # same deferral as REQ-230"), and REQ-230 names the reason for the
  # deferral: the router row "remains deferred per the same 'no consumer
  # contract' reasoning REQ-225/REQ-226 already state." Deferred, not
  # forbidden. The tree-wide grep was a convenient point-in-time PROXY for
  # "the wiring hasn't happened yet," valid only for as long as that
  # remained true.
  #
  # It stopped being true with REQ-311. REQ-309/310/311 close what the S10
  # stage file called gap 1 -- a query subsystem nothing routed to --
  # and REQ-311's POST /entities/query handler composes exactly these
  # modules by design: lib/letflow/routers/entities.ex aliases Compiler,
  # Cursor and FieldGrants and its run_query/5 chains
  # Compiler.compile/2 -> Allowlist.load/2 -> Cursor.paginate/5 ->
  # FieldGrants redaction, the sequence specified in
  # lib/letflow/design/req308-entity-http-surface.md §1's route table.
  # Left as-is, the old assertion asserted the ABSENCE of a feature that
  # had just been correctly built.
  #
  # What survives re-derivation is the part of the original intent that is
  # still load-bearing and still falsifiable: these modules are query
  # INTERNALS with exactly ONE sanctioned consumer. A second router
  # reaching into Cursor/FieldGrants directly would be a real regression --
  # duplicated pagination and, worse, a second redaction path that INV-2
  # does not cover. So the assertion is inverted rather than deleted: the
  # set of routers referencing them must be exactly [entities.ex], and
  # that one must use them in the designed composition.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- query internals have exactly one router consumer" do
    setup do
      router_files =
        Path.wildcard(Path.join([File.cwd!(), "lib", "letflow", "routers", "**/*.ex"]))

      # Guard the guard: a broken wildcard would make every assertion below
      # vacuously true.
      assert length(router_files) > 1

      referencing =
        router_files
        |> Enum.filter(fn file ->
          contents = File.read!(file)
          contents =~ "Query.Cursor" or contents =~ "Query.FieldGrants"
        end)
        |> Enum.map(&Path.relative_to(&1, File.cwd!()))
        |> Enum.sort()

      %{router_files: router_files, referencing: referencing}
    end

    test "Letflow.Routers.Entities is the ONLY router referencing Query.Cursor/Query.FieldGrants",
         %{referencing: referencing} do
      assert referencing == ["lib/letflow/routers/entities.ex"]
    end

    test "the one consumer composes them in the order design §1 specifies" do
      contents = File.read!(Path.join([File.cwd!(), "lib", "letflow", "routers", "entities.ex"]))

      assert contents =~ "alias Letflow.Entities.Query.Cursor"
      assert contents =~ "alias Letflow.Entities.Query.FieldGrants"

      # Compiler.compile/2 -> Cursor.paginate/5 -> a redaction step, in that
      # order, INSIDE run_query/5's with/1 chain.
      #
      # ⛔ Read the CHAIN, not the file. entities.ex documents itself
      # heavily and names `FieldGrants.redact_page/2` in its own @moduledoc
      # (~line 80) hundreds of lines ABOVE the call site -- a first-match
      # byte-offset comparison over the whole file measures prose order,
      # not composition order, and fails against correct code. (It did:
      # that was this test's own first draft.) Comment lines are stripped
      # for the same reason.
      chain = run_query_chain!(contents)

      compile_at = index_of!(chain, "Compiler.compile(")
      paginate_at = index_of!(chain, "Cursor.paginate(")
      redact_at = index_of!(chain, "redact(")

      assert compile_at < paginate_at
      assert paginate_at < redact_at
    end
  end

  # The code (comments stripped) of run_query/5's `with` chain, from the
  # `with` keyword to its `do`. Fails loudly rather than returning "" --
  # an absent or renamed chain must fail the ordering test, not satisfy it
  # vacuously.
  defp run_query_chain!(contents) do
    code =
      contents
      |> String.split("\n")
      |> Enum.reject(&(String.trim_leading(&1) =~ ~r/^#/))
      |> Enum.join("\n")

    case Regex.run(~r/defp run_query\(.*?\n\s*with (.*?) do\n/s, code, capture: :all_but_first) do
      [chain] -> chain
      nil -> flunk("expected lib/letflow/routers/entities.ex to define run_query/5 with a with/1 chain")
    end
  end

  # Byte offset of `needle` in `haystack`, failing loudly rather than
  # returning nil -- an absent call site must fail the ordering test, not
  # silently compare against nil.
  defp index_of!(haystack, needle) do
    case :binary.match(haystack, needle) do
      {at, _len} -> at
      :nomatch -> flunk("expected run_query/5's with chain to contain #{inspect(needle)}")
    end
  end
end
