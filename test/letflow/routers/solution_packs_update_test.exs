defmodule Letflow.Routers.SolutionPacksUpdateTest do
  @moduledoc """
  Router-level tests for REQ-380
  (`lib/letflow/design/req380-pack-update-review-apply-api.md`) —
  `POST /solution-packs/:pack_id/update-review` and
  `POST /solution-packs/:pack_id/update-apply`, added to
  `Letflow.Routers.SolutionPacks` by this requirement. See `test/specs/REQ-380.md`
  for the acceptance-criterion-to-test-case mapping and rationale.

  New file (design §8's stated expectation: no router-level test file for
  `solution_packs.ex` was found by that search) — this is the router-level half of
  the design's requested split; `test/letflow/routers/req078_supporting_routes_test.exs`
  already covers `/export`/`/install` for REQ-078 and is left untouched.

  Every test in this file dispatches **real HTTP requests** through
  `Letflow.Routers.SolutionPacks.call/2` (not a bare call to
  `Letflow.Definitions.SolutionPack.apply_pack_update/6`) — this is an API-level
  requirement (REQ-380's own scope fence: "backend API only, three routes/operations"),
  so route matching, `Letflow.Plugs.Authorize`, request-body validation, and response
  JSON shaping are all exercised, not bypassed.

  Uses `Letflow.DataCase` (real Postgres, per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1) and `Letflow.TenantFixture` for real provisioned tenant schemas.
  `async: false` — mirrors `test/letflow/routers/req078_supporting_routes_test.exs`'s
  own established reasoning (tenant provisioning needs `Sandbox.mode(Letflow.Repo,
  :auto)`).

  ## Dispatch strategy

  Direct `Letflow.Routers.SolutionPacks.call/2` with `conn.assigns[:auth_context]` set
  by hand — the same convention `req078_supporting_routes_test.exs`,
  `admin_services_test.exs`, and `dlq_test.exs` already establish: each handler reads
  `conn.assigns.auth_context` directly via `Letflow.Plugs.Authorize`, so nothing here
  depends on how that assign got populated. There is no `401 Unauthorized` concept in
  `Letflow.Plugs.Authorize` (see its own moduledoc) — an unauthenticated caller is
  represented, same as `admin_services_test.exs`, by an `auth_context` whose `roles`
  list is empty, which the plug denies with the identical `403` a wrong-but-
  authenticated role gets.

  `solution_pack_artefact_bases`/`pack_update_resolutions` are GLOBAL tables (REQ-041),
  fixture-insertable with no FK to `solution_pack_installs` (INV-PU-6, design §8's own
  note) — every fixture in this file inserts them directly, no `SolutionPack.install/3`
  call required to set up a scenario.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.PackUpdateResolution
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @solution_packs_opts Letflow.Routers.SolutionPacks.init([])

  # ── Shared helpers ─────────────────────────────────────────────────────────

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp build_conn(method, path, tenant_fixture, fields) do
    roles = Keyword.get(fields, :roles, ["PLATFORM_ADMIN"])
    body = Keyword.get(fields, :body, nil)
    user_id = Keyword.get(fields, :user_id, Ecto.UUID.generate())

    conn = conn(method, path)

    conn =
      if body do
        %{conn | body_params: body} |> put_req_header("content-type", "application/json")
      else
        conn
      end

    conn
    |> assign(:auth_context, %{
      user_id: user_id,
      tenant_id: tenant_fixture.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "req380-test-trace-id")
  end

  # GLOBAL table -- delete rows this file wrote so TenantFixture's own
  # on_exit (which deletes the tenants row) doesn't hit a FK violation.
  # Registered after the tenant fixture's own on_exit, so ExUnit's LIFO
  # on_exit ordering runs this FIRST -- mirrors
  # solution_pack_test.exs's cleanup_solution_pack_installs!/1 exactly.
  defp cleanup_pack_update_tables!(tenant_id) do
    on_exit(fn ->
      Repo.delete_all(from(r in PackUpdateResolution, where: r.tenant_id == ^tenant_id))
      Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))
    end)
  end

  defp insert_base!(tenant_id, pack_id, artefact_type, artefact_id, base_version, base_content) do
    %SolutionPackArtefactBase{}
    |> SolutionPackArtefactBase.upsert_changeset(%{
      tenant_id: tenant_id,
      pack_id: pack_id,
      artefact_type: artefact_type,
      artefact_id: artefact_id,
      base_version: base_version,
      base_content: base_content,
      captured_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
    })
    |> Repo.insert!()
  end

  defp fetch_base(tenant_id, pack_id, artefact_type, artefact_id) do
    Repo.one!(
      from(b in SolutionPackArtefactBase,
        where:
          b.tenant_id == ^tenant_id and b.pack_id == ^pack_id and
            b.artefact_type == ^artefact_type and b.artefact_id == ^artefact_id
      )
    )
  end

  defp resolution_rows(tenant_id, pack_id, target_version) do
    Repo.all(
      from(r in PackUpdateResolution,
        where:
          r.tenant_id == ^tenant_id and r.pack_id == ^pack_id and
            r.target_version == ^target_version
      )
    )
  end

  defp artefact_input(type, id, content),
    do: %{"artefact_type" => type, "artefact_id" => id, "content" => content}

  defp entry_for(body, artefact_id) do
    Enum.find(body["entries"] || body["applied_entries"], &(&1["artefact_id"] == artefact_id))
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # EO-001 -- update-review's four-way classification
  # ═══════════════════════════════════════════════════════════════════════════

  describe "EO-001: update-review returns each artefact under exactly one of the four groups" do
    test "one artefact per group, classified unchanged/safe_to_update/local_only/both_sides_conflict" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req380-eo1")
      pack_id = unique("req380-eo1-pack")
      cleanup_pack_update_tables!(tenant.tenant_id)
      artefact_type = "process_definition"

      ids = %{
        unchanged: Ecto.UUID.generate(),
        safe_to_update: Ecto.UUID.generate(),
        local_only: Ecto.UUID.generate(),
        both_sides_conflict: Ecto.UUID.generate()
      }

      base = fn bucket -> "base-#{bucket}-#{Map.fetch!(ids, bucket)}" end
      different = fn bucket, tag -> "different-#{bucket}-#{tag}-#{Map.fetch!(ids, bucket)}" end

      for bucket <- Map.keys(ids) do
        insert_base!(
          tenant.tenant_id,
          pack_id,
          artefact_type,
          Map.fetch!(ids, bucket),
          "1.0.0",
          base.(bucket)
        )
      end

      theirs_artefacts = [
        artefact_input(artefact_type, ids.unchanged, base.(:unchanged)),
        artefact_input(artefact_type, ids.safe_to_update, base.(:safe_to_update)),
        artefact_input(artefact_type, ids.local_only, different.(:local_only, "theirs")),
        artefact_input(
          artefact_type,
          ids.both_sides_conflict,
          different.(:both_sides_conflict, "theirs")
        )
      ]

      incoming_artefacts = [
        artefact_input(artefact_type, ids.unchanged, base.(:unchanged)),
        artefact_input(
          artefact_type,
          ids.safe_to_update,
          different.(:safe_to_update, "incoming")
        ),
        artefact_input(artefact_type, ids.local_only, base.(:local_only)),
        artefact_input(
          artefact_type,
          ids.both_sides_conflict,
          different.(:both_sides_conflict, "incoming")
        )
      ]

      body = %{
        "target_version" => "2.0.0",
        "theirs_artefacts" => theirs_artefacts,
        "incoming_artefacts" => incoming_artefacts
      }

      resp =
        build_conn(:post, "/#{pack_id}/update-review", tenant, body: body)
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert resp.status == 200
      resp_body = Jason.decode!(resp.resp_body)

      assert length(resp_body["entries"]) == 4

      expected_wire = %{
        unchanged: "unchanged",
        safe_to_update: "safe_to_update",
        local_only: "local_only",
        both_sides_conflict: "both_sides_conflict"
      }

      for {bucket, wire} <- expected_wire do
        entry = entry_for(resp_body, Map.fetch!(ids, bucket))
        refute is_nil(entry), "expected an entry for bucket #{bucket}"

        assert entry["classification"] == wire,
               "bucket #{bucket} misclassified: #{inspect(entry)}"
      end

      # Genuinely exercises all four groups, not merely "doesn't contradict" --
      # every wire classification value actually appears at least once.
      classifications = Enum.map(resp_body["entries"], & &1["classification"]) |> Enum.sort()

      assert classifications ==
               Enum.sort(["unchanged", "safe_to_update", "local_only", "both_sides_conflict"])

      assert resp_body["has_unresolved_conflicts"] == true
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # EO-002 -- update-apply blocks on an unresolved conflict, applies nothing
  # ═══════════════════════════════════════════════════════════════════════════

  describe "EO-002: update-apply refuses and names the unresolved artefact; applies nothing" do
    test "409 names the unresolved conflict; no base rows advance, no resolution rows persist -- including a resolution submitted for a DIFFERENT conflict in the same call" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req380-eo2")
      pack_id = unique("req380-eo2-pack")
      cleanup_pack_update_tables!(tenant.tenant_id)
      artefact_type = "process_definition"
      target_version = "2.0.0"

      # conflict_a: this call SUBMITS a resolution for it (keep_local).
      # conflict_b: this call submits NOTHING for it -- this is the one that
      # blocks the whole apply.
      conflict_a_id = Ecto.UUID.generate()
      conflict_b_id = Ecto.UUID.generate()

      base_a = "base-a-#{conflict_a_id}"
      base_b = "base-b-#{conflict_b_id}"

      insert_base!(tenant.tenant_id, pack_id, artefact_type, conflict_a_id, "1.0.0", base_a)
      insert_base!(tenant.tenant_id, pack_id, artefact_type, conflict_b_id, "1.0.0", base_b)

      theirs_artefacts = [
        artefact_input(artefact_type, conflict_a_id, "theirs-a-#{conflict_a_id}"),
        artefact_input(artefact_type, conflict_b_id, "theirs-b-#{conflict_b_id}")
      ]

      incoming_artefacts = [
        artefact_input(artefact_type, conflict_a_id, "incoming-a-#{conflict_a_id}"),
        artefact_input(artefact_type, conflict_b_id, "incoming-b-#{conflict_b_id}")
      ]

      body = %{
        "target_version" => target_version,
        "theirs_artefacts" => theirs_artefacts,
        "incoming_artefacts" => incoming_artefacts,
        "resolutions" => [
          %{
            "artefact_type" => artefact_type,
            "artefact_id" => conflict_a_id,
            "resolution" => "keep_local"
          }
        ]
      }

      resp =
        build_conn(:post, "/#{pack_id}/update-apply", tenant, body: body)
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert resp.status == 409
      resp_body = Jason.decode!(resp.resp_body)
      detail = resp_body["detail"] || resp_body["message"] || Jason.encode!(resp_body)

      assert detail =~ conflict_b_id
      assert detail =~ artefact_type

      # Atomicity (design §4.4): zero resolution rows for EITHER conflict --
      # not just the one that blocked, proving the whole call, including
      # conflict_a's own submitted resolution, rolled back.
      assert resolution_rows(tenant.tenant_id, pack_id, target_version) == []

      # Neither base row advanced.
      base_a_after = fetch_base(tenant.tenant_id, pack_id, artefact_type, conflict_a_id)
      base_b_after = fetch_base(tenant.tenant_id, pack_id, artefact_type, conflict_b_id)

      assert base_a_after.base_content == base_a
      assert base_a_after.base_version == "1.0.0"
      assert base_b_after.base_content == base_b
      assert base_b_after.base_version == "1.0.0"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # EO-003/EO-004/EO-005 -- keep_local apply, untouched artefact, idempotent re-review
  # ═══════════════════════════════════════════════════════════════════════════

  describe "EO-003/EO-004/EO-005: keep_local apply, untouched artefact, idempotent re-review" do
    test "keep_local leaves content+attribution as designed; the unchanged artefact in the same call is untouched; a later re-review marks the conflict resolved, not fresh" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req380-eo345")
      pack_id = unique("req380-eo345-pack")
      cleanup_pack_update_tables!(tenant.tenant_id)
      artefact_type = "process_definition"
      target_version = "2.0.0"
      actor_id = Ecto.UUID.generate()

      conflict_id = Ecto.UUID.generate()
      unchanged_id = Ecto.UUID.generate()

      conflict_base = "base-conflict-#{conflict_id}"
      unchanged_content = "same-content-#{unchanged_id}"

      insert_base!(tenant.tenant_id, pack_id, artefact_type, conflict_id, "1.0.0", conflict_base)

      insert_base!(
        tenant.tenant_id,
        pack_id,
        artefact_type,
        unchanged_id,
        "1.0.0",
        unchanged_content
      )

      conflict_theirs = "theirs-adapted-#{conflict_id}"
      conflict_incoming = "incoming-offered-#{conflict_id}"

      theirs_artefacts = [
        artefact_input(artefact_type, conflict_id, conflict_theirs),
        artefact_input(artefact_type, unchanged_id, unchanged_content)
      ]

      incoming_artefacts = [
        artefact_input(artefact_type, conflict_id, conflict_incoming),
        artefact_input(artefact_type, unchanged_id, unchanged_content)
      ]

      apply_body = %{
        "target_version" => target_version,
        "theirs_artefacts" => theirs_artefacts,
        "incoming_artefacts" => incoming_artefacts,
        "resolutions" => [
          %{
            "artefact_type" => artefact_type,
            "artefact_id" => conflict_id,
            "resolution" => "keep_local"
          }
        ]
      }

      # Pre-call snapshot of the untouched artefact's row, for a byte-identical
      # comparison after apply (EO-004).
      unchanged_before = fetch_base(tenant.tenant_id, pack_id, artefact_type, unchanged_id)

      apply_resp =
        build_conn(:post, "/#{pack_id}/update-apply", tenant,
          body: apply_body,
          user_id: actor_id
        )
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert apply_resp.status == 200
      apply_body_json = Jason.decode!(apply_resp.resp_body)

      # ── EO-003: keep_local artefact's content is unchanged; a
      # pack_update_resolutions row records attribution.
      conflict_entry = entry_for(apply_body_json, conflict_id)
      assert conflict_entry["action"] == "left_unchanged"
      assert conflict_entry["classification"] == "both_sides_conflict"

      conflict_base_after = fetch_base(tenant.tenant_id, pack_id, artefact_type, conflict_id)
      assert conflict_base_after.base_content == conflict_base
      assert conflict_base_after.base_version == "1.0.0"

      assert [resolution_row] = resolution_rows(tenant.tenant_id, pack_id, target_version)
      assert resolution_row.artefact_type == artefact_type
      assert resolution_row.artefact_id == conflict_id
      assert resolution_row.resolution == :keep_local
      assert resolution_row.resolved_by == actor_id
      refute is_nil(resolution_row.resolved_at)

      # ── EO-004: the untouched artefact (base == theirs == incoming), in the
      # same apply call, is unchanged in BOTH content and version.
      unchanged_entry = entry_for(apply_body_json, unchanged_id)
      assert unchanged_entry["action"] == "left_unchanged"
      assert unchanged_entry["classification"] == "unchanged"

      unchanged_after = fetch_base(tenant.tenant_id, pack_id, artefact_type, unchanged_id)
      assert unchanged_after.base_content == unchanged_before.base_content
      assert unchanged_after.base_version == unchanged_before.base_version

      # ── EO-005: a second update-review call, same target_version, same
      # (unchanged-by-construction) theirs content for the keep_local
      # artefact, does not re-flag it as a fresh (unresolved) conflict --
      # classification stays "both_sides_conflict", "resolved" flips to true.
      review_body = %{
        "target_version" => target_version,
        "theirs_artefacts" => theirs_artefacts,
        "incoming_artefacts" => incoming_artefacts
      }

      review_resp =
        build_conn(:post, "/#{pack_id}/update-review", tenant, body: review_body)
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert review_resp.status == 200
      review_body_json = Jason.decode!(review_resp.resp_body)

      re_reviewed_conflict_entry = entry_for(review_body_json, conflict_id)
      assert re_reviewed_conflict_entry["classification"] == "both_sides_conflict"
      assert re_reviewed_conflict_entry["resolved"] == true

      assert review_body_json["has_unresolved_conflicts"] == false
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Regression: resolution immutability (OQ-3) -- first-attribution-wins
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Regression: a resolved artefact's attribution AND applied action are both immutable (first-decision-wins)" do
    test "a second apply call submitting a DIFFERENT resolution for an already-resolved artefact does not overwrite the persisted resolved_by/resolved_at/resolution row" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req380-immut")
      pack_id = unique("req380-immut-pack")
      cleanup_pack_update_tables!(tenant.tenant_id)
      artefact_type = "process_definition"
      target_version = "2.0.0"

      first_actor = Ecto.UUID.generate()
      second_actor = Ecto.UUID.generate()

      artefact_id = Ecto.UUID.generate()
      base_content = "base-#{artefact_id}"
      theirs_content = "theirs-adapted-#{artefact_id}"
      incoming_content = "incoming-offered-#{artefact_id}"

      insert_base!(tenant.tenant_id, pack_id, artefact_type, artefact_id, "1.0.0", base_content)

      artefacts_body = %{
        "theirs_artefacts" => [artefact_input(artefact_type, artefact_id, theirs_content)],
        "incoming_artefacts" => [artefact_input(artefact_type, artefact_id, incoming_content)]
      }

      first_body =
        Map.merge(artefacts_body, %{
          "target_version" => target_version,
          "resolutions" => [
            %{
              "artefact_type" => artefact_type,
              "artefact_id" => artefact_id,
              "resolution" => "keep_local"
            }
          ]
        })

      first_resp =
        build_conn(:post, "/#{pack_id}/update-apply", tenant,
          body: first_body,
          user_id: first_actor
        )
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert first_resp.status == 200

      assert [row_after_first] = resolution_rows(tenant.tenant_id, pack_id, target_version)
      assert row_after_first.resolution == :keep_local
      assert row_after_first.resolved_by == first_actor
      first_resolved_at = row_after_first.resolved_at
      refute is_nil(first_resolved_at)

      # Second call: a DIFFERENT resolution (take_incoming) for the SAME
      # artefact/target_version, submitted by a different actor. Since the
      # artefact is already resolved (resolved: true from the first call's
      # persisted row), this apply call succeeds -- it is not blocked by
      # EO-002's unresolved-conflict check. The DB row's own step-3 insert
      # is a silent on_conflict: :nothing no-op (asserted below): the
      # persisted ATTRIBUTION (resolved_by/resolved_at/resolution) must
      # stay the first call's, permanently (design §4.3 step 3, OQ-3).
      second_body =
        Map.merge(artefacts_body, %{
          "target_version" => target_version,
          "resolutions" => [
            %{
              "artefact_type" => artefact_type,
              "artefact_id" => artefact_id,
              "resolution" => "take_incoming"
            }
          ]
        })

      second_resp =
        build_conn(:post, "/#{pack_id}/update-apply", tenant,
          body: second_body,
          user_id: second_actor
        )
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert second_resp.status == 200
      second_body_json = Jason.decode!(second_resp.resp_body)

      # Still exactly one resolution row, still the FIRST call's attribution,
      # completely unchanged -- this is the immutability claim itself
      # (design §4.3 step 3 / OQ-3): the DURABLE ATTRIBUTION RECORD
      # (resolved_by/resolved_at/resolution) never moves off the first
      # caller who resolved this artefact for this target_version, no
      # matter what a later call submits.
      assert [row_after_second] = resolution_rows(tenant.tenant_id, pack_id, target_version)
      assert row_after_second.id == row_after_first.id
      assert row_after_second.resolution == :keep_local
      assert row_after_second.resolved_by == first_actor
      assert row_after_second.resolved_at == first_resolved_at

      # ISS-0781: the applied action is ALSO immutable, not just the
      # attribution row. apply_entry/6's :conflict clause now always reads
      # the persisted pack_update_resolutions row
      # (apply_from_persisted_resolution/5) to decide the action -- never
      # this call's own `resolutions` argument -- so the second call's
      # differing "take_incoming" submission has NO effect on the action
      # either. The action, base_content, and base_version all continue to
      # reflect the FIRST call's persisted "keep_local" resolution: no
      # write, since apply_entry/6's :keep_local branch is :left_unchanged
      # and never calls advance_base/6, so the base row stays exactly what
      # insert_base!/6 seeded it to before either call ran.
      entry = entry_for(second_body_json, artefact_id)
      assert entry["action"] == "left_unchanged"

      base_after = fetch_base(tenant.tenant_id, pack_id, artefact_type, artefact_id)
      assert base_after.base_content == base_content
      assert base_after.base_version == "1.0.0"
    end

    # NOTE (ELIXIR-DEV, ISS-0781 implementation): the design doc (§4.2) also
    # specifies a reverse-ordering case (take_incoming first, keep_local
    # second, identical resubmission both calls) as a required new test.
    # That exact scenario is NOT reachable as literally described: once the
    # first call's :take_incoming resolution runs, advance_base/6 writes
    # base_content = entry.incoming, so on an identical second submission
    # Definitions.classify_artefact/3 (lib/letflow/definitions.ex:487-491)
    # sees base == incoming and reclassifies the entry as :local_only, not
    # :conflict -- it never reaches apply_entry/6's :conflict clause
    # (or apply_from_persisted_resolution/5) at all on the second call.
    # Confirmed by running the scenario exactly as specified: the second
    # call's action came back "left_unchanged", not "advanced_to_incoming".
    # This is a real gap in the design doc's test-scenario assumption
    # (it did not account for compute_pack_update_plan/5 re-classifying
    # against the now-advanced base), not a defect in this fix -- left for
    # CODE-DESIGNER/TEST-DESIGNER to resolve with a corrected fixture
    # (e.g. a differing second-call incoming payload that keeps the entry
    # classified :conflict) rather than silently landing a scenario that
    # cannot pass for the reason the design doc states.

    test "a second apply call submitting a DIFFERENT resolution for an already-resolved artefact applies the FIRST call's :merged resolved_content, not its own" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req380-immut-merge")
      pack_id = unique("req380-immut-merge-pack")
      cleanup_pack_update_tables!(tenant.tenant_id)
      artefact_type = "process_definition"
      target_version = "2.0.0"

      first_actor = Ecto.UUID.generate()
      second_actor = Ecto.UUID.generate()

      artefact_id = Ecto.UUID.generate()
      base_content = "base-#{artefact_id}"
      theirs_content = "theirs-adapted-#{artefact_id}"
      incoming_content = "incoming-offered-#{artefact_id}"
      merged_content = "merged-by-first-actor-#{artefact_id}"

      insert_base!(tenant.tenant_id, pack_id, artefact_type, artefact_id, "1.0.0", base_content)

      artefacts_body = %{
        "theirs_artefacts" => [artefact_input(artefact_type, artefact_id, theirs_content)],
        "incoming_artefacts" => [artefact_input(artefact_type, artefact_id, incoming_content)]
      }

      first_body =
        Map.merge(artefacts_body, %{
          "target_version" => target_version,
          "resolutions" => [
            %{
              "artefact_type" => artefact_type,
              "artefact_id" => artefact_id,
              "resolution" => "merged",
              "resolved_content" => merged_content
            }
          ]
        })

      first_resp =
        build_conn(:post, "/#{pack_id}/update-apply", tenant,
          body: first_body,
          user_id: first_actor
        )
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert first_resp.status == 200
      first_body_json = Jason.decode!(first_resp.resp_body)

      first_entry = entry_for(first_body_json, artefact_id)
      assert first_entry["action"] == "advanced_to_merged"

      base_after_first = fetch_base(tenant.tenant_id, pack_id, artefact_type, artefact_id)
      assert base_after_first.base_content == merged_content
      assert base_after_first.base_version == target_version

      second_body =
        Map.merge(artefacts_body, %{
          "target_version" => target_version,
          "resolutions" => [
            %{
              "artefact_type" => artefact_type,
              "artefact_id" => artefact_id,
              "resolution" => "take_incoming"
            }
          ]
        })

      second_resp =
        build_conn(:post, "/#{pack_id}/update-apply", tenant,
          body: second_body,
          user_id: second_actor
        )
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert second_resp.status == 200
      second_body_json = Jason.decode!(second_resp.resp_body)

      assert [row_after_second] = resolution_rows(tenant.tenant_id, pack_id, target_version)
      assert row_after_second.resolution == :merged
      assert row_after_second.resolved_by == first_actor
      assert row_after_second.resolved_content == merged_content

      # Action-level: the second call's "take_incoming" submission has no
      # effect -- the action still reflects the FIRST call's :merged
      # resolution, with the FIRST call's resolved_content, not the second
      # call's incoming_content. This is the case most likely to regress
      # silently, since resolved_content is data carried on the resolution
      # row itself, not derivable from entry.incoming.
      second_entry = entry_for(second_body_json, artefact_id)
      assert second_entry["action"] == "advanced_to_merged"

      base_after_second = fetch_base(tenant.tenant_id, pack_id, artefact_type, artefact_id)
      assert base_after_second.base_content == merged_content
      assert base_after_second.base_version == target_version
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Negative / shape coverage (design §8 item 6) -- exercises the route layer
  # itself, not only the context function.
  # ═══════════════════════════════════════════════════════════════════════════

  describe "negative/shape coverage" do
    test "update-review: malformed (non-object) body -> 400" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req380-neg-400")

      # Mirrors test/letflow/routers/definitions_write_test.exs's own
      # "malformed JSON body" idiom: object_body/1 (solution_packs.ex) treats
      # a `_json` body_params key carrying a non-object value as :error ->
      # Response.bad_request/2, 400 -- the shape a real non-object JSON POST
      # body decodes to under Plug.Parsers.JSON.
      resp =
        build_conn(:post, "/#{unique("pack")}/update-review", tenant, body: nil)
        |> put_req_header("content-type", "application/json")
        |> Map.put(:body_params, %{"_json" => "not an object"})
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert resp.status == 400
    end

    test "update-review: both artefact arrays empty -> 422 with the stated detail" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req380-neg-422-empty")

      body = %{
        "target_version" => "2.0.0",
        "theirs_artefacts" => [],
        "incoming_artefacts" => []
      }

      resp =
        build_conn(:post, "/#{unique("pack")}/update-review", tenant, body: body)
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert resp.status == 422
      assert resp.resp_body =~ "theirs_artefacts and incoming_artefacts must not both be empty"
    end

    test "update-apply: resolution \"merged\" with no resolved_content -> 422" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req380-neg-merged-missing")
      artefact_id = Ecto.UUID.generate()

      body = %{
        "target_version" => "2.0.0",
        "theirs_artefacts" => [artefact_input("process_definition", artefact_id, "theirs")],
        "incoming_artefacts" => [artefact_input("process_definition", artefact_id, "incoming")],
        "resolutions" => [
          %{
            "artefact_type" => "process_definition",
            "artefact_id" => artefact_id,
            "resolution" => "merged"
          }
        ]
      }

      resp =
        build_conn(:post, "/#{unique("pack")}/update-apply", tenant, body: body)
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert resp.status == 422
    end

    test "update-apply: resolution \"keep_local\" with a non-null resolved_content -> 422" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req380-neg-keeplocal-extra")
      artefact_id = Ecto.UUID.generate()

      body = %{
        "target_version" => "2.0.0",
        "theirs_artefacts" => [artefact_input("process_definition", artefact_id, "theirs")],
        "incoming_artefacts" => [artefact_input("process_definition", artefact_id, "incoming")],
        "resolutions" => [
          %{
            "artefact_type" => "process_definition",
            "artefact_id" => artefact_id,
            "resolution" => "keep_local",
            "resolved_content" => "should not be here"
          }
        ]
      }

      resp =
        build_conn(:post, "/#{unique("pack")}/update-apply", tenant, body: body)
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert resp.status == 422
    end

    test "update-apply: an unauthenticated caller (empty roles) gets 403" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req380-neg-403-unauth")
      artefact_id = Ecto.UUID.generate()

      body = %{
        "target_version" => "2.0.0",
        "theirs_artefacts" => [artefact_input("process_definition", artefact_id, "theirs")],
        "incoming_artefacts" => [artefact_input("process_definition", artefact_id, "incoming")],
        "resolutions" => []
      }

      resp =
        build_conn(:post, "/#{unique("pack")}/update-apply", tenant, body: body, roles: [])
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert resp.status == 403
    end

    test "update-apply: a PROCESS_OPERATOR caller (no :DefinitionsWrite) gets 403" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req380-neg-403-operator")
      artefact_id = Ecto.UUID.generate()

      body = %{
        "target_version" => "2.0.0",
        "theirs_artefacts" => [artefact_input("process_definition", artefact_id, "theirs")],
        "incoming_artefacts" => [artefact_input("process_definition", artefact_id, "incoming")],
        "resolutions" => []
      }

      resp =
        build_conn(:post, "/#{unique("pack")}/update-apply", tenant,
          body: body,
          roles: ["PROCESS_OPERATOR"]
        )
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert resp.status == 403
    end

    test "update-review: the same PROCESS_OPERATOR caller (holds :DefinitionsRead) gets 200 -- the concrete proof for §3.1/§4.1's stated role-matrix reasoning" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req380-neg-200-operator")
      pack_id = unique("req380-neg-200-operator-pack")
      artefact_id = Ecto.UUID.generate()

      insert_base!(
        tenant.tenant_id,
        pack_id,
        "process_definition",
        artefact_id,
        "1.0.0",
        "same-content"
      )

      cleanup_pack_update_tables!(tenant.tenant_id)

      body = %{
        "target_version" => "2.0.0",
        "theirs_artefacts" => [artefact_input("process_definition", artefact_id, "same-content")],
        "incoming_artefacts" => [
          artefact_input("process_definition", artefact_id, "same-content")
        ]
      }

      resp =
        build_conn(:post, "/#{pack_id}/update-review", tenant,
          body: body,
          roles: ["PROCESS_OPERATOR"]
        )
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert resp.status == 200
    end
  end
end
