defmodule Letflow.Test.ProvisioningRepo do
  @moduledoc """
  A second, dedicated `Ecto.Repo` used ONLY by
  `Letflow.TenantFixture.provisioned_tenant!/1` to perform tenant-schema
  provisioning (`Letflow.TenantProvisioning`/`Letflow.Test.TenantTemplate`
  calls) on a connection/pool/`DBConnection.Ownership.Manager` entirely
  separate from `Letflow.Repo`'s own.

  Implements `lib/letflow/design/iss0113-tenant-fixture-sandbox-restore-opt-in.md`
  §10 exactly — do not add behavior beyond it without a design update.

  ## Why this exists (ISS-0480)

  `Ecto.Adapters.SQL.Sandbox.mode/2`'s check-in-everyone effect
  (`DBConnection.Ownership.Manager.handle_call({:mode, mode}, ...)`) is scoped
  to the ownership-manager process for the SPECIFIC repo the call targets —
  one manager per pool, one pool per `Ecto.Repo`. Before this module existed,
  `provisioned_tenant!/1`'s own `Sandbox.mode(Letflow.Repo, :auto)` call
  reached into `Letflow.Repo`'s single shared pool and could check in a
  connection belonging to a wholly unrelated, concurrently-running
  `async: true` test that never called `TenantFixture` at all (ISS-0480).
  Provisioning now runs against THIS repo's own pool instead, so a
  `Sandbox.mode(Letflow.Test.ProvisioningRepo, :auto)` call structurally
  cannot reach anything checked out from `Letflow.Repo`.

  Test-only (`test/support/`, compiled under `elixirc_paths(:test)` per
  `mix.exs`, matching `Letflow.TenantFixture`'s and
  `Letflow.Test.TenantTemplate`'s own established placement) — **not** part
  of the shipped application, **never** referenced from `lib/`, **never**
  added to `lib/letflow/application.ex`'s supervision tree (design §10.3.3).
  Started explicitly in `test/test_helper.exs`, test-only boot sequencing,
  mirroring how `Letflow.Repo` itself is already supervised for tests today
  (via `Letflow.Application`'s own supervised child) without this repo being
  part of that production tree.

  No custom function is added here — this module exists purely as a second
  named `Ecto.Repo` with its own pool, config, and ownership manager;
  `TenantFixture` reaches it via `Ecto.Repo.put_dynamic_repo/1` (design
  §10.3.2), not via any function defined on this module.
  """

  use Ecto.Repo,
    otp_app: :letflow,
    adapter: Ecto.Adapters.Postgres
end
