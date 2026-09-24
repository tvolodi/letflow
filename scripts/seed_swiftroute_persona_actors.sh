#!/usr/bin/env bash
# seed_swiftroute_persona_actors.sh
#
# Provisions the letflow-side (Part B) of the SwiftRoute persona actors:
#   - Creates process-routing role groups: role-ops-manager, role-ceo
#   - Upserts tenant_role bindings for those groups
#   - Adds each persona actor to their appropriate group(s)
#
# PREREQUISITE (OQ-1): Part A must be completed first.
#   ai-dala-infra/scripts/qa-login.sh must have already created Keycloak accounts
#   for actor-swiftroute-lena, actor-swiftroute-marco, actor-swiftroute-alice
#   in the swiftroute realm, and those accounts must have synced into letflow's
#   users table before this script runs. If a user lookup returns empty items,
#   this script aborts with a clear error naming the missing actor.
#
# Persona → group mapping (§4 of the design doc):
#   actor-swiftroute-lena  (Dispatcher)  → TASK_WORKER only
#   actor-swiftroute-marco (Ops Manager) → TASK_WORKER + role-ops-manager
#   actor-swiftroute-alice (CEO)         → TASK_WORKER + role-ceo
#
# Prerequisites:
#   - curl and jq installed
#   - QA_AUTH_TOKEN: Bearer token for a PLATFORM_ADMIN user in the swiftroute tenant.
#       Must grant GroupsManage + RolesManage + UsersManage.
#   - QA_URL: base URL of the QA instance (default: https://qa.bizdala.com)
#
# Usage:
#   export QA_AUTH_TOKEN="<bearer-token>"
#   bash scripts/seed_swiftroute_persona_actors.sh
#
#   # Or override base URL:
#   QA_URL=https://qa.bizdala.com QA_AUTH_TOKEN="<token>" bash scripts/seed_swiftroute_persona_actors.sh
#
# Design source: lib/letflow/design/iss-0761-swiftroute-persona-actor-provisioning.md
# Issue: ISS-0739 / ISS-0761

set -euo pipefail

QA_URL="${QA_URL:-https://qa.bizdala.com}"
API="${QA_URL}/api/v1/identity"

if [[ -z "${QA_AUTH_TOKEN:-}" ]]; then
  echo "ERROR: QA_AUTH_TOKEN is not set." >&2
  echo "       Set it to a Bearer token for a PLATFORM_ADMIN user in the swiftroute tenant." >&2
  exit 1
fi

AUTH_HEADER="Authorization: Bearer ${QA_AUTH_TOKEN}"

echo "=== seed_swiftroute_persona_actors.sh ==="
echo "QA_URL: ${QA_URL}"
echo ""

# ---------------------------------------------------------------------------
# Helper: look up user by exact username; abort if not found (Part A missing)
# ---------------------------------------------------------------------------
lookup_user_id() {
  local username="$1"
  local response
  response=$(curl -sf \
    -H "${AUTH_HEADER}" \
    "${API}/users?search=${username}") || {
    echo "ERROR: GET /api/v1/identity/users?search=${username} failed (HTTP error)." >&2
    exit 1
  }
  local user_id
  user_id=$(echo "${response}" | jq -r '.items[0].id // empty')
  if [[ -z "${user_id}" ]]; then
    echo "ERROR: user ${username} not found." >&2
    echo "       Complete Part A (ai-dala-infra Keycloak provisioning) before running this script." >&2
    exit 1
  fi
  echo "${user_id}"
}

# ---------------------------------------------------------------------------
# Helper: find group ID by exact name from GET /groups listing
# Returns empty string if not found
# ---------------------------------------------------------------------------
find_group_id() {
  local name="$1"
  local response
  response=$(curl -sf \
    -H "${AUTH_HEADER}" \
    "${API}/groups") || {
    echo "ERROR: GET /api/v1/identity/groups failed (HTTP error)." >&2
    exit 1
  }
  echo "${response}" | jq -r --arg n "${name}" '.items[] | select(.name==$n) | .id' | head -1
}

# ---------------------------------------------------------------------------
# Helper: create or reuse a group by name; prints the group UUID
# ---------------------------------------------------------------------------
ensure_group() {
  local name="$1"
  local display_name="$2"
  local description="$3"

  local existing_id
  existing_id=$(find_group_id "${name}")

  if [[ -n "${existing_id}" ]]; then
    echo "  Group '${name}' already exists — skipping creation (id: ${existing_id})" >&2
    echo "${existing_id}"
    return
  fi

  local response
  response=$(curl -sf \
    -X POST \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    --data-ascii "{\"name\":\"${name}\",\"display_name\":\"${display_name}\",\"description\":\"${description}\"}" \
    "${API}/groups") || {
    echo "ERROR: POST /api/v1/identity/groups failed for name='${name}'." >&2
    exit 1
  }

  local group_id
  group_id=$(echo "${response}" | jq -r '.id // empty')
  if [[ -z "${group_id}" ]]; then
    echo "ERROR: POST /api/v1/identity/groups returned no id for '${name}'." >&2
    echo "Response: ${response}" >&2
    exit 1
  fi
  echo "  Group '${name}' created (id: ${group_id})" >&2
  echo "${group_id}"
}

# ---------------------------------------------------------------------------
# Helper: upsert tenant_role binding (POST /roles is an upsert — no pre-check needed)
# ---------------------------------------------------------------------------
upsert_role() {
  local name="$1"
  local group_id="$2"

  local response
  response=$(curl -sf \
    -X POST \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    --data-ascii "{\"name\":\"${name}\",\"kind\":\"process_routing_role\",\"group_id\":\"${group_id}\"}" \
    "${API}/roles") || {
    echo "ERROR: POST /api/v1/identity/roles failed for name='${name}'." >&2
    exit 1
  }

  local role_id
  role_id=$(echo "${response}" | jq -r '.id // empty')
  if [[ -z "${role_id}" ]]; then
    echo "ERROR: POST /api/v1/identity/roles returned no id for '${name}'." >&2
    echo "Response: ${response}" >&2
    exit 1
  fi
  echo "  Role '${name}' upserted (id: ${role_id})" >&2
}

# ---------------------------------------------------------------------------
# Helper: add user to group (naturally idempotent — 200 or 201 are both success)
# ---------------------------------------------------------------------------
add_group_member() {
  local group_id="$1"
  local user_id="$2"
  local label="$3"

  local http_status
  http_status=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    --data-ascii "{\"user_id\":\"${user_id}\"}" \
    "${API}/groups/${group_id}/members")

  case "${http_status}" in
    200) echo "  ${label} — already a member (200)" ;;
    201) echo "  ${label} — membership created (201)" ;;
    *)
      echo "ERROR: POST /api/v1/identity/groups/${group_id}/members returned HTTP ${http_status} for ${label}." >&2
      exit 1
      ;;
  esac
}

# ===========================================================================
# Step 1: Resolve TASK_WORKER group (must already exist — seeded at onboarding)
# ===========================================================================
echo "--- Step 1: Resolve TASK_WORKER group ---"
ROLES_RESPONSE=$(curl -sf \
  -H "${AUTH_HEADER}" \
  "${API}/roles") || {
  echo "ERROR: GET /api/v1/identity/roles failed (HTTP error)." >&2
  exit 1
}

TASK_WORKER_GROUP_ID=$(echo "${ROLES_RESPONSE}" | jq -r '.items[] | select(.name=="TASK_WORKER") | .group_id' | head -1)

if [[ -z "${TASK_WORKER_GROUP_ID}" ]]; then
  echo "ERROR: TASK_WORKER platform role not seeded." >&2
  echo "       Run tenant onboarding (RoleRegistry.seed_default_platform_role_groups/1) for the swiftroute tenant before running this script." >&2
  exit 1
fi
echo "  TASK_WORKER group_id: ${TASK_WORKER_GROUP_ID}"

# ===========================================================================
# Step 2: Ensure process-routing groups + role bindings exist
# ===========================================================================
echo ""
echo "--- Step 2: Ensure role-ops-manager group and tenant_role ---"
OPS_MGR_GROUP_ID=$(ensure_group \
  "role-ops-manager" \
  "Ops Manager" \
  "Process-routing role for operations managers in the SwiftRoute shipment approval process.")
upsert_role "role-ops-manager" "${OPS_MGR_GROUP_ID}"

echo ""
echo "--- Step 3: Ensure role-ceo group and tenant_role ---"
CEO_GROUP_ID=$(ensure_group \
  "role-ceo" \
  "CEO" \
  "Process-routing role for CEOs in the SwiftRoute shipment approval process.")
upsert_role "role-ceo" "${CEO_GROUP_ID}"

# ===========================================================================
# Step 3: Resolve persona actor user IDs (abort cleanly if Part A is missing)
# ===========================================================================
echo ""
echo "--- Step 4: Resolve persona actor user IDs ---"
LENA_ID=$(lookup_user_id "actor-swiftroute-lena")
echo "  actor-swiftroute-lena  : ${LENA_ID}"
MARCO_ID=$(lookup_user_id "actor-swiftroute-marco")
echo "  actor-swiftroute-marco : ${MARCO_ID}"
ALICE_ID=$(lookup_user_id "actor-swiftroute-alice")
echo "  actor-swiftroute-alice : ${ALICE_ID}"

# ===========================================================================
# Step 4: Add group memberships per §4 persona mapping
# ===========================================================================
echo ""
echo "--- Step 5: Add group memberships ---"

# Lena → TASK_WORKER only
add_group_member "${TASK_WORKER_GROUP_ID}" "${LENA_ID}"  "lena  → TASK_WORKER"

# Marco → TASK_WORKER + role-ops-manager
add_group_member "${TASK_WORKER_GROUP_ID}" "${MARCO_ID}" "marco → TASK_WORKER"
add_group_member "${OPS_MGR_GROUP_ID}"     "${MARCO_ID}" "marco → role-ops-manager"

# Alice → TASK_WORKER + role-ceo
add_group_member "${TASK_WORKER_GROUP_ID}" "${ALICE_ID}" "alice → TASK_WORKER"
add_group_member "${CEO_GROUP_ID}"         "${ALICE_ID}" "alice → role-ceo"

# ===========================================================================
# Summary + Verification hints
# ===========================================================================
echo ""
echo "=== Provisioning complete ==="
echo "  role-ops-manager group_id : ${OPS_MGR_GROUP_ID}"
echo "  role-ceo group_id         : ${CEO_GROUP_ID}"
echo "  TASK_WORKER group_id      : ${TASK_WORKER_GROUP_ID}"
echo ""
echo "--- Verification ---"
echo "# 1. Confirm role-ops-manager and role-ceo tenant_role rows exist:"
echo "curl -sf -H \"Authorization: Bearer \$QA_AUTH_TOKEN\" \\"
echo "  \"${QA_URL}/api/v1/identity/roles\" | \\"
echo "  jq '[.items[] | select(.name == \"role-ops-manager\" or .name == \"role-ceo\")]'"
echo "# Expected: 2 items, each with kind == \"process_routing_role\""
echo ""
echo "# 2. Confirm marco is a member of role-ops-manager:"
echo "curl -sf -H \"Authorization: Bearer \$QA_AUTH_TOKEN\" \\"
echo "  \"${QA_URL}/api/v1/identity/groups/${OPS_MGR_GROUP_ID}/members\" | \\"
echo "  jq '[.items[] | select(.username == \"actor-swiftroute-marco\")]'"
echo "# Expected: 1 item"
echo ""
echo "# 3. Confirm alice is a member of role-ceo:"
echo "curl -sf -H \"Authorization: Bearer \$QA_AUTH_TOKEN\" \\"
echo "  \"${QA_URL}/api/v1/identity/groups/${CEO_GROUP_ID}/members\" | \\"
echo "  jq '[.items[] | select(.username == \"actor-swiftroute-alice\")]'"
echo "# Expected: 1 item"
echo ""
echo "# 4. Confirm lena, marco, alice are all TASK_WORKER members:"
echo "curl -sf -H \"Authorization: Bearer \$QA_AUTH_TOKEN\" \\"
echo "  \"${QA_URL}/api/v1/identity/groups/${TASK_WORKER_GROUP_ID}/members\" | \\"
echo "  jq '[.items[] | select(.username | test(\"actor-swiftroute-(lena|marco|alice)\"))]'"
echo "# Expected: 3 items"
