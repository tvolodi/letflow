defmodule Letflow.Engine.Expr do
  @moduledoc """
  Pure CEL-subset expression evaluator — ports the subset of R-Co's
  `src/expr/` surface that `transition.zig`'s `evaluateGatewayCondition()`
  (~L1118, R-Co's EXP-102 adapter) actually needs for `:EXCLUSIVE_GATEWAY`
  edge conditions (REQ-050, `lib/letflow/design/req050-exclusive-gateway-cel.md`
  §4). It ports variable references, the 6 comparison operators, boolean
  `and`/`or`/`not`, and literal values (numbers, strings, booleans, `null`) —
  not a full port of all 7 `src/expr/` files (`lexer.zig`, `parser.zig`,
  `ast.zig`, `evaluator.zig`, `error.zig`, `mod.zig`, `benchmark.zig`).
  `benchmark.zig` in particular is a Zig benchmarking harness with no Elixir
  equivalent and is not ported at all. A fuller expression surface, if a
  later stage needs one, extends this module rather than replacing it
  (`docs/migration/stage-3-instance-engine.md`).

  ## Purity and determinism (AC8)

  Every function here is a pure function of its typed arguments alone — no
  `Letflow.Repo`, no `Logger.*`, no clock read, no `:rand`/`:crypto`, no
  `File.*`/HTTP/process-mailbox call anywhere in `translate_cel_to_expr/1`,
  `parse/1`, `eval/2`, or `evaluate_condition/2`'s call graphs. Two calls
  with `==`-equal arguments return `==`-equal results, both times — the same
  guarantee `transition.zig`'s own header states for the ported reference:
  "`expr.parse()` and `expr.evaluate()` are pure computations."

  Verification (grep/`mix xref`-checkable, matching
  `Letflow.Engine.Transition`'s own precedent):

  ```bash
  grep -n "Repo\\.\\|Logger\\.\\|DateTime\\.\\|System\\.os_time\\|System\\.system_time\\|HTTPoison\\|Req\\.\\|File\\.\\|:rand\\.\\|:crypto\\." lib/letflow/engine/expr.ex
  ```

  must return zero matches.
  """

  @typedoc "A literal or resolved value in this expr subset."
  @type value :: number() | String.t() | boolean() | nil

  @typedoc "The 6 comparison operators this subset's grammar supports."
  @type cmp_op :: :eq | :neq | :lt | :lte | :gt | :gte

  @typedoc """
  Internal expr-syntax AST. `{:var, path}` holds a dotted-field path with
  the leading `variables.` token already stripped by `translate_cel_to_expr/1`
  — `path` is a non-empty list of `String.t()` field segments.
  """
  @type ast ::
          {:lit, value()}
          | {:var, path :: [String.t()]}
          | {:not, ast()}
          | {:and, ast(), ast()}
          | {:or, ast(), ast()}
          | {:cmp, cmp_op(), ast(), ast()}

  # Function-call-syntax markers that identify CEL macros, type-conversion
  # functions, and collection functions in one pass (design doc §4.4) --
  # they all share `name(` call syntax. `in` is checked separately below
  # since it is a bare keyword, not a `name(` call.
  @unsupported_call_markers [
    "has(",
    "matches(",
    "all(",
    "exists_one(",
    "exists(",
    "int(",
    "uint(",
    "double(",
    "string(",
    "bool(",
    "bytes(",
    "duration(",
    "timestamp(",
    "size(",
    "map(",
    "map{",
    "filter("
  ]

  @doc """
  Translates a CEL-syntax condition string (as authored in a definition
  graph's `Edge.t().condition`) into this module's expr-syntax grammar.
  Pure string-level rewrite — never touches `variables`, never parses, never
  evaluates. Returns `{:error, :unsupported_cel_feature}` if `cel_condition`
  uses a macro, a type-conversion function, a collection function, or the
  ternary operator (design doc §4.4, ported from `hasCelUnsupportedFeatures()`)
  without applying any rewrite; returns `{:error, :translate_error}` for
  input the 4 rewrite rules cannot produce well-formed expr syntax from
  (design doc §4.2 step 3, this module's own defensive addition).
  """
  @spec translate_cel_to_expr(cel_condition :: String.t()) ::
          {:ok, expr_source :: String.t()}
          | {:error, :unsupported_cel_feature}
          | {:error, :translate_error}
  def translate_cel_to_expr(cel_condition) when is_binary(cel_condition) do
    trimmed = String.trim(cel_condition)

    cond do
      trimmed == "" ->
        {:error, :translate_error}

      unsupported_cel_feature?(cel_condition) ->
        {:error, :unsupported_cel_feature}

      true ->
        expr_source =
          cel_condition
          |> strip_variables_prefix()
          |> String.replace("&&", "and")
          |> String.replace("||", "or")
          |> rewrite_not()

        if String.trim(expr_source) == "" do
          {:error, :translate_error}
        else
          {:ok, expr_source}
        end
    end
  end

  def translate_cel_to_expr(_cel_condition), do: {:error, :translate_error}

  # Rule 1: strip every `variables.` prefix. A bare `variables` with no
  # field after the dot is left as-is here; the resulting expr source (if
  # otherwise empty or malformed) is caught by the empty-source check above
  # or by parse/1's own error path -- this module never raises either way.
  @spec strip_variables_prefix(String.t()) :: String.t()
  defp strip_variables_prefix(cel_condition) do
    String.replace(cel_condition, "variables.", "")
  end

  # Rule 4: replace every `!` that is NOT immediately followed by `=`, with
  # `not `. `!=` passes through unchanged -- implemented as a negative-
  # lookahead regex per design doc §4.3's explicit carve-out.
  @spec rewrite_not(String.t()) :: String.t()
  defp rewrite_not(expr_source) do
    Regex.replace(~r/!(?!=)/, expr_source, "not ")
  end

  # Design doc §4.4: a `name(` call-syntax marker catches macros,
  # type-conversion functions, and collection functions in one pass; `in`
  # is a separate bare-keyword check; `?` outside a quoted string span
  # signals the ternary operator. All markers are checked against the
  # ORIGINAL, untranslated cel_condition, before any rewrite rule runs.
  @spec unsupported_cel_feature?(String.t()) :: boolean()
  defp unsupported_cel_feature?(cel_condition) do
    Enum.any?(@unsupported_call_markers, &String.contains?(cel_condition, &1)) or
      contains_in_operator?(cel_condition) or
      contains_bare_question_mark?(cel_condition)
  end

  # Detects the CEL `in` membership operator as a standalone word (not part
  # of a longer identifier like `printer` or a quoted string).
  @spec contains_in_operator?(String.t()) :: boolean()
  defp contains_in_operator?(cel_condition) do
    Regex.match?(~r/(?<![A-Za-z0-9_."'])in(?![A-Za-z0-9_])/, strip_string_literals(cel_condition))
  end

  # Detects a bare `?` (the ternary operator) outside any quoted-string
  # span -- a literal `?` inside a CEL string value must not false-positive.
  @spec contains_bare_question_mark?(String.t()) :: boolean()
  defp contains_bare_question_mark?(cel_condition) do
    String.contains?(strip_string_literals(cel_condition), "?")
  end

  # Removes the contents of every single- or double-quoted string literal
  # span (replacing each with an empty quoted string), so unsupported-
  # feature markers are only ever detected outside string-literal text.
  @spec strip_string_literals(String.t()) :: String.t()
  defp strip_string_literals(cel_condition) do
    cel_condition
    |> (&Regex.replace(~r/"([^"\\]|\\.)*"/, &1, "\"\"")).()
    |> (&Regex.replace(~r/'([^'\\]|\\.)*'/, &1, "''")).()
  end

  @doc """
  Parses an expr-syntax string (as produced by `translate_cel_to_expr/1`)
  into this module's internal `ast()`. A small recursive-descent parser over
  the grammar design doc §4.5 states (`or_expr` > `and_expr` > `not_expr` >
  `cmp_expr` > `operand`, lowest-to-highest precedence `or`, `and`, `not`,
  comparison, primary).
  """
  @spec parse(expr_source :: String.t()) ::
          {:ok, ast()} | {:error, {:parse_error, reason :: term()}}
  def parse(expr_source) when is_binary(expr_source) do
    with {:ok, tokens} <- tokenize(expr_source),
         {:ok, ast, []} <- parse_or(tokens) do
      {:ok, ast}
    else
      {:ok, _ast, leftover} -> {:error, {:parse_error, {:trailing_input, leftover}}}
      {:error, reason} -> {:error, {:parse_error, reason}}
    end
  end

  # --- tokenizer ---------------------------------------------------------

  @spec tokenize(String.t()) :: {:ok, [term()]} | {:error, term()}
  defp tokenize(expr_source) do
    do_tokenize(expr_source, [])
  end

  @spec do_tokenize(String.t(), [term()]) :: {:ok, [term()]} | {:error, term()}
  defp do_tokenize(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp do_tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r] do
    do_tokenize(rest, acc)
  end

  defp do_tokenize(<<"(", rest::binary>>, acc), do: do_tokenize(rest, [{:lparen} | acc])
  defp do_tokenize(<<")", rest::binary>>, acc), do: do_tokenize(rest, [{:rparen} | acc])

  defp do_tokenize(<<"==", rest::binary>>, acc), do: do_tokenize(rest, [{:cmp_op, :eq} | acc])
  defp do_tokenize(<<"!=", rest::binary>>, acc), do: do_tokenize(rest, [{:cmp_op, :neq} | acc])
  defp do_tokenize(<<"<=", rest::binary>>, acc), do: do_tokenize(rest, [{:cmp_op, :lte} | acc])
  defp do_tokenize(<<">=", rest::binary>>, acc), do: do_tokenize(rest, [{:cmp_op, :gte} | acc])
  defp do_tokenize(<<"<", rest::binary>>, acc), do: do_tokenize(rest, [{:cmp_op, :lt} | acc])
  defp do_tokenize(<<">", rest::binary>>, acc), do: do_tokenize(rest, [{:cmp_op, :gt} | acc])

  defp do_tokenize(<<"\"", _::binary>> = input, acc), do: tokenize_string(input, ?", acc)
  defp do_tokenize(<<"'", _::binary>> = input, acc), do: tokenize_string(input, ?', acc)

  defp do_tokenize(<<c, _::binary>> = input, acc) when c in ?0..?9 do
    # Same capture-group shape as the identifier clause above: `(\.\d+)?`
    # makes any decimal literal (e.g. "3.14") return a 2-element
    # `[match, decimal_part]` list, not `[match]` -- matching on `[match | _]`
    # handles both integer and decimal literals uniformly.
    case Regex.run(~r/\A-?\d+(\.\d+)?/, input) do
      [match | _] ->
        rest = binary_part(input, byte_size(match), byte_size(input) - byte_size(match))

        number =
          if String.contains?(match, "."),
            do: String.to_float(match),
            else: String.to_integer(match)

        do_tokenize(rest, [{:lit, number} | acc])

      nil ->
        {:error, {:invalid_number, input}}
    end
  end

  defp do_tokenize(<<c, _::binary>> = input, acc) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    # `Regex.run/2` returns the full match plus one entry per capture group --
    # the trailing `(\.[A-Za-z_][A-Za-z0-9_]*)*` group means any dotted,
    # multi-segment identifier (e.g. "order.status") yields a 2-element list
    # (`[match, last_dot_segment]`), not the 1-element `[match]` a bare
    # identifier produces. Matching on `[match | _]` (full match only, capture
    # groups discarded) handles both shapes uniformly instead of raising on
    # every multi-segment path -- see ISS-0086/GH#303.
    case Regex.run(~r/\A[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*/, input) do
      [match | _] ->
        rest = binary_part(input, byte_size(match), byte_size(input) - byte_size(match))
        do_tokenize(rest, [identifier_token(match) | acc])

      nil ->
        {:error, {:invalid_identifier, input}}
    end
  end

  defp do_tokenize(<<c, _::binary>>, _acc), do: {:error, {:unexpected_char, <<c>>}}

  @spec identifier_token(String.t()) :: term()
  defp identifier_token("and"), do: {:and}
  defp identifier_token("or"), do: {:or}
  defp identifier_token("not"), do: {:not}
  defp identifier_token("true"), do: {:lit, true}
  defp identifier_token("false"), do: {:lit, false}
  defp identifier_token("null"), do: {:lit, nil}
  defp identifier_token(ident), do: {:var, String.split(ident, ".")}

  @spec tokenize_string(String.t(), byte(), [term()]) :: {:ok, [term()]} | {:error, term()}
  defp tokenize_string(<<quote, rest::binary>>, quote, acc) do
    case scan_string_literal(rest, quote, <<>>) do
      {:ok, content, remainder} -> do_tokenize(remainder, [{:lit, content} | acc])
      :error -> {:error, {:unterminated_string, rest}}
    end
  end

  # Scans a string literal body up to its closing, un-escaped `quote` byte. A
  # backslash immediately followed by `quote` is consumed as one escaped-quote
  # unit -- unescaped into the literal's value rather than treated as the
  # terminator -- mirroring `strip_string_literals/1`'s `\\.` regex
  # alternative, which the CEL-detection stage already assumed. Any other
  # backslash sequence passes through unchanged (no broader escape-sequence
  # grammar, e.g. `\n`, is implied or needed here). Before this, the
  # tokenizer had no escape handling at all and terminated on the first raw
  # quote byte regardless of a preceding backslash, so ANY string literal
  # containing an escaped quote of its own delimiter failed to parse
  # (ISS-0087/GH#304 -- discovered while investigating a narrower ternary-
  # detection question; this is the actual, broader bug behind it).
  @spec scan_string_literal(String.t(), byte(), binary()) ::
          {:ok, String.t(), String.t()} | :error
  defp scan_string_literal(<<quote, remainder::binary>>, quote, content),
    do: {:ok, content, remainder}

  defp scan_string_literal(<<?\\, quote, rest::binary>>, quote, content),
    do: scan_string_literal(rest, quote, <<content::binary, quote>>)

  defp scan_string_literal(<<c, rest::binary>>, quote, content),
    do: scan_string_literal(rest, quote, <<content::binary, c>>)

  defp scan_string_literal(<<>>, _quote, _content), do: :error

  # --- recursive-descent parser -------------------------------------------

  @spec parse_or([term()]) :: {:ok, ast(), [term()]} | {:error, term()}
  defp parse_or(tokens) do
    with {:ok, left, rest} <- parse_and(tokens) do
      parse_or_rest(left, rest)
    end
  end

  defp parse_or_rest(left, [{:or} | rest]) do
    with {:ok, right, rest2} <- parse_and(rest) do
      parse_or_rest({:or, left, right}, rest2)
    end
  end

  defp parse_or_rest(left, rest), do: {:ok, left, rest}

  @spec parse_and([term()]) :: {:ok, ast(), [term()]} | {:error, term()}
  defp parse_and(tokens) do
    with {:ok, left, rest} <- parse_not(tokens) do
      parse_and_rest(left, rest)
    end
  end

  defp parse_and_rest(left, [{:and} | rest]) do
    with {:ok, right, rest2} <- parse_not(rest) do
      parse_and_rest({:and, left, right}, rest2)
    end
  end

  defp parse_and_rest(left, rest), do: {:ok, left, rest}

  @spec parse_not([term()]) :: {:ok, ast(), [term()]} | {:error, term()}
  defp parse_not([{:not} | rest]) do
    with {:ok, sub, rest2} <- parse_not(rest) do
      {:ok, {:not, sub}, rest2}
    end
  end

  defp parse_not(tokens), do: parse_cmp(tokens)

  @spec parse_cmp([term()]) :: {:ok, ast(), [term()]} | {:error, term()}
  defp parse_cmp(tokens) do
    with {:ok, left, rest} <- parse_operand(tokens) do
      case rest do
        [{:cmp_op, op} | rest2] ->
          with {:ok, right, rest3} <- parse_operand(rest2) do
            {:ok, {:cmp, op, left, right}, rest3}
          end

        _ ->
          {:ok, left, rest}
      end
    end
  end

  @spec parse_operand([term()]) :: {:ok, ast(), [term()]} | {:error, term()}
  defp parse_operand([{:lparen} | rest]) do
    with {:ok, inner, rest2} <- parse_or(rest) do
      case rest2 do
        [{:rparen} | rest3] -> {:ok, inner, rest3}
        other -> {:error, {:expected_rparen, other}}
      end
    end
  end

  defp parse_operand([{:lit, v} | rest]), do: {:ok, {:lit, v}, rest}
  defp parse_operand([{:var, path} | rest]), do: {:ok, {:var, path}, rest}
  defp parse_operand([]), do: {:error, :unexpected_end_of_input}
  defp parse_operand([tok | _rest]), do: {:error, {:unexpected_token, tok}}

  @doc """
  Evaluates `ast` against `variables`, resolving `{:var, path}` nodes via
  successive string-keyed `Map.get/2`-shaped lookups. An undefined variable
  (missing key at any step of `path`) is an eval error, not a nil-propagating
  case; `and`/`or`/`not`/ordering-comparison operands that are not the
  required type are also eval errors (design doc §4.6).
  """
  @spec eval(ast(), variables :: map()) ::
          {:ok, value()} | {:error, {:eval_error, reason :: term()}}
  def eval({:lit, v}, _variables), do: {:ok, v}

  def eval({:var, path}, variables) when is_map(variables) do
    resolve_var(path, variables, path)
  end

  def eval({:not, sub}, variables) do
    with {:ok, v} <- eval(sub, variables) do
      if is_boolean(v) do
        {:ok, not v}
      else
        {:error, {:eval_error, {:type_mismatch, :not, v}}}
      end
    end
  end

  def eval({:and, l, r}, variables) do
    with {:ok, lv} <- eval(l, variables),
         {:ok, rv} <- eval(r, variables) do
      if is_boolean(lv) and is_boolean(rv) do
        {:ok, lv and rv}
      else
        {:error, {:eval_error, {:type_mismatch, :and, lv, rv}}}
      end
    end
  end

  def eval({:or, l, r}, variables) do
    with {:ok, lv} <- eval(l, variables),
         {:ok, rv} <- eval(r, variables) do
      if is_boolean(lv) and is_boolean(rv) do
        {:ok, lv or rv}
      else
        {:error, {:eval_error, {:type_mismatch, :or, lv, rv}}}
      end
    end
  end

  def eval({:cmp, op, l, r}, variables) when op in [:eq, :neq] do
    with {:ok, lv} <- eval(l, variables),
         {:ok, rv} <- eval(r, variables) do
      {:ok, if(op == :eq, do: lv == rv, else: lv != rv)}
    end
  end

  def eval({:cmp, op, l, r}, variables) when op in [:lt, :lte, :gt, :gte] do
    with {:ok, lv} <- eval(l, variables),
         {:ok, rv} <- eval(r, variables) do
      if is_number(lv) and is_number(rv) do
        {:ok, apply_ordering(op, lv, rv)}
      else
        {:error, {:eval_error, {:type_mismatch, op, lv, rv}}}
      end
    end
  end

  @spec apply_ordering(cmp_op(), number(), number()) :: boolean()
  defp apply_ordering(:lt, l, r), do: l < r
  defp apply_ordering(:lte, l, r), do: l <= r
  defp apply_ordering(:gt, l, r), do: l > r
  defp apply_ordering(:gte, l, r), do: l >= r

  @spec resolve_var([String.t()], term(), [String.t()]) ::
          {:ok, value()} | {:error, {:eval_error, {:undefined_variable, [String.t()]}}}
  defp resolve_var([], value, _full_path), do: {:ok, value}

  defp resolve_var([key | rest], map, full_path) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> resolve_var(rest, value, full_path)
      :error -> {:error, {:eval_error, {:undefined_variable, full_path}}}
    end
  end

  defp resolve_var(_path, _non_map, full_path) do
    {:error, {:eval_error, {:undefined_variable, full_path}}}
  end

  @doc """
  The composed, always-boolean, never-`{:error, _}` entry point gateway
  dispatch calls per edge (design doc §4.7). Composition:
  `translate_cel_to_expr/1` -> `parse/1` -> `eval/2` -> `true` iff every
  stage succeeds and `eval/2` returns exactly `{:ok, true}`; every other
  outcome at every stage (translation error, unsupported CEL feature, parse
  error, eval error, or a non-boolean `{:ok, _}` result) uniformly means
  `false` -- one catch-false rule, not several.
  """
  @spec evaluate_condition(cel_condition :: String.t(), variables :: map()) :: boolean()
  def evaluate_condition(cel_condition, variables) do
    with {:ok, expr_source} <- translate_cel_to_expr(cel_condition),
         {:ok, ast} <- parse(expr_source),
         {:ok, true} <- eval(ast, variables) do
      true
    else
      _ -> false
    end
  end
end
