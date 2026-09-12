defmodule Letflow.Packs.BilimbagaPackInstallTest do
  @moduledoc """
  REQ-328 -- performs a REAL `Letflow.Definitions.SolutionPack.install/3` of
  `priv/packs/bilimbaga/pack.json` against a real provisioned tenant, then
  activates, writes real records, and reads them back.

  This is the test that makes S10 phase P2's exit condition ("a tenant with a
  working question bank and exam configuration, and zero exam-specific Elixir")
  testable. Its value is entirely in running the real install path -- nothing
  here asserts that an install *would* work.

  ## Two different things in two different places -- do not conflate them

  `install/3`'s RESULT map carries `status: "installed"` for every entity
  definition: `solution_pack.ex`'s `installed_entity_definition_maps/1`
  hardcodes that literal string unconditionally. The PERSISTED
  `Letflow.Entities.EntityDefinition` row's `status` is the atom `:inactive`
  (0026 section 2). Asserting `"inactive"` on the result map would fail against
  correct platform behaviour. Both are asserted below, separately.

  ## Activation order matters; install order does not

  `install/3` writes `:inactive` metadata rows and emits no DDL, so the order of
  `entity_definitions` in the pack document is irrelevant to it. Table creation
  is lazy and gated on the ACTIVE definition
  (`TenantProvisioning.ensure_entity_table/2`), and `resolve_fk_target_tables/1`
  is a pure `"entity_" <> name` concat with no existence check -- so creating a
  table for an entity type whose FK target table does not exist yet emits
  `REFERENCES` against a missing table and fails as an opaque Postgres 42P01.
  `@activation_order` below is the FK DAG's topological order; see
  `priv/packs/bilimbaga/README.md`.

  ## No production module is modified by this requirement

  This file is a test. It reads `priv/packs/bilimbaga/pack.json` and calls
  existing, already-gated public API.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions.ExportImport
  alias Letflow.Definitions.SolutionPack
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion

  @pack_path Path.join([File.cwd!(), "priv", "packs", "bilimbaga", "pack.json"])
  @definitions_dir Path.join([File.cwd!(), "priv", "packs", "bilimbaga", "entity_definitions"])
  @generator_path Path.join([File.cwd!(), "priv", "packs", "bilimbaga", "generate_pack.exs"])

  @entity_types ~w(
    category tag question answer_option question_tag
    exam exam_section exam_question_rule exam_question_rule_tag exam_manual_question
  )

  # Topological order over the ten documents' own `foreign_keys`:
  #   category, tag, exam       -- zero FKs
  #   question                  -> category
  #   exam_section              -> exam
  #   answer_option             -> question
  #   question_tag              -> question, tag
  #   exam_question_rule        -> exam, exam_section, category
  #   exam_question_rule_tag    -> exam_question_rule, tag
  #   exam_manual_question      -> exam_question_rule, question
  @activation_order ~w(
    category tag exam
    question exam_section
    answer_option question_tag exam_question_rule
    exam_question_rule_tag exam_manual_question
  )

  defp pack_document, do: @pack_path |> File.read!() |> Jason.decode!()

  defp tenant do
    Letflow.TenantFixture.provisioned_tenant!(slug_prefix: "req328-pack-install")
  end

  # REQ-297's promotion mechanism: registering + running a ColumnPromotion is
  # what creates the per-entity-type table (carrying the entity type's FULL
  # promoted-column set, FK REFERENCES clauses included) and what makes the live
  # `Records.create_record/2` dual-write populate that column. Activation alone
  # creates no table. See README.md's install -> activate -> promote sequence.
  defp promote!(tenant_id, entity_type, attribute, pg_type, opts \\ []) do
    spec =
      case Keyword.get(opts, :references_entity) do
        nil -> %{pg_type: pg_type, nullable: true}
        target -> %{pg_type: pg_type, nullable: true, references_entity: target}
      end

    assert {:ok, [row]} =
             TenantProvisioning.register_column_promotion(entity_type, attribute, spec, [
               tenant_id
             ])

    assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
             TenantProvisioning.run_column_promotion(row.id)

    :ok
  end

  defp create_record!(schema, entity_type, field_values) do
    assert {:ok, %{record: record}} =
             Records.create_record(
               %{
                 entity_type: entity_type,
                 field_values: field_values,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: Ecto.UUID.generate()
               },
               schema
             )

    record
  end

  # ---------------------------------------------------------------------------
  # Provenance (AC1) -- pack.json IS committed, so drift from the ten source
  # files must fail the suite.
  # ---------------------------------------------------------------------------

  describe "provenance: the committed pack.json does not drift from its ten sources" do
    test "each embedded definition_json is structurally equal to its source file" do
      document = pack_document()

      for packed <- document["entity_definitions"] do
        source =
          @definitions_dir
          |> Path.join("#{packed["name"]}.json")
          |> File.read!()
          |> Jason.decode!()

        assert packed["definition_json"] == source,
               "pack.json's embedded #{packed["name"]} definition_json has drifted from " <>
                 "priv/packs/bilimbaga/entity_definitions/#{packed["name"]}.json -- " <>
                 "regenerate with: mix run priv/packs/bilimbaga/generate_pack.exs"
      end
    end

    test "the generator script that is the only permitted writer of pack.json exists" do
      assert File.exists?(@generator_path)
    end
  end

  # ---------------------------------------------------------------------------
  # Document shape (AC2, AC3) -- asserted against the real module constants,
  # never a remembered string.
  # ---------------------------------------------------------------------------

  describe "pack-document shape" do
    test "carries all eight keys parse_document/1 fetches, plus exported_at" do
      document = pack_document()

      for key <- ~w(pack_id version bpm_export_schema_version definitions
                    service_catalog_entries variable_schemas entity_definitions manifest) do
        assert Map.has_key?(document, key), "missing key #{key}"
      end

      assert Map.has_key?(document, "exported_at")

      # Read from the module, not remembered.
      assert document["bpm_export_schema_version"] == ExportImport.export_schema_version()

      # Decision 0027: a non-empty array is permanently rejected.
      assert document["service_catalog_entries"] == []
      assert document["definitions"] == []
      assert document["variable_schemas"] == []
    end

    test "entity_definitions carries exactly the ten authored types, correctly wrapped" do
      document = pack_document()
      packed = document["entity_definitions"]

      assert length(packed) == 10
      assert Enum.sort(Enum.map(packed, & &1["name"])) == Enum.sort(@entity_types)

      for entry <- packed do
        assert is_binary(entry["entity_definition_id"])
        assert is_binary(entry["name"])
        assert is_binary(entry["display_name"])
        assert is_binary(entry["logical_shape_version"])
        assert is_map(entry["definition_json"])

        # decode_logical_shape_version/1 calls Base.decode16(hex, case: :lower).
        assert {:ok, _raw} = Base.decode16(entry["logical_shape_version"], case: :lower)

        # Wrapper name/display_name must agree with the nested document's own.
        assert entry["name"] == entry["definition_json"]["name"]
        assert entry["display_name"] == entry["definition_json"]["display_name"]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # THE REAL INSTALL, and everything that depends on it. One test, because the
  # tenant is expensive and every later step builds on the same install.
  # ---------------------------------------------------------------------------

  describe "a real SolutionPack.install/3 against a real provisioned tenant" do
    test "installs, does not activate, then activates and serves a working question bank" do
      %{tenant_id: tenant_id, schema_name: schema} = tenant()
      actor_id = Ecto.UUID.generate()

      # ---- 1. THE REAL INSTALL -------------------------------------------
      assert {:ok, install_result} =
               SolutionPack.install(pack_document(), actor_id, prefix: schema)

      # Quoted verbatim into the run output -- the requirement's evidence.
      IO.puts("\n=== REQ-328 install_result (verbatim) ===")
      IO.puts(inspect(install_result, pretty: true, limit: :infinity, printable_limit: :infinity))
      IO.puts("=== end install_result ===\n")

      assert install_result.pack_id == "bilimbaga-question-bank"
      assert install_result.version == "1.0.0"
      assert is_binary(install_result.install_id)
      assert install_result.installed_definitions == []
      assert install_result.variable_schemas_written == 0
      assert install_result.warnings == []

      # ---- 2. ten entries, each status "installed" -- the literal string
      #         installed_entity_definition_maps/1 hardcodes. NOT "inactive".
      installed = install_result.installed_entity_definitions
      assert length(installed) == 10
      assert Enum.sort(Enum.map(installed, & &1.name)) == Enum.sort(@entity_types)
      assert Enum.all?(installed, &(&1.status == "installed"))
      assert Enum.uniq(Enum.map(installed, & &1.status)) == ["installed"]

      # ---- 3. role_mapping_checklist: every declared role unbound ---------
      checklist = install_result.role_mapping_checklist

      assert checklist == [
               %{role_name: "super_admin", bound: false},
               %{role_name: "examiner", bound: false},
               %{role_name: "department_admin", bound: false}
             ]

      # ...because none of them is one of the five platform roles.
      known = MapSet.new(Letflow.Api.Authorization.roles(), &Atom.to_string/1)
      assert Enum.all?(checklist, &(not MapSet.member?(known, &1.role_name)))

      # ---- 4a. the PERSISTED rows are :inactive -- the other of the two
      #          different things, in the other of the two different places.
      for entity_type <- @entity_types do
        assert {:ok, %EntityDefinition{status: :inactive}} =
                 Definitions.get_definition_by_name(entity_type, schema)
      end

      # ---- 4b. the cheapest REAL proof of non-activation: a write before
      #          activation is rejected for want of an ACTIVE definition.
      assert {:error, {:definition_not_found, "category"}} =
               Records.create_record(
                 %{
                   entity_type: "category",
                   field_values: %{
                     "name" => %{"kk" => "a", "ru" => "a", "en" => "a"},
                     "sort_order" => 1
                   },
                   actor_id: actor_id,
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      # ---- 5. ACTIVATE in FK-dependency order ----------------------------
      for entity_type <- @activation_order do
        assert {:ok, %EntityDefinition{status: :active}} =
                 Definitions.activate_definition(entity_type, actor_id, "REQ-328 go-live", schema)
      end

      # ---- 5b. PROMOTE, in the same dependency order. Promotion is what
      #          creates each per-entity-type table (with its FK REFERENCES
      #          clauses) and what makes the live dual-write populate the
      #          promoted columns. A target's table must exist before a
      #          referencing table is created -- same DAG, same reason.
      # A promotion on entity type E creates E's table carrying E's FULL
      # promoted-column set -- which includes a REFERENCES clause for EVERY
      # fk_def E declares, not just the attribute being promoted. So every one
      # of E's FK TARGET tables must already exist. Verified empirically: with
      # exam_section unpromoted, promoting exam_question_rule.exam_id emitted
      # REFERENCES against a missing entity_exam_section and failed as
      # ERROR 42P01 (undefined_table). Hence one promotion per entity type,
      # in @activation_order.
      promote!(tenant_id, "category", "sort_order", "bigint")
      promote!(tenant_id, "tag", "name", "text")
      promote!(tenant_id, "exam", "status", "text")

      promote!(tenant_id, "question", "category_id", "uuid", references_entity: "category")
      promote!(tenant_id, "question", "difficulty", "text")
      promote!(tenant_id, "exam_section", "sort_order", "bigint")

      promote!(tenant_id, "answer_option", "sort_order", "bigint")
      promote!(tenant_id, "question_tag", "question_id", "uuid", references_entity: "question")
      promote!(tenant_id, "question_tag", "tag_id", "uuid", references_entity: "tag")
      promote!(tenant_id, "exam_question_rule", "exam_id", "uuid", references_entity: "exam")
      promote!(tenant_id, "exam_question_rule", "sort_order", "bigint")

      promote!(tenant_id, "exam_question_rule_tag", "rule_id", "uuid",
        references_entity: "exam_question_rule"
      )

      promote!(tenant_id, "exam_manual_question", "sort_order", "bigint")

      # ---- 6a. REAL RECORDS: a category, and a question referencing it ---
      category =
        create_record!(schema, "category", %{
          "name" => %{
            "kk" => "Qauipsizdik sanasy",
            "ru" => "Osoznannaya bezopasnost",
            "en" => "Security Awareness"
          },
          "track" => "security",
          "sort_order" => 1
        })

      assert {:ok, read_category} = Latest.get(category.record_id, "category", schema)
      assert read_category.field_values["track"] == "security"
      assert read_category.field_values["sort_order"] == 1
      assert read_category.field_values["name"]["en"] == "Security Awareness"

      # ---- 6b. :localized_text with all three locales (ISS-0617's path) --
      stem = %{
        "kk" => "Kupiya sozdi kimmen bolisuge bolady?",
        "ru" => "S kem mozhno delitsya parolem?",
        "en" => "With whom may you share your password?"
      }

      question =
        create_record!(schema, "question", %{
          "category_id" => category.record_id,
          "difficulty" => "easy",
          "type" => "single",
          "default_locale" => "en",
          "status" => "active",
          "version" => 1,
          "stem" => stem
        })

      assert {:ok, read_question} = Latest.get(question.record_id, "question", schema)
      assert read_question.field_values["stem"] == stem
      assert read_question.field_values["stem"]["kk"] == stem["kk"]
      assert read_question.field_values["stem"]["ru"] == stem["ru"]
      assert read_question.field_values["stem"]["en"] == stem["en"]
      assert read_question.field_values["category_id"] == category.record_id

      # ---- 6c. THE FK CONSTRAINT ACTUALLY BITES --------------------------
      # A question naming a category that does not exist. The promoted
      # category_id column carries a real Postgres REFERENCES (REQ-298), so the
      # dual-write is rejected rather than succeeding.
      orphan_category_id = Ecto.UUID.generate()

      fk_error =
        try do
          Records.create_record(
            %{
              entity_type: "question",
              field_values: %{
                "category_id" => orphan_category_id,
                "difficulty" => "hard",
                "type" => "single",
                "default_locale" => "en",
                "status" => "draft",
                "version" => 1,
                "stem" => %{"kk" => "x", "ru" => "x", "en" => "orphan"}
              },
              actor_id: actor_id,
              idempotency_key: Ecto.UUID.generate()
            },
            schema
          )
        rescue
          exception -> {:raised, exception}
        end

      IO.puts("\n=== REQ-328 FK-violation result (verbatim) ===")
      IO.puts(inspect(fk_error, pretty: true, limit: :infinity, printable_limit: :infinity))
      IO.puts("=== end FK-violation result ===\n")

      assert fk_violation?(fk_error),
             "expected a Postgres foreign_key_violation for a nonexistent category_id, got: " <>
               inspect(fk_error)

      # ---- 6d. tag + question_tag join rows ------------------------------
      tag = create_record!(schema, "tag", %{"name" => "passwords"})
      other_tag = create_record!(schema, "tag", %{"name" => "unrelated"})

      other_question =
        create_record!(schema, "question", %{
          "category_id" => category.record_id,
          "difficulty" => "medium",
          "type" => "truefalse",
          "default_locale" => "en",
          "status" => "active",
          "version" => 1,
          "stem" => %{"kk" => "b", "ru" => "b", "en" => "an unrelated question"}
        })

      _link =
        create_record!(schema, "question_tag", %{
          "question_id" => question.record_id,
          "tag_id" => tag.record_id
        })

      _other_link =
        create_record!(schema, "question_tag", %{
          "question_id" => other_question.record_id,
          "tag_id" => other_tag.record_id
        })

      assert {:ok, read_tag} = Latest.get(tag.record_id, "tag", schema)
      assert read_tag.field_values["name"] == "passwords"

      # ---- 6e. REQ-300's `through` many-to-many join ---------------------
      request = %{
        entity_type: "question",
        filters: [%{field: "difficulty", op: :eq, value: "easy"}],
        join: [%{entity_type: "tag", through: "question_tag", fk: "fk_question_tag_tag_id"}]
      }

      assert {:ok, query} = Compiler.compile(request, schema)
      rows = Repo.all(query, prefix: schema)

      IO.puts("\n=== REQ-328 through-join request + rows (verbatim) ===")
      IO.puts("request: " <> inspect(request, pretty: true))
      IO.puts("rows: " <> inspect(rows, pretty: true, limit: :infinity, printable_limit: 400))
      IO.puts("=== end through-join ===\n")

      assert [row] = rows
      assert row.primary.field_values["stem"]["en"] == stem["en"]
      assert Ecto.UUID.load!(row["tag"].record_id) == tag.record_id
      assert row["tag"].field_values["name"] == "passwords"

      # ---- 7. REQ-327's half: an exam, and a rule referencing it ---------
      exam =
        create_record!(schema, "exam", %{
          "title" => %{
            "kk" => "Qauipsizdik emtihany",
            "ru" => "Ekzamen po bezopasnosti",
            "en" => "Security Awareness Exam"
          },
          "status" => "draft",
          "time_limit_minutes" => 30,
          "passing_score_pct" => "70.00",
          "max_attempts" => 2,
          "shuffle_questions" => true,
          "shuffle_options" => true,
          "show_answers" => "after_completion",
          "on_tab_switch" => "warn",
          "certificate_enabled" => true
        })

      assert {:ok, read_exam} = Latest.get(exam.record_id, "exam", schema)
      assert read_exam.field_values["title"]["en"] == "Security Awareness Exam"
      assert read_exam.field_values["status"] == "draft"
      assert read_exam.field_values["time_limit_minutes"] == 30
      assert read_exam.field_values["max_attempts"] == 2

      rule =
        create_record!(schema, "exam_question_rule", %{
          "exam_id" => exam.record_id,
          "mode" => "random",
          "category_id" => category.record_id,
          "difficulty" => "easy",
          "count" => 5,
          "sort_order" => 0
        })

      assert {:ok, read_rule} = Latest.get(rule.record_id, "exam_question_rule", schema)
      assert read_rule.field_values["exam_id"] == exam.record_id
      assert read_rule.field_values["mode"] == "random"
      assert read_rule.field_values["count"] == 5
    end
  end

  defp fk_violation?({:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}}),
    do: true

  defp fk_violation?({:raised, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}}),
    do: true

  defp fk_violation?({:error, {_step, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}}}),
    do: true

  defp fk_violation?(_other), do: false
end
