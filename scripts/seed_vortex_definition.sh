#!/usr/bin/env bash
# seed_vortex_definition.sh
#
# Deploys the two Vortex ProcessDefinitions to a live Letflow QA instance:
#   1. "Production Order Release" v1.0  (proc-vortex-production-order-release)
#   2. "Supplier Quality Deviation" v1.0 (proc-vortex-supplier-quality-deviation,
#       proc-vortex-quality-deviation -- both aliases resolve to this same
#       definition; see decision C in
#       lib/letflow/design/iss0897-meridian-vortex-definition-seeding.md)
# Idempotent: each unit skips creation if its definition already exists and is
# ACTIVE. A failure in one unit still exits the whole script (set -euo pipefail).
#
# Prerequisites:
#   - curl and jq installed
#   - QA_AUTH_TOKEN: Bearer token for a user in the vortex tenant with
#       DefinitionsWrite. Provisioned via
#       `qa-uat-env.sh token vortex-admin-user` (ai-dala-infra, sibling repo).
#   - QA_URL: base URL of the QA instance (default: https://qa.bizdala.com)
#
# Usage:
#   export QA_AUTH_TOKEN="<bearer-token>"
#   bash scripts/seed_vortex_definition.sh
#
#   # Or override defaults:
#   QA_URL=https://qa.bizdala.com QA_AUTH_TOKEN="<token>" bash scripts/seed_vortex_definition.sh
#
# Design source: lib/letflow/design/iss0897-meridian-vortex-definition-seeding.md
# Payload sources of truth:
#   test/fixtures/simulation/vortex/process_quality_check.yaml (-> Production Order Release)
#   test/fixtures/simulation/vortex/process_work_order.yaml    (-> Supplier Quality Deviation)
# Issue: ISS-0897

set -euo pipefail

QA_URL="${QA_URL:-https://qa.bizdala.com}"
API="${QA_URL}/api/v1"

if [[ -z "${QA_AUTH_TOKEN:-}" ]]; then
  echo "ERROR: QA_AUTH_TOKEN is not set." >&2
  echo "       Set it to a Bearer token for a user with DefinitionsWrite in the vortex tenant." >&2
  exit 1
fi

AUTH_HEADER="Authorization: Bearer ${QA_AUTH_TOKEN}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== seed_vortex_definition.sh ==="
echo "QA_URL: ${QA_URL}"

seed_definition() {
  local display_name="$1"
  local encoded_name="$2"
  local fixture_path="$3"
  shift 3
  local aliases=("$@")

  echo ""
  echo "--- ${display_name}: checking for existing active definition ---"
  local existing
  existing=$(curl -sf \
    -H "${AUTH_HEADER}" \
    "${API}/definitions?name=${encoded_name}&status=active") || {
    echo "ERROR: GET /api/v1/definitions failed (HTTP error) for '${display_name}'." >&2
    exit 1
  }

  local existing_id
  existing_id=$(echo "${existing}" | jq -r '.items[0].id // empty')

  if [[ -n "${existing_id}" ]]; then
    echo "Definition already exists and is ACTIVE — skipping creation."
    echo "  Definition ID : ${existing_id}"
    echo "  Name          : $(echo "${existing}" | jq -r '.items[0].name')"
    echo "  Version       : $(echo "${existing}" | jq -r '.items[0].version')"
    echo "  Status        : $(echo "${existing}" | jq -r '.items[0].status')"
    echo ""
    echo "Browse at: ${QA_URL}/api/v1/definitions/${existing_id}"
    for alias in "${aliases[@]}"; do
      echo "  Scenario process_id : ${alias} (see test/fixtures/uat/process-definition-aliases/${alias}.yaml)"
    done
    return 0
  fi

  echo "--- ${display_name}: creating definition (DRAFT) ---"
  local payload
  payload=$(cat "${SCRIPT_DIR}/../${fixture_path}")

  local create_response
  create_response=$(curl -sf \
    -X POST \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "${API}/definitions") || {
    echo "ERROR: POST /api/v1/definitions failed for '${display_name}'." >&2
    echo "       If you got a 409 the definition already exists as DRAFT; activate it manually or re-run after deleting it." >&2
    exit 1
  }

  local definition_id
  definition_id=$(echo "${create_response}" | jq -r '.id')
  if [[ -z "${definition_id}" || "${definition_id}" == "null" ]]; then
    echo "ERROR: POST /api/v1/definitions returned no id for '${display_name}'." >&2
    echo "Response: ${create_response}" >&2
    exit 1
  fi

  echo "  Created (DRAFT) — ID: ${definition_id}"
  echo "  Status: $(echo "${create_response}" | jq -r '.status')"

  echo "--- ${display_name}: activating definition ---"
  local activate_response
  activate_response=$(curl -sf \
    -X POST \
    -H "${AUTH_HEADER}" \
    "${API}/definitions/${definition_id}/activate") || {
    echo "ERROR: POST /api/v1/definitions/${definition_id}/activate failed for '${display_name}'." >&2
    exit 1
  }

  echo "  Activated — Status: $(echo "${activate_response}" | jq -r '.status')"
  echo ""
  echo "=== ${display_name}: deployment complete ==="
  echo "  Definition ID   : ${definition_id}"
  echo "  Name            : $(echo "${activate_response}" | jq -r '.name')"
  echo "  Version         : $(echo "${activate_response}" | jq -r '.version')"
  echo "  Status          : $(echo "${activate_response}" | jq -r '.status')"
  echo "  Browse at       : ${QA_URL}/api/v1/definitions/${definition_id}"
  for alias in "${aliases[@]}"; do
    echo "  Scenario process_id : ${alias} (see test/fixtures/uat/process-definition-aliases/${alias}.yaml)"
  done
}

seed_definition \
  "Production Order Release" \
  "Production+Order+Release" \
  "test/fixtures/qa/vortex_production_order_release_process_definition.json" \
  "proc-vortex-production-order-release"

seed_definition \
  "Supplier Quality Deviation" \
  "Supplier+Quality+Deviation" \
  "test/fixtures/qa/vortex_supplier_quality_deviation_process_definition.json" \
  "proc-vortex-supplier-quality-deviation" \
  "proc-vortex-quality-deviation"

echo ""
echo "=== seed_vortex_definition.sh complete ==="
