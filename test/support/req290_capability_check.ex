defmodule Letflow.Support.Req290CapabilityCheck do
  @moduledoc """
  REQ-290 (AC3) reference implementation of `req289-expr-conformance-corpus.md` §13's
  client-behaviour contract for `priv/expr_conformance/manifest.json`'s
  `capabilities` marker: fail loudly on an unrecognised capability, never silently
  skip and never silently guess.

  No TypeScript/Dart client exists yet (REQ-293/REQ-294, out of this requirement's
  scope), so this small, pure Elixir module proves the contract is actually
  implementable and actually distinguishable from its two forbidden failure modes
  (SKIP, GUESS) — see `test/support/req290_capability_check_test.exs`. Test-support
  fixture code only (compiled for `Mix.env() == :test`, per `mix.exs`'s
  `elixirc_paths/1`), not production `lib/` code — same convention as
  `test/support/req072_probe.ex`.
  """

  @typedoc "Result of comparing a manifest's declared capabilities against a client's own."
  @type compatibility :: :compatible | {:incompatible, unsupported :: [String.t()]}

  @doc """
  Compares `manifest_capabilities` (as read from `manifest.json`'s `capabilities`
  array) against `client_capabilities` (the tags this client statically knows how to
  evaluate). Returns `:compatible` when every manifest capability is one the client
  supports, or `{:incompatible, unsupported}` naming exactly the unsupported tags.
  """
  @spec check_compatibility(
          client_capabilities :: MapSet.t(String.t()),
          manifest_capabilities :: [String.t()]
        ) :: compatibility()
  def check_compatibility(client_capabilities, manifest_capabilities) do
    unsupported =
      manifest_capabilities
      |> Enum.reject(&MapSet.member?(client_capabilities, &1))

    case unsupported do
      [] -> :compatible
      _ -> {:incompatible, unsupported}
    end
  end

  @doc """
  Runs `evaluate_thunk` only when `compatibility` is `:compatible`, returning its
  result unchanged. On `{:incompatible, unsupported}`, `evaluate_thunk` is NEVER
  invoked and this returns `{:error, {:stale_version, unsupported}}` instead — the
  fail-loud outcome. The return type is a closed 2-arm union: there is no third arm
  for "returned nothing" (skip) or "returned a substituted default without the
  `:stale_version` tag" (guess) that satisfies this `@spec`.
  """
  @spec evaluate_or_fail(
          compatibility :: compatibility(),
          evaluate_thunk :: (-> {:ok, term()} | {:error, term()})
        ) :: {:ok, term()} | {:error, {:stale_version, unsupported :: [String.t()]}}
  def evaluate_or_fail(:compatible, evaluate_thunk) when is_function(evaluate_thunk, 0) do
    evaluate_thunk.()
  end

  def evaluate_or_fail({:incompatible, unsupported}, evaluate_thunk)
      when is_function(evaluate_thunk, 0) do
    {:error, {:stale_version, unsupported}}
  end
end
