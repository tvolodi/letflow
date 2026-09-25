# Decision 0040 — Authenticated Route Rate Limiting

**Date:** 2026-09-25  
**Filed by:** ORCH (ISS-0826, GH#1819)  
**Status:** decided

---

## Context

Discovered by SECURITY-REVIEWER during WF03-ISS0816-20260925 Step 3c while assessing
whether a proposed client-side member-drain (`groupsApi.listAllMembers`, up to 20
sequential requests per gesture) could amplify load on authenticated list routes.

`Letflow.Plugs.PublicReadRateLimit` is mounted only on `Letflow.Routers.PublicRead`
(the unauthenticated public read surface). Authenticated traffic passes through
`Letflow.Plugs.Admission` (`pool: :global`, `pool: :tenant`), which bounds
**concurrency** — the number of in-flight requests simultaneously — not **rate** — the
number of requests over time. A strictly sequential client occupies one admission slot
and can issue an unlimited number of requests sequentially over time without ever
tripping the concurrency pool.

So there is currently **no per-actor rate limit on authenticated list routes.**

## Decision

**No per-actor rate limit is added at this stage.** The rationale:

1. **Concurrency bounding is the meaningful protection today.** Letflow's admission
   pools (`Letflow.Plugs.Admission`) ensure that burst traffic from any client (or any
   group of clients) cannot exhaust the database connection pool or overwhelm the VM
   scheduler. Admission rejects requests when capacity is saturated — the server
   degrades gracefully rather than being overwhelmed. This is the correct protection
   against the threat model of concern (overloaded infra), even without a rate limiter.

2. **Sequential clients are bounded by admission.** A client issuing sequential
   requests occupies exactly one admission slot per request; its pipeline is naturally
   rate-limited by round-trip latency. Only parallel clients (multiple simultaneous
   requests) could saturate the concurrency pool — and parallel clients are already
   bounded.

3. **The specific case that surfaced this finding is benign.** The `listAllMembers`
   drain issues at most 20 sequential requests per user gesture, with at most one
   in-flight at a time. The realistic path is a single request (page_size 200 is
   `@max_page_size`). This does not constitute an amplifier.

4. **Per-actor rate limiting is planned but deferred to S4.** R-Co's
   `src/api/middleware/rate_limit.zig` and `src/api/middleware/quota_enforcement.zig`
   are explicit S4 deferred plugs — see `lib/letflow/plugs/api_pipeline.ex`'s
   "Deferred plugs" table (`Letflow.Plugs.RateLimit`, `Letflow.Plugs.QuotaEnforcement`
   with owning-stage S4). The design for per-actor rate limiting belongs in S4's own
   requirements, not here as a side-effect of a MINOR finding.

## Concurrency vs. rate — the distinction

These two mechanisms are often conflated but are different:

- **Concurrency bounding** (Admission): limits *how many requests are simultaneously
  in flight*. A client that sends 1 000 requests sequentially is never rejected —
  it just waits for each to complete before sending the next, and each request is
  processed normally.
- **Rate limiting** (not yet present for authenticated traffic): limits *how many
  requests a caller may send per unit of time*, regardless of concurrency. This
  prevents a sequential flood that would otherwise overwhelm downstream resources
  over time.

The current stance is: concurrency bounding is the operative protection for now;
rate limiting is explicitly S4 work.

## What a future SECURITY-REVIEWER gate should know

When reviewing any change that adds or modifies authenticated list routes:

- `Letflow.Plugs.Admission` provides concurrency bounding, not rate limiting.
  A 200-OK response from an admission-gated route does not mean the actor is
  rate-limited; it means there was available concurrency capacity.
- No per-actor rate limit exists on authenticated routes as of this writing.
  A change that could amplify sequential request volume per actor should flag
  this explicitly in the SECURITY-REVIEWER handoff, cite this decision record,
  and note the actor's realistic request count per gesture (as the SECURITY-REVIEWER
  who filed ISS-0826 correctly did).
- Per-actor rate limiting is S4 planned work (`Letflow.Plugs.RateLimit`,
  `api_pipeline.ex` deferred-plugs table). Do not design around its absence as
  if it will never arrive.

## Related

- `docs/agents/instructions/security-invariants.md` (no INV for rate limiting — this
  record IS the explicit statement of the current position)
- `lib/letflow/plugs/api_pipeline.ex` (deferred plugs table: RateLimit, QuotaEnforcement)
- `lib/letflow/plugs/admission.ex` (the operative concurrency bound)
- ISS-0826 / GH#1819 (the filing that triggered this record)
