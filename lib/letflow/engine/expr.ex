defmodule Letflow.Engine.Expr do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Pure CEL-subset expression evaluator — ports the subset of R-Co's
  `src/expr/` surface that `transition.zig`'s `evaluateGatewayCondition()`
  (~L1118, R-Co's EXP-102 adapter) actually needs for `:EXCLUSIVE_GATEWAY`
  edge conditions (REQ-050, `lib/letflow/design/req050-exclusive-gateway-cel.md`
  §4), extended by REQ-197
  (`lib/letflow/design/req197-expr-arithmetic-and-errors.md`) with binary
  arithmetic, unary negation, and a structured parse-error surface. It ports
  variable references, the 6 comparison operators, boolean `and`/`or`/`not`,
  literal values (numbers, strings, booleans, `null`), and binary
  `+ - * / %` plus unary `-` — not a full port of all 7 `src/expr/` files
  (`lexer.zig`, `parser.zig`, `ast.zig`, `evaluator.zig`, `error.zig`,
  `mod.zig`, `benchmark.zig`). `benchmark.zig` in particular is a Zig
  latency-benchmarking harness (1,000 warm-up plus 10,000 measured
  iterations against a 10 microsecond target, debug-print output only,
  imported by nothing) with no production behaviour and no Elixir
  equivalent, and is deliberately not ported at all. A fuller expression
  surface, if a later stage needs one, extends this module rather than
  replacing it (`docs/migration/stage-3-instance-engine.md`).

  ## R-Co's `src/expr` is not a CEL implementation (AC11)

  R-Co's EXP-102 cut over *from* a vendored CEL (`vendor/cel`) *to*
  `src/expr`, retiring CEL entirely. `@unsupported_call_markers` below
  therefore rejects CEL vocabulary (macros, type-conversion functions,
  collection functions, `in`, the ternary operator) that **neither** R-Co
  **nor** Letflow implements — this module's translation layer restricts
  authored conditions to exactly the grammar `src/expr` (the target this
  port implements) actually supports, not a Letflow gap against a CEL
  surface neither implementation ever had. A
  future contributor tempted to "complete" CEL support against
  `@unsupported_call_markers` would be acting against a closed EXP-102
  decision, not filling a real gap.

  ## `now()` / `date_add()` / `date_diff()` are deliberately not added (AC9)

  PROVENANCE (historical, not current decision authority):
  R-Co's real builtin whitelist (`src/expr/lexer.zig` L17-32) has 11
  entries: `length`, `lower`, `upper`, `trim`, `contains`, `startsWith`,
  `endsWith`, `coalesce`, `now`, `date_add`, `date_diff`. R-Co's
  `evaluator.zig` documents, in its own comment, that `now()` is
  "inherently impure; all other built-ins are pure." Adding `now()` (or
  `date_add`/`date_diff` insofar as they depend on it) here would read the
  system clock from inside this module, which would break both this
  module's grep-verified purity contract below and REQ-050's determinism
  guarantee (two calls with `==`-equal arguments must return `==`-equal
  results) — a guarantee event-sourced replay of a past instance's gateway
  routing decision depends on bit-for-bit. This is a decided, permanent
  disposition, not an open deferral: if a future requirement genuinely
  needs clock-dependent evaluation, the correct mechanism is an
  **injected evaluation timestamp passed in by the caller** (e.g. an
  `eval_context` argument the caller — which already has access to
  whatever "current time" concept the engine uses — resolves and passes
  in), never a clock read inside `expr.ex` itself. Call syntax for
  builtins does not exist yet at all (REQ-198 adds it for the 8 pure
  string/coalesce builtins); nothing here partially builds toward `now()`.

  ## REQ-198: 8 pure builtin functions, ASCII-only case conversion (AC6)

  PROVENANCE (historical, not current decision authority):
  `length`, `lower`, `upper`, `trim`, `contains`, `startsWith`, `endsWith`,
  `coalesce` are R-Co's other 8 builtin-whitelist entries (of its real
  11 — `now`/`date_add`/`date_diff` excluded, see above) — all pure, added
  by REQ-198 (`lib/letflow/design/req198-expr-builtin-functions.md`) as a
  new lex-time closed whitelist (`@builtin_function_names`) plus call
  syntax (`{:call, name, args}`). **`lower/1`/`upper/1` are ASCII-only case
  conversion, matching R-Co exactly — DECIDED, not full Unicode casing.**
  `String.downcase(s, :ascii)`/`String.upcase(s, :ascii)` are used
  deliberately instead of the Unicode-default `String.downcase/1`/
  `String.upcase/1`, which would silently diverge from R-Co on non-ASCII
  input (e.g. R-Co's `lower("CAFÉ")` leaves `É` unchanged, yielding
  `"cafÉ"`, not the Unicode-aware `"café"`) — see the design doc §3.2.1 for
  the full reasoning. `trim/1` strips only the same 4-byte ASCII
  whitespace set `do_tokenize/2` already treats as whitespace (space, tab,
  `\\n`, `\\r`), not `String.trim/1`'s broader Unicode-whitespace default.

  ## Purity and determinism (AC8)

  PROVENANCE (historical, not current decision authority):
  Every function here is a pure function of its typed arguments alone — no
  `Letflow.Repo`, no `Logger` call, no clock read, no `:rand`/`:crypto`, no
  `File` call/HTTP/process-mailbox call anywhere in `translate_cel_to_expr/1`,
  `parse/1`, `parse_strict/1`, `eval/2`, or `evaluate_condition/2`'s call
  graphs. Two calls with `==`-equal arguments return `==`-equal results,
  both times — the same guarantee `transition.zig`'s own header states for
  the ported reference: "`expr.parse()` and `expr.evaluate()` are pure
  computations." This still holds after REQ-197's arithmetic/parse-error
  additions: the float-division-by-zero sentinel (`:infinity`, see below)
  is constructed directly from a comparison against `0.0`, never via a
  clock-touching float-formatting trick, and `parse_failure()` deliberately
  carries no timestamp field.

  Verification (grep/`mix xref`-checkable, matching
  `Letflow.Engine.Transition`'s own precedent):

  ```bash
  grep -n "Repo\\.\\|Logger\\.\\|DateTime\\.\\|System\\.os_time\\|System\\.system_time\\|HTTPoison\\|Req\\.\\|File\\.\\|:rand\\.\\|:crypto\\." lib/letflow/engine/expr.ex
  ```

  must return zero matches.
  """

  @typedoc """
  PROVENANCE (historical, not current decision authority):
  Sentinel result for a float arithmetic outcome that IEEE 754 represents
  as a non-finite float but the BEAM cannot construct via native `/`
  without raising `ArithmeticError` (§4.3 of the REQ-197 design doc) —
  never produced by a literal or a variable, only by `eval/2`'s own
  float-division clause.

  PROVENANCE (historical, not current decision authority):
  **REVIEWER GATE (OQ-1, design §4.3/§4.6) RESOLVED (rework iteration 2):**
  REVIEWER confirmed IEEE 754 division-by-zero sign/NaN rules are a fixed
  mathematical standard, not an R-Co-specific implementation choice, so no
  amount of R-Co source access could change the correct answer here — the
  earlier "unverified against `evaluator.zig`" deferral did not actually
  apply to sign determination. The full signed-infinity/NaN 3-way split is
  now implemented: `:infinity` (positive), `:neg_infinity`, and `:nan`,
  per the per-operator dividend-sign table in §4.3 and the ordering/
  equality guard rules in §4.6.
  """
  @type infinity_marker :: :infinity | :neg_infinity | :nan

  @typedoc "A literal or resolved value in this expr subset."
  @type value :: number() | String.t() | boolean() | nil | infinity_marker()

  @typedoc "The 6 comparison operators this subset's grammar supports."
  @type cmp_op :: :eq | :neq | :lt | :lte | :gt | :gte

  @typedoc "The 5 binary arithmetic operators REQ-197 adds."
  @type arith_op :: :add | :sub | :mul | :div | :mod

  @typedoc """
  Every name REQ-198's closed lex-time whitelist recognizes as a
  builtin-function call. Exactly these 8 -- `now`, `date_add`, `date_diff`
  (R-Co's 3 clock-dependent builtins) are deliberately excluded, see the
  moduledoc's "`now()` / `date_add()` / `date_diff()` are deliberately not
  added" section.
  """
  @type builtin_name ::
          :length | :lower | :upper | :trim | :contains | :startsWith | :endsWith | :coalesce

  # REQ-198 §1.3: a plain, closed, compile-time list of exactly 8 atoms --
  # no registration hook, no runtime mutation. Consulted only by
  # identifier_token/1 and identifier_token_kv/1's builtin-name mapping
  # clauses below, which convert a scanned identifier string to one of
  # these atoms via a fixed, exhaustive, closed 8-clause literal mapping
  # (never String.to_atom/1 on attacker-controlled input).
  @builtin_function_names ~w(length lower upper trim contains startsWith endsWith coalesce)a

  @doc false
  # Exposes @builtin_function_names (§1.3) -- kept in sync with
  # identifier_token/1's/identifier_token_kv/1's literal 8-clause mapping
  # above by construction (both are hand-written from the same closed list).
  @spec builtin_function_names() :: [builtin_name()]
  def builtin_function_names, do: @builtin_function_names

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
          | {:arith, arith_op(), ast(), ast()}
          | {:neg, ast()}
          | {:call, builtin_name(), args :: [ast()]}

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
        # PROVENANCE (historical, not current decision authority):
        # Rules 2/3: `&&`/`||` -> `" and "`/`" or "`, WITH surrounding spaces
        # (ISS-0085/GH#302 fix; transition.zig:1177/:1183 emit the same
        # padded literals). CEL itself doesn't require whitespace around
        # `&&`/`||`, so an unpadded rewrite fuses adjacent tokens into one
        # identifier (`a&&b` -> `aandb`) instead of `a and b` -- a silent
        # wrong-edge routing bug, not a parse error. Already-spaced input can
        # end up with doubled spaces (`a  and  b`); harmless, since
        # `do_tokenize/2` below already skips whitespace during lexing, the
        # same standard tokenizer behavior R-Co's lexer also relies on.
        expr_source =
          cel_condition
          |> strip_variables_prefix()
          |> String.replace("&&", " and ")
          |> String.replace("||", " or ")
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
  `cmp_expr` > `additive_expr` > `multiplicative_expr` > `unary_expr` >
  `operand`, lowest-to-highest precedence `or`, `and`, `not`, comparison,
  `+`/`-`, `*`/`/`/`%`, unary `-`, primary).

  UNCHANGED by REQ-197 (design doc §6.1/§6.4): this function's `@spec` and
  outer `{:ok, ast()} | {:error, {:parse_error, reason}}` return shape are
  byte-identical to before this requirement. `reason`'s vocabulary of
  possible terms is unextended (arithmetic introduces no new grammar
  failure mode beyond the existing "unexpected token"/"unexpected end of
  input" shapes, which already fire correctly for a misplaced `+`/`-`/`*`/
  `/`/`%` token). See `parse_strict/1` below for the new, separate,
  structured-error entry point this requirement adds.
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
  # REQ-198 §2.1: the comma separating builtin-call arguments.
  defp do_tokenize(<<",", rest::binary>>, acc), do: do_tokenize(rest, [{:comma} | acc])

  defp do_tokenize(<<"==", rest::binary>>, acc), do: do_tokenize(rest, [{:cmp_op, :eq} | acc])
  defp do_tokenize(<<"!=", rest::binary>>, acc), do: do_tokenize(rest, [{:cmp_op, :neq} | acc])
  defp do_tokenize(<<"<=", rest::binary>>, acc), do: do_tokenize(rest, [{:cmp_op, :lte} | acc])
  defp do_tokenize(<<">=", rest::binary>>, acc), do: do_tokenize(rest, [{:cmp_op, :gte} | acc])
  defp do_tokenize(<<"<", rest::binary>>, acc), do: do_tokenize(rest, [{:cmp_op, :lt} | acc])
  defp do_tokenize(<<">", rest::binary>>, acc), do: do_tokenize(rest, [{:cmp_op, :gt} | acc])

  # REQ-197 §3.2: 5 new single-character operator tokens. `-` feeds BOTH
  # parse_additive/1 (binary `-`) and parse_unary/1 (unary `-`) -- which
  # meaning applies is determined purely by grammar position, never by the
  # lexer, which only ever emits one token kind for `-`.
  defp do_tokenize(<<"+", rest::binary>>, acc), do: do_tokenize(rest, [{:arith_op, :add} | acc])
  defp do_tokenize(<<"-", rest::binary>>, acc), do: do_tokenize(rest, [{:arith_op, :sub} | acc])
  defp do_tokenize(<<"*", rest::binary>>, acc), do: do_tokenize(rest, [{:arith_op, :mul} | acc])
  defp do_tokenize(<<"/", rest::binary>>, acc), do: do_tokenize(rest, [{:arith_op, :div} | acc])
  defp do_tokenize(<<"%", rest::binary>>, acc), do: do_tokenize(rest, [{:arith_op, :mod} | acc])

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
  # REQ-198 §1.1/§1.3: the 8-name closed builtin-function whitelist, a
  # fixed literal mapping (never String.to_atom/1 on arbitrary input),
  # inserted ahead of the final catch-all {:var, ...} clause below.
  defp identifier_token("length"), do: {:builtin_call, :length}
  defp identifier_token("lower"), do: {:builtin_call, :lower}
  defp identifier_token("upper"), do: {:builtin_call, :upper}
  defp identifier_token("trim"), do: {:builtin_call, :trim}
  defp identifier_token("contains"), do: {:builtin_call, :contains}
  defp identifier_token("startsWith"), do: {:builtin_call, :startsWith}
  defp identifier_token("endsWith"), do: {:builtin_call, :endsWith}
  defp identifier_token("coalesce"), do: {:builtin_call, :coalesce}
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

  # --- REQ-197 §6: position-tracking tokenizer + parser for parse_strict/1 -
  #
  # IMPLEMENTATION NOTE (deviation from design §6.2, flagged for REVIEWER):
  # the design's stated preference is that parse/1 and parse_strict/1 "share
  # one underlying tokenizer and one underlying grammar implementation."
  # This implementation instead gives parse_strict/1 its own
  # position-tracking tokenizer/parser pair below, structurally mirroring
  # `do_tokenize/2`'s clauses and `parse_or/1`..`parse_primary/1`'s call
  # chain one-for-one, rather than threading a position-tracking accumulator
  # through the existing functions. This is a deliberate, lower-risk choice:
  # `do_tokenize/2` carries two prior bug-fix histories (ISS-0086, ISS-0087)
  # around its regex/escape handling, and `parse/1`'s outer shape must stay
  # byte-identical (§6.1) with zero risk of regression. The duplication is
  # confined to this tokenizer/parser pair; both copies share
  # `identifier_token/1`'s sibling `identifier_token_kv/1`, `scan_string_literal/3`,
  # and produce identical `ast()` shapes for identical input. Flagged to
  # REVIEWER rather than silently diverging from the design's stated
  # preference.

  @typedoc "One lexed token plus the source position where it started (§6.2)."
  @type positioned_token :: %{
          kind: token_kind(),
          value: term(),
          text: String.t(),
          line: pos_integer(),
          column: pos_integer()
        }

  @typedoc "Every distinct token shape this grammar's lexer produces (§6.2)."
  @type token_kind ::
          :lparen
          | :rparen
          | :cmp_op
          | :arith_op
          | :and
          | :or
          | :not
          | :lit
          | :var
          | :builtin_call
          | :comma

  @typedoc "The one internal error shape every tokenizer/grammar failure site produces (§6.3)."
  @type internal_parse_error :: %{
          reason: parse_error_reason(),
          line: pos_integer(),
          column: pos_integer(),
          token_text: String.t()
        }

  @typedoc "Every distinct parse failure reason (§6.3) -- the same 8 shapes `parse/1` produces."
  @type parse_error_reason ::
          {:invalid_number, text :: String.t()}
          | {:invalid_identifier, text :: String.t()}
          | {:unexpected_char, char :: String.t()}
          | {:unterminated_string, text :: String.t()}
          | {:expected_rparen, found :: term()}
          | :unexpected_end_of_input
          | {:unexpected_token, token :: term()}
          | {:trailing_input, tokens :: [term()]}

  @typedoc "The structured parse-failure record `parse_strict/1` returns (§6.4)."
  @type parse_failure :: %{
          line: pos_integer(),
          column: pos_integer(),
          token_text: String.t(),
          message: String.t()
        }

  @doc """
  Parses an expr-syntax string exactly like `parse/1` (same input contract:
  already post-`translate_cel_to_expr/1`, never raw CEL), but on failure
  returns a structured `parse_failure()` -- line, column, the offending
  token's exact source text, and a fixed English message -- instead of a
  bare error atom (REQ-197 SCOPE item 3). On success, returns the identical
  `ast()` `parse/1` would return for the same input.

  This function is for callers this requirement does not itself add
  (validation, authoring, a future editor, per the requirement text) --
  `evaluate_condition/2`'s call graph (`translate_cel_to_expr/1` -> `parse/1`
  -> `eval/2`) never calls this function, directly or indirectly (§6.6).
  """
  @spec parse_strict(expr_source :: String.t()) :: {:ok, ast()} | {:error, parse_failure()}
  def parse_strict(expr_source) when is_binary(expr_source) do
    with {:ok, tokens, eof_pos} <- tokenize_positioned(expr_source),
         {:ok, ast, []} <- parse_or_p(tokens, eof_pos) do
      {:ok, ast}
    else
      {:ok, _ast, [tok | _rest] = leftover} ->
        {:error,
         package_failure(mk_err({:trailing_input, leftover}, tok.line, tok.column, tok.text))}

      {:error, internal_error} ->
        {:error, package_failure(internal_error)}
    end
  end

  @spec mk_err(parse_error_reason(), pos_integer(), pos_integer(), String.t()) ::
          internal_parse_error()
  defp mk_err(reason, line, column, token_text) do
    %{reason: reason, line: line, column: column, token_text: token_text}
  end

  @spec package_failure(internal_parse_error()) :: parse_failure()
  defp package_failure(%{reason: reason, line: line, column: column, token_text: token_text}) do
    %{line: line, column: column, token_text: token_text, message: describe_parse_error(reason)}
  end

  @doc false
  # §6.5: pure, one clause per parse_error_reason() variant, fixed English
  # sentence -- the offending token's own text is carried separately in
  # parse_failure().token_text, so this needs no string formatting.
  @spec describe_parse_error(parse_error_reason()) :: String.t()
  defp describe_parse_error(:unexpected_end_of_input), do: "unexpected end of input"
  defp describe_parse_error({:unexpected_token, _}), do: "unexpected token"
  defp describe_parse_error({:expected_rparen, _}), do: "expected closing parenthesis"
  defp describe_parse_error({:unterminated_string, _}), do: "unterminated string literal"
  defp describe_parse_error({:invalid_number, _}), do: "invalid numeric literal"
  defp describe_parse_error({:invalid_identifier, _}), do: "invalid identifier"
  defp describe_parse_error({:unexpected_char, _}), do: "unexpected character"
  defp describe_parse_error({:trailing_input, _}), do: "trailing input after expression"

  # --- position-tracking tokenizer ----------------------------------------

  @spec tokenize_positioned(String.t()) ::
          {:ok, [positioned_token()], eof_pos :: %{line: pos_integer(), column: pos_integer()}}
          | {:error, internal_parse_error()}
  defp tokenize_positioned(expr_source) do
    do_tokenize_positioned(expr_source, 1, 1, [])
  end

  @spec advance_pos(pos_integer(), pos_integer(), String.t()) ::
          {pos_integer(), pos_integer()}
  defp advance_pos(line, column, text) do
    text
    |> String.to_charlist()
    |> Enum.reduce({line, column}, fn
      ?\n, {l, _c} -> {l + 1, 1}
      _, {l, c} -> {l, c + 1}
    end)
  end

  @spec ptok(token_kind(), term(), String.t(), pos_integer(), pos_integer()) ::
          positioned_token()
  defp ptok(kind, value, text, line, column) do
    %{kind: kind, value: value, text: text, line: line, column: column}
  end

  defp do_tokenize_positioned(<<>>, line, column, acc) do
    {:ok, Enum.reverse(acc), %{line: line, column: column}}
  end

  defp do_tokenize_positioned(<<c, rest::binary>>, line, column, acc)
       when c in [?\s, ?\t, ?\n, ?\r] do
    {line2, column2} = advance_pos(line, column, <<c>>)
    do_tokenize_positioned(rest, line2, column2, acc)
  end

  defp do_tokenize_positioned(<<"(", rest::binary>>, line, column, acc) do
    do_tokenize_positioned(rest, line, column + 1, [ptok(:lparen, nil, "(", line, column) | acc])
  end

  defp do_tokenize_positioned(<<")", rest::binary>>, line, column, acc) do
    do_tokenize_positioned(rest, line, column + 1, [ptok(:rparen, nil, ")", line, column) | acc])
  end

  # REQ-198 §2.1: the comma separating builtin-call arguments.
  defp do_tokenize_positioned(<<",", rest::binary>>, line, column, acc) do
    do_tokenize_positioned(rest, line, column + 1, [ptok(:comma, nil, ",", line, column) | acc])
  end

  defp do_tokenize_positioned(<<"==", rest::binary>>, line, column, acc) do
    do_tokenize_positioned(rest, line, column + 2, [
      ptok(:cmp_op, :eq, "==", line, column) | acc
    ])
  end

  defp do_tokenize_positioned(<<"!=", rest::binary>>, line, column, acc) do
    do_tokenize_positioned(rest, line, column + 2, [
      ptok(:cmp_op, :neq, "!=", line, column) | acc
    ])
  end

  defp do_tokenize_positioned(<<"<=", rest::binary>>, line, column, acc) do
    do_tokenize_positioned(rest, line, column + 2, [
      ptok(:cmp_op, :lte, "<=", line, column) | acc
    ])
  end

  defp do_tokenize_positioned(<<">=", rest::binary>>, line, column, acc) do
    do_tokenize_positioned(rest, line, column + 2, [
      ptok(:cmp_op, :gte, ">=", line, column) | acc
    ])
  end

  defp do_tokenize_positioned(<<"<", rest::binary>>, line, column, acc) do
    do_tokenize_positioned(rest, line, column + 1, [ptok(:cmp_op, :lt, "<", line, column) | acc])
  end

  defp do_tokenize_positioned(<<">", rest::binary>>, line, column, acc) do
    do_tokenize_positioned(rest, line, column + 1, [ptok(:cmp_op, :gt, ">", line, column) | acc])
  end

  defp do_tokenize_positioned(<<"+", rest::binary>>, line, column, acc) do
    do_tokenize_positioned(rest, line, column + 1, [
      ptok(:arith_op, :add, "+", line, column) | acc
    ])
  end

  defp do_tokenize_positioned(<<"-", rest::binary>>, line, column, acc) do
    do_tokenize_positioned(rest, line, column + 1, [
      ptok(:arith_op, :sub, "-", line, column) | acc
    ])
  end

  defp do_tokenize_positioned(<<"*", rest::binary>>, line, column, acc) do
    do_tokenize_positioned(rest, line, column + 1, [
      ptok(:arith_op, :mul, "*", line, column) | acc
    ])
  end

  defp do_tokenize_positioned(<<"/", rest::binary>>, line, column, acc) do
    do_tokenize_positioned(rest, line, column + 1, [
      ptok(:arith_op, :div, "/", line, column) | acc
    ])
  end

  defp do_tokenize_positioned(<<"%", rest::binary>>, line, column, acc) do
    do_tokenize_positioned(rest, line, column + 1, [
      ptok(:arith_op, :mod, "%", line, column) | acc
    ])
  end

  defp do_tokenize_positioned(<<"\"", _::binary>> = input, line, column, acc),
    do: tokenize_string_positioned(input, ?", line, column, acc)

  defp do_tokenize_positioned(<<"'", _::binary>> = input, line, column, acc),
    do: tokenize_string_positioned(input, ?', line, column, acc)

  defp do_tokenize_positioned(<<c, _::binary>> = input, line, column, acc) when c in ?0..?9 do
    case Regex.run(~r/\A-?\d+(\.\d+)?/, input) do
      [match | _] ->
        rest = binary_part(input, byte_size(match), byte_size(input) - byte_size(match))

        number =
          if String.contains?(match, "."),
            do: String.to_float(match),
            else: String.to_integer(match)

        {line2, column2} = advance_pos(line, column, match)

        do_tokenize_positioned(rest, line2, column2, [
          ptok(:lit, number, match, line, column) | acc
        ])

      nil ->
        {:error, mk_err({:invalid_number, input}, line, column, input)}
    end
  end

  defp do_tokenize_positioned(<<c, _::binary>> = input, line, column, acc)
       when c in ?a..?z or c in ?A..?Z or c == ?_ do
    case Regex.run(~r/\A[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*/, input) do
      [match | _] ->
        rest = binary_part(input, byte_size(match), byte_size(input) - byte_size(match))
        {kind, value} = identifier_token_kv(match)
        {line2, column2} = advance_pos(line, column, match)

        do_tokenize_positioned(rest, line2, column2, [
          ptok(kind, value, match, line, column) | acc
        ])

      nil ->
        {:error, mk_err({:invalid_identifier, input}, line, column, input)}
    end
  end

  defp do_tokenize_positioned(<<c, _::binary>>, line, column, _acc) do
    {:error, mk_err({:unexpected_char, <<c>>}, line, column, <<c>>)}
  end

  @spec identifier_token_kv(String.t()) :: {token_kind(), term()}
  defp identifier_token_kv("and"), do: {:and, nil}
  defp identifier_token_kv("or"), do: {:or, nil}
  defp identifier_token_kv("not"), do: {:not, nil}
  defp identifier_token_kv("true"), do: {:lit, true}
  defp identifier_token_kv("false"), do: {:lit, false}
  defp identifier_token_kv("null"), do: {:lit, nil}
  # REQ-198 §1.1/§1.3: mirrors identifier_token/1's closed 8-name mapping.
  defp identifier_token_kv("length"), do: {:builtin_call, :length}
  defp identifier_token_kv("lower"), do: {:builtin_call, :lower}
  defp identifier_token_kv("upper"), do: {:builtin_call, :upper}
  defp identifier_token_kv("trim"), do: {:builtin_call, :trim}
  defp identifier_token_kv("contains"), do: {:builtin_call, :contains}
  defp identifier_token_kv("startsWith"), do: {:builtin_call, :startsWith}
  defp identifier_token_kv("endsWith"), do: {:builtin_call, :endsWith}
  defp identifier_token_kv("coalesce"), do: {:builtin_call, :coalesce}
  defp identifier_token_kv(ident), do: {:var, String.split(ident, ".")}

  @spec tokenize_string_positioned(String.t(), byte(), pos_integer(), pos_integer(), [
          positioned_token()
        ]) ::
          {:ok, [positioned_token()], %{line: pos_integer(), column: pos_integer()}}
          | {:error, internal_parse_error()}
  defp tokenize_string_positioned(<<quote, rest::binary>> = input, quote, line, column, acc) do
    case scan_string_literal(rest, quote, <<>>) do
      {:ok, content, remainder} ->
        consumed = binary_part(input, 0, byte_size(input) - byte_size(remainder))
        {line2, column2} = advance_pos(line, column, consumed)

        do_tokenize_positioned(remainder, line2, column2, [
          ptok(:lit, content, consumed, line, column) | acc
        ])

      :error ->
        {:error, mk_err({:unterminated_string, rest}, line, column, rest)}
    end
  end

  # --- position-tracking recursive-descent parser (mirrors parse_or/1..
  # parse_primary/1 below one-for-one, over positioned_token() maps instead
  # of bare tuples, threading `eof_pos` through for the
  # :unexpected_end_of_input case) ------------------------------------------

  @spec parse_or_p([positioned_token()], map()) ::
          {:ok, ast(), [positioned_token()]} | {:error, internal_parse_error()}
  defp parse_or_p(tokens, eof_pos) do
    with {:ok, left, rest} <- parse_and_p(tokens, eof_pos) do
      parse_or_rest_p(left, rest, eof_pos)
    end
  end

  defp parse_or_rest_p(left, [%{kind: :or} | rest], eof_pos) do
    with {:ok, right, rest2} <- parse_and_p(rest, eof_pos) do
      parse_or_rest_p({:or, left, right}, rest2, eof_pos)
    end
  end

  defp parse_or_rest_p(left, rest, _eof_pos), do: {:ok, left, rest}

  @spec parse_and_p([positioned_token()], map()) ::
          {:ok, ast(), [positioned_token()]} | {:error, internal_parse_error()}
  defp parse_and_p(tokens, eof_pos) do
    with {:ok, left, rest} <- parse_not_p(tokens, eof_pos) do
      parse_and_rest_p(left, rest, eof_pos)
    end
  end

  defp parse_and_rest_p(left, [%{kind: :and} | rest], eof_pos) do
    with {:ok, right, rest2} <- parse_not_p(rest, eof_pos) do
      parse_and_rest_p({:and, left, right}, rest2, eof_pos)
    end
  end

  defp parse_and_rest_p(left, rest, _eof_pos), do: {:ok, left, rest}

  @spec parse_not_p([positioned_token()], map()) ::
          {:ok, ast(), [positioned_token()]} | {:error, internal_parse_error()}
  defp parse_not_p([%{kind: :not} | rest], eof_pos) do
    with {:ok, sub, rest2} <- parse_not_p(rest, eof_pos) do
      {:ok, {:not, sub}, rest2}
    end
  end

  defp parse_not_p(tokens, eof_pos), do: parse_cmp_p(tokens, eof_pos)

  @spec parse_cmp_p([positioned_token()], map()) ::
          {:ok, ast(), [positioned_token()]} | {:error, internal_parse_error()}
  defp parse_cmp_p(tokens, eof_pos) do
    with {:ok, left, rest} <- parse_additive_p(tokens, eof_pos) do
      case rest do
        [%{kind: :cmp_op, value: op} | rest2] ->
          with {:ok, right, rest3} <- parse_additive_p(rest2, eof_pos) do
            {:ok, {:cmp, op, left, right}, rest3}
          end

        _ ->
          {:ok, left, rest}
      end
    end
  end

  @spec parse_additive_p([positioned_token()], map()) ::
          {:ok, ast(), [positioned_token()]} | {:error, internal_parse_error()}
  defp parse_additive_p(tokens, eof_pos) do
    with {:ok, left, rest} <- parse_multiplicative_p(tokens, eof_pos) do
      parse_additive_rest_p(left, rest, eof_pos)
    end
  end

  defp parse_additive_rest_p(left, [%{kind: :arith_op, value: op} | rest], eof_pos)
       when op in [:add, :sub] do
    with {:ok, right, rest2} <- parse_multiplicative_p(rest, eof_pos) do
      parse_additive_rest_p({:arith, op, left, right}, rest2, eof_pos)
    end
  end

  defp parse_additive_rest_p(left, rest, _eof_pos), do: {:ok, left, rest}

  @spec parse_multiplicative_p([positioned_token()], map()) ::
          {:ok, ast(), [positioned_token()]} | {:error, internal_parse_error()}
  defp parse_multiplicative_p(tokens, eof_pos) do
    with {:ok, left, rest} <- parse_unary_p(tokens, eof_pos) do
      parse_multiplicative_rest_p(left, rest, eof_pos)
    end
  end

  defp parse_multiplicative_rest_p(left, [%{kind: :arith_op, value: op} | rest], eof_pos)
       when op in [:mul, :div, :mod] do
    with {:ok, right, rest2} <- parse_unary_p(rest, eof_pos) do
      parse_multiplicative_rest_p({:arith, op, left, right}, rest2, eof_pos)
    end
  end

  defp parse_multiplicative_rest_p(left, rest, _eof_pos), do: {:ok, left, rest}

  @spec parse_unary_p([positioned_token()], map()) ::
          {:ok, ast(), [positioned_token()]} | {:error, internal_parse_error()}
  defp parse_unary_p([%{kind: :arith_op, value: :sub} | rest], eof_pos) do
    with {:ok, sub, rest2} <- parse_unary_p(rest, eof_pos) do
      {:ok, {:neg, sub}, rest2}
    end
  end

  defp parse_unary_p(tokens, eof_pos), do: parse_primary_p(tokens, eof_pos)

  @spec parse_primary_p([positioned_token()], map()) ::
          {:ok, ast(), [positioned_token()]} | {:error, internal_parse_error()}
  # REQ-198 §2.1: mirrors parse_primary/1's builtin-call clause above.
  defp parse_primary_p([%{kind: :builtin_call, value: name}, %{kind: :lparen} | rest], eof_pos) do
    with {:ok, args, rest2} <- parse_call_args_p(rest, eof_pos) do
      {:ok, {:call, name, args}, rest2}
    end
  end

  defp parse_primary_p([%{kind: :lparen} | rest], eof_pos) do
    with {:ok, inner, rest2} <- parse_or_p(rest, eof_pos) do
      case rest2 do
        [%{kind: :rparen} | rest3] ->
          {:ok, inner, rest3}

        [tok | _] = other ->
          {:error, mk_err({:expected_rparen, other}, tok.line, tok.column, tok.text)}

        [] ->
          {:error, mk_err({:expected_rparen, []}, eof_pos.line, eof_pos.column, "")}
      end
    end
  end

  defp parse_primary_p([%{kind: :lit, value: v} | rest], _eof_pos), do: {:ok, {:lit, v}, rest}

  defp parse_primary_p([%{kind: :var, value: path} | rest], _eof_pos),
    do: {:ok, {:var, path}, rest}

  defp parse_primary_p([], eof_pos) do
    {:error, mk_err(:unexpected_end_of_input, eof_pos.line, eof_pos.column, "")}
  end

  defp parse_primary_p([tok | _rest], _eof_pos) do
    {:error, mk_err({:unexpected_token, tok}, tok.line, tok.column, tok.text)}
  end

  # REQ-198 §2.1: mirrors parse_call_args/1 / parse_call_args_rest/2 above,
  # over positioned_token() maps.
  @spec parse_call_args_p([positioned_token()], map()) ::
          {:ok, [ast()], [positioned_token()]} | {:error, internal_parse_error()}
  defp parse_call_args_p([%{kind: :rparen} | rest], _eof_pos), do: {:ok, [], rest}

  defp parse_call_args_p(tokens, eof_pos) do
    with {:ok, arg, rest} <- parse_or_p(tokens, eof_pos) do
      parse_call_args_rest_p([arg], rest, eof_pos)
    end
  end

  @spec parse_call_args_rest_p([ast()], [positioned_token()], map()) ::
          {:ok, [ast()], [positioned_token()]} | {:error, internal_parse_error()}
  defp parse_call_args_rest_p(acc, [%{kind: :comma} | rest], eof_pos) do
    with {:ok, arg, rest2} <- parse_or_p(rest, eof_pos) do
      parse_call_args_rest_p([arg | acc], rest2, eof_pos)
    end
  end

  defp parse_call_args_rest_p(acc, [%{kind: :rparen} | rest], _eof_pos) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_call_args_rest_p(_acc, [tok | _] = other, _eof_pos) do
    {:error, mk_err({:expected_rparen, other}, tok.line, tok.column, tok.text)}
  end

  defp parse_call_args_rest_p(_acc, [], eof_pos) do
    {:error, mk_err({:expected_rparen, []}, eof_pos.line, eof_pos.column, "")}
  end

  # --- recursive-descent parser (used by parse/1, unchanged by REQ-197) --

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
    with {:ok, left, rest} <- parse_additive(tokens) do
      case rest do
        [{:cmp_op, op} | rest2] ->
          with {:ok, right, rest3} <- parse_additive(rest2) do
            {:ok, {:cmp, op, left, right}, rest3}
          end

        _ ->
          {:ok, left, rest}
      end
    end
  end

  # REQ-197 §2.1 level 5: `+`/`-`, left-associative, binding looser than
  # `*`/`/`/`%`. Mirrors parse_or_rest/parse_and_rest's left-folding shape.
  @spec parse_additive([term()]) :: {:ok, ast(), [term()]} | {:error, term()}
  defp parse_additive(tokens) do
    with {:ok, left, rest} <- parse_multiplicative(tokens) do
      parse_additive_rest(left, rest)
    end
  end

  defp parse_additive_rest(left, [{:arith_op, op} | rest]) when op in [:add, :sub] do
    with {:ok, right, rest2} <- parse_multiplicative(rest) do
      parse_additive_rest({:arith, op, left, right}, rest2)
    end
  end

  defp parse_additive_rest(left, rest), do: {:ok, left, rest}

  # REQ-197 §2.1 level 6: `*`/`/`/`%`, left-associative, binding tighter
  # than `+`/`-` and looser than unary `-`.
  @spec parse_multiplicative([term()]) :: {:ok, ast(), [term()]} | {:error, term()}
  defp parse_multiplicative(tokens) do
    with {:ok, left, rest} <- parse_unary(tokens) do
      parse_multiplicative_rest(left, rest)
    end
  end

  defp parse_multiplicative_rest(left, [{:arith_op, op} | rest]) when op in [:mul, :div, :mod] do
    with {:ok, right, rest2} <- parse_unary(rest) do
      parse_multiplicative_rest({:arith, op, left, right}, rest2)
    end
  end

  defp parse_multiplicative_rest(left, rest), do: {:ok, left, rest}

  # REQ-197 §2.1 level 7: unary `-`, prefix, right-recursive (mirrors
  # parse_not/1's own recursive-call shape so `- - x` parses). Only `-` is
  # consulted here -- there is no unary `+` in R-Co's stated surface, so a
  # leading `+5` is a parse error falling out of parse_primary/1's existing
  # unmatched-token clause, per the design's deliberate choice (§3.1).
  @spec parse_unary([term()]) :: {:ok, ast(), [term()]} | {:error, term()}
  defp parse_unary([{:arith_op, :sub} | rest]) do
    with {:ok, sub, rest2} <- parse_unary(rest) do
      {:ok, {:neg, sub}, rest2}
    end
  end

  defp parse_unary(tokens), do: parse_primary(tokens)

  @spec parse_primary([term()]) :: {:ok, ast(), [term()]} | {:error, term()}
  # REQ-198 §2.1: a {:builtin_call, name} token immediately followed by
  # {:lparen} is a builtin-function call. A bare {:builtin_call, _} with no
  # following {:lparen} does NOT match this clause and falls through to the
  # unmatched-token error clause below (§2.2 -- deliberate).
  defp parse_primary([{:builtin_call, name}, {:lparen} | rest]) do
    with {:ok, args, rest2} <- parse_call_args(rest) do
      {:ok, {:call, name, args}, rest2}
    end
  end

  defp parse_primary([{:lparen} | rest]) do
    with {:ok, inner, rest2} <- parse_or(rest) do
      case rest2 do
        [{:rparen} | rest3] -> {:ok, inner, rest3}
        other -> {:error, {:expected_rparen, other}}
      end
    end
  end

  defp parse_primary([{:lit, v} | rest]), do: {:ok, {:lit, v}, rest}
  defp parse_primary([{:var, path} | rest]), do: {:ok, {:var, path}, rest}
  defp parse_primary([]), do: {:error, :unexpected_end_of_input}
  defp parse_primary([tok | _rest]), do: {:error, {:unexpected_token, tok}}

  # REQ-198 §2.1: comma-separated arg_list?, terminated by {:rparen}. An
  # immediate {:rparen} means zero arguments (arity is not a grammar-level
  # restriction -- §4/design doc §2 note -- checked later at eval time).
  @spec parse_call_args([term()]) :: {:ok, [ast()], [term()]} | {:error, term()}
  defp parse_call_args([{:rparen} | rest]), do: {:ok, [], rest}

  defp parse_call_args(tokens) do
    with {:ok, arg, rest} <- parse_or(tokens) do
      parse_call_args_rest([arg], rest)
    end
  end

  @spec parse_call_args_rest([ast()], [term()]) :: {:ok, [ast()], [term()]} | {:error, term()}
  defp parse_call_args_rest(acc, [{:comma} | rest]) do
    with {:ok, arg, rest2} <- parse_or(rest) do
      parse_call_args_rest([arg | acc], rest2)
    end
  end

  defp parse_call_args_rest(acc, [{:rparen} | rest]), do: {:ok, Enum.reverse(acc), rest}
  defp parse_call_args_rest(_acc, other), do: {:error, {:expected_rparen, other}}

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
      cond do
        # REQ-197 §4.6: real IEEE 754 NaN self-inequality -- :nan == :nan is
        # false and :nan != anything (including :nan) is true. Plain Elixir
        # `==`/`!=` would otherwise wrongly say `:nan == :nan` since they
        # are equal atoms, so this override is checked first.
        lv == :nan or rv == :nan ->
          {:ok, op == :neq}

        true ->
          {:ok, if(op == :eq, do: lv == rv, else: lv != rv)}
      end
    end
  end

  def eval({:cmp, op, l, r}, variables) when op in [:lt, :lte, :gt, :gte] do
    with {:ok, lv} <- eval(l, variables),
         {:ok, rv} <- eval(r, variables) do
      cond do
        # REQ-197 §4.5 (REVISED, rework iteration 1): a nil operand in an
        # ordering comparison PROPAGATES -- {:ok, nil} -- rather than
        # falling through to the type-mismatch error below. This is a
        # deliberate, real behavioural change to this clause (design doc
        # §4.5/§4.6), checked first because nil, :nan, the infinity
        # markers, and the is_number case are mutually exclusive operand
        # shapes, so this cannot shadow anything below it.
        lv == nil or rv == nil ->
          {:ok, nil}

        # REQ-197 §4.6 (rework iteration 2, OQ-1 resolved): :nan compares as
        # false against everything via every ordering operator, including
        # :nan vs :nan, matching real IEEE 754 NaN semantics. Checked ahead
        # of the infinity-marker branch below since :nan is mutually
        # exclusive with :infinity/:neg_infinity.
        lv == :nan or rv == :nan ->
          {:ok, false}

        # REQ-197 §4.6: :infinity/:neg_infinity participate in ordering as
        # the greatest/least possible value respectively, handled inside
        # apply_ordering/3.
        (is_number(lv) or lv in [:infinity, :neg_infinity]) and
            (is_number(rv) or rv in [:infinity, :neg_infinity]) ->
          {:ok, apply_ordering(op, lv, rv)}

        true ->
          {:error, {:eval_error, {:type_mismatch, op, lv, rv}}}
      end
    end
  end

  def eval({:arith, op, l, r}, variables) do
    with {:ok, lv} <- eval(l, variables),
         {:ok, rv} <- eval(r, variables) do
      apply_arith(op, lv, rv)
    end
  end

  def eval({:neg, sub}, variables) do
    with {:ok, v} <- eval(sub, variables) do
      apply_neg(v)
    end
  end

  # REQ-198 §3/§4: evaluates every argument left-to-right first (short-
  # circuiting on the first argument that itself errors, before arity or
  # type checking of the call ever runs), THEN checks arity against
  # length(args), THEN dispatches to the named builtin's semantics.
  def eval({:call, name, args}, variables) do
    with {:ok, values} <- eval_args(args, variables, []),
         :ok <- check_arity(name, length(values)) do
      apply_builtin(name, values)
    end
  end

  @spec eval_args([ast()], variables :: map(), [value()]) ::
          {:ok, [value()]} | {:error, {:eval_error, reason :: term()}}
  defp eval_args([], _variables, acc), do: {:ok, Enum.reverse(acc)}

  defp eval_args([arg | rest], variables, acc) do
    with {:ok, v} <- eval(arg, variables) do
      eval_args(rest, variables, [v | acc])
    end
  end

  @typedoc "Per-builtin arity requirement (§4)."
  @type arity_requirement :: {:exactly, non_neg_integer()} | {:at_least, non_neg_integer()}

  @spec required_arity(builtin_name()) :: arity_requirement()
  defp required_arity(name) when name in [:length, :lower, :upper, :trim], do: {:exactly, 1}
  defp required_arity(name) when name in [:contains, :startsWith, :endsWith], do: {:exactly, 2}
  defp required_arity(:coalesce), do: {:at_least, 1}

  @spec check_arity(builtin_name(), non_neg_integer()) ::
          :ok
          | {:error,
             {:eval_error, {:wrong_arity, builtin_name(), arity_requirement(), non_neg_integer()}}}
  defp check_arity(name, got) do
    requirement = required_arity(name)

    ok? =
      case requirement do
        {:exactly, n} -> got == n
        {:at_least, n} -> got >= n
      end

    if ok? do
      :ok
    else
      {:error, {:eval_error, {:wrong_arity, name, requirement, got}}}
    end
  end

  # REQ-198 §3.1: string byte length. nil propagates; non-string is a
  # type-mismatch error.
  @spec apply_builtin(builtin_name(), [value()]) ::
          {:ok, value()} | {:error, {:eval_error, reason :: term()}}
  defp apply_builtin(:length, [nil]), do: {:ok, nil}
  defp apply_builtin(:length, [s]) when is_binary(s), do: {:ok, byte_size(s)}
  defp apply_builtin(:length, [s]), do: {:error, {:eval_error, {:type_mismatch, :length, s}}}

  # REQ-198 §3.2/§3.2.1: ASCII-only case conversion, matching R-Co exactly
  # -- String.downcase/2 and String.upcase/2 with the :ascii mode, NOT the
  # Unicode-default String.downcase/1 / String.upcase/1 (moduledoc).
  defp apply_builtin(:lower, [nil]), do: {:ok, nil}
  defp apply_builtin(:lower, [s]) when is_binary(s), do: {:ok, String.downcase(s, :ascii)}
  defp apply_builtin(:lower, [s]), do: {:error, {:eval_error, {:type_mismatch, :lower, s}}}

  defp apply_builtin(:upper, [nil]), do: {:ok, nil}
  defp apply_builtin(:upper, [s]) when is_binary(s), do: {:ok, String.upcase(s, :ascii)}
  defp apply_builtin(:upper, [s]), do: {:error, {:eval_error, {:type_mismatch, :upper, s}}}

  # REQ-198 §3.3: strips only the same 4-byte ASCII whitespace set
  # do_tokenize/2 already treats as whitespace, not Unicode whitespace.
  defp apply_builtin(:trim, [nil]), do: {:ok, nil}
  defp apply_builtin(:trim, [s]) when is_binary(s), do: {:ok, ascii_trim(s)}
  defp apply_builtin(:trim, [s]), do: {:error, {:eval_error, {:type_mismatch, :trim, s}}}

  # REQ-198 §3.4: boolean, byte-substring semantics; either-argument-nil
  # yields nil, checked BEFORE the type check.
  defp apply_builtin(:contains, [a, b]),
    do: string_predicate(:contains, a, b, &String.contains?/2)

  defp apply_builtin(:startsWith, [a, b]),
    do: string_predicate(:startsWith, a, b, &String.starts_with?/2)

  defp apply_builtin(:endsWith, [a, b]),
    do: string_predicate(:endsWith, a, b, &String.ends_with?/2)

  # REQ-198 §3.5: variadic, >=1 arg (enforced by check_arity/2 above --
  # coalesce() never reaches this clause). First non-nil value, else nil.
  # No type restriction on the arguments at all.
  defp apply_builtin(:coalesce, values), do: {:ok, Enum.find(values, nil, &(&1 != nil))}

  @spec string_predicate(
          builtin_name(),
          value(),
          value(),
          (String.t(), String.t() -> boolean())
        ) :: {:ok, boolean() | nil} | {:error, {:eval_error, reason :: term()}}
  defp string_predicate(_name, nil, _b, _fun), do: {:ok, nil}
  defp string_predicate(_name, _a, nil, _fun), do: {:ok, nil}

  defp string_predicate(_name, a, b, fun) when is_binary(a) and is_binary(b) do
    {:ok, fun.(a, b)}
  end

  defp string_predicate(name, a, b, _fun) do
    {:error, {:eval_error, {:type_mismatch, name, a, b}}}
  end

  # REQ-198 §3.3: byte-level ASCII-whitespace trim, mirroring
  # do_tokenize/2's own `c in [?\s, ?\t, ?\n, ?\r]` guard -- deliberately
  # NOT String.trim/1, which trims a broader Unicode-whitespace set.
  @spec ascii_trim(String.t()) :: String.t()
  defp ascii_trim(binary) do
    binary
    |> ascii_trim_leading()
    |> ascii_trim_trailing()
  end

  @spec ascii_trim_leading(String.t()) :: String.t()
  defp ascii_trim_leading(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r],
    do: ascii_trim_leading(rest)

  defp ascii_trim_leading(binary), do: binary

  @spec ascii_trim_trailing(String.t()) :: String.t()
  defp ascii_trim_trailing(binary) do
    size = byte_size(binary)

    if size > 0 and :binary.at(binary, size - 1) in [?\s, ?\t, ?\n, ?\r] do
      ascii_trim_trailing(binary_part(binary, 0, size - 1))
    else
      binary
    end
  end

  # REQ-197 §4.2: checked in this exact order for every binary arithmetic
  # node. Null check (asymmetric with comparison, see §4.5) is checked
  # FIRST, before any type/promotion logic.
  @spec apply_arith(arith_op(), value(), value()) ::
          {:ok, value()} | {:error, {:eval_error, reason :: term()}}
  defp apply_arith(op, lv, rv) when lv == nil or rv == nil do
    {:error, {:eval_error, {:null_in_arithmetic, op, lv, rv}}}
  end

  defp apply_arith(op, lv, rv) when not is_number(lv) or not is_number(rv) do
    {:error, {:eval_error, {:type_mismatch, op, lv, rv}}}
  end

  defp apply_arith(op, lv, rv) when is_integer(lv) and is_integer(rv) do
    apply_int_arith(op, lv, rv)
  end

  defp apply_arith(op, lv, rv) do
    apply_float_arith(op, lv * 1.0, rv * 1.0)
  end

  # REQ-197 §4.3 row A: both-integer semantics.
  @spec apply_int_arith(arith_op(), integer(), integer()) ::
          {:ok, integer()} | {:error, {:eval_error, reason :: term()}}
  defp apply_int_arith(:add, l, r), do: {:ok, l + r}
  defp apply_int_arith(:sub, l, r), do: {:ok, l - r}
  defp apply_int_arith(:mul, l, r), do: {:ok, l * r}
  defp apply_int_arith(:div, l, 0), do: {:error, {:eval_error, {:division_by_zero, :int, l, 0}}}
  defp apply_int_arith(:div, l, r), do: {:ok, div(l, r)}
  defp apply_int_arith(:mod, l, 0), do: {:error, {:eval_error, {:modulo_by_zero, :int, l, 0}}}
  defp apply_int_arith(:mod, l, r), do: {:ok, rem(l, r)}

  # REQ-197 §4.3 row B: float semantics (both operands already promoted to
  # float by apply_arith/3's final clause). Float division by a zero
  # divisor cannot go through native `/` (raises ArithmeticError on the
  # BEAM) -- constructed directly instead, per the signed-infinity/NaN
  # 3-way dividend-sign split (OQ-1 resolved, rework iteration 2): a
  # positive dividend over a zero divisor yields :infinity, a negative
  # dividend yields :neg_infinity, and 0.0/0.0 yields :nan (true IEEE
  # 754 0.0/0.0 behaviour). Clause order matters: the l == 0.0 clause
  # must come before the l > 0.0 / l < 0.0 clauses since 0.0 satisfies
  # neither of those guards on its own, but is checked explicitly first
  # for clarity and to match the design doc's own ordering.
  @spec apply_float_arith(arith_op(), float(), float()) ::
          {:ok, float() | infinity_marker()} | {:error, {:eval_error, reason :: term()}}
  defp apply_float_arith(:add, l, r), do: {:ok, l + r}
  defp apply_float_arith(:sub, l, r), do: {:ok, l - r}
  defp apply_float_arith(:mul, l, r), do: {:ok, l * r}
  defp apply_float_arith(:div, l, r) when r == 0.0 and l == 0.0, do: {:ok, :nan}
  defp apply_float_arith(:div, l, r) when r == 0.0 and l > 0.0, do: {:ok, :infinity}
  defp apply_float_arith(:div, l, r) when r == 0.0 and l < 0.0, do: {:ok, :neg_infinity}
  defp apply_float_arith(:div, l, r), do: {:ok, l / r}

  defp apply_float_arith(:mod, l, r) do
    {:error, {:eval_error, {:modulo_by_zero, :float, l, r}}}
  end

  # REQ-197 §4.4: unary negation. Negating :infinity/:neg_infinity flips
  # sign (only reachable via a nested `-(-1.0/0.0)`-shaped expression);
  # negating :nan stays :nan, matching real IEEE 754 NaN negation (which
  # flips an unobservable sign bit only).
  @spec apply_neg(value()) :: {:ok, value()} | {:error, {:eval_error, reason :: term()}}
  defp apply_neg(nil), do: {:error, {:eval_error, {:null_in_arithmetic, :neg, nil}}}
  defp apply_neg(:infinity), do: {:ok, :neg_infinity}
  defp apply_neg(:neg_infinity), do: {:ok, :infinity}
  defp apply_neg(:nan), do: {:ok, :nan}
  defp apply_neg(v) when is_number(v), do: {:ok, -v}
  defp apply_neg(v), do: {:error, {:eval_error, {:type_mismatch, :neg, v}}}

  # REQ-197 §4.6: :infinity is the greatest possible value and
  # :neg_infinity the least (OQ-1 resolved, rework iteration 2). The
  # caller (eval/2's ordering-comparison clause) already filters out
  # :nan before apply_ordering/3 is ever invoked, so no :nan clause is
  # needed here. Two equal markers hit the `l == r` fast path
  # (`<=`/`>=` true, `<`/`>` false). Plain-number clauses (no infinity
  # marker on either side) come last and are unchanged from before this
  # requirement.
  @spec apply_ordering(cmp_op(), number() | infinity_marker(), number() | infinity_marker()) ::
          boolean()
  defp apply_ordering(op, l, r)
       when l in [:infinity, :neg_infinity] or r in [:infinity, :neg_infinity] do
    cond do
      l == r -> op in [:lte, :gte]
      l == :infinity -> op in [:gt, :gte]
      l == :neg_infinity -> op in [:lt, :lte]
      r == :infinity -> op in [:lt, :lte]
      r == :neg_infinity -> op in [:gt, :gte]
    end
  end

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
