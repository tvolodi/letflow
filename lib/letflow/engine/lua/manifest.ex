defmodule Letflow.Engine.Lua.Manifest do
  @moduledoc """
  REQ-158 (LUA-07, load-time half) — the capability-manifest data shape, its
  canonical hash, and the pure load-time validation gate that rejects a manifest
  that no longer matches its paired script artifact, before any script text
  executes. Implements `lib/letflow/design/req158-lua-manifest-validation.md`
  exactly. Completes LUA-07 alongside REQ-058
  (`lib/letflow/engine/lua_script_audit.ex`), which shipped only the
  audit-persistence half.

  A caller constructing a `Letflow.Engine.Lua.Executor.script_ref()` value
  should prefer the map shape `%{manifest: t(), script_source: binary()}` to
  pair this struct with a script's source text, rather than `Executor`'s
  legacy bare-`binary()` shape, which exists only to keep ~40 pre-existing
  test call sites (predating this requirement) compiling and running
  unchanged.

  This module has no dependency on `Letflow.Engine.Lua.Executor` or
  `Letflow.Engine.LuaScriptAudit`, and neither of those modules calls into this one
  (INV-MAN-2) — the one exception is `Letflow.Engine.Lua.Executor`'s own
  `manifest_hash` computation, which calls `compute_hash/2` here directly rather
  than duplicating this module's byte-layout logic. `validate_at_load/3` performs
  no I/O of any kind: no `Repo` call, no file read, no call into `Executor` or
  `LuaScriptAudit`. It is pure grant-set/manifest-shape logic, mirroring
  `Letflow.Engine.Lua.Capabilities`'s own "pure, independent of how or whether it
  is ever wired into a `Lua.t()`" positioning.

  ## The hash algorithm and exactly which bytes it covers (design §4)

  The hash is **SHA-256**, hex-encoded using **lowercase** hex digits — the
  identical digest algorithm and encoding `Letflow.Engine.Lua.Executor` already
  used for its own bare script-source hash before this requirement, and continues
  to use via `compute_hash/2` after it (this module is the single source of the
  byte-layout formula; `Executor` calls it rather than duplicating the logic).

  ### Framing: length-prefixed fields, not raw byte-value separators

  An earlier revision of this module joined fields with raw separator bytes
  (`0x00` between `script_id`/capabilities/`script_source`, `0x0A` between
  capability-list entries) on the assumption that those byte values "cannot
  appear inside a `String.t()` in practice." **That assumption is false.**
  `String.t()`/`binary()` values in Elixir can contain any byte, including a
  literal `0x00` or `0x0A` — nothing in `validate_shape/1` forbids it. A
  raw-separator scheme is therefore vulnerable to a delimiter-injection
  collision: e.g. `capabilities: ["a\nb", "c"]` and
  `capabilities: ["a", "b", "c"]` joined with `<<0x0A>>` both produce the
  byte-identical string `"a\nb\nc"`, even though they are two genuinely
  different capability declarations — this was found and empirically
  confirmed by SECURITY-REVIEWER.

  To close this class of collision entirely, every variable-length field is
  instead **length-prefixed**: each field is encoded as its own byte length as
  an unsigned 32-bit big-endian integer (`<<byte_size(field)::32>>`),
  immediately followed by the field's raw bytes. Because the reader always
  knows exactly how many bytes belong to a field before reading them, the byte
  boundary between fields is unambiguous regardless of what bytes appear
  inside any field — there is no separator byte value to collide with, so no
  assumption about which bytes a field "cannot practically contain" is needed.

  The digest is computed over the concatenation, in this exact order, of:

  1. `<<byte_size(manifest.script_id)::32>> <> manifest.script_id`.
  2. The manifest's capability list, canonicalized before inclusion: converted
     through `Letflow.Engine.Lua.Capabilities.new/1` and back to a list (this
     deduplicates and gives a `MapSet`-backed set), then sorted in ascending
     lexicographic (byte) order, then each entry `cap` encoded as
     `<<byte_size(cap)::32>> <> cap` and concatenated in that sort order. An
     empty capability list contributes zero bytes at this step (not a
     placeholder string).
  3. `<<byte_size(script_source)::32>> <> script_source`, `script_source`
     exactly as supplied — no trimming, no line-ending normalization, no
     encoding transformation of any kind.

  **Determinism (INV-MAN-1):** `compute_hash/2` is pure — no I/O, no randomness,
  no wall-clock or process-identity input. Equal inputs (per the canonicalization
  above — capability order and duplicates do not matter) always produce an equal
  output string. Changing `script_id`, any single capability string, or even a
  single byte of `script_source` changes the digest.

  ## R-Co field carried over vs. dropped (AC6)

  PROVENANCE (historical, not current decision authority):
  `R-Co/src/lua/manifest.zig` is **not present in this checkout** — confirmed by
  `find` returning no result for the file or for any `R-Co` directory at all, the
  same pattern already hit for `R-Co/src/lua/capabilities.zig` and
  `R-Co/src/lua/host_api/mod.zig` (REQ-157). This module's `script_id`/
  `capabilities` shape is derived entirely from `docs/requirements.yaml`
  REQ-158's own restatement of LUA-07 and REQ-157's already-built `capability()`
  type — not from reading `R-Co/src/lua/manifest.zig` directly, because that file
  is absent from this checkout. No field of the original is named here as
  "deliberately dropped," because the original was never read to know what fields
  it had. If a future SECURITY-REVIEWER or REVIEWER pass gains access to the
  original source and finds it carried additional fields (e.g. a
  version/generation number, an author/actor identity, an expiry, or a
  signature), that finding should be reconciled against this module rather than
  assumed already covered.
  """

  alias Letflow.Engine.Lua.Capabilities

  @enforce_keys [:script_id, :capabilities]
  defstruct [:script_id, :capabilities]

  @type t :: %__MODULE__{
          script_id: String.t(),
          capabilities: [Capabilities.capability()]
        }

  @type shape_error :: {:invalid_script_id, term()} | {:invalid_capabilities, term()}

  @type load_error ::
          {:manifest_mismatch, registered_hash :: String.t(), computed_hash :: String.t()}
          | {:invalid_manifest, shape_error()}

  @doc """
  Structural validation only — never consults a script artifact or a registered
  hash. `script_id` must be a non-empty `String.t()`; `capabilities` must be a
  `list()` whose every element is a `String.t()`. Exists so a malformed manifest
  (a `nil` `script_id`, or a capabilities list containing a non-string) is
  rejected with a distinct, named reason before hashing is even attempted.
  """
  @spec validate_shape(t()) :: :ok | {:error, shape_error()}
  def validate_shape(%__MODULE__{script_id: script_id, capabilities: capabilities}) do
    cond do
      not (is_binary(script_id) and script_id != "") ->
        {:error, {:invalid_script_id, script_id}}

      not (is_list(capabilities) and Enum.all?(capabilities, &is_binary/1)) ->
        {:error, {:invalid_capabilities, capabilities}}

      true ->
        :ok
    end
  end

  @doc """
  Computes the canonical manifest+script hash — see the moduledoc for the exact
  algorithm and byte layout. Does not validate `manifest`'s shape first; callers
  that need the shape guard should go through `validate_at_load/3`, which runs
  `validate_shape/1` before ever calling this function.
  """
  @spec compute_hash(t(), script_source :: binary()) :: String.t()
  def compute_hash(%__MODULE__{script_id: script_id, capabilities: capabilities}, script_source)
      when is_binary(script_id) and is_list(capabilities) and is_binary(script_source) do
    canonical_capabilities =
      capabilities
      |> Capabilities.new()
      |> Enum.to_list()
      |> Enum.sort()
      |> Enum.map(&length_prefixed/1)
      |> IO.iodata_to_binary()

    digest_input =
      length_prefixed(script_id) <> canonical_capabilities <> length_prefixed(script_source)

    :crypto.hash(:sha256, digest_input) |> Base.encode16(case: :lower)
  end

  # Encodes `field` as an unambiguous, delimiter-free frame: its byte length
  # as an unsigned 32-bit big-endian integer, followed by its raw bytes. Used
  # for every variable-length field `compute_hash/2` folds into the digest, so
  # that no separator byte value (and therefore no assumption about which
  # bytes a field "cannot practically contain") is needed to keep field
  # boundaries unambiguous — see the moduledoc's "Framing" section.
  @spec length_prefixed(binary()) :: binary()
  defp length_prefixed(field) when is_binary(field) do
    <<byte_size(field)::32>> <> field
  end

  @doc """
  Returns `Letflow.Engine.Lua.Capabilities.new(manifest.capabilities)` — the one
  and only conversion point from a manifest's declared capability list to the
  `grant_set()` type `Letflow.Engine.Lua.Platform.install/2` consumes. Whether/
  when a caller actually invokes `Platform.install/2` with this returned grant
  set is out of this requirement's scope (design §1, OQ-3).
  """
  @spec to_grant_set(t()) :: Capabilities.grant_set()
  def to_grant_set(%__MODULE__{capabilities: capabilities}) do
    Capabilities.new(capabilities)
  end

  @doc """
  The single load-time gate this requirement adds (design §3). Performs, in this
  exact order: (1) `validate_shape/1` against `manifest` — on failure, returns
  `{:error, {:invalid_manifest, shape_error}}` immediately, with no hash computed
  and no comparison attempted; (2) `compute_hash/2` over `manifest` and
  `script_source`; (3) a plain equality comparison of the computed hash against
  the caller-supplied `registered_hash` — equal means `{:ok, computed_hash}`,
  unequal means `{:error, {:manifest_mismatch, registered_hash, computed_hash}}`.

  Performs no I/O of any kind. The ordering guarantee this requirement needs
  ("rejection happens before any script text executes") is a caller-discipline
  guarantee: a caller must obtain `{:ok, manifest_hash}` from this function
  *before* it ever constructs a call to
  `Letflow.Engine.LuaScriptAudit.execute_script_for_audit/6` (the only path that
  reaches `Letflow.Engine.Lua.Executor.execute_with_manifest/2,3`, and therefore
  the only path that runs any script text at all). See the design doc §3.2 for
  the full argument.
  """
  @spec validate_at_load(
          manifest :: t(),
          script_source :: binary(),
          registered_hash :: String.t()
        ) :: {:ok, manifest_hash :: String.t()} | {:error, load_error()}
  def validate_at_load(%__MODULE__{} = manifest, script_source, registered_hash)
      when is_binary(script_source) and is_binary(registered_hash) do
    case validate_shape(manifest) do
      {:error, shape_error} ->
        {:error, {:invalid_manifest, shape_error}}

      :ok ->
        computed_hash = compute_hash(manifest, script_source)

        if computed_hash == registered_hash do
          {:ok, computed_hash}
        else
          {:error, {:manifest_mismatch, registered_hash, computed_hash}}
        end
    end
  end
end
