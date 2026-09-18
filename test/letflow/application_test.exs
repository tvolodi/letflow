defmodule Letflow.ApplicationTest do
  use ExUnit.Case, async: true

  # No Letflow.DataCase here deliberately: this test asserts on the live
  # supervision tree (process registration, Supervisor.which_children/1),
  # not on anything backed by Postgres. Pulling in the sandboxed-connection
  # test case would suggest a DB dependency that doesn't exist.

  # REQ-016 acceptance criterion 2: "lib/letflow/application.ex's children
  # list includes a supervised Oidcc.ProviderConfiguration.Worker child
  # spec, sourced from config rather than a literal hardcoded issuer URL."
  #
  # REQ-370 (design req370-multi-issuer-oidc-verification.md §4) replaced the single,
  # always-running, config-registered-name static worker with
  # Letflow.Oidc.ProviderRegistry -- a DynamicSupervisor that starts per-realm workers
  # LAZILY (on first verification attempt against that realm, design §4.1's own "why
  # lazy-on-demand" reasoning), never eagerly at boot. There is therefore no longer any
  # single Oidcc.ProviderConfiguration.Worker process "alive at boot, registered under
  # a configured name" for this test to find -- :provider_name itself was removed from
  # every config file (design §6). These three tests are rewritten to assert the new
  # shape: ProviderRegistry itself (not a per-realm worker) is the supervised,
  # always-running, config-independent child; the actual per-realm worker lifecycle is
  # covered by test/letflow/oidc/provider_registry_multi_realm_test.exs's
  # `ProviderRegistry.ensure_started/1` unit tests instead (which need real tenant
  # fixtures this DB-free file deliberately does not use).
  #
  # This proves the child spec is actually wired into the real, running
  # supervision tree Letflow.Application starts for every test run (not
  # just present as dead code in application.ex that nothing exercises).
  # Every mix test invocation already boots Letflow.Application once via
  # ExUnit's normal app-start path — this test just inspects that
  # already-running tree rather than starting anything itself, so it adds
  # no wall-clock cost beyond a couple of in-VM lookups.
  test "the OIDC ProviderRegistry is alive and registered under its own module name" do
    pid = Process.whereis(Letflow.Oidc.ProviderRegistry)

    assert is_pid(pid), "expected Letflow.Oidc.ProviderRegistry to be a registered, live process"
    assert Process.alive?(pid)
  end

  test "Letflow.Supervisor.Infrastructure supervises the OIDC ProviderRegistry as a real child, not just config-referenced" do
    # REQ-219 (design req219-supervision-layering.md §1.1) moved the OIDC
    # worker, along with the rest of the original flat 20-child list, one
    # level down from Letflow.Supervisor's own direct children into
    # Letflow.Supervisor.Infrastructure -- it is no longer a direct child
    # of Letflow.Supervisor itself, only of this named sub-supervisor.
    children = Supervisor.which_children(Letflow.Supervisor.Infrastructure)

    oidc_child =
      Enum.find(children, fn
        {_id, _pid, _type, [Letflow.Oidc.ProviderRegistry]} -> true
        _ -> false
      end)

    # A DynamicSupervisor is its own child :supervisor type, not :worker.
    assert {_id, pid, :supervisor, [Letflow.Oidc.ProviderRegistry]} = oidc_child
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "the deployment-wide oidc config (keycloak_base_url/client_id) is present and non-empty, not hardcoded" do
    oidc_config = Application.fetch_env!(:letflow, :oidc) |> Map.new()

    # REQ-370 §6: :issuer/:provider_name are retired -- keycloak_base_url is the new
    # per-realm-issuer-derivation source (Letflow.Oidc.ProviderRegistry.start_worker/2
    # builds "#{keycloak_base_url}/realms/#{realm}" from it, lazily, per realm --
    # covered directly by provider_registry_multi_realm_test.exs). client_id/
    # signing_algs remain genuinely deployment-wide (not per-realm), unchanged by
    # REQ-370. Asserting shape (config-sourced, present, non-empty) rather than
    # pinning the exact placeholder string, so this test doesn't need to change if
    # the placeholder value itself is ever swapped for another non-resolving one.
    assert %{keycloak_base_url: keycloak_base_url, client_id: client_id} = oidc_config
    assert is_binary(keycloak_base_url) and keycloak_base_url != ""
    assert is_binary(client_id) and client_id != ""
  end

  # REQ-128: lib/letflow/application.ex's start/2 reads
  # `Keyword.get(oidc_config, :allow_unsafe_http, false)` and feeds it into
  # Oidcc.ProviderConfiguration.Worker's `quirks: %{allow_unsafe_http: ...}`
  # opt, which relaxes oidcc's default HTTPS-only discovery-document
  # validation. config/dev.exs and config/test.exs deliberately set
  # `allow_unsafe_http: true` (the local Keycloak container serves discovery
  # over plain HTTP, no TLS termination in front of it) — config/prod.exs
  # deliberately does NOT set the key at all, so `Keyword.get/3`'s `false`
  # default is what holds a real deployed issuer to oidcc's safe
  # HTTPS-only validation.
  #
  # Nothing else in this suite exercises config/prod.exs specifically — every
  # other test in this file inspects the *currently loaded* env
  # (`Application.fetch_env!/2`), which under `mix test` is always
  # config/test.exs's, never prod's. This test reads config/prod.exs's own
  # source directly via Config.Reader, independent of MIX_ENV, so a future
  # accidental `allow_unsafe_http: true` added to config/prod.exs fails this
  # test instead of silently shipping a relaxed-validation production issuer.
  test "config/prod.exs's :oidc config does not set :allow_unsafe_http, so application.ex's Keyword.get default (false) holds a real production issuer to safe HTTPS-only discovery validation" do
    prod_config_path = Path.expand("../../config/prod.exs", __DIR__)

    config = Config.Reader.read!(prod_config_path)
    oidc_config = Keyword.fetch!(config[:letflow], :oidc)

    refute Keyword.has_key?(oidc_config, :allow_unsafe_http),
           "config/prod.exs must not set :allow_unsafe_http -- doing so would relax " <>
             "oidcc's HTTPS-only discovery validation for a real production issuer " <>
             "(see lib/letflow/application.ex's provider_configuration_opts comment)"
  end
end
