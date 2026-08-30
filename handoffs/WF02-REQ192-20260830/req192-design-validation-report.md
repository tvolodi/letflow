# REQ-192 CODE-DESIGN-VALIDATOR report (Step 1b, iteration 2 — recheck after rework 1)

Verdict: **PASS**

## What changed since iteration 1 (rework 1, commit c53d9e36)

Diffed `7ea5acb9..c53d9e36` for `lib/letflow/design/req192-service-catalog-routes.md`
directly (not trusting CODE-DESIGNER's summary). Only §5 changed, in exactly the way
required:

1. The false claim that querying `Letflow.ServiceCatalog.Entry` directly from the router
   "is not different in kind from `Letflow.Routers.Audit`'s or `Letflow.Routers.Metrics`'s
   own direct-schema-query precedents" is **gone** — that sentence was deleted, not
   reworded/hedged.
2. New text added in its place states plainly: *"This is not backed by existing
   precedent — it is a deliberate, first-of-its-kind exception, flagged here for REVIEWER
   sign-off, not something this design rests on prior art."* It then correctly names what
   Audit and Metrics actually do — `Letflow.Routers.Audit` delegates to
   `Letflow.EventStore.read_global/1`; `Letflow.Routers.Metrics` delegates to
   `Letflow.Engine.count_instances_by_status/1` and sibling context-module functions —
   explicitly as *context-module calls*, distinct from what this design proposes (a raw
   `Repo`/`Ecto.Query` call from the router itself). Independently re-read both
   `lib/letflow/routers/audit.ex` and `lib/letflow/routers/metrics.ex` to confirm this
   characterization is accurate (matches iteration 1's own finding).
3. The exception is explicitly routed to REVIEWER for a real sign-off decision at Step
   2d ("REVIEWER must independently weigh and explicitly sign off on this exception... it
   is not to be treated as routine or pre-approved by analogy to anything already in the
   codebase") — not treated as pre-approved.
4. The adjoining "Named as a finding for REVIEWER" paragraph (keyset-shape duplication of
   `list_for_tenant/2`) was cross-referenced to the exception above ("in addition to the
   layering exception above" / "retiring the direct-schema-query exception entirely") —
   consistent addition, not a new defect.

No other section of the diff was touched. The underlying decision (query `Entry` directly)
was correctly left unchanged — only its justification was corrected, as required.

## Re-verified unchanged (byte-for-byte, per the diff) from iteration 1's PASS findings

1. **Two-router claim (§1)** — untouched by the diff; previously verified against
   `test/letflow/api/authorization_enforcement_test.exs` L55-90's `@mount_prefix`
   mechanism.
2. **Permission mapping (§3)** — untouched; previously verified against
   `lib/letflow/api/authorization.ex` L108-113, L308-313, L417-419, L453-484.
3. **409 `Error` constructors (§11)** — untouched; previously verified against
   `lib/letflow/api/error.ex` L55-65, L351-360 and `service_catalog.ex`'s real
   `update_scope/2`/`delete/1` return shapes.
4. **Field-gap findings (§8)** — untouched; both `max_retries` and
   `request_schema`/`response_schema` gaps against `web/src/api/services.ts` and
   `entry.ex`/`service_catalog.ex`'s `register_attrs()` still stand as previously
   verified.
5. **Stale-comment finding (§3)** — untouched; `authorization.ex` L416-419's stale
   "platform-admin enforced in handler" comment finding still correctly left unfixed.
6. **No implementation code.** `grep -n '```'` over the current full file returns zero
   matches.

## Conclusion

The rework fixes the exact defect named in iteration 1 (fabricated precedent claim),
does so honestly (names the real Audit/Metrics behavior instead of just deleting the
claim and leaving a gap), and correctly defers the actual accept/reject judgment on the
layering exception to REVIEWER rather than smuggling in self-approval. No new defect
introduced, nothing else regressed. All 10 acceptance criteria still map to concrete
design sections (§4 AC1, §5 AC2, §6/§7 AC3, §13 AC4, §9/§12 AC5, §6 AC6, §10 AC7, §14
AC8, §14 AC9, out of design scope AC10/mix test+compile). No TBD/deferral language.

Routing to ELIXIR-DEV (Step 2a) with the original acceptance criteria plus three findings
carried forward as implementation/REVIEWER-attention items: (1) the two `ServiceRecord`/
`Entry` field gaps (`max_retries`, `request_schema`/`response_schema`) and their stated
interim resolutions, (2) the stale `authorization.ex` L416-419 comment (left unfixed, out
of scope), and (3) the §5 direct-schema-query layering exception, explicitly flagged for
REVIEWER sign-off at Step 2d.
