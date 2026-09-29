defmodule Letflow.Identity.RoleBackfill do
  @moduledoc """
  ISS-0886: one-time-per-tenant remediation for tenants provisioned before
  ISS-0778 shipped (2026-09-22) and therefore never got the six platform-role
  `Group`+`TenantRole` bindings (`Letflow.Api.Authorization.roles/0`) that
  `Letflow.TenantOnboarding.provision_and_migrate/1` now seeds automatically
  at tenant-creation time. Without those rows, every non-admin OIDC user on
  such a tenant reads `roles: []` from `Letflow.Identity.list_effective_role_names/2`
  and gets 403 everywhere — see `docs/issues/ISS-0886.yaml` for the full
  root-cause writeup, `lib/letflow/design/iss0886-role-backfill-preexisting-tenants.md`
  for the design this module implements exactly (§2.1).

  `run/0` iterates every tenant schema via
  `Letflow.TenantProvisioning.list_registrations/0` (the same registry
  `Letflow.TenantProvisioning.replay_all_pending/0` sweeps) and calls
  `Letflow.Identity.RoleRegistry.seed_default_platform_role_groups/1`
  (completely unmodified — its own `get_or_create_group_by_name/2`/
  `upsert_role/4` upsert semantics are already idempotent, design §1) once per
  tenant. Sequential `Enum.reduce_while/3`, deliberately NOT
  `Task.async_stream/3` — REQ-045's "row-lock arbitration over per-unit
  concurrent processes" decision, the same rationale
  `Letflow.TenantProvisioning.replay_all_pending/0`'s own moduledoc cites for
  the identical shape.

  Before seeding each tenant, this module reads how many platform-role
  `tenant_role` rows that tenant already held (a read-only classification
  query, not a new write path) so the accumulated result can tell an operator
  which tenants were genuinely affected (`:seeded`, held fewer than all six
  before this call) from which were already fully seeded (`:unchanged`,
  a true no-op write) — design §2.1 step 2, resolving the design's OQ-2 in
  favor of keeping the split: the issue's own `fix_direction` implies
  operators want to know which tenants changed, to narrow what needs
  re-verifying after a QA run.

  A hard failure on one tenant halts the sweep immediately
  (`{:error, {:backfill_failed, tenant_id, reason}}`) rather than silently
  skipping it — every `{:error, _}` `seed_default_platform_role_groups/1` can
  return is a genuine failure needing operator attention, unlike
  `Letflow.TenantProvisioning.Backfill.run/1`'s own third `:skipped` bucket
  for its legitimate "duplicate version" case, which has no analogue here
  (design §2.1 step 2). No rollback of tenants already processed before the
  halt — matches `seed_default_platform_role_groups/1`'s own documented
  no-compensating-rollback precedent (design §7 INV-BF4); a retried `run/0`
  call converges the remaining tenants via idempotency (INV-BF3).

  ## Deviation from the design doc, flagged for REVIEWER (not silently forced)

  Design §2.1 step 2 only pattern-matches `seed_default_platform_role_groups/1`'s
  `{:ok, _}` / `{:error, reason}` return shapes. Empirically confirmed (ad hoc
  probe against a real Postgres tenant schema, dropped mid-run): that function
  does **not** itself guard against its tenant schema having vanished the way
  `Letflow.EventStore.Registry.register_type/2` does (which returns
  `{:error, :tenant_schema_missing}` — the exact case
  `Letflow.TenantProvisioning.Backfill.run/1` pattern-matches on) — it instead
  lets the underlying `Postgrex.Error` (`undefined_table`) propagate as a raised
  exception. Implemented as designed, `process_registration/2` below would
  crash this sweep instead of halting cleanly with an actionable tenant_id on
  exactly the ISS-0343-shaped race `replay_all_pending/0` itself defends
  against one function away in the very module this design cites as its
  sequential-loop precedent. This module therefore adds the identical
  `try/rescue` `replay_all_pending/0` already uses for this exact scenario,
  converting an unexpected exception into the same
  `{:error, {:backfill_failed, tenant_id, reason}}` shape a genuine
  `seed_default_platform_role_groups/1` error return produces — no new
  abstraction, no behavior change to `RoleRegistry` itself, just the one
  missing safety net this design's own cited precedent already establishes as
  this codebase's convention for a cross-tenant sweep.

  No `Repo.transaction/1` wrapping the whole sweep — each tenant's own
  `seed_default_platform_role_groups/1` call is already internally
  transactional per `upsert_role/4`; holding one DB connection/transaction
  open across every tenant schema for the sweep's full duration is a shape
  this codebase consistently avoids elsewhere (neither
  `replay_all_pending/0` nor `Letflow.TenantProvisioning.Backfill.run/1` wrap
  their outer loop in a transaction either).

  Writes only `groups`/`tenant_role` rows, in whichever tenant schema it is
  currently processing (design §7 INV-BF1) — never a `group_members` row
  (INV-BF2): seeding a role binding does not by itself grant any existing
  user membership in it. A backfilled tenant's existing users still need
  their next login (`Letflow.Identity.sync_role_claims_from_token/3`) or an
  explicit `Letflow.Identity.add_group_member/3` call to actually gain a
  grant.
  """

  import Ecto.Query

  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantRole
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @doc """
  Sweeps every tenant registered in `Letflow.TenantProvisioning.list_registrations/0`,
  seeding the six platform-role bindings for each via
  `Letflow.Identity.RoleRegistry.seed_default_platform_role_groups/1`.

  Returns `{:ok, %{seeded: [tenant_id], unchanged: [tenant_id]}}` on success —
  both lists in the same order `list_registrations/0` returned them (design
  §2.1 step 3) — or the halted
  `{:error, {:backfill_failed, tenant_id, reason}}` from the first tenant
  whose `seed_default_platform_role_groups/1` call failed.
  """
  @spec run() ::
          {:ok, %{seeded: [Ecto.UUID.t()], unchanged: [Ecto.UUID.t()]}}
          | {:error, {:backfill_failed, tenant_id :: Ecto.UUID.t(), reason :: term()}}
  def run do
    TenantProvisioning.list_registrations()
    |> Enum.reduce_while({:ok, %{seeded: [], unchanged: []}}, fn registration, {:ok, acc} ->
      process_registration(registration, acc)
    end)
    |> finalize()
  end

  @spec process_registration(Registration.t(), %{
          seeded: [Ecto.UUID.t()],
          unchanged: [Ecto.UUID.t()]
        }) ::
          {:cont, {:ok, map()}} | {:halt, {:error, {:backfill_failed, Ecto.UUID.t(), term()}}}
  defp process_registration(%Registration{tenant_id: tenant_id, schema_name: schema_name}, acc) do
    held_platform_role_names_before = held_platform_role_names(schema_name)

    case RoleRegistry.seed_default_platform_role_groups(prefix: schema_name) do
      {:ok, _tenant_roles} ->
        {:cont, {:ok, classify(acc, tenant_id, held_platform_role_names_before)}}

      {:error, reason} ->
        {:halt, {:error, {:backfill_failed, tenant_id, reason}}}
    end
  rescue
    # See this module's moduledoc "Deviation from the design doc" section --
    # mirrors Letflow.TenantProvisioning.replay_all_pending/0's identical
    # try/rescue for the same "tenant schema vanished mid-sweep" case, which
    # seed_default_platform_role_groups/1 (unlike Registry.register_type/2)
    # does not itself guard against.
    exception ->
      {:halt, {:error, {:backfill_failed, tenant_id, {:unexpected_exception, exception}}}}
  end

  @spec classify(map(), Ecto.UUID.t(), [String.t()]) :: map()
  defp classify(acc, tenant_id, held_platform_role_names_before)
       when length(held_platform_role_names_before) < 6 do
    %{acc | seeded: [tenant_id | acc.seeded]}
  end

  defp classify(acc, tenant_id, _held_platform_role_names_before) do
    %{acc | unchanged: [tenant_id | acc.unchanged]}
  end

  @spec held_platform_role_names(String.t()) :: [String.t()]
  defp held_platform_role_names(schema_name) do
    from(t in TenantRole, where: t.kind == :platform_role, select: t.name)
    |> Repo.all(prefix: schema_name)
  end

  @spec finalize({:ok, map()} | {:error, term()}) ::
          {:ok, %{seeded: [Ecto.UUID.t()], unchanged: [Ecto.UUID.t()]}} | {:error, term()}
  defp finalize({:ok, %{seeded: seeded, unchanged: unchanged}}) do
    {:ok, %{seeded: Enum.reverse(seeded), unchanged: Enum.reverse(unchanged)}}
  end

  defp finalize({:error, _reason} = error), do: error
end
