/** canonicalizeArtefactContent — REQ-381 §2.1
 *
 *  TypeScript port of `Letflow.Definitions.SolutionPack`'s private
 *  `canonicalize_artefact_content/1` / `canonicalize_json/1`
 *  (`lib/letflow/definitions/solution_pack.ex:1542-1565`). Byte-for-byte
 *  equivalent algorithm:
 *
 *    1. A map/object has its keys sorted (`Enum.sort/1` on `Map.keys/1`,
 *       rebuilt via `Jason.OrderedObject.new/1` so the sorted order survives
 *       encoding) — ported here as `Object.keys(...).sort()` (the same
 *       default lexicographic/code-unit ordering JS provides with no
 *       comparator argument), rebuilding the object in that key order.
 *    2. A list/array is mapped over recursively, order preserved (never
 *       sorted).
 *    3. An atom (excluding booleans/`nil`) is converted via
 *       `Atom.to_string/1` — has **no TypeScript counterpart** and is
 *       intentionally omitted: every value this function will ever receive
 *       is already plain decoded JSON (from the app's API client or
 *       `JSON.parse`), never an Elixir term. This is a property of this
 *       function's two call
 *       sites (`GET /definitions/:id`'s `response.graph`, and a solution-pack
 *       document's `definitions[].graph` — REQ-381 design §2), not an
 *       assumption this function makes about its argument.
 *    4. Anything else (string, number, boolean, `null`) passes through
 *       unchanged.
 *    5. The whole structure is then `JSON.stringify()`'d with no
 *       separators/indentation argument — its default output already has no
 *       insignificant whitespace, matching `Jason.encode!/1`'s default.
 *
 *  ## Residual risks — disclosed, not silently assumed away (design §2.1)
 *
 *  - **Key ordering.** `Enum.sort/1` on Elixir binaries orders by UTF-8 byte
 *    value, which for valid UTF-8 text equals Unicode codepoint order.
 *    `Array.prototype.sort()`'s default string comparator orders by UTF-16
 *    *code unit* value. These coincide for every key in the Basic
 *    Multilingual Plane (BMP, codepoints U+0000–U+FFFF, which is every
 *    field-name literal this codebase's `lib/letflow/definitions/graph.ex`
 *    actually produces — grepped to confirm zero non-ASCII, let alone
 *    non-BMP, field names exist). They are **not guaranteed identical** for
 *    a key containing an astral-plane character (codepoint >= U+10000, which
 *    JS represents as a UTF-16 surrogate pair): such a key's *codepoint*
 *    value is numerically far above every BMP key, but its *lead surrogate*
 *    (U+D800–U+DBFF) sorts as if it were a low/mid-BMP character, which can
 *    reorder it relative to some higher BMP keys. This is real, disclosed,
 *    and NOT covered by the golden-fixture set below (deliberately — a
 *    fixture case exercising it would encode a known divergence as an
 *    expected-failure, and no real field name in this codebase is anything
 *    but ASCII). Flagged for REVIEWER, same as design doc §2.1/OQ-4.
 *  - **Number formatting.** `Jason.encode!/1` uses Erlang's own
 *    shortest-round-trip integer/float formatting; `JSON.stringify` uses the
 *    JS engine's own shortest-round-trip formatting. These coincide for
 *    integers within `Number.MAX_SAFE_INTEGER` and ordinary decimal floats
 *    (covered by the golden-fixture set), but are unverified beyond that
 *    range — this function does not special-case large integers or attempt
 *    to preserve precision past what a JS `number` can hold.
 *  - **String escaping.** Both `Jason.encode!/1` and `JSON.stringify` use
 *    minimal (non-HTML-safe) JSON string escaping by default; verified by
 *    the golden-fixture set's control-character and multi-byte-UTF-8 cases.
 */

export type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue }

function canonicalizeValue(value: JsonValue): JsonValue {
  if (Array.isArray(value)) {
    return value.map(canonicalizeValue)
  }
  if (value !== null && typeof value === 'object') {
    const sortedKeys = Object.keys(value).sort()
    const result: { [key: string]: JsonValue } = {}
    for (const key of sortedKeys) {
      result[key] = canonicalizeValue(value[key])
    }
    return result
  }
  // string | number | boolean | null — pass through unchanged (step 4).
  return value
}

/**
 * Recursively sorts object keys, preserves array element order, passes
 * strings/numbers/booleans/null through unchanged, then serialises with
 * `JSON.stringify`'s default (no insignificant whitespace) output.
 *
 * Input: an already-JSON-decoded value — e.g. `GET /definitions/:id`'s
 * `response.graph`, or a pack document's `definitions[].graph`. This is the
 * type of value the app's API client or `JSON.parse` ever produce; there is
 * no JS equivalent of an Elixir atom for this function to handle, so step 3 of
 * `canonicalize_json/1` has no TS counterpart and is intentionally omitted
 * (see the module doc's "steps that don't carry over") — not a partial
 * port, a complete one for the input shape this function will ever actually
 * receive.
 */
export function canonicalizeArtefactContent(value: JsonValue): string {
  return JSON.stringify(canonicalizeValue(value))
}
