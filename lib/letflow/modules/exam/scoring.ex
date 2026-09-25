defmodule Letflow.Modules.Exam.Scoring do
  @moduledoc """
  REQ-332 -- per-question and total session scoring, ported exactly from
  `backend/internal/sessions/grading.go` (FR-BB311/roadmap 3.11). Authorized
  by `lib/letflow/design/req330-exam-live-session.md` §7's rule-2 module
  table, `Letflow.Modules.Exam.Scoring` row -- read that document, and decision
  `docs/migration/decisions/0030-exam-session-p3-bucket-verdicts.md`'s
  Finding 1, before changing this module's responsibilities.

  ## Rule-2 justification (verbatim from the design doc's table, REQ-330/0022 rule 2)

  **Why not A (a definition).** Grading arithmetic (single/true-false as
  1-or-0, multiple-choice partial credit clamped to [0,1], Likert
  weighted-polarity normalization, short-text as `pending_manual`) is
  executable per-question-type logic with an explicit
  unanswered-question-as-wrong rule and a no-correct-option error case --
  none of this is expressible as static field structure.

  **Why not B (a generic platform capability).** The five grading rules are
  specific to this vertical's question-type taxonomy
  (single/multiple/likert/short-text) and are, per decision `0030` Finding
  1, not currently reachable via the platform's one generic scripting
  mechanism (`Letflow.Engine.Lua.Executor`, unwired for node dispatch) --
  there is no generic capability to route through today.

  ## Unanswered = wrong, not skipped

  `score_session/3`'s caller (`Letflow.Modules.Exam.Session`) builds
  `answers_by_question_id` as a full outer join over `questions` -- a
  question absent from that map is passed to `score_question/2` as `answer
  = nil`, scored exactly like an empty selection. This is the Elixir-side
  equivalent of `grading.go`'s `LEFT JOIN` against the answers table: an
  absent answer becomes an empty selection, not a skipped question.

  ## No-correct-option is an ERROR, not a zero (`grading.go` AC-10)

  A `:single`/`:true_false`/`:multiple` question whose `correct_option_ids`
  is empty means the question bank itself is broken -- silently scoring
  zero would hide that defect rather than surface it. `score_question/2`
  returns `{:error, :question_without_correct_option}` for these three
  types. `:likert` and `:short_text` have no "correct option" concept (a
  weighted scale and a free-text pending-manual answer, respectively) and
  are not subject to this check.
  """

  @typedoc "The closed set of question types this vertical grades."
  @type question_type :: :single | :true_false | :multiple | :likert | :short_text

  @typedoc """
  One question fed to `score_question/2`/`score_session/3`. `likert_options`
  is required (and only meaningful) for `:likert` -- a map of
  `option_id => %{weight: float(), polarity: :positive | :negative}`, since
  the design doc's own `@spec` sketch for `question_row()` does not carry
  Likert's weight/polarity data and it must come from somewhere for the
  weighted-polarity normalisation to be computable.
  """
  @type question_row :: %{
          required(:question_id) => String.t(),
          required(:type) => question_type(),
          optional(:correct_option_ids) => [String.t()],
          optional(:likert_options) => %{
            String.t() => %{weight: float(), polarity: :positive | :negative}
          }
        }

  @type answer_row ::
          %{
            required(:selected_option_ids) => [String.t()],
            optional(:text_answer) => String.t() | nil
          }
          | nil

  @type per_question_score :: %{
          required(:question_id) => String.t(),
          required(:score) => float(),
          required(:max_score) => float(),
          required(:grading_status) => :graded | :pending_manual,
          optional(:text_answer) => String.t() | nil
        }

  @type submission_outcome :: %{
          status: :submitted | :grading_pending,
          total_score: float(),
          total_max_score: float(),
          percentage: float(),
          passed: boolean() | nil
        }

  @doc """
  Scores one question against one (possibly absent) answer. `answer == nil`
  means unanswered, graded as wrong -- never skipped.
  """
  @spec score_question(question_row(), answer_row()) ::
          {:ok, per_question_score()} | {:error, :question_without_correct_option}
  def score_question(%{type: type} = question, answer) when type in [:single, :true_false] do
    with :ok <- ensure_correct_option(question) do
      selected = selected_ids(answer)
      correct = MapSet.new(Map.get(question, :correct_option_ids, []))

      score =
        if length(selected) == 1 and MapSet.member?(correct, hd(selected)), do: 1.0, else: 0.0

      {:ok, graded(question.question_id, score, 1.0)}
    end
  end

  def score_question(%{type: :multiple} = question, answer) do
    with :ok <- ensure_correct_option(question) do
      selected = selected_ids(answer)
      correct = MapSet.new(Map.get(question, :correct_option_ids, []))
      total_correct = MapSet.size(correct)

      correct_selected = Enum.count(selected, &MapSet.member?(correct, &1))
      incorrect_selected = length(selected) - correct_selected

      numerator = max(correct_selected - incorrect_selected, 0)
      score = (numerator / total_correct) |> min(1.0) |> max(0.0)

      {:ok, graded(question.question_id, score * 1.0, 1.0)}
    end
  end

  def score_question(%{type: :likert} = question, answer) do
    likert_options = Map.get(question, :likert_options, %{})
    selected = selected_ids(answer)

    score =
      case selected do
        [option_id] ->
          case Map.fetch(likert_options, option_id) do
            {:ok, %{weight: weight, polarity: polarity}} ->
              normalize_likert(weight, polarity, likert_options)

            :error ->
              0.0
          end

        _other ->
          0.0
      end

    {:ok, graded(question.question_id, score, 1.0)}
  end

  def score_question(%{type: :short_text} = question, answer) do
    # ISS-0650: the candidate's submitted `text_answer` is carried straight
    # through into the per-question result -- never scored (there is no
    # scoring rule for free text), but no longer dropped either, so the
    # `:pending_manual` grading_status this clause always returns has an
    # actual answer attached for whatever reads it next, not a hardcoded
    # `nil`. `answer` is `nil` for an unanswered question (this module's own
    # "unanswered = wrong, not skipped" rule) -- `text_answer` is `nil` in
    # that case too.
    text_answer = text_answer_of(answer)

    {:ok,
     %{
       question_id: question.question_id,
       score: 0.0,
       max_score: 1.0,
       grading_status: :pending_manual,
       text_answer: text_answer
     }}
  end

  @doc """
  Scores every question in a session (design §8): builds one
  `per_question_score()` per question (an unanswered question scored as
  wrong via `score_question/2`'s `nil`-answer clause), sums to a session
  total, and derives `passed`/`status`. If ANY question is `:short_text`,
  `status` is `:grading_pending` and `passed` is `nil` -- a
  partially-graded session is never reported `:submitted`/`passed`.
  """
  @spec score_session(
          questions :: [question_row()],
          answers_by_question_id :: %{String.t() => answer_row()},
          passing_threshold :: float()
        ) ::
          {:ok, %{per_question: [per_question_score()], outcome: submission_outcome()}}
          | {:error, :question_without_correct_option}
  def score_session(questions, answers_by_question_id, passing_threshold) do
    questions
    |> Enum.reduce_while({:ok, []}, fn question, {:ok, acc} ->
      answer = Map.get(answers_by_question_id, question.question_id)

      case score_question(question, answer) do
        {:ok, per_question_score} -> {:cont, {:ok, [per_question_score | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed_scores} ->
        per_question = Enum.reverse(reversed_scores)

        {:ok,
         %{
           per_question: per_question,
           outcome: build_outcome(questions, per_question, passing_threshold)
         }}

      {:error, _reason} = error ->
        error
    end
  end

  # ---------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------

  defp selected_ids(nil), do: []
  defp selected_ids(%{selected_option_ids: ids}), do: ids || []

  defp text_answer_of(nil), do: nil
  defp text_answer_of(%{text_answer: text_answer}), do: text_answer
  defp text_answer_of(_answer), do: nil

  defp ensure_correct_option(question) do
    if Map.get(question, :correct_option_ids, []) == [] do
      {:error, :question_without_correct_option}
    else
      :ok
    end
  end

  defp graded(question_id, score, max_score) do
    %{question_id: question_id, score: score, max_score: max_score, grading_status: :graded}
  end

  # Weighted-polarity normalisation (grading.go's gradeLikert, ported): the
  # selected option's weight is normalised against the FULL range of
  # weights this question's options carry, then inverted for a `:negative`
  # polarity option -- a low raw weight on a negatively-worded item means
  # the same underlying sentiment as a high raw weight on a positively
  # worded one.
  defp normalize_likert(weight, polarity, likert_options) do
    weights = likert_options |> Map.values() |> Enum.map(& &1.weight)
    {min_weight, max_weight} = Enum.min_max(weights)

    if max_weight == min_weight do
      1.0
    else
      case polarity do
        :positive -> (weight - min_weight) / (max_weight - min_weight)
        :negative -> (max_weight - weight) / (max_weight - min_weight)
      end
    end
  end

  defp build_outcome(questions, per_question, passing_threshold) do
    total_score = Enum.reduce(per_question, 0.0, &(&1.score + &2))
    total_max_score = Enum.reduce(per_question, 0.0, &(&1.max_score + &2))
    percentage = if total_max_score > 0.0, do: total_score / total_max_score * 100.0, else: 0.0

    status =
      if Enum.any?(questions, &(&1.type == :short_text)), do: :grading_pending, else: :submitted

    passed = if status == :submitted, do: percentage >= passing_threshold, else: nil

    %{
      status: status,
      total_score: total_score,
      total_max_score: total_max_score,
      percentage: percentage,
      passed: passed
    }
  end
end
