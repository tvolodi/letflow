defmodule Letflow.Definitions.SchemasTest do
  @moduledoc """
  Pure, no-I/O tests for REQ-027's two `Ecto.Schema` modules under
  `lib/letflow/definitions/` -- `Letflow.Definitions.ProcessDefinition` and
  `Letflow.Definitions.InstanceDefinitionSnapshot`. See `test/specs/REQ-027.md` for the
  full test-case rationale, the WF-02 Step 3 scope-test verdict, and why the moduledoc
  assertions in this file are the *weaker* half of a pair wherever a structural fact
  exists to assert instead.

  `async: true` is safe here: this module performs no database I/O at all (it reads only
  compiled module metadata via `__info__/1`, `__schema__/1`, `Ecto.Enum` reflection and
  `Code.fetch_docs/1`) and attaches no global `:telemetry` handler -- deliberately not
  repeating the `async: true` + global-handler mistake `docs/issues/ISS-0011.yaml`
  records. It therefore does not use `Letflow.DataCase`; there is no connection to check
  out. The database-touching half of REQ-027's coverage lives in
  `test/letflow/definitions/migrations_test.exs`, which is `async: false`.

  Moduledoc assertions read the compiled `Docs` chunk through `Code.fetch_docs/1` rather
  than reading the `.ex` file as a string, so they assert on what the module actually
  publishes (a matching sentence in an ordinary `#` comment elsewhere in the file would
  not satisfy them). Whitespace is normalised before matching so re-wrapping a paragraph
  is not a failure while deleting or weakening a claim is.

  This file mirrors `test/letflow/event_store/schemas_test.exs`'s established shape for
  REQ-023 rather than inventing a parallel style.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Definitions.ProcessDefinition

  # ---------------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------------

  # A schema module's own public API, with the functions `use Ecto.Schema` generates
  # (__schema__/1,2, __struct__/0,1, __changeset__/0) filtered out. Every one of those is
  # `__`-prefixed, so the filter is exact rather than a hand-maintained deny-list.
  defp own_public_api(module) do
    module.__info__(:functions)
    |> Enum.reject(fn {name, _arity} ->
      name |> Atom.to_string() |> String.starts_with?("__")
    end)
    |> Enum.sort()
  end

  # The module's published moduledoc with runs of whitespace collapsed to single spaces,
  # so an assertion on a sentence that happens to be line-wrapped in the source still
  # matches. Deliberately pattern-matches the "documented" shape: a module whose
  # moduledoc was deleted (`:none`) or hidden (`:hidden`) raises here, which is the
  # correct outcome for acceptance criteria 4 and 5.
  defp normalized_moduledoc(module) do
    {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
      Code.fetch_docs(module)

    String.replace(moduledoc, ~r/\s+/, " ")
  end

  # Minimal local helper mirroring the one already in
  # test/letflow/event_store/schemas_test.exs and test/letflow/identity_test.exs.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # Uniqueness comes from System.unique_integer([:positive, :monotonic]) -- a VM counter,
  # never an RNG and never a clock.
  defp valid_definition_attrs do
    %{
      tenant_id: Ecto.UUID.generate(),
      name: "req027-def-#{System.unique_integer([:positive, :monotonic])}",
      version: "1.0.0",
      graph: %{"nodes" => [], "edges" => []},
      created_by: Ecto.UUID.generate()
    }
  end

  defp valid_snapshot_attrs do
    %{
      instance_id: Ecto.UUID.generate(),
      definition_id: Ecto.UUID.generate(),
      definition_name: "req027-snap-#{System.unique_integer([:positive, :monotonic])}",
      definition_ver: "1.0.0",
      graph: %{"nodes" => [], "edges" => []}
    }
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 5: "both Ecto.Schema modules' @moduledoc cite R-Co
  # src/design/definition.md (PD-01/PD-07/PD-08 sections) as the ported source"
  # ---------------------------------------------------------------------------------

  describe "acceptance criterion 5 -- ported-source citations" do
    test "both definition schema modules' moduledocs cite R-Co's src/design/definition.md and its PD-01, PD-07 and PD-08 sections" do
      for module <- [ProcessDefinition, InstanceDefinitionSnapshot] do
        doc = normalized_moduledoc(module)

        assert doc =~ "src/design/definition.md",
               "#{inspect(module)}'s moduledoc does not cite R-Co's src/design/definition.md"

        for section <- ["PD-01", "PD-07", "PD-08"] do
          assert doc =~ section,
                 "#{inspect(module)}'s moduledoc does not cite the #{section} section"
        end

        # The criterion says "as the ported source", not merely "mentions somewhere".
        assert doc =~ "Ported from R-Co's `src/design/definition.md`",
               "#{inspect(module)}'s moduledoc mentions definition.md but does not name it as the PORTED SOURCE"
      end
    end

    test "both moduledocs carry REQ-027's mandated 'schema only' scope note" do
      # requirements.yaml states this in its own words: "Note explicitly in both
      # moduledocs: this requirement builds schema only." The nearest structural guard is
      # migrations_test.exs's column-set equality, which fails if REQ-030/REQ-033-owned
      # columns ever leak into these migrations and quietly falsify the claim below.
      for module <- [ProcessDefinition, InstanceDefinitionSnapshot] do
        doc = normalized_moduledoc(module)

        assert doc =~ "This requirement (REQ-027) builds schema only.",
               "#{inspect(module)}'s moduledoc drops REQ-027's mandated schema-only scope note"

        assert doc =~ "REQ-033",
               "#{inspect(module)}'s moduledoc does not name REQ-033 as the owner of the snapshot create/retrieve functions"
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 4 (moduledoc half): "instance_definition_snapshots.definition_id
  # references process_definitions.id with no ON DELETE CASCADE, and the moduledoc states
  # this is deliberate per PD-08"
  #
  # The database half -- pg_constraint.confdeltype read from the live catalog, plus the
  # behavioural delete-rejection test -- is in migrations_test.exs. Both halves exist
  # because prose and catalog can drift apart, and only one of them is load-bearing.
  # ---------------------------------------------------------------------------------

  describe "acceptance criterion 4 -- the snapshot FK's deliberate absence of ON DELETE CASCADE" do
    test "InstanceDefinitionSnapshot's moduledoc states the missing ON DELETE CASCADE is deliberate per PD-08" do
      doc = normalized_moduledoc(InstanceDefinitionSnapshot)

      assert doc =~
               "`definition_id` references `process_definitions.id` with NO ON DELETE CASCADE"

      assert doc =~ "This is deliberate, per PD-08's \"FK without `ON DELETE CASCADE`\" paragraph"

      assert doc =~
               "Deletion of the source definition does NOT automatically remove snapshot rows"

      # PD-08's own edge case, and the reason the absence is not an oversight.
      assert doc =~
               "Definition hard-deleted (DRAFT) after instances were started from it: instances retain their snapshot and continue normally"

      # Step 2d carry-forward (e) / ISS-0024: the moduledoc must keep saying that adding
      # a cascade here is a defect, so the next agent to read REQ-033's criterion wording
      # is not invited to "fix" it.
      assert doc =~
               "Adding `on_delete: :delete_all` here would destroy exactly the data this table exists to preserve"
    end

    test "InstanceDefinitionSnapshot.create_changeset/2 declares the FK constraint by Ecto's real default name" do
      # Pins the constraint NAME the changeset is wired to. If the declared name and the
      # real constraint name ever drift apart, a dangling definition_id raises
      # Ecto.ConstraintError instead of returning {:error, changeset} --
      # migrations_test.exs asserts that end-to-end against real Postgres, this fails in
      # milliseconds with a precise message.
      changeset =
        InstanceDefinitionSnapshot.create_changeset(
          %InstanceDefinitionSnapshot{},
          valid_snapshot_attrs()
        )

      assert changeset.valid?

      assert Enum.any?(changeset.constraints, fn constraint ->
               constraint.type == :foreign_key and
                 constraint.constraint == "instance_definition_snapshots_definition_id_fkey" and
                 constraint.field == :definition_id
             end),
             "expected a :foreign_key constraint named instance_definition_snapshots_definition_id_fkey on :definition_id, got #{inspect(changeset.constraints)}"
    end

    test "InstanceDefinitionSnapshot's own public API is exactly create_changeset/2 -- write-once, no update or delete path (design INV-DEF-6)" do
      assert own_public_api(InstanceDefinitionSnapshot) == [create_changeset: 2]

      # Stated explicitly as well as implied by the equality above, so a failure reads
      # against PD-08's own wording ("Snapshots read-only after creation").
      refute Keyword.has_key?(InstanceDefinitionSnapshot.__info__(:functions), :update_changeset)
      refute Keyword.has_key?(InstanceDefinitionSnapshot.__info__(:functions), :changeset)
    end

    test "ProcessDefinition deliberately DOES expose update_changeset/2 -- the contrast that proves the assertion above discriminates" do
      # Without this negative control, the assertion above would pass just as happily
      # against a directory where nobody writes update changesets at all.
      assert own_public_api(ProcessDefinition) == [create_changeset: 2, update_changeset: 2]
    end

    test "there is no belongs_to association across the snapshot -> definition edge (design INV-DEF-6)" do
      # A real DB foreign key exists, but an Ecto association would invite
      # Repo.preload/2 across an edge PD-08 exists to break: a snapshot is meaningful
      # WITHOUT its source definition, which is the entire point of copying the graph.
      assert InstanceDefinitionSnapshot.__schema__(:associations) == []
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 2 (schema-module half): "process_definitions has a unique index
  # on (name, version) and a partial unique index on name WHERE status = 'active'"
  #
  # The real indexes, their predicates and their behaviour are asserted in
  # migrations_test.exs. These pin the names the changesets map a 23505 by: if the
  # declared name and the real index name drift apart, a duplicate insert raises
  # Ecto.ConstraintError instead of returning {:error, changeset}, breaking the error
  # contract REQ-030 depends on.
  # ---------------------------------------------------------------------------------

  describe "acceptance criterion 2 -- both unique constraints are declared by index name" do
    test "create_changeset/2 and update_changeset/2 both declare uq_definition_version and uq_active_definition by index name" do
      changesets = [
        {:create_changeset,
         ProcessDefinition.create_changeset(%ProcessDefinition{}, valid_definition_attrs())},
        {:update_changeset,
         ProcessDefinition.update_changeset(%ProcessDefinition{}, valid_definition_attrs())}
      ]

      for {label, changeset} <- changesets do
        assert changeset.valid?,
               "#{label} rejected a well-formed definition: #{inspect(errors_on(changeset))}"

        assert Enum.any?(changeset.constraints, fn constraint ->
                 constraint.type == :unique and
                   constraint.constraint == "uq_definition_version"
               end),
               "#{label} does not declare uq_definition_version, got #{inspect(changeset.constraints)}"

        assert Enum.any?(changeset.constraints, fn constraint ->
                 constraint.type == :unique and
                   constraint.constraint == "uq_active_definition" and
                   constraint.field == :name
               end),
               "#{label} does not declare uq_active_definition on :name, got #{inspect(changeset.constraints)}"
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # Carry-forward (a.2), pure half (Step 1b/2c): `status` is stored LOWERCASE, and that is
  # load-bearing. uq_active_definition's predicate is `WHERE status = 'active'`. If the
  # Ecto.Enum ever dumped a different case -- e.g. R-Co's own uppercase ACTIVE, which the
  # sibling Letflow.EventStore.InstanceProjection really does use -- the index would match
  # ZERO rows, PD-03's single-active-per-name invariant would be silently unenforced, and
  # nothing anywhere would raise. migrations_test.exs asserts the other side of this pair
  # against the live catalog and against real inserts.
  # ---------------------------------------------------------------------------------

  describe "carry-forward (a.2) -- status dumps lowercase (design INV-DEF-3)" do
    test "ProcessDefinition's status enum dumps the exact lowercase literals uq_active_definition's predicate is written against" do
      assert Ecto.Enum.values(ProcessDefinition, :status) == [
               :draft,
               :active,
               :deprecated,
               :archived
             ]

      assert Ecto.Enum.dump_values(ProcessDefinition, :status) == [
               "draft",
               "active",
               "deprecated",
               "archived"
             ]

      # Stated as its own assertion so a failure reads against the invariant rather than
      # against a list literal: every dumped value must be its own downcase.
      for dumped <- Ecto.Enum.dump_values(ProcessDefinition, :status) do
        assert dumped == String.downcase(dumped),
               "status dumps #{inspect(dumped)}, which is not lowercase -- uq_active_definition's WHERE status = 'active' predicate would stop matching rows"
      end
    end

    test "a freshly built ProcessDefinition struct carries the :draft default, the only way a row acquires an initial status (design INV-DEF-8)" do
      assert %ProcessDefinition{}.status == :draft
    end

    test "neither changeset casts :status -- status movement is a guarded UPDATE, never a changeset (design INV-DEF-8)" do
      # PD-04's transitions are guarded single-statement UPDATEs
      # (... WHERE id = $1 AND status = '<expected>'); that WHERE clause IS the
      # concurrency control, and a changeset-mediated read-modify-write would reintroduce
      # the lost-update race it exists to prevent. REQ-030 owns the transition table.
      for {label, changeset} <- [
            {:create_changeset,
             ProcessDefinition.create_changeset(
               %ProcessDefinition{},
               Map.put(valid_definition_attrs(), :status, :active)
             )},
            {:update_changeset,
             ProcessDefinition.update_changeset(
               %ProcessDefinition{},
               Map.put(valid_definition_attrs(), :status, :active)
             )}
          ] do
        assert changeset.valid?

        refute Map.has_key?(changeset.changes, :status),
               "#{label} cast :status, which INV-DEF-8 forbids"
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # Carry-forward (b), pure half (Step 2d): the `graph` default is written twice as
  # independent literals -- once in the migration (~line 82) and once in the schema module
  # (~line 98) -- with nothing keeping them in sync. This pins the schema-module side;
  # migrations_test.exs reads the DATABASE default back out of a real row and asserts the
  # two agree.
  # ---------------------------------------------------------------------------------

  describe "carry-forward (b) -- the graph default literal (schema-module side)" do
    test "a freshly built ProcessDefinition struct's graph default is definition.md's DefinitionGraph shape" do
      assert %ProcessDefinition{}.graph == %{"nodes" => [], "edges" => []}
    end

    test "InstanceDefinitionSnapshot's graph has NO default -- a snapshot is always a copy of a real definition's graph" do
      # An empty-graph default here would mask a capture bug in REQ-033: the snapshot
      # would look successfully written while carrying nothing.
      assert %InstanceDefinitionSnapshot{}.graph == nil
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 3 (schema-module half): "process_definitions has a nullable stage
  # column and a partial index on stage WHERE stage IS NOT NULL, per definition.md's PD-07
  # section"
  #
  # The physical nullability and the index itself are asserted in migrations_test.exs.
  # ---------------------------------------------------------------------------------

  describe "acceptance criterion 3 -- stage is open-ended free text (design INV-DEF-4)" do
    test "stage is castable, optional on both changesets, and validated only for length -- no enum, per PD-07" do
      # PD-07: "no enum validation is applied (stage labels are open-ended text)". Fed
      # through the real changeset rather than read off the source, so a validate_inclusion
      # added later fails here.
      arbitrary_label = "stage-#{System.unique_integer([:positive, :monotonic])}"

      with_stage =
        ProcessDefinition.create_changeset(
          %ProcessDefinition{},
          Map.put(valid_definition_attrs(), :stage, arbitrary_label)
        )

      assert with_stage.valid?,
             "an arbitrary free-text stage label was rejected: #{inspect(errors_on(with_stage))}"

      assert with_stage.changes.stage == arbitrary_label

      # ...and omitting it entirely is equally valid, which is what makes the column's
      # NULLs -- and therefore idx_def_stage's WHERE stage IS NOT NULL predicate --
      # reachable at all.
      without_stage =
        ProcessDefinition.create_changeset(%ProcessDefinition{}, valid_definition_attrs())

      assert without_stage.valid?
      refute Map.has_key?(without_stage.changes, :stage)
      assert %ProcessDefinition{}.stage == nil

      # The one bound PD-07 does impose.
      too_long =
        ProcessDefinition.create_changeset(
          %ProcessDefinition{},
          Map.put(valid_definition_attrs(), :stage, String.duplicate("s", 256))
        )

      refute too_long.valid?
      assert %{stage: [_ | _]} = errors_on(too_long)
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 1 (schema-module half): the tables live in MANY Postgres schemas,
  # one per tenant, so a compile-time prefix would defeat the whole :prefix mechanism --
  # and would do so silently, since every call that passes `prefix:` explicitly would
  # still appear to work.
  # ---------------------------------------------------------------------------------

  describe "acceptance criterion 1 -- module-to-table mapping and per-tenant prefixing" do
    test "each definition schema module points at its designed table name (design section 5.1)" do
      assert ProcessDefinition.__schema__(:source) == "process_definitions"
      assert InstanceDefinitionSnapshot.__schema__(:source) == "instance_definition_snapshots"
    end

    test "neither definition schema module pins a compile-time @schema_prefix (design INV-DEF-7)" do
      for module <- [ProcessDefinition, InstanceDefinitionSnapshot] do
        assert module.__schema__(:prefix) == nil,
               "#{inspect(module)} pins @schema_prefix #{inspect(module.__schema__(:prefix))}, which INV-DEF-7 forbids"
      end
    end

    test "primary keys are as designed: a generated binary_id on definitions, a caller-supplied instance_id on snapshots" do
      assert ProcessDefinition.__schema__(:primary_key) == [:id]
      assert InstanceDefinitionSnapshot.__schema__(:primary_key) == [:instance_id]

      # The instance id is minted by S3's engine and supplied by the caller, never by
      # this row -- an autogenerate here would mint a second, different id and orphan the
      # snapshot from the instance it describes.
      assert InstanceDefinitionSnapshot.__schema__(:autogenerate_id) == nil

      # snapshotted_at is assigned by the column's DB default and read back, mirroring
      # R-Co's INSERT ... RETURNING (definition.md:1995-2006).
      assert InstanceDefinitionSnapshot.__schema__(:read_after_writes) == [:snapshotted_at]
    end
  end

  # ---------------------------------------------------------------------------------
  # Supporting coverage: the changeset validations design section 5.1 specifies. Not
  # acceptance criteria in their own right, but a silent drift in either is caught here
  # rather than at REQ-030's or REQ-033's first integration test.
  # ---------------------------------------------------------------------------------

  describe "changeset validations (pure, no I/O)" do
    test "ProcessDefinition.create_changeset/2 requires every field a create must supply" do
      changeset = ProcessDefinition.create_changeset(%ProcessDefinition{}, %{})

      refute changeset.valid?

      errors = errors_on(changeset)

      for field <- [:tenant_id, :name, :version, :created_by] do
        assert Map.has_key?(errors, field),
               "expected #{field} to be required, errors: #{inspect(errors)}"
      end
    end

    test "ProcessDefinition.create_changeset/2 rejects an empty name and an over-long name" do
      empty =
        ProcessDefinition.create_changeset(
          %ProcessDefinition{},
          %{valid_definition_attrs() | name: ""}
        )

      refute empty.valid?
      assert %{name: [_ | _]} = errors_on(empty)

      too_long =
        ProcessDefinition.create_changeset(
          %ProcessDefinition{},
          %{valid_definition_attrs() | name: String.duplicate("n", 256)}
        )

      refute too_long.valid?
      assert %{name: [_ | _]} = errors_on(too_long)
    end

    test "ProcessDefinition.update_changeset/2 structurally cannot re-point a definition at another tenant or creator" do
      definition = %ProcessDefinition{
        id: Ecto.UUID.generate(),
        tenant_id: Ecto.UUID.generate(),
        created_by: Ecto.UUID.generate()
      }

      changeset =
        ProcessDefinition.update_changeset(definition, %{
          tenant_id: Ecto.UUID.generate(),
          created_by: Ecto.UUID.generate(),
          name: "renamed-#{System.unique_integer([:positive, :monotonic])}",
          version: "2.0.0",
          graph: %{"nodes" => [], "edges" => []}
        })

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :tenant_id)
      refute Map.has_key?(changeset.changes, :created_by)
      assert changeset.changes.version == "2.0.0"
    end

    test "InstanceDefinitionSnapshot.create_changeset/2 requires all five captured fields" do
      changeset = InstanceDefinitionSnapshot.create_changeset(%InstanceDefinitionSnapshot{}, %{})

      refute changeset.valid?

      errors = errors_on(changeset)

      for field <- [:instance_id, :definition_id, :definition_name, :definition_ver, :graph] do
        assert Map.has_key?(errors, field),
               "expected #{field} to be required, errors: #{inspect(errors)}"
      end
    end

    test "InstanceDefinitionSnapshot.create_changeset/2 declares the primary-key unique constraint by name" do
      # What lets REQ-033 return its SnapshotAlreadyExists-equivalent instead of raising.
      changeset =
        InstanceDefinitionSnapshot.create_changeset(
          %InstanceDefinitionSnapshot{},
          valid_snapshot_attrs()
        )

      assert Enum.any?(changeset.constraints, fn constraint ->
               constraint.type == :unique and
                 constraint.constraint == "instance_definition_snapshots_pkey" and
                 constraint.field == :instance_id
             end),
             "expected a :unique constraint named instance_definition_snapshots_pkey on :instance_id, got #{inspect(changeset.constraints)}"
    end
  end
end
