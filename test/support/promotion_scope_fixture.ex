defmodule Letflow.Support.PromotionScopeFixture do
  @moduledoc """
  Test-only helpers shared by the REQ-446 test files
  (`req446_cross_tenant_denial_test.exs`, `promotion_platform_events_shaping_test.exs`,
  `promotion_context_shaping_test.exs`; design OQ-4: lifted here rather than copied three times).

  Lifted from `promotion_scope_test.exs` / `routers/promotions_test.exs` (those files keep their
  own private copies, unchanged). All helpers write into a named provisioned tenant fixture's
  schema; none touches application config (the platform pin stays in
  `Letflow.Support.PlatformTenantFixture`). Test-only; never referenced from `lib/`.
  """

  import ExUnit.Assertions

  alias Letflow.Definitions
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.PromotionAssertionRun
  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Definitions.PromotionReviewStore
  alias Letflow.EventStore
  alias Letflow.EventStore.Registry
  alias Letflow.Repo

  @type fixture :: Letflow.TenantFixture.tenant_fixture()

  @doc "A process key unique across the run."
  @spec unique_key(String.t()) :: String.t()
  def unique_key(prefix \\ "req446-key"),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  @doc "The bytes a caller can observe: status, body, and every header but the request id."
  @spec observable(Plug.Conn.t()) :: {integer(), binary(), [{binary(), binary()}]}
  def observable(resp) do
    {resp.status, resp.resp_body,
     Enum.reject(resp.resp_headers, &(elem(&1, 0) == "x-request-id"))}
  end

  @doc "A valid two-node graph."
  @spec valid_graph() :: map()
  def valid_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  @doc "Inserts `name` at `version` and flips it to active (raw; one active version per name)."
  @spec insert_active_definition!(fixture(), String.t(), String.t()) :: ProcessDefinition.t()
  def insert_active_definition!(fixture, name, version) do
    definition =
      %ProcessDefinition{}
      |> ProcessDefinition.create_changeset(%{
        name: name,
        version: version,
        graph: valid_graph(),
        created_by: Ecto.UUID.generate()
      })
      |> Repo.insert!(prefix: fixture.schema_name)

    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               ~s(UPDATE "#{fixture.schema_name}"."process_definitions" SET status = 'active' ) <>
                 "WHERE id = $1 AND status = 'draft'",
               [Ecto.UUID.dump!(definition.id)]
             )

    definition
  end

  @doc """
  Creates and activates `name` at 1.0.0 and then 2.0.0 through `Definitions.create/2` and
  `Definitions.activate/2` (the raw insert would break the single-active index).
  """
  @spec two_version_history!(fixture(), String.t()) :: :ok
  def two_version_history!(fixture, name) do
    for version <- ["1.0.0", "2.0.0"] do
      assert {:ok, created} =
               Definitions.create(
                 %{
                   name: name,
                   version: version,
                   graph: valid_graph(),
                   created_by: Ecto.UUID.generate()
                 },
                 prefix: fixture.schema_name
               )

      assert {:ok, %{definition: _}} =
               Definitions.activate(created.id, prefix: fixture.schema_name)
    end

    :ok
  end

  @doc """
  Inserts one `pending_review` review into `fixture`'s schema through the real
  `PromotionReviewStore.insert_review/2`. The plan names `source_id` and `target_id` and carries
  one added graph-node entry; overrides are merged into the plan map before the digest is taken.
  Returns `%{review: review, plan: plan, digest: digest}`.
  """
  @spec seed_review!(fixture(), String.t(), String.t(), map()) :: map()
  def seed_review!(fixture, source_id, target_id, overrides \\ %{}) do
    plan =
      Map.merge(
        %{
          source_tenant_id: source_id,
          target_tenant_id: target_id,
          process_key: unique_key("req446-review"),
          source_definition_id: Ecto.UUID.generate(),
          target_definition_id: nil,
          base_version: nil,
          entries: [
            %{
              type: :graph_node,
              id: "n1-#{System.unique_integer([:positive, :monotonic])}",
              change_kind: :added,
              after: %{"id" => "n1", "node_type" => "START"},
              before: nil
            }
          ]
        },
        overrides
      )

    digest = PromotionDigest.compute_plan_digest(plan)

    assert {:ok, review} =
             PromotionReviewStore.insert_review(
               %{plan: plan, digest: digest, requested_by: Ecto.UUID.generate()},
               prefix: fixture.schema_name
             )

    %{review: review, plan: plan, digest: digest}
  end

  @doc "The run-assertions artifact object (keys id, assertions, fixtures, rng_seed, ...)."
  @spec artifact() :: map()
  def artifact do
    row =
      Jason.encode!(%{
        "id" => Ecto.UUID.generate(),
        "tenant_id" => Ecto.UUID.generate(),
        "name" => "req446-fixture",
        "version" => "1.0.0",
        "status" => "draft",
        "graph" => %{"nodes" => [], "edges" => []},
        "created_by" => Ecto.UUID.generate(),
        "created_at" => "2026-01-01T00:00:00.000000",
        "updated_at" => "2026-01-01T00:00:00.000000"
      })

    %{
      "id" => "req446-artifact",
      "assertions" => [%{"id" => "a1", "payload" => Jason.encode!(%{"result" => "expected"})}],
      "fixtures" => [%{"table_name" => "process_definitions", "row_json" => row}],
      "rng_seed" => 1_700_000_000 * 4_294_967_296 + 424_242,
      "non_deterministic_fields" => [],
      "candidate_definitions" => []
    }
  end

  @doc "Registers a fresh permissive (`{\"type\": \"object\"}`) event type for the tenant; returns its name."
  @spec register_event_type!(String.t()) :: String.t()
  def register_event_type!(tenant_id) do
    name = "REQ446_EVT_" <> to_string(System.unique_integer([:positive, :monotonic]))

    assert {:ok, _} =
             Registry.register_type(
               %{
                 "name" => name,
                 "schema_version" => 1,
                 "json_schema" => %{"type" => "object"},
                 "description" => "REQ-446 shaping test fixture"
               },
               tenant_id
             )

    name
  end

  @doc """
  Appends one sentinel-stream event of a freshly registered fixture type, with `payload` (a map
  with string keys), into `fixture`'s schema. Returns `{event_type, event_id}`.
  """
  @spec append_fixture_event!(fixture(), map()) :: {String.t(), String.t()}
  def append_fixture_event!(fixture, payload) do
    event_type = register_event_type!(fixture.tenant_id)

    attrs = %{
      instance_id: EventStore.platform_instance_id(),
      event_type: event_type,
      payload: Jason.encode!(payload),
      actor_id: Ecto.UUID.generate(),
      idempotency_key: "req446-" <> to_string(System.unique_integer([:positive, :monotonic]))
    }

    assert {:ok, %{event: event}} =
             EventStore.append_platform_event(attrs, prefix: fixture.schema_name)

    {event_type, event.event_id}
  end

  @doc """
  Every row of every schema the REQ-446 routes can write, per fixture: definitions (id, name,
  version, status), reviews (id, status, row version) and the assertion-run count.
  """
  @spec snapshot([fixture()]) :: map()
  def snapshot(fixtures) do
    for fixture <- fixtures, into: %{} do
      definitions =
        ProcessDefinition
        |> Repo.all(prefix: fixture.schema_name)
        |> Enum.map(&{&1.id, &1.name, &1.version, &1.status})
        |> Enum.sort()

      reviews =
        PromotionReview
        |> Repo.all(prefix: fixture.schema_name)
        |> Enum.map(&{&1.id, &1.status, &1.row_version})
        |> Enum.sort()

      runs = Repo.aggregate(PromotionAssertionRun, :count, :id, prefix: fixture.schema_name)

      {fixture.tenant_id, {definitions, reviews, runs}}
    end
  end
end
