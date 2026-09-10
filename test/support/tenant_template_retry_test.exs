defmodule Letflow.Test.TenantTemplateRetryTest do
  @moduledoc """
  Regression coverage for ISS-0578 — design
  `lib/letflow/design/iss0578-tenant-clone-transient-connection-retry.md`:
  bounded retry-with-backoff around `clone_tenant_schema!/1`'s clone
  transaction, for the narrow class of `%Postgrex.Error{}`/
  `%DBConnection.ConnectionError{}` failure named there.

  `do_clone_with_retry/2` is a private function in
  `Letflow.Test.TenantTemplate` (design §3.1) — it is exercised here only
  through the public `clone_tenant_schema!/1` entry point, same as any other
  caller.

  No mocking library exists in this codebase (`mix.exs` has no `mox`/`meck`
  dependency), matching this codebase's own established convention
  (`test/letflow/scheduler_test.exs`, `test/letflow/sandbox_pool_test.exs`)
  of triggering `Postgrex.Error`/`DBConnection.ConnectionError` via real,
  deterministic Postgres conditions instead of an injected double:

    - retryable-then-succeeds: a real name collision (`CREATE SCHEMA` with no
      `IF NOT EXISTS` against an already-existing schema) genuinely raises
      `%Postgrex.Error{postgres: %{code: :duplicate_schema}}` on attempt 1;
      the retry's own cleanup (`DROP SCHEMA IF EXISTS ... CASCADE`) clears it
      before attempt 2, which then succeeds against real Postgres.
    - retries exhausted: `"tenant_template"` is temporarily renamed away for
      the duration of one `clone_tenant_schema!/1` call, so every attempt's
      `CREATE TABLE (LIKE "tenant_template"....)` genuinely raises
      `%Postgrex.Error{postgres: %{code: :undefined_schema}}` — a failure the
      retry's own clone-schema-only cleanup cannot clear, so it persists
      across all `@clone_max_attempts` attempts exactly as a real, sustained
      outage would. Always restored via `after`, even on assertion failure.
    - non-retryable: a real `tenant_schemas.schema_name` unique-constraint
      collision (a pre-existing `Registration` row already using the target
      clone schema name) makes step 9's `Repo.insert!/1` genuinely raise
      `Ecto.InvalidChangesetError` — a real exception, but not one
      `retryable?/1` matches — so it must propagate on the first attempt with
      no cleanup and no added latency.

  `async: false`, matching `tenant_template_test.exs` and this whole file's
  own real-schema-level DDL — not per-connection sandboxed state.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.Test.TenantTemplate
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @template_schema "tenant_template"

  # Same reasoning as tenant_template_test.exs's own setup: replay_migrations/2
  # (invoked by ensure_template!/0) checks out its OWN connection rather than
  # participating in the shared/ambient sandbox one, so `:auto` mode is
  # required before calling into this fixture at all.
  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  describe "retryable Postgrex.Error on attempt 1, success on retry" do
    test "a genuine duplicate_schema Postgrex.Error is retried and a subsequent success is returned" do
      :ok = TenantTemplate.ensure_template!()

      tenant = insert_throwaway_tenant!("iss0578-retry-success")
      on_exit(fn -> cleanup_tenant!(tenant) end)

      clone_schema = clone_schema_name(tenant.id)

      # do_clone/2's own `CREATE SCHEMA "#{clone_schema}"` step has no
      # `IF NOT EXISTS` (design §2.3 step 2) -- pre-creating it here makes
      # attempt 1 genuinely collide, raising a real
      # %Postgrex.Error{postgres: %{code: :duplicate_schema}}.
      Repo.query!(~s(CREATE SCHEMA "#{clone_schema}"))

      started_at = System.monotonic_time(:millisecond)
      assert {:ok, ^clone_schema} = TenantTemplate.clone_tenant_schema!(tenant.id)
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      # One retry happened: at least one 200ms backoff sleep elapsed. This is
      # a floor on our OWN deliberate Process.sleep/1 call, not a timing race
      # against another process, so it is not flaky the way asserting on
      # wall-clock ordering between independent processes would be.
      assert elapsed_ms >= 200

      # The clone actually completed correctly on the successful retry --
      # not just "returned {:ok, _}" but a real, queryable clone schema.
      assert %{rows: [[1]]} =
               Repo.query!(
                 "SELECT 1 FROM information_schema.schemata WHERE schema_name = $1",
                 [clone_schema]
               )
    end
  end

  describe "retries exhausted after @clone_max_attempts (3) attempts" do
    test "a persistent Postgrex.Error survives all attempts and propagates via the unchanged error tuple" do
      :ok = TenantTemplate.ensure_template!()

      tenant = insert_throwaway_tenant!("iss0578-retry-exhausted")
      on_exit(fn -> cleanup_tenant!(tenant) end)

      hidden_name = "tenant_template_iss0578_hidden_" <> hex_suffix()

      # Rename the REAL, shared "tenant_template" away for the duration of
      # this one clone_tenant_schema!/1 call, so do_clone/2's own
      # `CREATE TABLE (LIKE "tenant_template"..." )` genuinely raises a real
      # Postgrex.Error (Postgres reports the missing template schema as
      # `invalid_schema_name`, SQLSTATE 3F000 -- verified against the real
      # error this session, not assumed) on every attempt -- this failure is
      # NOT cleared by the retry's own clone-schema-only
      # `DROP SCHEMA IF EXISTS ... CASCADE`, so it persists across all 3
      # attempts exactly as a real, sustained outage would (design
      # §2.2/INV-5). Always restored, even if the assertion below fails, so
      # no other test observes a missing template.
      Repo.query!(~s(ALTER SCHEMA "#{@template_schema}" RENAME TO "#{hidden_name}"))

      try do
        started_at = System.monotonic_time(:millisecond)
        result = TenantTemplate.clone_tenant_schema!(tenant.id)
        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        assert {:error, {:clone_failed, %Postgrex.Error{postgres: %{code: :invalid_schema_name}}}} =
                 result

        # Two retries happened (3 total attempts): at least two 200ms
        # backoff sleeps elapsed.
        assert elapsed_ms >= 400
      after
        Repo.query!(~s(ALTER SCHEMA "#{hidden_name}" RENAME TO "#{@template_schema}"))
      end
    end
  end

  describe "non-retryable exception propagates immediately, no retry" do
    test "a real, non-Postgrex/non-DBConnection exception is not retried" do
      :ok = TenantTemplate.ensure_template!()

      tenant = insert_throwaway_tenant!("iss0578-non-retryable")
      on_exit(fn -> cleanup_tenant!(tenant) end)

      clone_schema = clone_schema_name(tenant.id)

      # A pre-existing Registration row already claiming clone_schema as its
      # own schema_name makes step 9's `Repo.insert!/1` (design §3.1's note:
      # do_clone/2's own Registration insert, `:626-632`) genuinely violate
      # `tenant_schemas`'s real `unique_index(:schema_name)` constraint.
      # Registration.changeset/2 declares `unique_constraint(:schema_name)`,
      # so Ecto maps that real Postgres unique violation to an INVALID
      # changeset rather than letting a raw Postgrex.Error escape --
      # Repo.insert!/1 on an invalid changeset then raises a real
      # Ecto.InvalidChangesetError, a genuinely different exception struct
      # that retryable?/1 does not match.
      colliding_tenant = insert_throwaway_tenant!("iss0578-non-retryable-collider")
      on_exit(fn -> cleanup_tenant!(colliding_tenant) end)

      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      Repo.insert_all(Registration, [
        %{
          id: Ecto.UUID.generate(),
          tenant_id: colliding_tenant.id,
          schema_name: clone_schema,
          provisioned_at: now
        }
      ])

      # Structural, not timing-based, proof of "no retry happened": a single
      # do_clone/2 attempt already does 150-250+ round trips (design §0.1),
      # so a wall-clock floor/ceiling around this call cannot distinguish
      # "one attempt" from "one attempt plus a retry" the way it reliably can
      # for the other two tests here (whose baseline work is comparatively
      # tiny next to one 200ms backoff sleep). Instead, count how many times
      # do_clone/2's own first statement (`CREATE SCHEMA "#{clone_schema}"`)
      # actually ran, via the real Ecto SQL debug log -- exactly once means
      # exactly one attempt; a second occurrence would mean this non-retryable
      # exception was (incorrectly) retried.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result = TenantTemplate.clone_tenant_schema!(tenant.id)
          assert {:error, {:clone_failed, %Ecto.InvalidChangesetError{}}} = result
        end)

      create_schema_occurrences =
        log
        |> String.split("\n")
        |> Enum.count(&String.contains?(&1, ~s(CREATE SCHEMA "#{clone_schema}")))

      assert create_schema_occurrences == 1
    end
  end

  defp insert_throwaway_tenant!(slug_prefix) do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug(slug_prefix),
        display_name: "ISS-0578 retry test (throwaway)"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp clone_schema_name(tenant_id) do
    {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant_id)
    schema_name
  end

  defp cleanup_tenant!(tenant) do
    schema_name = clone_schema_name(tenant.id)
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))

    Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
    Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
  end

  defp hex_suffix do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
