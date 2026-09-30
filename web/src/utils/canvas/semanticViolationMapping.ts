/**
 * semanticViolationMapping — REQ-431 §4: maps REQ-372's server-side semantic
 * decision-rule violations (`Graph.Violation` = `{code, message}`, no separate
 * nodeId/edgeId field) onto the canvas's existing `ValidationError` shape.
 *
 * Anchoring strategy (§4.1): both REQ-372 violation codes
 * (`:undeclared_variable_reference`, `:incompatible_comparison_operand_types`)
 * share one fixed, machine-generated message prefix, verified verbatim against
 * `lib/letflow/definitions/semantic_validation.ex`:
 *
 *   Edge '<edge.id>' (from EXCLUSIVE_GATEWAY node '<edge.source>') condition ...
 *
 * Capture group 1 = edge id, group 2 = source node id. This is parsed because
 * it is produced by exactly one string-interpolation call site per code, never
 * free-form prose, and its shape never varies. The optional suggestion clause
 * ("; nearest declared field: '<nearest>'") comes strictly after this prefix
 * and is never parsed — it is rendered verbatim as part of `message`, which is
 * ALWAYS included in full and unmodified (EO-001/EO-003's "rule as authored"
 * and "shows the typed field name ... suggests ... nearest existing field").
 *
 * Fallback discipline: if the regex does not match — a future violation code
 * added to the closed union without a matching update here, or an upstream
 * message-grammar change — the violation still renders as a flat problem-list
 * item (verbatim message, no nodeId/edgeId), never dropped, never thrown. This
 * mapping is total.
 */

import type { GraphValidationViolation } from '@/api/definitions'
import type { ValidationError } from '@/components/canvas/ValidationSummaryBar'

const SEMANTIC_VIOLATION_PREFIX_RE = /^Edge '([^']+)' \(from EXCLUSIVE_GATEWAY node '([^']+)'\) condition /

export function mapSemanticViolationToValidationError(
  violation: GraphValidationViolation,
): ValidationError {
  const match = SEMANTIC_VIOLATION_PREFIX_RE.exec(violation.message)
  if (!match) {
    // No anchor derivable — still render, flat, per §4.1's fallback discipline.
    return { message: violation.message, severity: 'error' }
  }
  const [, edgeId, nodeId] = match
  return {
    nodeId,
    edgeId,
    message: violation.message,
    severity: 'error',
  }
}

export function mapSemanticViolationsToValidationErrors(
  violations: GraphValidationViolation[],
): ValidationError[] {
  return violations.map(mapSemanticViolationToValidationError)
}
