defmodule Letflow.Simulation.RunnerTemplateAndOutcomesTest do
  @moduledoc """
  REQ-205 (`lib/letflow/design/req205-simulation-harness-foundation.md` §5, §6).

  `test/letflow/simulation/runner_test.exs` already covers the AC4/AC5 happy
  path (a real HTTP api-via step, `instance_state` verification, and a
  `via: :gui` step's `:deferred_to_s8` recording). This module closes the
  gaps TEST-DESIGNER identified on top of that coverage, none of which
  ELIXIR-DEV's smoke tests exercised:

  1. `{{produces.X}}` template substitution's **substring form** (not just
     the whole-string form `runner_test.exs` already exercises) resolves to
     a real, runtime-only value -- proven by reading it back from Postgres
     after the run, not by a hardcoded expectation (design §5).
  2. Template substitution **fails closed** on an unresolved reference --
     both the plain "no such produces key" case and the specific case this
     design calls out by name (§3.3 step 3): a later step referencing a
     `via: gui` step's (nonexistent) `produces` output. Neither silently
     substitutes `nil` nor the literal template string.
  3. The `task_assigned` and `audit_event` expected-outcome verification
     methods (design §6) each get a real-query test pair (a match that
     passes and a mismatch that fails) proving neither method is the
     forbidden "no error was raised" stand-in
     (`.claude/agents/uat-runner.md`'s explicit rule, which this design
     cites by path) -- a stub that always returned `:pass` would fail the
     mismatch case in each pair.

  Real Postgres (`Letflow.DataCase`), `async: false`, same reasoning as
  `runner_test.exs`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Audit.Entry, as: AuditEntry
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.Tenant
  alias Letflow.Instances
  alias Letflow.Repo
  alias Letflow.Simulation.Runner
  alias Letflow.Simulation.Scenario
  alias Letflow.Simulation.Seed
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @fixtures_dir Path.expand("../../fixtures/simulation/swiftroute", __DIR__)

  setup do
    Sandbox.mode(Letflow.Repo, :auto)

    unique = Letflow.TenantSlugFixture.unique_slug("req205-tmpl")

    company = %{
      "slug" => unique,
      "display_name" => "REQ-205 Template Test Co",
      "hostname" => unique <> ".simulation.test"
    }

    {:ok, %{tenant: tenant}} = Seed.seed_company(company)
    {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)

    {:ok, org_structure} =
      YamlElixir.read_from_file(Path.join(@fixtures_dir, "org_structure.yaml"))

    org_structure =
      update_in(org_structure["people"], fn people ->
        Enum.map(people, fn person -> Map.update!(person, "username", &(&1 <> "-" <> unique)) end)
      end)

    {:ok, [operator | _rest]} = Seed.seed_users(org_structure, tenant)

    {:ok, process_fixture} =
      YamlElixir.read_from_file(Path.join(@fixtures_dir, "process_route_approval.yaml"))

    process_fixture = Map.update!(process_fixture, "name", &(&1 <> "-" <> unique))

    {:ok, definition} = Seed.seed_process(process_fixture, tenant, operator.id)

    {:ok, %{token: _token, plaintext: plaintext}} =
      Identity.create_token(operator.id, %{roles: ["PLATFORM_ADMIN"]}, prefix: schema_name)

    on_exit(fn -> teardown(unique) end)

    %{
      tenant: tenant,
      schema_name: schema_name,
      definition: definition,
      operator: operator,
      actor: %{"token" => plaintext, "tenant_slug" => unique}
    }
  end

  defp teardown(slug) do
    case Identity.get_tenant_by_slug(slug) do
      {:ok, tenant} ->
        case TenantProvisioning.schema_name_for_tenant(tenant.id) do
          {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
          {:error, _reason} -> :ok
        end

        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
        Repo.delete_all(from(o in OnboardingRecord, where: o.tenant_id == ^tenant.id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))

      {:error, :not_found} ->
        :ok
    end
  end

  # ── §5: substring-form template substitution, verified against real state ──

  test "template substitution: substring form resolves a prior step's produced id into a later step's params, verified in Postgres afterward",
       %{schema_name: schema_name, definition: definition, actor: actor} do
    scenario = %Scenario{
      id: "req205-template-substring",
      company_id: "swiftroute",
      process_id: definition.name,
      actors: %{"operator" => actor},
      preconditions: [],
      steps: [
        %{
          via: :api,
          action: "POST /api/v1/instances",
          params: %{"definition_name" => definition.name, "initial_variables" => %{}},
          produces: "first",
          actor: "operator"
        },
        %{
          via: :api,
          action: "POST /api/v1/instances",
          params: %{
            "definition_name" => definition.name,
            "initial_variables" => %{
              "note" => "ref:{{produces.first.instance_id}}:end"
            }
          },
          produces: "second",
          actor: "operator"
        }
      ],
      expected_outcomes: [
        %{
          verification: %{
            method: :instance_state,
            args: %{
              "prefix" => schema_name,
              "instance_ref" => "{{produces.second.instance_id}}",
              "status" => "COMPLETED"
            }
          }
        }
      ]
    }

    assert {:ok, report} = Runner.run(scenario)

    assert [%{outcome: :ok, captured: first_captured}, %{outcome: :ok, captured: second_captured}] =
             report.step_results

    first_instance_id = first_captured["instance_id"]
    second_instance_id = second_captured["instance_id"]
    refute first_instance_id == second_instance_id

    # The proof this isn't vacuous: the expected substring value embeds a
    # value (first_instance_id) that only exists at runtime -- it cannot be
    # hardcoded -- and we read it back from real Postgres state, not from
    # the Runner's own in-memory report.
    assert {:ok, projection} = Instances.get_by_id(second_instance_id, prefix: schema_name)
    assert projection.variables["note"] == "ref:#{first_instance_id}:end"

    assert [%{outcome: :pass}] = report.outcome_results
  end

  # ── §5: fail-closed behavior ─────────────────────────────────────────────

  test "template substitution: an unresolved produces reference fails closed with :unresolved_template, not nil or the literal string",
       %{schema_name: schema_name, definition: definition, actor: actor} do
    scenario = %Scenario{
      id: "req205-template-unresolved",
      company_id: "swiftroute",
      process_id: definition.name,
      actors: %{"operator" => actor},
      preconditions: [
        %{check: :custom, args: %{"predicate" => "always_true", "prefix" => schema_name}}
      ],
      steps: [
        %{
          via: :api,
          action: "POST /api/v1/instances",
          params: %{
            "definition_name" => definition.name,
            "initial_variables" => %{"note" => "{{produces.nonexistent_step.some_field}}"}
          },
          actor: "operator"
        }
      ],
      expected_outcomes: []
    }

    assert {:ok, report} = Runner.run(scenario)

    assert [%{outcome: :error, detail: detail}] = report.step_results
    assert detail == {:unresolved_template, "produces.nonexistent_step.some_field"}
  end

  test "template substitution: a later step referencing a via:gui step's (nonexistent) produces output fails closed rather than silently passing through",
       %{schema_name: schema_name, definition: definition, actor: actor} do
    scenario = %Scenario{
      id: "req205-template-gui-deferred-reference",
      company_id: "swiftroute",
      process_id: definition.name,
      actors: %{"operator" => actor},
      preconditions: [
        %{check: :custom, args: %{"predicate" => "always_true", "prefix" => schema_name}}
      ],
      steps: [
        %{
          via: :gui,
          action: "fill out onboarding wizard",
          produces: "gui_output",
          actor: "operator"
        },
        %{
          via: :api,
          action: "POST /api/v1/instances",
          params: %{
            "definition_name" => definition.name,
            "initial_variables" => %{"note" => "{{produces.gui_output.wizard_id}}"}
          },
          actor: "operator"
        }
      ],
      expected_outcomes: []
    }

    assert {:ok, report} = Runner.run(scenario)

    assert [gui_result, api_result] = report.step_results
    assert gui_result.outcome == :deferred_to_s8
    assert gui_result.captured == nil

    # The critical assertion: the api step does NOT silently proceed with a
    # `nil` note, a literal `"{{produces.gui_output.wizard_id}}"` string, or
    # a 2xx success -- it fails closed, exactly per design §3.3 step 3.
    assert api_result.outcome == :error
    assert api_result.detail == {:unresolved_template, "produces.gui_output.wizard_id"}
  end

  # ── §6: task_assigned -- real query, match + mismatch pair ───────────────

  describe "task_assigned verification method" do
    setup %{tenant: tenant, schema_name: schema_name, operator: operator} do
      instance_id = Ecto.UUID.generate()

      %InstanceProjection{}
      |> InstanceProjection.insert_changeset(%{
        instance_id: instance_id,
        status: :active,
        definition_id: Ecto.UUID.generate()
      })
      |> Repo.insert!(prefix: schema_name)

      token =
        %TokenRecord{}
        |> TokenRecord.insert_changeset(%{
          instance_id: instance_id,
          node_id: "review",
          branch_id: "b1"
        })
        |> Repo.insert!(prefix: schema_name)

      task =
        %EngineTask{}
        |> EngineTask.insert_changeset(%{
          instance_id: instance_id,
          token_id: token.id,
          node_id: "review",
          node_name: "Review",
          assignee_type: "user",
          assignee_ref: operator.id
        })
        |> Repo.insert!(prefix: schema_name)

      %{task: task, tenant: tenant}
    end

    test "passes when the persisted assignee matches, by a real DB read", %{
      schema_name: schema_name,
      task: task,
      operator: operator
    } do
      scenario = %Scenario{
        id: "req205-task-assigned-match",
        company_id: "swiftroute",
        process_id: "n/a",
        preconditions: [],
        steps: [],
        expected_outcomes: [
          %{
            verification: %{
              method: :task_assigned,
              args: %{
                "prefix" => schema_name,
                "task_ref" => task.id,
                "expected_assignee_user_id" => operator.id
              }
            }
          }
        ]
      }

      assert {:ok, report} = Runner.run(scenario)
      assert [%{outcome: :pass, observed: observed}] = report.outcome_results
      assert observed.assignee_ref == operator.id
    end

    test "fails when the expected assignee does not match the real persisted row -- proving this is not a no-error stub",
         %{schema_name: schema_name, task: task} do
      wrong_user_id = Ecto.UUID.generate()

      scenario = %Scenario{
        id: "req205-task-assigned-mismatch",
        company_id: "swiftroute",
        process_id: "n/a",
        preconditions: [],
        steps: [],
        expected_outcomes: [
          %{
            verification: %{
              method: :task_assigned,
              args: %{
                "prefix" => schema_name,
                "task_ref" => task.id,
                "expected_assignee_user_id" => wrong_user_id
              }
            }
          }
        ]
      }

      assert {:ok, report} = Runner.run(scenario)
      assert [%{outcome: :fail, observed: observed}] = report.outcome_results
      refute observed.assignee_ref == wrong_user_id
    end
  end

  # ── §6: audit_event -- real query, driven by a real HTTP-triggered event ──

  describe "audit_event verification method" do
    # NOTE (TEST-DESIGNER finding, reported in the handoff -- not fixed here,
    # not this role's remit): `verify_outcome/2`'s `:audit_event` clause reads
    # `args` raw (`_produces` is discarded, see runner.ex's function head) --
    # unlike `:task_assigned`/`:instance_state`, it never runs `args` through
    # `resolve_ref/3`'s `{{produces.X}}` template substitution. A scenario
    # cannot scope an audit_event check to "the resource this run just
    # created" via `"resource_id" => "{{produces.instance.instance_id}}"` --
    # that literal string is sent to the query verbatim and matches nothing.
    # These tests therefore verify scoped only by `resource_type`/`event_type`
    # (real filters that *do* work) rather than by the produced resource_id,
    # which is the only way to get a genuine, non-vacuous pass/fail pair out
    # of this method as currently implemented.
    test "passes for the real instance.create audit row a genuine HTTP-dispatched instance-start produces",
         %{schema_name: schema_name, definition: definition, actor: actor} do
      scenario = %Scenario{
        id: "req205-audit-event-match",
        company_id: "swiftroute",
        process_id: definition.name,
        actors: %{"operator" => actor},
        preconditions: [],
        steps: [
          %{
            via: :api,
            action: "POST /api/v1/instances",
            params: %{"definition_name" => definition.name, "initial_variables" => %{}},
            produces: "instance",
            actor: "operator"
          }
        ],
        expected_outcomes: [
          %{
            verification: %{
              method: :audit_event,
              args: %{
                "prefix" => schema_name,
                "resource_type" => "instance",
                "event_type" => "instance.create"
              }
            }
          }
        ]
      }

      assert {:ok, report} = Runner.run(scenario)
      assert [%{outcome: :ok}] = report.step_results
      assert [%{outcome: :pass, observed: %{matching_entry: entry}}] = report.outcome_results
      assert %AuditEntry{action: "instance.create"} = entry
    end

    test "fails when the expected event_type has no matching real row -- proving this is not a no-error stub",
         %{schema_name: schema_name, definition: definition, actor: actor} do
      scenario = %Scenario{
        id: "req205-audit-event-mismatch",
        company_id: "swiftroute",
        process_id: definition.name,
        actors: %{"operator" => actor},
        preconditions: [],
        steps: [
          %{
            via: :api,
            action: "POST /api/v1/instances",
            params: %{"definition_name" => definition.name, "initial_variables" => %{}},
            produces: "instance",
            actor: "operator"
          }
        ],
        expected_outcomes: [
          %{
            verification: %{
              method: :audit_event,
              args: %{
                "prefix" => schema_name,
                "resource_type" => "instance",
                "event_type" => "instance.this_event_type_never_happened"
              }
            }
          }
        ]
      }

      assert {:ok, report} = Runner.run(scenario)
      assert [%{outcome: :ok}] = report.step_results
      assert [%{outcome: :fail, observed: %{matching_entry: nil}}] = report.outcome_results
    end
  end
end
