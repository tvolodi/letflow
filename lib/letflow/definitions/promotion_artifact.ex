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
  §11 OQ-2). The default evaluator's traced function body never reads it either
  (confirmed against `assertion_rerun.zig`), so leaving it unread here is deliberate,
  not an oversight.
  """

  alias Letflow.SandboxPool.FixtureLoader.FixtureRow

  defmodule Assertion do
    @moduledoc """
    One assertion to replay: its stable `id` (used both in `failing_assertion_ids` on a
    failure and as the extension point a custom `assertion_evaluator` keys off of) and
    its `payload` -- the placeholder "result" text the default evaluator echoes back
    verbatim when non-empty (design §6): non-empty payload counts as a pass, empty
    counts as a fail (matching `assertion_rerun.zig`'s placeholder rule).
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
          # question, §11 OQ-3, not resolved here); the full
          # 64-bit value is passed through unmodified to `assertion_evaluator_fun`
          # as `rng_seed` and also reseeds this call's own `:rand` state before
          # each of the two replay passes per assertion.
          rng_seed: non_neg_integer(),
          # Dot-path strings, e.g. "metadata.timestamp" -- stripped from both
          # replay results before the byte-level double-run comparison (design §6.1).
          non_deterministic_fields: [String.t()],
          candidate_definitions: [CandidateDefinition.t()]
        }

  @doc """
  Decodes R8's request-body `artifact` object into a `t()` (NEW, REQ-077 design
  §9.4). Pure, no I/O, never raises on any input -- every branch returns a tagged
  value. `@enforce_keys` raises on a missing key if a struct is built naively, so
  every field is validated BEFORE construction, never construct-then-rescue.

  Unknown keys inside `artifact` are ignored (`Map.take/2` discipline, matching the
  outer request-body validation). On the first structural problem, returns
  `{:error, {:invalid_artifact, key_path}}` -- `key_path` is for logs/tests only;
  REQ-077 design §7.5 deliberately does not echo it into the HTTP response.
  """
  @spec from_json(map()) :: {:ok, t()} | {:error, {:invalid_artifact, field :: String.t()}}
  def from_json(%{} = json) do
    with {:ok, id} <- fetch_string(json, "id"),
         {:ok, assertions} <- fetch_list(json, "assertions", &assertion_from_json/1),
         {:ok, fixtures} <- fetch_list(json, "fixtures", &fixture_from_json/1),
         {:ok, rng_seed} <- fetch_non_neg_integer(json, "rng_seed"),
         {:ok, non_deterministic_fields} <-
           fetch_list(json, "non_deterministic_fields", &fetch_plain_string/1),
         {:ok, candidate_definitions} <-
           fetch_list(json, "candidate_definitions", &candidate_definition_from_json/1) do
      {:ok,
       %__MODULE__{
         id: id,
         assertions: assertions,
         fixtures: fixtures,
         rng_seed: rng_seed,
         non_deterministic_fields: non_deterministic_fields,
         candidate_definitions: candidate_definitions
       }}
    end
  end

  def from_json(_not_a_map), do: {:error, {:invalid_artifact, "artifact"}}

  # Every item-decoder below returns a plain (unprefixed) field name on
  # failure -- `decode_list/3` is the ONLY place a "<list-key>." prefix is
  # ever applied, so no field path can be double-prefixed.

  defp assertion_from_json(%{} = json) do
    with {:ok, id} <- fetch_string(json, "id"),
         {:ok, payload} <- fetch_string(json, "payload") do
      {:ok, %Assertion{id: id, payload: payload}}
    end
  end

  defp assertion_from_json(_), do: {:error, {:invalid_artifact, "<item>"}}

  defp fixture_from_json(%{} = json) do
    with {:ok, table_name} <- fetch_string(json, "table_name"),
         {:ok, row_json} <- fetch_string(json, "row_json") do
      {:ok, %FixtureRow{table_name: table_name, row_json: row_json}}
    end
  end

  defp fixture_from_json(_), do: {:error, {:invalid_artifact, "<item>"}}

  defp candidate_definition_from_json(%{} = json) do
    with {:ok, process_key} <- fetch_string(json, "process_key"),
         {:ok, graph_json} <- fetch_string(json, "graph_json"),
         {:ok, variable_schema} <- fetch_string(json, "variable_schema") do
      {:ok,
       %CandidateDefinition{
         process_key: process_key,
         graph_json: graph_json,
         variable_schema: variable_schema
       }}
    end
  end

  defp candidate_definition_from_json(_), do: {:error, {:invalid_artifact, "<item>"}}

  defp fetch_string(json, key) do
    case Map.fetch(json, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _missing_or_wrong_type -> {:error, {:invalid_artifact, key}}
    end
  end

  # Plain-string list items (non_deterministic_fields) -- no field name of
  # their own, so decode_list/3's "<key>.<item-field>" prefix collapses to
  # just the list key itself on failure.
  defp fetch_plain_string(value) when is_binary(value), do: {:ok, value}
  defp fetch_plain_string(_), do: {:error, {:invalid_artifact, "<item>"}}

  defp fetch_non_neg_integer(json, key) do
    case Map.fetch(json, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      _missing_or_wrong_type -> {:error, {:invalid_artifact, key}}
    end
  end

  defp fetch_list(json, key, item_decoder) do
    case Map.fetch(json, key) do
      {:ok, value} when is_list(value) -> decode_list(value, item_decoder, key)
      _missing_or_wrong_type -> {:error, {:invalid_artifact, key}}
    end
  end

  defp decode_list(items, item_decoder, key) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case item_decoder.(item) do
        {:ok, decoded} ->
          {:cont, {:ok, [decoded | acc]}}

        {:error, {:invalid_artifact, "<item>"}} ->
          {:halt, {:error, {:invalid_artifact, key}}}

        {:error, {:invalid_artifact, field}} ->
          {:halt, {:error, {:invalid_artifact, key <> "." <> field}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = error -> error
    end
  end
end
