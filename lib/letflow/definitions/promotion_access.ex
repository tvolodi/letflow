defmodule Letflow.Definitions.PromotionAccess do
  @moduledoc """
  The real `permission_checker` for the promotion pipeline (ISS-0993 design
  section 9), replacing the allow-all `PromotionPlan.default_permission_checker/2`.

  A1 ships this module and does NOT wire it into any call site yet (A2 replaces
  every `&PromotionPlan.default_permission_checker/2` in `promotions.ex`,
  `tenants.ex` and `definitions.ex` with `checker_for(conn.assigns.auth_context)`).

  The checker is invoked as `checker.(actor_id, source_tenant_id)`
  (`Promotion`, `PromotionPlan`, `Definitions.rollback_definition_version/4`).
  It IGNORES the first argument and compares the SECOND, `source_tenant_id`,
  with the caller's tenant id: `true` iff they are equal (case-insensitively), or
  the caller holds platform scope, recomputed when the closure is built through
  `Letflow.PlatformTenant.scope_facts_for/1` (the stored flag is never read, a
  missing key cannot raise).

  Decision point OQ-2: only a source/target tenant OTHER than the caller's is
  operator-only. `Letflow.PlatformTenant.cross_tenant_promotion_operator_only?/0`
  is the single line that switches this back to the legacy allow-all pairing.
  """

  alias Letflow.PlatformTenant

  @spec checker_for(map() | term()) :: (term(), term() -> boolean())
  def checker_for(auth_context) do
    platform_scope? = PlatformTenant.scope_facts_for(auth_context).platform_scope?
    own_tenant_id = if is_map(auth_context), do: Map.get(auth_context, :tenant_id), else: nil

    fn _actor_id, source_tenant_id ->
      PlatformTenant.cross_tenant_promotion_operator_only?() == false or
        platform_scope? or own?(own_tenant_id, source_tenant_id)
    end
  end

  defp own?(own, source) when is_binary(own) and is_binary(source),
    do: String.downcase(own) == String.downcase(source)

  defp own?(_own, _source), do: false
end
