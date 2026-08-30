defmodule Letflow.Api.AuthorizationEnforcementTest do
  @moduledoc """
  REQ-131's enforcement artefact (per REQ-130's design
  `lib/letflow/design/req130-authorization-generalization.md` §4): walks
  every route macro invocation across every module under
  `lib/letflow/routers/` that `use`s `Letflow.Api.AuthorizedRouter`, by
  introspecting each router's own compiled `__authz_routes__/0` (accumulated
  at compile time by `Letflow.Api.AuthorizedRouter`'s `authz_get/3` etc
  macros) — **not** by re-parsing source, matching the design's own stated
  shape requirement.

  For each `{method, path_template, policy_key}` route, asserts either:

    * `Letflow.Api.Authorization.endpoint_policy_key(method, path_template)`
      returns the SAME, non-`:Unknown` atom the route itself declared (the
      common case — the route's own policy key is backed by a real,
      present `Letflow.Api.Authorization.endpoint_policy_key/2` clause); or
    * the exact `{method, path_template}` pair is named on `@allowlist`
      below, with a stated reason — reserved for a route whose declared
      policy key is enforced directly (bypassing
      `Authorization.endpoint_policy_key/2`) because no clause exists for
      it in `lib/letflow/api/authorization.ex`, which this requirement does
      not modify (see each allowlisted route's own router-file comment).

  A route added to any router under `lib/letflow/routers/` with NO policy
  key at all (declared via the plain `get`/`post`/`put`/`patch`/`delete`
  macros instead of `authz_get`/`authz_post`/`authz_put`/`authz_patch`/
  `authz_delete`) is not accumulated into `__authz_routes__/0` at all, so
  this test cannot see it directly — but `Letflow.Plugs.Authorize` still
  runs for it at request time and evaluates it as `:Unknown`
  (fail-closed-EXCEPT-`PLATFORM_ADMIN`), covered instead by
  `test/letflow/api/authorize_plug_test.exs`'s unmatched-route case (AC5).
  This file's job is narrower and stricter: catch a route that WAS given a
  policy key but whose key drifted from (or was never backed by) the
  matrix, and force it into one of the two states above rather than leaving
  it silently reachable only by whoever happens to hold that key.

  `tenant_config.ex`/`mobile_tenant_config.ex` are excluded from this walk
  entirely (not allowlisted within it) — they are mounted outside
  `Letflow.Plugs.ApiPipeline` and never reach `Letflow.Plugs.Authorize`, by
  design (REQ-130's design §1/§4).
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.Authorization

  @routers [
    Letflow.Routers.Identity,
    Letflow.Routers.Audit,
    Letflow.Routers.Definitions,
    Letflow.Routers.Instances,
    Letflow.Routers.Onboarding,
    Letflow.Routers.Tenants,
    Letflow.Routers.Tasks,
    Letflow.Routers.SolutionPacks,
    Letflow.Routers.Promotions,
    Letflow.Routers.Services,
    Letflow.Routers.AdminServices
  ]

  # `Letflow.Plugs.ApiPipeline`'s own `forward/2` mount prefix per router
  # (see that module). `Letflow.Api.Authorization.endpoint_policy_key/2`
  # indexes its clauses by the FULL external path -- mount prefix + a
  # router's own local `Plug.Router` match pattern -- with exactly one
  # documented exception: `Letflow.Routers.Identity` is mounted at
  # `/identity`, but every one of its own already-shipped
  # `endpoint_policy_key/2` clauses (`/users*`, `/groups*`, `/tokens*`,
  # `/roles*`) omits that prefix, matching how the pre-REQ-131 route-local
  # `with_authorized_scope/4` calls in that router always passed the
  # UNPREFIXED literal (confirmed against `identity.ex`'s own pre-REQ-131
  # source). This test computes the same full path an
  # `authz_*` route's declared policy key must resolve against, from each
  # router's own local match pattern (as recorded in `__authz_routes__/0`)
  # plus this table -- it does not change how `Letflow.Plugs.Authorize`
  # enforces a route at runtime (that already uses the route's own directly
  # declared policy key, never a lookup through this function).
  @mount_prefix %{
    Letflow.Routers.Identity => "",
    Letflow.Routers.Audit => "/audit",
    Letflow.Routers.Definitions => "/definitions",
    Letflow.Routers.Instances => "/instances",
    Letflow.Routers.Onboarding => "/onboarding",
    Letflow.Routers.Tenants => "/tenants",
    Letflow.Routers.Tasks => "/tasks",
    Letflow.Routers.SolutionPacks => "/solution-packs",
    Letflow.Routers.Promotions => "/promotions",
    Letflow.Routers.Services => "/services",
    Letflow.Routers.AdminServices => "/admin/services"
  }

  # {method, path_template, reason} -- a route whose declared policy key is
  # enforced directly by Letflow.Plugs.Authorize (a real, present route
  # option) but is NOT backed by a matching Authorization.endpoint_policy_key/2
  # clause, because this requirement does not modify
  # lib/letflow/api/authorization.ex. Per REQ-130's design §4: "either add a
  # policy key or add to the allowlist with a stated reason" -- these four
  # are the "add to the allowlist" branch, closing what were previously
  # silent, wholly-unguarded gaps (any authenticated tenant caller, any
  # role) rather than leaving them open. Flagged for REVIEWER.
  @allowlist [
    {"POST", "/instances/:id/rebind-pins",
     "no Authorization.endpoint_policy_key/2 clause exists for this route (REQ-078/design §2.2(b)); " <>
       "route declares :InstancesCancel directly (lib/letflow/routers/instances.ex), reusing the " <>
       "same permission POST /instances/:id/cancel already requires, closing a previously wholly-open gap"},
    {"POST", "/instances/:id/reconstruct",
     "no Authorization.endpoint_policy_key/2 clause exists for this route (REQ-079/design §2.2(b)); " <>
       "route declares :InstancesCancel directly, same reasoning as /:id/rebind-pins above"},
    {"POST", "/solution-packs/export",
     "no Authorization.endpoint_policy_key/2 clause exists for this route (REQ-078/design §2.2(b)); " <>
       "route declares :DefinitionsRead directly (lib/letflow/routers/solution_packs.ex), closing a " <>
       "previously wholly-open gap"},
    {"POST", "/solution-packs/install",
     "no Authorization.endpoint_policy_key/2 clause exists for this route; route declares " <>
       ":DefinitionsCreate directly (required_permission/1 already maps it to :DefinitionsWrite), " <>
       "same reasoning as /solution-packs/export above"},
    {"POST", "/definitions/:id/validate",
     "no Authorization.endpoint_policy_key/2 clause exists for this route (REQ-078/design §1); " <>
       "route declares :DefinitionsRead directly (lib/letflow/routers/definitions.ex), closing a " <>
       "previously wholly-open gap"}
  ]

  describe "every declared route resolves to a real, present, matching policy key" do
    for router <- @routers do
      @router router

      test "#{inspect(router)}.__authz_routes__/0 -- every route matches or is allowlisted" do
        routes = @router.__authz_routes__()
        prefix = Map.fetch!(@mount_prefix, @router)

        # Every router in @routers must actually use Letflow.Api.AuthorizedRouter
        # (this would be an empty list, not a compile error, for a router that
        # forgot -- so assert non-emptiness for every router known to declare
        # at least one route; Letflow.Routers.Promotions is the one exception,
        # because REQ-077 deliberately declares every one of its ten routes
        # with the plain get/post macros (all `:Unknown`-gated, see that
        # router's own moduledoc), never authz_get/authz_post, so
        # __authz_routes__/0 stays empty even though the router is fully
        # live -- asserted separately below.
        for {method, local_path, declared_key} <- routes do
          full_path = full_path(prefix, local_path)
          real_key = Authorization.endpoint_policy_key(method, full_path)

          cond do
            real_key == declared_key and real_key != :Unknown ->
              :ok

            allowlisted?(method, full_path) ->
              :ok

            true ->
              flunk("""
              #{inspect(@router)}: route #{method} #{full_path} (router-local match pattern \
              #{inspect(local_path)}) declares policy key #{inspect(declared_key)}, but \
              Letflow.Api.Authorization.endpoint_policy_key/2 returns #{inspect(real_key)} for \
              that (method, path) pair, and this route is not on the enforcement test's \
              explicit allowlist.

              Either:
                1. add/fix the Authorization.endpoint_policy_key/2 clause so it returns \
              #{inspect(declared_key)} for #{inspect({method, full_path})}, or
                2. add {#{inspect(method)}, #{inspect(full_path)}, "<reason>"} to \
              @allowlist in this test file, with a stated reason.
              """)
          end
        end
      end
    end
  end

  test "Letflow.Routers.Promotions declares zero authz_*-macro routes (all ten REQ-077 routes are :Unknown-gated via the plain get/post macros instead, see that router's own moduledoc)" do
    assert Letflow.Routers.Promotions.__authz_routes__() == []
  end

  test "every allowlisted route is actually declared by its router (no stale allowlist entries)" do
    all_declared_full_paths =
      for router <- @routers,
          {method, local_path, _key} <- router.__authz_routes__() do
        {method, full_path(Map.fetch!(@mount_prefix, router), local_path)}
      end

    for {method, full_path, _reason} <- @allowlist do
      assert {method, full_path} in all_declared_full_paths,
             "#{method} #{full_path} is on @allowlist but no router declares it via authz_*/3 " <>
               "-- remove the stale allowlist entry"
    end
  end

  defp allowlisted?(method, full_path) do
    Enum.any?(@allowlist, fn {m, p, _reason} -> m == method and p == full_path end)
  end

  # mount prefix "" (Letflow.Routers.Identity) + local "/users" -> "/users".
  # Every other router: local "/" -> exactly the prefix (never prefix <> "/");
  # any other local path -> prefix <> local_path.
  defp full_path(prefix, "/"), do: if(prefix == "", do: "/", else: prefix)
  defp full_path(prefix, local_path), do: prefix <> local_path
end
