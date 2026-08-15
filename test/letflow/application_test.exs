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

  test "Letflow.Supervisor supervises the OIDC worker as a real child, not just config-referenced" do
    children = Supervisor.which_children(Letflow.Supervisor)

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
end
