#!/usr/bin/env bash
# seed_vortex_persona_actors.sh
#
# Provisions the letflow-side (Part B) of the Vortex persona actors (ISS-0931):
#   - Creates process-routing role groups + tenant_role bindings for every role
#     referenced by the Vortex QA definitions (4 roles)
#   - Adds each persona actor to TASK_WORKER (implicit) and to its role groups
#
# Prerequisites:
#   - curl and jq installed
#   - Part A done: Keycloak accounts actor-vortex-* exist and have synced into
#     letflow's users table (ai-dala-infra). Missing actor => abort naming it.
#   - QA_AUTH_TOKEN: Bearer token for a PLATFORM_ADMIN user in the vortex tenant
#       (GroupsManage + RolesManage + UsersManage).
#   - QA_URL: base URL (default: https://qa.bizdala.com)
#   - Run AFTER scripts/seed_vortex_definition.sh.
#
# Usage:
#   QA_AUTH_TOKEN="<token>" bash scripts/seed_vortex_persona_actors.sh
#
# Assumption: the persona -> role mapping comes from the scenario `actors:` blocks
# (test/fixtures/uat/scenarios/vortex/*.yaml) and
# test/fixtures/simulation/vortex/org_structure.yaml; dirk -> role-ceo is inferred
# from org structure, not stated verbatim. Role groups are the authoritative part;
# a BA may amend the PERSONAS table only.
# TASK_WORKER is implicit for every persona and never listed below.
#
# role-procurement-manager is deliberately NOT seeded: no Vortex definition
# references it (scenario/definition mismatch; flagged to BA-VORTEX).
#
# Design: lib/letflow/design/iss0931-meridian-vortex-persona-actor-provisioning.md

set -euo pipefail

ROLES=(
  "role-production-manager"
  "role-controller"
  "role-quality-manager"
  "role-ceo"
)
PERSONAS=(
  "actor-vortex-sabine|role-production-manager"
  "actor-vortex-stefan|role-controller"
  "actor-vortex-karl|role-quality-manager"
  "actor-vortex-dirk|role-ceo"
  "actor-vortex-anna|"
  "actor-vortex-nina|"
  "actor-vortex-felix|"
  "actor-vortex-max|"
  "actor-vortex-claudia|"
)

source "$(dirname "${BASH_SOURCE[0]}")/lib/seed_persona_actors_base.sh"

persona_require_env
persona_run vortex
