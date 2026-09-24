#!/usr/bin/env bash
# seed_swiftroute_definition.sh
#
# Deploys the SwiftRoute "Shipment Approval" v1.0 ProcessDefinition to a
# live Letflow QA instance. Idempotent: skips creation if the definition
# already exists and is ACTIVE.
#
# Prerequisites:
#   - curl and jq installed
#   - QA_AUTH_TOKEN: Bearer token for a user in the swiftroute tenant with
#       DefinitionsWrite (for deployment) + InstancesStart/TasksList/TasksComplete
#       (for AC2/AC3 verification).  A PLATFORM_ADMIN or PROCESS_OPERATOR token
#       satisfies all four.
#   - QA_URL: base URL of the QA instance (default: https://qa.bizdala.com)
#   - SWIFTROUTE_TENANT_ID: UUID of the swiftroute tenant (optional; used only
#       for the PLATFORM_ADMIN provisioning note; the actual API calls are
#       scoped by the authenticated user's OIDC token, not this variable).
#
# Usage:
#   export QA_AUTH_TOKEN="<bearer-token>"
#   bash scripts/seed_swiftroute_definition.sh
#
#   # Or override defaults:
#   QA_URL=https://qa.bizdala.com QA_AUTH_TOKEN="<token>" bash scripts/seed_swiftroute_definition.sh
#
# If the swiftroute tenant does not yet exist on QA, provision it first:
#   curl -sf -X POST "$QA_URL/api/v1/tenants" \
#     -H "Authorization: Bearer $PLATFORM_ADMIN_TOKEN" \
#     -H "Content-Type: application/json" \
#     -d '{"slug":"swiftroute","display_name":"SwiftRoute Ltd","admin_email":"admin@swiftroute.example"}'
#
# Design source: lib/letflow/design/req395-swiftroute-definition-deployment.md
# Payload source of truth: test/fixtures/simulation/swiftroute/process_route_approval.yaml
# REQ: REQ-395 (Stage S7)

set -euo pipefail

QA_URL="${QA_URL:-https://qa.bizdala.com}"
API="${QA_URL}/api/v1"

if [[ -z "${QA_AUTH_TOKEN:-}" ]]; then
  echo "ERROR: QA_AUTH_TOKEN is not set." >&2
  echo "       Set it to a Bearer token for a user with DefinitionsWrite in the swiftroute tenant." >&2
  exit 1
fi

AUTH_HEADER="Authorization: Bearer ${QA_AUTH_TOKEN}"

echo "=== seed_swiftroute_definition.sh ==="
echo "QA_URL: ${QA_URL}"

# --- Idempotency guard ---
# Check if a definition named "Shipment Approval" with status ACTIVE already exists.
echo "--- Checking for existing active definition ---"
EXISTING=$(curl -sf \
  -H "${AUTH_HEADER}" \
  "${API}/definitions?name=Shipment+Approval&status=active") || {
  echo "ERROR: GET /api/v1/definitions failed (HTTP error)." >&2
  exit 1
}

EXISTING_ID=$(echo "${EXISTING}" | jq -r '.items[0].id // empty')

if [[ -n "${EXISTING_ID}" ]]; then
  echo "Definition already exists and is ACTIVE — skipping creation."
  echo "  Definition ID : ${EXISTING_ID}"
  echo "  Name          : $(echo "${EXISTING}" | jq -r '.items[0].name')"
  echo "  Version       : $(echo "${EXISTING}" | jq -r '.items[0].version')"
  echo "  Status        : $(echo "${EXISTING}" | jq -r '.items[0].status')"
  echo ""
  echo "Browse at: ${QA_URL}/api/v1/definitions/${EXISTING_ID}"
  exit 0
fi

# --- Step 1: POST /api/v1/definitions (create as DRAFT) ---
echo "--- Creating definition (DRAFT) ---"
PAYLOAD='{
  "name": "Shipment Approval",
  "version": "1.0",
  "description": "Sequential approval chain for high-value or non-standard shipments. Dispatcher raises the request; Operations Manager reviews; if value exceeds 500 the CEO must co-sign. Exercises: sequential chain + CEL conditional branch.",
  "graph": {
    "nodes": [
      {
        "id": "start",
        "node_type": "START"
      },
      {
        "id": "ops-review",
        "node_type": "HUMAN_TASK",
        "attributes": {
          "role": "role-ops-manager",
          "escalation_timer_duration": "PT2H",
          "escalation_role": "role-ceo"
        }
      },
      {
        "id": "ceo-approval-gate",
        "node_type": "EXCLUSIVE_GATEWAY"
      },
      {
        "id": "ceo-approval",
        "node_type": "HUMAN_TASK",
        "attributes": {
          "role": "role-ceo"
        }
      },
      {
        "id": "release-shipment",
        "node_type": "SERVICE_TASK",
        "attributes": {
          "endpoint": "POST /internal/shipments/{shipment_id}/release",
          "timeout_ms": 300000
        }
      },
      {
        "id": "auto-reject",
        "node_type": "SERVICE_TASK",
        "attributes": {
          "endpoint": "POST /internal/shipments/{shipment_id}/reject",
          "timeout_ms": 300000
        }
      },
      {
        "id": "notify-requester",
        "node_type": "SERVICE_TASK",
        "attributes": {
          "endpoint": "POST /webhooks/notify",
          "timeout_ms": 300000
        }
      },
      {
        "id": "end-approved",
        "node_type": "END"
      },
      {
        "id": "end-rejected",
        "node_type": "END"
      }
    ],
    "edges": [
      { "id": "e0",                  "source": "start",             "target": "ops-review" },
      { "id": "e1",                  "source": "ops-review",        "target": "ceo-approval-gate", "condition": "variables.ops_decision == '\''approve'\''" },
      { "id": "e2",                  "source": "ops-review",        "target": "notify-requester",  "condition": "variables.ops_decision == '\''reject'\''" },
      { "id": "fallback-ops-review", "source": "ops-review",        "target": "ceo-approval" },
      { "id": "e3",                  "source": "ceo-approval-gate", "target": "ceo-approval",      "condition": "variables.declared_value > 500" },
      { "id": "e4",                  "source": "ceo-approval-gate", "target": "release-shipment",  "condition": "variables.declared_value <= 500" },
      { "id": "e5",                  "source": "ceo-approval",      "target": "release-shipment",  "condition": "variables.ceo_decision == '\''approve'\''" },
      { "id": "e6",                  "source": "ceo-approval",      "target": "auto-reject",       "condition": "variables.ceo_decision == '\''reject'\''" },
      { "id": "timeout-ceo-approval","source": "ceo-approval",      "target": "auto-reject" },
      { "id": "e7",                  "source": "release-shipment",  "target": "end-approved" },
      { "id": "e8",                  "source": "auto-reject",       "target": "end-rejected" },
      { "id": "e9",                  "source": "notify-requester",  "target": "end-rejected" }
    ]
  }
}'

CREATE_RESPONSE=$(curl -sf \
  -X POST \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}" \
  "${API}/definitions") || {
  echo "ERROR: POST /api/v1/definitions failed." >&2
  echo "       If you got a 409 the definition already exists as DRAFT; activate it manually or re-run after deleting it." >&2
  exit 1
}

DEFINITION_ID=$(echo "${CREATE_RESPONSE}" | jq -r '.id')
if [[ -z "${DEFINITION_ID}" || "${DEFINITION_ID}" == "null" ]]; then
  echo "ERROR: POST /api/v1/definitions returned no id." >&2
  echo "Response: ${CREATE_RESPONSE}" >&2
  exit 1
fi

echo "  Created (DRAFT) — ID: ${DEFINITION_ID}"
echo "  Status: $(echo "${CREATE_RESPONSE}" | jq -r '.status')"

# --- Step 2: POST /api/v1/definitions/{id}/activate ---
echo "--- Activating definition ---"
ACTIVATE_RESPONSE=$(curl -sf \
  -X POST \
  -H "${AUTH_HEADER}" \
  "${API}/definitions/${DEFINITION_ID}/activate") || {
  echo "ERROR: POST /api/v1/definitions/${DEFINITION_ID}/activate failed." >&2
  echo "       If you see a 422, check OQ-3 (CEL single-quote syntax) and OQ-4 (QA code version includes REQ-396)." >&2
  exit 1
}

echo "  Activated — Status: $(echo "${ACTIVATE_RESPONSE}" | jq -r '.status')"
echo ""
echo "=== Deployment complete ==="
echo "  Definition ID   : ${DEFINITION_ID}"
echo "  Name            : $(echo "${ACTIVATE_RESPONSE}" | jq -r '.name')"
echo "  Version         : $(echo "${ACTIVATE_RESPONSE}" | jq -r '.version')"
echo "  Status          : $(echo "${ACTIVATE_RESPONSE}" | jq -r '.status')"
echo "  Browse at       : ${QA_URL}/api/v1/definitions/${DEFINITION_ID}"
echo ""
echo "--- AC1 verification ---"
echo "Run: curl -sf -H \"Authorization: Bearer \$QA_AUTH_TOKEN\" \"${API}/definitions?name=Shipment+Approval&status=active\" | jq ."
echo ""
echo "--- AC2 verification (declared_value: 750) ---"
echo "Run: curl -sf -X POST -H \"Authorization: Bearer \$QA_AUTH_TOKEN\" -H \"Content-Type: application/json\" \\"
echo "  -d '{\"definition_id\":\"${DEFINITION_ID}\",\"initial_variables\":{\"declared_value\":750}}' \\"
echo "  \"${API}/instances\" | jq ."
echo ""
echo "--- AC3 verification (declared_value: 400) ---"
echo "Run: curl -sf -X POST -H \"Authorization: Bearer \$QA_AUTH_TOKEN\" -H \"Content-Type: application/json\" \\"
echo "  -d '{\"definition_id\":\"${DEFINITION_ID}\",\"initial_variables\":{\"declared_value\":400}}' \\"
echo "  \"${API}/instances\" | jq ."
