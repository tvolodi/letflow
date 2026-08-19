defmodule Letflow.TenantSlugFixture do
  @moduledoc """
  Shared, collision-proof `tenants.slug` fixture generator for test-only
  `insert_tenant!/0` (or `/1`, `/2`) helpers across the suite.

  Fixes ISS-0059: `System.unique_integer([:positive, :monotonic])` is only
  unique within a single BEAM VM run. Any test module that switches
  `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` (real, non-rolled-back
  commits) can leave `tenants` rows behind if a prior `mix test` invocation
  crashed or was killed before its `on_exit` cleanup ran. A fresh VM's
  monotonic counter restarts from a low value and can reproduce a
  previously-used integer, causing `tenants_slug_index has already been
  taken` (`Ecto.InvalidChangesetError`).

  `Ecto.UUID.generate/0` is not derived from any in-process counter or
  wall-clock value that resets, so a slug built from it is collision-proof
  across VM restarts as well as within a single run.
  """

  @spec unique_slug(prefix :: String.t()) :: String.t()
  def unique_slug(prefix) when is_binary(prefix) do
    "#{prefix}-#{Ecto.UUID.generate()}"
  end
end
