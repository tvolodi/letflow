# 0013 — The authorization role set is five roles; the realm gains `PROCESS_OPERATOR`

Status: decided (2026-08-22). Owner: ELIXIR-DEV.

## Question

Three places in this system name a set of roles, and they do not agree:

| Source | Role set |
|---|---|
| `Letflow.Api.Authorization` (REQ-069, `done`) | `PLATFORM_ADMIN`, `PROCESS_DESIGNER`, **`PROCESS_OPERATOR`**, `TASK_WORKER`, `AGENT_RUNNER` |
| R-Co's dev realm fixture, `infrastructure/keycloak/realms/bpm-default.json` | `PLATFORM_ADMIN`, `PROCESS_DESIGNER`, `TASK_WORKER`, `AGENT_RUNNER` — **no `PROCESS_OPERATOR`** |
| `web/src/components/layout/AppShell.tsx` nav gating | `PLATFORM_ADMIN`, `PROCESS_DESIGNER`, **`PROCESS_OPERATOR`**, `TASK_WORKER` |

The SPA gates four nav entries — Instances, My Tasks, DLQ, Webhooks — on a role
that the realm cannot issue. R-Co worked around this in the same file by seeding
its `operator-user` with `PLATFORM_ADMIN` instead.

So: does Letflow reconcile *downward* (drop `PROCESS_OPERATOR` from the matrix
and the SPA, matching the realm), or *upward* (add the role to the realm)?

## Decision

**Upward. The five-role matrix in `Letflow.Api.Authorization` is the contract.
Every realm Letflow authenticates against must define all five roles, including
`PROCESS_OPERATOR`.** Nothing is reconciled downward; no role is removed from the
matrix or from the SPA's nav gating.

## Reasoning

This looked like a design question and turned out to be a defect. The evidence
decides it:

PROVENANCE (historical, not current decision authority):
**R-Co's own backend defines the role.** `src/api/authorization.zig` declares
`PROCESS_OPERATOR` in its `Role` enum, and the identifier appears **48 times**
across `src/` — including a full permission arm (`.PROCESS_OPERATOR => switch
(permission)`, line 197), a guard clause at line 145, and named tests such as
`TC-IDN-03-02: TASK_WORKER + PROCESS_OPERATOR can cancel instances`. The role is
load-bearing in the source Letflow ported from. `src/api/middleware/auth.zig`
maps the string `"PROCESS_OPERATOR"` onto it during claim parsing, so R-Co's
backend is built to *receive* the role from a token.

**REQ-069 ported it correctly.** `Letflow.Api.Authorization` is a faithful port
of a 281-line module. The five-role set is not an invention to be trimmed — it
is the thing the port was gated on.

PROVENANCE (historical, not current decision authority):
**The realm file is the odd one out, and it is a dev fixture.**
`bpm-default.json` is 175 lines of local bootstrap data, imported by
`start-dev --import-realm`. It is not a specification of the platform's role
model, and it was never validated against `authorization.zig` — which is
precisely how it came to omit a role the backend has 48 references to. The
`operator-user` seeded with `PLATFORM_ADMIN` is the tell: someone needed an
operator account, found the role missing, and granted admin instead of fixing
the fixture.

**Reconciling downward would silently widen privilege.** That workaround is not
cosmetic. Under it, an account named for the operator role holds full platform
administration — every admin route, every tenant. Copying the fixture into
Letflow unexamined would import a privilege escalation as a seed value, and it
would look intentional because it is checked in. Deleting `PROCESS_OPERATOR`
from the matrix instead would make that permanent: the four nav entries gated on
it would have to be regranted to some other role, and the only role that
currently covers them is `PLATFORM_ADMIN`.

**The cost is asymmetric.** Adding a role to a realm is a JSON entry. Removing a
role from an authorization matrix means re-deriving every permission arm it
appears in, changing the SPA's gating, and diverging from the R-Co contract that
S7's parity work will eventually be measured against.

## Consequences

- Letflow's realm configuration defines five realm roles. `REQ-128` creates it
  that way from the start rather than importing R-Co's file and patching it.
- The seeded operator account holds `PROCESS_OPERATOR`, **not** `PLATFORM_ADMIN`.
  Carrying R-Co's grant across would defeat the point of this record.
- `REQ-129` verifies the three sources agree, and adds a check that fails if they
  drift again. A mismatch between an authorization matrix and an identity
  provider's issuable roles is invisible at compile time in both languages and
  silent at runtime — the role simply never appears in a token — so it needs a
  test, not a convention.
- `AGENT_RUNNER` stays in the matrix and stays absent from the SPA's nav, which
  is correct and not part of this drift: it is a machine role for the deferred
  runtime-agent subsystem, and `Api.Authorization`'s moduledoc already records it
  as ported-but-unreachable. It should exist in the realm for the same reason it
  exists in the matrix — so the port stays faithful — but no human user is seeded
  with it.
- This record does **not** settle how roles map to Keycloak *groups*, or whether
  tenant-scoped roles (`Letflow.Identity.TenantRole`) ever feed the same matrix.
  `RoleRegistry`'s moduledoc is explicit that it has no coupling to the
  OIDC/claim-mapping pipeline; that separation is untouched here.

## Note on numbering

`REQ-123` (drafted 2026-08-21) reserved `0013-cutover-strategy.md` for S8's
cutover decision, which cannot be written until S7 produces a correctness signal.
This record took `0013` because it is being decided now; `REQ-123` was updated in
the same commit to name `0014-cutover-strategy.md`. Decision records are numbered
in the order they are actually decided, not the order they are anticipated.
