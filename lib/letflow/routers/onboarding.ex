defmodule Letflow.Routers.Onboarding do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Tenant self-service onboarding sub-router (REQ-076), mounted at `/onboarding`
  directly by `Letflow.Plugs.ApiPipeline` (so full paths under `/api/v1` are
  `/api/v1/onboarding`, `/api/v1/onboarding/:id`). Ports `src/api/routes/onboarding.zig`'s
  `handleOnboarding`, `handleGetOnboarding`, `handleGetOnboardingByHostname`. See
  `lib/letflow/design/req076-identity-tokens-roles-onboarding.md` §8 for the full design.

  * POST /                (mounted path: `POST /api/v1/onboarding`)          -> `handle_create/1`
  * GET  /:id              (mounted path: `GET /api/v1/onboarding/:id`)       -> `handle_get/2`
  * GET  /?hostname=       (mounted path: `GET /api/v1/onboarding`)           -> `handle_get_by_hostname/1`

  All three require `:TenantsManage` — reused, not a new permission (same
  risk class and PLATFORM_ADMIN-only intent as `Letflow.Routers.Tenants`,
  REQ-075 §1.1: creating a tenant, and reading records that disclose which
  hostnames/slugs exist platform-wide, is exactly the kind of "wrong role,
  right nobody" operation that matrix already gates this way). No
  tenant-scoped `:prefix` preamble exists on this router (unlike
  `Letflow.Routers.Identity`) — same structural reason `Letflow.Routers.Tenants`
  has none: these handlers decide which tenants exist, so there is no tenant
  context to scope by. Every handler calls
  `Letflow.Api.Authorization.evaluate_access/2` **before any `Repo` call of any
  kind** — a `Deny403` decision returns immediately.

  ## One tenant-provisioning path, not two (AC8)

  `POST /onboarding`'s tenant-creation sequence is `Letflow.Identity.create_tenant/1`
  -> `Letflow.TenantOnboarding.provision_and_migrate/1` (which itself sequences
  `Letflow.TenantProvisioning.provision_tenant_schema/1` and
  `Letflow.TenantProvisioning.replay_migrations/2` — the **identical**
  two-call sequence `Letflow.Routers.Tenants`'s `POST /tenants` handler
  already uses, REQ-075 §7.1) -> `Letflow.Identity.create_onboarding/1`. This
  module does not reimplement schema creation or migration replay, and does
  not add a second orchestration — there is one tenant-provisioning path on
  this platform, not two. As of the AC9/AC10 SCOPE EXTENSION (run
  `WF02-REQ076-20260822`), `Letflow.TenantOnboarding.provision_and_migrate/1`
  is also the function the recovery entry point
  (`Letflow.TenantOnboarding.recover_provisioning/1`, AC9) calls — one place,
  not two, that ever sequences these primitives.

  ## The `:migrating` status window (AC10)

  `handle_create/1` creates the tenant row with `"status" => "migrating"`
  (`Letflow.Identity.Tenant.status`'s existing three-value `Ecto.Enum` — no
  schema/changeset change). `Letflow.TenantOnboarding.provision_and_migrate/1`
  flips it to `:active` on success. See `Letflow.TenantOnboarding`'s own
  moduledoc for the full AC10 argument, including the accepted,
  structurally-credential-less empty-schema read gap (OQ-6) — not repeated
  here.

  ## The `GET /onboarding?hostname=` PLATFORM_ADMIN gate is deliberate (AC7, INV-5)

  This route is gated identically to its two siblings (`:TenantsManage`,
  PLATFORM_ADMIN-only) — **not** a public/pre-authentication lookup, even
  though the query mechanism (a bare hostname string, not a resource id
  scoped to the caller's own tenant) might suggest otherwise. Two independent
  reasons, both confirmed by direct inspection, not assumed:

    PROVENANCE (historical, not current decision authority):
    1. The historical Zig `handleGetOnboardingByHostname` (`onboarding.zig:379-409`)
       opens with the identical `actor.role != .PLATFORM_ADMIN` gate as its two
       siblings — confirmed by direct inspection, there is no pre-authentication
       branch anywhere in that handler.
    2. The frontend's only real caller of this endpoint
       (`web/src/api/onboarding.ts`'s `getOnboardingByHostname`, from
       `OnboardingResultPage.tsx`) is reached exclusively via the
       `admin/onboarding/:onboardingId/result` route. That route requires
       authentication (`ProtectedRoute` in `web/src/components/layout/AppShell.tsx`
       checks `isAuthenticated` only) — it is **not**, by itself, restricted to
       PLATFORM_ADMIN specifically; `AppShell.tsx`'s `roles:` array on that
       route only controls sidebar link visibility, not access. The real
       enforcement of "only a PLATFORM_ADMIN can actually use this page's data"
       is this backend route's own `:TenantsManage` gate below, not anything on
       the frontend. There is no anonymous/pre-login caller of this endpoint
       anywhere in the already-written frontend contract.

  The indistinguishability guarantee AC7/INV-5 demand protects a caller who
  does **not** hold `:TenantsManage` — since `evaluate_access/2` runs before
  any `Repo` call on this route (same ordering as every handler below), a
  hostname that was never bound to any tenant and a hostname bound to a real
  *other* tenant both produce a byte-identical 403 with zero DB round trips
  either way, for any caller lacking `:TenantsManage`. What a `:TenantsManage`
  caller itself sees (200 for a bound hostname, 404 for an unbound one) is
  deliberately **not** required to be indistinguishable — that caller already
  has standing to know, exactly like `GET /onboarding/:id`'s own plain 404 for
  a nonexistent id, never claimed to be INV-5-protected either.

  ## What is deliberately NOT ported (design §8.5)

  Keycloak realm/client provisioning, initial-admin-user creation, the
  idempotency-key header + conflict-on-mismatch mechanism, and the
  background-saga `state: pending/completed/failed` polling shape are all
  absent here — none has an acceptance criterion in this requirement, and this
  module's flow is fully synchronous (a slow provisioning step blocks the HTTP
  response rather than returning 201 immediately and polling), matching
  `Letflow.Routers.Tenants`'s own synchronous `POST /tenants` orchestration.
  The `hostname`/`slug` unique-index constraints on `onboarding_registry` and
  `tenants` already give this simpler flow a comparable "can't silently
  double-create" property without the saga/idempotency-record machinery.

  ## Response allowlist

  `onboarding_map/1` is a hand-built map with exactly the five keys named in
  its own @doc — never a `Jason.Encoder` derivation over
  `%Letflow.Identity.OnboardingRecord{}`.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.Identity
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.TenantOnboarding

  authz_post "/", :TenantsManage do
    handle_create(conn)
  end

  authz_get "/:id", :TenantsManage do
    handle_get(conn, conn.params["id"])
  end

  authz_get "/", :TenantsManage do
    handle_get_by_hostname(conn)
  end

  match _ do
    Response.not_found(conn)
  end

  # ── POST / (design §8.2/§8.3, AC8) ───────────────────────────────────────

  @create_schema [
    %FieldConstraint{
      name: "slug",
      required: true,
      type: :string,
      reject_empty_string: true,
      min_length: 3,
      max_length: 63
    },
    %FieldConstraint{
      name: "display_name",
      required: true,
      type: :string,
      reject_empty_string: true,
      min_length: 1,
      max_length: 255
    },
    %FieldConstraint{
      name: "hostname",
      required: true,
      type: :string,
      reject_empty_string: true,
      min_length: 1,
      max_length: 255
    }
  ]

  defp handle_create(conn) do
    case Validation.validate(@create_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, %{"slug" => slug, "hostname" => hostname} = attrs} ->
        create_attrs =
          attrs
          |> Map.take(["slug", "display_name"])
          |> Map.put("status", "migrating")

        case Identity.create_tenant(create_attrs) do
          {:error, :duplicate_slug} ->
            Response.conflict(conn, "slug already exists")

          {:error, %Ecto.Changeset{}} ->
            Response.unprocessable(conn, "validation failed")

          {:ok, tenant} ->
            provision_and_bind(conn, tenant, slug, hostname)
        end
    end
  end

  # Routes through Letflow.TenantOnboarding.provision_and_migrate/1 (AC8/AC9's
  # "one tenant-provisioning path, not two") -- the same function the
  # recovery entry point (Letflow.TenantOnboarding.recover_provisioning/1)
  # calls, rather than this handler sequencing
  # Letflow.TenantProvisioning.provision_tenant_schema/1 and
  # Letflow.TenantProvisioning.replay_migrations/2 itself. Same external
  # behavior as before this extension: both failure tags below still fall
  # into the same internal_error catch-all. No compensating rollback on a
  # provisioning/replay failure -- see Letflow.TenantProvisioning's moduledoc
  # "No reconciliation path for a half-provisioned tenant" section. Adding a
  # rollback here would orphan a real Postgres schema; not attempted.
  defp provision_and_bind(conn, tenant, slug, hostname) do
    with {:ok, _registration} <- TenantOnboarding.provision_and_migrate(tenant.id),
         {:ok, record} <-
           Identity.create_onboarding(%{tenant_id: tenant.id, slug: slug, hostname: hostname}) do
      Response.created(conn, onboarding_map(record))
    else
      {:error, :duplicate_hostname} -> Response.conflict(conn, "hostname already bound")
      {:error, %Ecto.Changeset{}} -> Response.unprocessable(conn, "validation failed")
      {:error, {:provisioning_failed, _reason}} -> Response.internal_error(conn)
      {:error, {:migration_failed, _exception}} -> Response.internal_error(conn)
      _provisioning_or_replay_error -> Response.internal_error(conn)
    end
  end

  # ── GET /:id (design §8.3) ───────────────────────────────────────────────
  #
  # Plain 404 -- this route is authenticated/PLATFORM_ADMIN, not the
  # anti-enumeration one (see moduledoc's "GET /onboarding?hostname= ... is
  # deliberate" section for why the hostname route differs).

  defp handle_get(conn, id) do
    case Identity.get_onboarding(id) do
      {:ok, record} -> Response.ok(conn, onboarding_map(record))
      {:error, :not_found} -> Response.not_found(conn)
    end
  end

  # ── GET /?hostname= (design §8.3/§8.4, AC7, INV-5) ───────────────────────

  defp handle_get_by_hostname(conn) do
    conn = fetch_query_params(conn)

    case Map.get(conn.query_params, "hostname") do
      hostname when is_binary(hostname) and hostname != "" ->
        case Identity.get_onboarding_by_hostname(hostname) do
          {:ok, record} -> Response.ok(conn, onboarding_map(record))
          {:error, :not_found} -> Response.not_found(conn)
        end

      _missing_or_empty ->
        Response.bad_request(conn, "hostname query parameter is required")
    end
  end

  # ── Response allowlist ────────────────────────────────────────────────────

  @doc false
  # Exactly 5 keys, hand-built -- never a Jason.Encoder derivation over the
  # full %OnboardingRecord{} struct.
  @spec onboarding_map(OnboardingRecord.t()) :: map()
  defp onboarding_map(%OnboardingRecord{} = record) do
    %{
      "id" => record.id,
      "tenant_id" => record.tenant_id,
      "slug" => record.slug,
      "hostname" => record.hostname,
      "created_at" => iso8601(record.inserted_at)
    }
  end

  # Matches Letflow.Routers.Identity's own user_map/1 convention exactly (ISO
  # 8601 via DateTime.to_iso8601/1 over the NaiveDateTime-as-UTC assumption
  # already established elsewhere in this codebase).
  defp iso8601(%NaiveDateTime{} = naive) do
    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end
end
