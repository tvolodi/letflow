defmodule Letflow.Definitions.PromotionArtifact do
  @moduledoc """
  Plain structs (no `Ecto.Schema`, no DB backing) describing the input
  `Letflow.Definitions.apply_promotion_assertion_rerun/6` consumes — the artifact
  produced upstream (plan/digest computation, REQ-036) and replayed against an
  ephemeral REQ-039 sandbox. See
  `lib/letflow/design/req040-promotion-assertion-rerun.md` §5.

  Matches the `Letflow.SandboxPool.SandboxClaim`/`Letflow.SandboxPool.FixtureLoader.FixtureRow`
  nested-struct convention: small, non-persisted value types nested in one file.

  `fixtures` reuses `Letflow.SandboxPool.FixtureLoader.FixtureRow.t()` directly — the
  exact same struct `load_fixtures_only/3` already accepts — no field-for-field
  duplicate struct is introduced here.

  `candidate_definitions` is passed through unread by
  `apply_promotion_assertion_rerun/6`'s own default assertion-replay path — it exists
  as a stable extension point for a future, custom `assertion_evaluator` (design §0(a),
  §11 OQ-2), matching R-Co's own `assertion_rerun.zig`, whose traced function body never
  reads it either.
  """

  alias Letflow.SandboxPool.FixtureLoader.FixtureRow

  defmodule Assertion do
    @moduledoc """
    One assertion to replay: its stable `id` (used both in `failing_assertion_ids` on a
    failure and as the extension point a custom `assertion_evaluator` keys off of) and
    its `payload` -- the placeholder "result" text the default evaluator echoes back
    verbatim when non-empty (design §6, a direct port of `assertion_rerun.zig`'s own
    placeholder pass/fail rule: non-empty payload counts as a pass, empty counts as a
    fail).
    """

    @enforce_keys [:id, :payload]
    defstruct [:id, :payload]

    @type t :: %__MODULE__{id: String.t(), payload: String.t()}
  end

  defmodule CandidateDefinition do
    @moduledoc """
    A candidate definition available to a custom `assertion_evaluator`, not read by
    the default one (see this file's moduledoc). Field shape mirrors what a
    process-definition candidate needs to be replayed against a sandbox: its
    `process_key`, `graph_json`, and `variable_schema`.
    """

    @enforce_keys [:process_key, :graph_json, :variable_schema]
    defstruct [:process_key, :graph_json, :variable_schema]

    @type t :: %__MODULE__{
            process_key: String.t(),
            graph_json: String.t(),
            variable_schema: String.t()
          }
  end

  @enforce_keys [
    :id,
    :assertions,
    :fixtures,
    :rng_seed,
    :non_deterministic_fields,
    :candidate_definitions
  ]
  defstruct [
    :id,
    :assertions,
    :fixtures,
    :rng_seed,
    :non_deterministic_fields,
    :candidate_definitions
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          assertions: [Assertion.t()],
          fixtures: [FixtureRow.t()],
          # Upper 32 bits derive frozen_clock_ms (design §6 -- an explicit open
          # question, §11 OQ-3, restating R-Co's own Open question 1); the full
          # 64-bit value is passed through unmodified to `assertion_evaluator_fun`
          # as `rng_seed` and also reseeds this call's own `:rand` state before
          # each of the two replay passes per assertion.
          rng_seed: non_neg_integer(),
          # Dot-path strings, e.g. "metadata.timestamp" -- stripped from both
          # replay results before the byte-level double-run comparison (design §6.1).
          non_deterministic_fields: [String.t()],
          candidate_definitions: [CandidateDefinition.t()]
        }
end
