defmodule Letflow.Exam.QuestionSetResolver do
  @moduledoc """
  REQ-332 -- resolves a seeded, reproducible question subset from a
  configured pool/rule set (ported from `backend/internal/sessions/service.go`'s
  `CreateSession`, FR-BB35/roadmap 3.5). Authorized by
  `lib/letflow/design/req330-exam-live-session.md` §7's rule-2 module table,
  `Letflow.Exam.QuestionSetResolver` row -- read that document before
  changing this module's responsibilities.

  ## Rule-2 justification (verbatim from the design doc's table, REQ-330/0022 rule 2)

  **Why not A (a definition).** Deterministically resolves a seeded,
  shuffled, truncated question subset from a pool against rule configuration
  -- this requires threading a seeded PRNG (`:rand`) through pool selection,
  truncation, and two independent shuffle steps, which is executable logic,
  not declarative field structure.

  **Why not B (a generic platform capability).** The pool/rule/count/shuffle
  model is shaped by this vertical's exam-rule schema (pools, rule counts,
  `options_order`); no existing platform abstraction treats "resolve a
  reproducible seeded item subset from a configured pool" as a generic
  capability, and building one now would be speculative ahead of a second
  caller.

  ## Reproducibility -- what is guaranteed, and what is deliberately NOT

  `resolve/5` seeds the calling process's `:rand` state once, via
  `:rand.seed/2`, at the start of resolution: same `seed` + same
  `rules`/`pool`/shuffle flags always yields the same
  `[resolved_question()]`, in THIS implementation. Byte-identical output
  against Go's `math/rand` (the reference implementation's own PRNG) is
  explicitly **NOT** a goal and must never be asserted by a test -- Go's
  `math/rand` and Erlang's `:rand` are different PRNG algorithms with
  different internal state and different output streams for the same
  numeric seed, so "same seed" cannot mean "same bytes" across the two
  languages; only same-seed-in-Letflow-yields-same-output-in-Letflow is a
  real, checkable property.

  Never generalises beyond this vertical's own `rules :: [%{pool_id, count}]`
  shape (design doc §8) -- no second caller exists today (0022 rule 3).
  """

  @typedoc "One question available in a pool, as fed to `resolve/5` (design §8)."
  @type question_row :: %{question_id: String.t(), option_ids: [String.t()]}

  @typedoc "One materialised, resolved question (design §8)."
  @type resolved_question :: %{
          question_id: String.t(),
          sort_order: non_neg_integer(),
          options_order: [String.t()]
        }

  @typedoc "One rule: pull `count` questions from the pool named `pool_id`."
  @type rule :: %{pool_id: String.t(), count: pos_integer()}

  @doc """
  Resolves `rules` against `pool` (a map of `pool_id => [question_row()]`),
  seeding `:rand` from `seed` first (design §8). A rule whose pool has fewer
  candidates than its `count` fails the whole resolution with
  `{:error, :pool_underflow}` -- no partial result is ever returned.
  """
  @spec resolve(
          rules :: [rule()],
          pool :: %{String.t() => [question_row()]},
          shuffle_questions? :: boolean(),
          shuffle_options? :: boolean(),
          seed :: integer()
        ) :: {:ok, [resolved_question()]} | {:error, :pool_underflow}
  def resolve(rules, pool, shuffle_questions?, shuffle_options?, seed)
      when is_list(rules) and is_map(pool) and is_boolean(shuffle_questions?) and
             is_boolean(shuffle_options?) and is_integer(seed) do
    :rand.seed(:exsss, {seed, seed, seed})

    with {:ok, selected} <- pick_from_rules(rules, pool) do
      ordered = if shuffle_questions?, do: Enum.shuffle(selected), else: selected

      resolved =
        ordered
        |> Enum.with_index()
        |> Enum.map(fn {question_row, index} ->
          options_order =
            if shuffle_options?,
              do: Enum.shuffle(question_row.option_ids),
              else: question_row.option_ids

          %{
            question_id: question_row.question_id,
            sort_order: index,
            options_order: options_order
          }
        end)

      {:ok, resolved}
    end
  end

  defp pick_from_rules(rules, pool) do
    Enum.reduce_while(rules, {:ok, []}, fn %{pool_id: pool_id, count: count}, {:ok, acc} ->
      candidates = Map.get(pool, pool_id, [])

      if length(candidates) < count do
        {:halt, {:error, :pool_underflow}}
      else
        picked = candidates |> Enum.shuffle() |> Enum.take(count)
        {:cont, {:ok, acc ++ picked}}
      end
    end)
  end
end
