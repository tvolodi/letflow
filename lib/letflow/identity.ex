defmodule Letflow.Identity do
  @moduledoc """
  Context module for the identity domain. `provision_oidc_user/3` (below) ports
  the JIT (just-in-time) user-provisioning orchestration from
  `src/oidc/jit_provisioning.zig` together with the actual upsert from
  `src/identity/registry.zig`'s `createOrGetJitOidcUser` (lines ~843-912),
  operating on REQ-015's `users` schema (`Letflow.Identity.User`).

  Matches this project's established `Letflow.RowApproval`-style pattern: a
  top-level context module in `lib/letflow/`, backed by schema files in a
  same-named subdirectory (`lib/letflow/identity/user.ex` and friends).

  See `lib/letflow/design/req018-jit-provisioning.md` for the full design this
  module implements.
  """

  alias Letflow.Identity.User
  alias Letflow.Oidc.IdentityContext
  alias Letflow.Oidc.JitProvisioningConfig
  alias Letflow.Repo

  @type provisioning_error ::
          :jit_disabled
          | :realm_tenant_mismatch
          | :external_identity_collision
          | Ecto.Changeset.t()
          | term()

  @doc """
  Idempotent upsert keyed on `(tenant_id, external_realm, external_id)`:
  returns the existing user if one already matches that triple, otherwise
  creates one. `tenant_id` is trusted as already-resolved/authoritative by the
  caller (REQ-019/021's territory) — it is not read from
  `identity_context.tenant_id` (the token-claimed hint, not the authoritative
  value) and not re-derived or cross-checked here.

  Returns `{:ok, %{user: user, created: created?}}` on success, where
  `created?` is `true` only when this call actually inserted the row (`false`
  on every subsequent call for the same identity). Always returns
  `{:error, reason}` on failure — never raises on a realistic failure path
  (JIT-disabled, changeset validation failure including a `username`
  collision, or the conflict-race fallback).
  """
  @spec provision_oidc_user(
          identity_context :: IdentityContext.t(),
          tenant_id :: Ecto.UUID.t(),
          jit_config :: JitProvisioningConfig.t()
        ) ::
          {:ok, %{user: User.t(), created: boolean()}}
          | {:error, provisioning_error()}
  def provision_oidc_user(
        %IdentityContext{} = identity_context,
        tenant_id,
        %JitProvisioningConfig{} = jit_config
      ) do
    if jit_config.enabled do
      upsert_by_external_identity(identity_context, tenant_id, jit_config)
    else
      {:error, :jit_disabled}
    end
  end

  # The upsert algorithm — select-first / INSERT ... ON CONFLICT ... DO
  # NOTHING / re-select-on-conflict, matching registry.zig lines 843-912
  # exactly. Deliberately not Ecto.Multi (this is one logical conditional
  # insert, not several writes needing transactional composition) and
  # deliberately not a naive insert-then-rescue-unique-constraint-error
  # pattern (that would change the concurrency semantics R-Co's own
  # implementation chose) — see
  # lib/letflow/design/req018-jit-provisioning.md §3.
  defp upsert_by_external_identity(identity_context, tenant_id, jit_config) do
    case get_by_external_identity(tenant_id, identity_context) do
      %User{} = existing ->
        {:ok, %{user: existing, created: false}}

      nil ->
        insert_or_fetch(identity_context, tenant_id, jit_config)
    end
  end

  defp insert_or_fetch(identity_context, tenant_id, jit_config) do
    attrs = %{
      tenant_id: tenant_id,
      external_realm: identity_context.realm,
      external_id: identity_context.external_user_id,
      username: identity_context.preferred_username,
      display_name: identity_context.display_name || identity_context.preferred_username,
      email: identity_context.email,
      status: jit_config.default_status
    }

    changeset = User.jit_changeset(%User{}, attrs)

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target:
             {:unsafe_fragment, "(external_realm, external_id) WHERE external_id IS NOT NULL"},
           returning: true
         ) do
      {:ok, %User{id: id} = inserted} ->
        # Empirically verified against real Postgres (see handoff notes):
        # with this schema's client-generated binary_id primary key,
        # Repo.insert/2 + on_conflict: :nothing + returning: true does NOT
        # distinguish "genuinely inserted" from "suppressed by ON CONFLICT DO
        # NOTHING" anywhere in the returned {:ok, struct} — every field,
        # including the primary key, is padded from the changeset's own
        # locally-known data when the database's RETURNING clause yields zero
        # rows, so a suppressed insert and a real one produce
        # struct-for-struct identical {:ok, %User{}} results. The design's
        # anticipated `id: nil` signal does not occur for this schema (it
        # would only occur for a server-generated, e.g. serial, primary key).
        # The only reliable way to tell them apart is to check whether a row
        # with our own freshly-generated id actually exists in the database —
        # Repo.get/2 on the primary key is the cheapest form of that check.
        if Repo.get(User, id) do
          {:ok, %{user: inserted, created: true}}
        else
          re_select_on_conflict(tenant_id, identity_context)
        end

      {:error, %Ecto.Changeset{}} = error ->
        error
    end
  end

  defp re_select_on_conflict(tenant_id, identity_context) do
    case get_by_external_identity(tenant_id, identity_context) do
      %User{} = existing ->
        {:ok, %{user: existing, created: false}}

      nil ->
        {:error, :external_identity_collision}
    end
  end

  defp get_by_external_identity(tenant_id, identity_context) do
    Repo.get_by(User,
      tenant_id: tenant_id,
      external_realm: identity_context.realm,
      external_id: identity_context.external_user_id
    )
  end
end
