defmodule Letflow.Engine.LuaScriptAudit do
  @moduledoc """
  REQ-058 (LUA-07) — Lua script execution audit persistence path. Implements
  `lib/letflow/design/req058-lua-script-audit.md` exactly.

  This module is a MINIMAL, deliberately narrow engine-side call path that (a) invokes an
  injected script executor and (b) persists the resulting manifest hash to a queryable
  audit record.

  It is NOT the SERVICE_TASK script-execution handler and must not be called from
  processServiceTaskRuntimeInTx or any other normal process-execution flow. The general
  SERVICE_TASK-with-script integration (R-Co's src/design/lua-integration.md section 25)
  remains unbuilt; when it lands, that work supersedes this function rather than building
  on it.

  The LUA EXECUTION RUNTIME ITSELF is S5 scope (docs/migration/stage-5-scripting-plugins.md).
  This module ports only the audit-persistence path, against an injected Executor behaviour
  (see Executor below) -- not a real Lua interpreter. mix.exs gains no Lua/NIF dependency
  here. S5's own build-vs-bind decision record (Elixir NIF/Port wrapping a real Lua runtime
  vs. reimplementing) is a prerequisite for whoever supplies a real Executor implementation;
  this module does not pre-empt that choice.

  ## Ordering (design §5, INV-LSA-1)

  `instance_id` is validated (non-`nil`, well-formed UUID) BEFORE `executor` is ever
  invoked. An invalid `instance_id` short-circuits with `{:error, :invalid_instance_id}`
  and results in zero executor calls and zero audit rows.

  ## Manifest hash mismatch (design §5 step 3, INV-LSA-2)

  A mismatch between the executor's reported `manifest_hash` and the caller-supplied
  `registered_hash` returns a distinct, pattern-matchable
  `{:manifest_hash_mismatch, registered_hash, actual_hash}` error and writes no audit
  row — this is the whole point of persisting a manifest hash; a mismatch must never be
  silently recorded as if it were a normal, trusted execution.

  ## No caller yet (design §1, §9 OQ-4)

  As of this requirement, nothing in this codebase calls `execute_script_for_audit/6` —
  this requirement builds the audit-path function and its storage only.
  """

  import Ecto.Changeset

  alias Letflow.Engine.LuaScriptAudit.{AuditRecord, Executor}
  alias Letflow.Repo

  defmodule AuditRecord do
    @moduledoc """
    `Ecto.Schema` for the `lua_script_execution_audit` table (design §3). Schema-per-tenant
    — no `@schema_prefix`; every `Repo` call passes `prefix:` explicitly (design §3, §5).
    No `tenant_id` column (Decision 0006 D2 — the per-tenant Postgres schema boundary
    alone provides tenant isolation).
    """

    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "lua_script_execution_audit" do
      field(:instance_id, Ecto.UUID)
      field(:manifest_hash, :string)
      field(:actor_id, Ecto.UUID)
      field(:executed_at, :utc_datetime_usec, read_after_writes: true)

      timestamps(type: :utc_datetime_usec)
    end

    @type t :: %__MODULE__{}

    @doc """
    Structural changeset for the single insert this module ever performs (design §3). Does
    no I/O.
    """
    @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
    def insert_changeset(record, attrs) do
      record
      |> cast(attrs, [:instance_id, :manifest_hash, :actor_id])
      |> validate_required([:instance_id, :manifest_hash, :actor_id])
    end
  end

  defmodule Executor do
    @moduledoc """
    Injected script-execution dependency (design §4). Implementations are ordinary
    modules `use`ing `@behaviour Letflow.Engine.LuaScriptAudit.Executor`, passed to
    `execute_script_for_audit/6` as a plain module atom — never resolved via
    `Application.get_env/2`. No default/no-op implementation ships in this file; S5
    builds the real one, TEST-DESIGNER builds its own test-double module(s).
    """

    @typedoc """
    Deliberately opaque — S5's build-vs-bind decision
    (docs/migration/stage-5-scripting-plugins.md) has not been made, so this behaviour
    cannot know whether a real executor expects a script body string, a compiled
    bytecode reference, a file path, or something else. Pinning a concrete type here
    would silently pre-empt that decision.
    """
    @type script_ref :: term()

    @type manifest_result :: %{manifest_hash: String.t()}

    @doc """
    Executes `script_ref` and reports the manifest hash it produced.
    `execute_script_for_audit/6` independently compares the returned `manifest_hash`
    against its own caller-supplied `registered_hash` regardless of what this callback
    does with `registered_hash` itself (design §4) — a lazy/non-conforming
    implementation cannot bypass the mismatch check.
    """
    @callback execute_with_manifest(script_ref(), registered_hash :: String.t()) ::
                {:ok, manifest_result()} | {:error, term()}
  end

  @typedoc "Every distinct, pattern-matchable failure `execute_script_for_audit/6` returns."
  @type error_reason ::
          :missing_prefix
          | :invalid_instance_id
          | {:manifest_hash_mismatch, registered_hash :: String.t(), actual_hash :: String.t()}
          | {:executor_failed, term()}
          | {:insert_failed, Ecto.Changeset.t()}

  @doc """
  Invokes `executor.execute_with_manifest/2` and persists the resulting manifest hash to
  a queryable `AuditRecord` row (design §5). `instance_id` is validated strictly before
  `executor` is ever touched (INV-LSA-1). A manifest hash mismatch is a distinct,
  pattern-matchable error and writes no row (INV-LSA-2). `opts[:prefix]` (the tenant
  Postgres schema name) is required — there is no `public`-schema fallback (INV-LSA-6).
  """
  @spec execute_script_for_audit(
          executor :: module(),
          instance_id :: String.t() | nil,
          script_ref :: Executor.script_ref(),
          registered_hash :: String.t(),
          actor_id :: Ecto.UUID.t(),
          opts :: [prefix: String.t()]
        ) :: {:ok, AuditRecord.t()} | {:error, error_reason()}
  def execute_script_for_audit(executor, instance_id, script_ref, registered_hash, actor_id, opts)
      when is_atom(executor) do
    with {:ok, prefix} <- validate_prefix(opts),
         {:ok, validated_instance_id} <- validate_instance_id(instance_id),
         {:ok, %{manifest_hash: actual_hash}} <-
           executor_result(executor, script_ref, registered_hash),
         :ok <- verify_manifest_hash(registered_hash, actual_hash) do
      insert_audit_record(validated_instance_id, actual_hash, actor_id, prefix)
    end
  end

  # Step 0 (INV-LSA-6) -- opts[:prefix] must be present and non-nil BEFORE the executor
  # is ever invoked or any insert happens. There is no public-schema fallback: unlike
  # `Repo.insert(prefix: opts[:prefix])`, which silently resolves a missing/nil
  # `:prefix` to Ecto's default schema (see lib/letflow/event_store.ex:176's identical
  # fail-closed precedent), this fails closed with a distinct typed error and performs
  # zero writes.
  defp validate_prefix(opts) do
    case Keyword.fetch(opts, :prefix) do
      {:ok, prefix} when is_binary(prefix) and prefix != "" -> {:ok, prefix}
      _ -> {:error, :missing_prefix}
    end
  end

  # Step 1 (design §5) -- executor is never touched on this path (INV-LSA-1).
  defp validate_instance_id(nil), do: {:error, :invalid_instance_id}

  defp validate_instance_id(instance_id) when is_binary(instance_id) do
    case Ecto.UUID.cast(instance_id) do
      {:ok, cast_id} -> {:ok, cast_id}
      :error -> {:error, :invalid_instance_id}
    end
  end

  defp validate_instance_id(_other), do: {:error, :invalid_instance_id}

  # Step 2 (design §5) -- the sole I/O this function delegates to something outside
  # itself.
  defp executor_result(executor, script_ref, registered_hash) do
    case executor.execute_with_manifest(script_ref, registered_hash) do
      {:ok, %{manifest_hash: _} = result} -> {:ok, result}
      {:error, reason} -> {:error, {:executor_failed, reason}}
    end
  end

  # Step 3 (design §5) -- distinct, pattern-matchable mismatch error (INV-LSA-2). No
  # audit row is written on this path.
  defp verify_manifest_hash(registered_hash, actual_hash) when actual_hash == registered_hash,
    do: :ok

  defp verify_manifest_hash(registered_hash, actual_hash),
    do: {:error, {:manifest_hash_mismatch, registered_hash, actual_hash}}

  # Step 3 continued -- exactly one insert path (INV-LSA-3). `prefix` was already
  # validated present/non-nil by `validate_prefix/1` above.
  defp insert_audit_record(instance_id, manifest_hash, actor_id, prefix) do
    attrs = %{instance_id: instance_id, manifest_hash: manifest_hash, actor_id: actor_id}

    %AuditRecord{}
    |> AuditRecord.insert_changeset(attrs)
    |> Repo.insert(prefix: prefix)
    |> case do
      {:ok, record} -> {:ok, record}
      {:error, changeset} -> {:error, {:insert_failed, changeset}}
    end
  end
end
