defmodule Letflow.Definitions.PromotionDigest do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Computes and verifies a deterministic SHA-256 digest over a
  `Letflow.Definitions.PromotionPlan.t()`'s `entries`. Ported from R-Co's
  `src/definition/promotion_digest.zig` (PRM-03), per
  `lib/letflow/design/promotion_plan.md` §5 (the gate-approved design this
  module implements).

  Pure — depends only on `Jason` and the `:crypto`/`Base` stdlib modules, no
  `Letflow.Repo`, no compile-time dependency on
  `Letflow.Definitions.PromotionPlan` (structural typing: any
  `%{entries: [...]}`-shaped map is accepted).

  ## `verify_digest/2` uses `:crypto.hash_equals/2`, never `==`/`=:=`

  Digest comparison in `verify_digest/2` is always
  `:crypto.hash_equals/2` (OTP's constant-time binary comparator) — never
  `Kernel.==/2` or `:erlang.=:=/2` directly on the two digest strings. This
  is INV-PRM-5: grep-checkable, `:crypto.hash_equals/2` must be the only
  comparator against a `plan_digest`-shaped value in this module.

  ## Entry-order determinism precondition (design §2.5)

  `compute_plan_digest/1` sorts JSON **object** keys during canonicalization
  but does **not** reorder JSON **arrays** — `entries` is encoded as a JSON
  array, so its element order must already be deterministic by the time it
  reaches this module.
  `Letflow.Definitions.PromotionPlan.compute_promotion_plan/5` guarantees
  this (its own moduledoc states the same cross-module dependency).

  ## A second, separate canonicaliser exists (REQ-202)

  A second, separate canonicaliser exists at
  `Letflow.Repository.Canonicaliser` (REQ-202), which DOES normalize
  numbers, for the artifact-repository content store. This module's
  `canonicalize/1` deliberately does not, to avoid changing already-stored
  promotion digests. The two must not be merged; see
  `Letflow.Repository.Canonicaliser`'s moduledoc for the full reasoning.
  """

  @doc """
  SHA-256 over the canonical JSON serialization of `plan.entries` (not the
  full plan envelope), returned as a 64-char lowercase hex string.

  Pure — cannot fail on a well-typed input, so the return type is a bare
  `String.t()`, not `{:ok, _}` (same divergence from the usual
  `:ok`/`:error` convention that `Graph.validate_graph/1` already
  establishes as precedent in this codebase).

  Algorithm, named exactly:

    1. `canonicalize/1` recursively walks `plan.entries`: a map has its keys
       sorted (`Enum.sort/1` on `Map.keys/1`) and is rebuilt as a
       `Jason.OrderedObject.new/1` so the sorted order survives into the
       emitted JSON text; a list is mapped over (order preserved, not
       sorted — array order is significant); an atom is converted via
       `Atom.to_string/1`; anything else (`String.t()`, number, boolean,
       `nil`) is returned unchanged. `nil` values are never dropped.
    2. `Jason.encode!/1` the canonicalized structure (default output has no
       insignificant whitespace).
    3. `:crypto.hash(:sha256, canonical_json_binary)` -> raw 32-byte digest.
    4. `Base.encode16/2` with `case: :lower` -> the 64-char lowercase hex
       string.
  """
  @spec compute_plan_digest(plan :: %{entries: [map()]}) :: String.t()
  def compute_plan_digest(%{entries: entries}) do
    entries
    |> canonicalize()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Verifies `digest` against `plan_or_digest`. If `plan_or_digest` is a
  binary (already in the 64-lowercase-hex-char digest shape), compares it
  directly against `digest`; otherwise (a plan-shaped map with an
  `:entries` key), calls `compute_plan_digest/1` on it first, then
  compares. Comparison is always `:crypto.hash_equals/2` (constant-time),
  never `Kernel.==/2` or `:erlang.=:=/2` directly on the two strings.
  """
  @spec verify_digest(
          digest :: String.t(),
          plan_or_digest :: %{entries: [map()]} | String.t()
        ) :: boolean()
  def verify_digest(digest, plan_or_digest) when is_binary(plan_or_digest) do
    :crypto.hash_equals(digest, plan_or_digest)
  end

  def verify_digest(digest, %{entries: _entries} = plan) do
    :crypto.hash_equals(digest, compute_plan_digest(plan))
  end

  # --- canonicalize/1 (design §5.1) ------------------------------------------

  @spec canonicalize(term()) :: term()
  defp canonicalize(value) when is_map(value) do
    value
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn key -> {key, canonicalize(Map.get(value, key))} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(value) when is_list(value) do
    Enum.map(value, &canonicalize/1)
  end

  defp canonicalize(value) when is_atom(value) and not is_boolean(value) and not is_nil(value) do
    Atom.to_string(value)
  end

  defp canonicalize(value), do: value
end
