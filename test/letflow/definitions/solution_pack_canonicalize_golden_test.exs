defmodule Letflow.Definitions.SolutionPackCanonicalizeGoldenTest do
  @moduledoc """
  REQ-381 design §2.1 — cross-language golden-fixture cross-check, Elixir half.

  `web/src/lib/canonicalizeArtefactContent.ts` is a hand-written TypeScript
  port of this module's own private `canonicalize_artefact_content/1` /
  `canonicalize_json/1` (`lib/letflow/definitions/solution_pack.ex:1542-1565`).
  A port that has never been checked against the real algorithm is itself a
  risk (design §2.1's closing paragraph) — this test and its TypeScript
  sibling (`web/src/lib/__tests__/canonicalizeArtefactContent.test.ts`) are
  what retires it: both load the SAME checked-in fixture file
  (`test/fixtures/canonical_json/golden_cases.json`, `{name, input, expected}`
  per case) and assert their own language's canonicalizer reproduces
  `expected` for every case.

  This file proves the fixture's `expected` field is not a hand-typed guess:
  each generated test round-trips its case's `input` through the real, only
  public seam that reaches the private function under test —
  `Letflow.Definitions.SolutionPack.capture_artefact_bases/5` — the same way
  the fixture file's `expected` values were originally generated (a one-off
  `mix letflow.gen_canonical_golden` run, not itself checked in — this file's
  own assertions are the durable, re-runnable proof instead). A future
  change to `canonicalize_json/1` that silently changes its output fails
  this test before it could silently break the TypeScript port's own
  cross-check against the same (now-stale) fixture.

  Uses `Letflow.DataCase` (real Postgres) and `Letflow.TenantFixture`, same
  convention as `test/letflow/routers/solution_packs_update_test.exs` --
  `solution_pack_artefact_bases` is a GLOBAL table (REQ-041), so no tenant
  schema provisioning is exercised, only the FK-satisfying tenant row.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.SolutionPack
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @golden_path Path.join([File.cwd!(), "test/fixtures/canonical_json/golden_cases.json"])
  @golden_cases @golden_path |> File.read!() |> Jason.decode!()

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "canonical-golden-check")

    on_exit(fn ->
      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )
    end)

    %{tenant_id: tenant.tenant_id}
  end

  test "the checked-in golden fixture file is non-empty" do
    assert length(@golden_cases) > 0
  end

  for golden_case <- @golden_cases do
    name = Map.fetch!(golden_case, "name")
    input = Map.fetch!(golden_case, "input")
    expected = Map.fetch!(golden_case, "expected")

    test "#{name}: canonicalize_artefact_content/1 reproduces the checked-in expected value",
         %{tenant_id: tenant_id} do
      artefact_id = Ecto.UUID.generate()

      {:ok, [base]} =
        SolutionPack.capture_artefact_bases(
          tenant_id,
          "golden-check-#{unquote(name)}",
          "1.0.0",
          [
            %{
              artefact_type: "process_definition",
              artefact_id: artefact_id,
              content: unquote(Macro.escape(input))
            }
          ],
          DateTime.truncate(DateTime.utc_now(), :microsecond)
        )

      assert base.base_content == unquote(expected)
    end
  end
end
