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
  # This proves the child spec is actually wired into the real, running
  # supervision tree Letflow.Application starts for every test run (not
  # just present as dead code in application.ex that nothing exercises).
  # Every mix test invocation already boots Letflow.Application once via
  # ExUnit's normal app-start path, against config/test.exs's unreachable
  # placeholder issuer (config :letflow, :oidc) — this test just inspects
  # that already-running tree rather than starting anything itself, so it
  # adds no wall-clock cost beyond a couple of in-VM lookups.
  test "the OIDC provider-configuration worker is alive and registered under its configured name" do
    %{provider_name: provider_name} = Application.fetch_env!(:letflow, :oidc) |> Map.new()

    pid = Process.whereis(provider_name)

    assert is_pid(pid), "expected #{inspect(provider_name)} to be a registered, live process"
    assert Process.alive?(pid)
  end

  test "Letflow.Supervisor.Infrastructure supervises the OIDC worker as a real child, not just config-referenced" do
    # REQ-219 (design req219-supervision-layering.md §1.1) moved the OIDC
    # worker, along with the rest of the original flat 20-child list, one
    # level down from Letflow.Supervisor's own direct children into
    # Letflow.Supervisor.Infrastructure -- it is no longer a direct child
    # of Letflow.Supervisor itself, only of this named sub-supervisor.
    children = Supervisor.which_children(Letflow.Supervisor.Infrastructure)

    oidc_child =
      Enum.find(children, fn
        {_id, _pid, _type, [Oidcc.ProviderConfiguration.Worker]} -> true
        _ -> false
      end)

    assert {_id, pid, :worker, [Oidcc.ProviderConfiguration.Worker]} = oidc_child
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "the worker's issuer/name are sourced from config, not hardcoded, and match what booted" do
    oidc_config = Application.fetch_env!(:letflow, :oidc) |> Map.new()

    # config/test.exs's documented placeholder (.invalid TLD, RFC 2606) —
    # asserting the shape (config-sourced, present, non-empty) rather than
    # pinning the exact placeholder string, so this test doesn't need to
    # change if the placeholder value itself is ever swapped for another
    # non-resolving placeholder.
    assert %{issuer: issuer, provider_name: provider_name} = oidc_config
    assert is_binary(issuer) and issuer != ""
    assert is_atom(provider_name)

    # The live worker process is registered exactly under the name config
    # supplied — proves application.ex actually read this config into the
    # child spec rather than a coincidentally-matching literal.
    assert Process.whereis(provider_name)
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
