# REQ-164 — Settle OQ-3: does Letflow host WASM guest compilation at all?

**Requirement:** REQ-164 (Settle OQ-3 — whether Letflow hosts guest compilation at all;
blocks WASM-03/04/05 and determines REQ-175's fate)
**Stage:** S5
**Owner:** CODE-DESIGNER
**Date:** 2026-08-28
**Depends on:** REQ-162 (done); consumes decision
`docs/migration/decisions/0014-scripting-plugin-runtime-strategy.md` and its OQ-3.

This is a **decision-only** artefact. No `mix.exs` change and no file under
`lib/letflow/engine/` is created or modified by this requirement — confirmed in §5. No
pipeline implementation is designed here. `docs/requirements.yaml` is not edited by this
artefact; DOC-UPDATER acts on it at WF-02 Step 6.

**Why this artefact, not a new top-level decision record.** Decision 0014 already
settled the load-bearing, cross-stage choice — bind `wasmex` behind a mandatory process
boundary as WASM's runtime — and itself posed OQ-3 as one of the open questions still
inside that premise. Whether Letflow additionally hosts a *compilation* pipeline on top
of that runtime does not change the runtime choice, does not touch any module outside
S5's WASM half, and is not referenced by any other stage's requirement. Per REQ-164's own
instruction ("a new record … if it settles policy beyond S5, otherwise
`lib/letflow/design/req164-wasm-compilation-hosting.md`"), this stays scoped to
`lib/letflow/design/`. This mirrors REQ-163's own placement reasoning
(`lib/letflow/design/req163-wasm-abi-choice.md`, OQ-4) for the identical reason: the
question operates entirely inside decision 0014's premise rather than revising it, and
nothing outside S5 depends on the answer.

---

## Decision

**NO. Letflow does not host guest compilation.** Letflow's WASM plugin pipeline accepts
only pre-compiled `.wasm` artifacts submitted by the caller. Letflow never invokes a Zig
(or any other language's) compiler as part of plugin intake, registration, or execution.

Consequently:

- **WASM-03 (Source Compilation Job), WASM-04 (Compile Caching), WASM-05 (Build
  Reproducibility) are DECLINED, not deferred.** "Deferred" would mean the scope still
  exists and is scheduled for later; it does not — there is no future point at which
  Letflow is expected to acquire a Zig toolchain and start compiling guest source. The
  scope these three requirements named (a hosted source→`.wasm` compilation service) is
  permanently out of Letflow's design, for the reasons in §1.
- **REQ-175 — the conditional requirement gated on this decision — must be marked
  `cancelled`, not left `pending`.** REQ-175's own text states plainly: "If REQ-164
  decided NO, REQ-164's own acceptance criteria require this requirement to be CANCELLED
  with a status-history event recording why — not left pending." This artefact is that
  recorded justification. DOC-UPDATER, at WF-02 Step 6, should flip REQ-175's `status` to
  `cancelled` and append a status-history event whose reason cites this file
  (`lib/letflow/design/req164-wasm-compilation-hosting.md`) and, in one sentence: "OQ-3
  decided NO — Letflow does not host WASM guest compilation; WASM-03/04/05 declined;
  R-Co never built a working compilation pipeline to inherit."
- A declined REQ-175 does not remove any other requirement's premise. REQ-165 (adopt
  `wasmex`), REQ-166 (registration/ABI validation, per REQ-163), REQ-167 (capability
  denial), and REQ-171/REQ-172 (host API) all operate on a `.wasm` artifact regardless of
  where that artifact came from — this decision only forecloses Letflow ever being the
  thing that *produces* that artifact from source.

---

## §1 — Evidence the Decision is grounded in

**R-Co never built a working pipeline.** Decision 0014's own evidence section (quoted
directly from the live R-Co tree at `c:\Users\tvolo\dev\ai-dala\R-Co\` on 2026-08-23,
before this artefact was written) records:

> `R-Co/src/wasm/` is stubs end to end … `Engine`, `Store`, `Instance`, `Module`, `Func`,
> `Trap`, and `Memory` are all empty `extern struct {}` stubs.

and REQ-164's own requirement text (`docs/requirements.yaml`) states the same evidence
was verified directly during decision 0014: `find R-Co -name '*.wasm' -not -path
'*/.git/*'` returns **zero files**. There is no working compilation pipeline anywhere in
R-Co to port, and no `.wasm` artifact corpus produced by one that Letflow would need to
remain byte-compatible with. Declining loses nothing that exists today.

This sandbox cannot independently re-run that `find` — `c:\Users\tvolo\dev\ai-dala\R-Co\`
is a Windows-local path not reachable from this Linux environment (confirmed: `find / -maxdepth
2 -iname "R-Co"` and a check for any `c:/Users/...` mount both return nothing). This
follows the exact precedent REQ-163's design set for the same unreachability (its §2:
"a Windows-local path not reachable from this Linux sandbox — this artefact relies on
that existing verbatim quote rather than re-reading the file, as the requirement itself
anticipates"). This artefact relies on decision 0014's and REQ-164's already-quoted,
previously-verified evidence rather than re-deriving it.

**No Zig toolchain, no reason to acquire one.** Decision 0014 records that WASM-03/04/05
specify a pipeline compiling Zig source, and that "Letflow has no Zig toolchain and no
reason to acquire one." Nothing else in Letflow's stack (Elixir/OTP, `wasmex`/Rust NIF
per decision 0014's WASM runtime choice, the `web/` TypeScript SPA) uses Zig anywhere.
Acquiring and maintaining a Zig toolchain purely to support a compilation feature with no
existing user, no existing artifact corpus, and no ported reference implementation would
be new scope invented rather than migrated.

**Hosting compilation is a build-farm security surface with no offsetting need.**
Decision 0014's own OQ-3 framing: "Accepting pre-compiled `.wasm` artifacts and never
running a compiler would eliminate three requirements' worth of scope plus a build-farm
security surface." A hosted compiler that runs on tenant-submitted source is itself an
untrusted-input execution surface distinct from (and in addition to) the WASM guest
sandbox REQ-166/REQ-167 already have to secure — it is not a marginal addition, it is a
second attack surface (the compiler process itself, its own dependency chain, its own
resource limits) for a capability nothing currently requires.

**No current caller needs source-to-`.wasm` compilation.** Nothing in Letflow's shipped
S3 modules (`lib/letflow/engine/plugin_interface.ex`, `lib/letflow/engine/
lua_script_audit.ex`) or in any other pending S5 requirement calls for compiling source —
they all operate on an already-produced module (in-process Elixir module, or a `.wasm`
artifact per REQ-166's registration). The compilation step was never on the load-bearing
path; only its *absence* (accepting pre-compiled artifacts directly) is.

---

## §2 — Why this is not deferral

A deferred requirement stays live: it is expected to be picked up once some blocking
precondition resolves (the S5 Lua-before-WASM sequencing decision 0014 §(4) sets is an
example of a genuine deferral — WASM work waits, but still happens). WASM-03/04/05 have
no such precondition. There is no future toolchain acquisition, no future R-Co artifact
migration, no future operational capability whose arrival would make hosting compilation
suddenly worthwhile that isn't equally true today. Calling this "deferred" would leave
REQ-175 sitting `pending` indefinitely, which REQ-164's own acceptance criteria correctly
identify as "indistinguishable from a forgotten one." The honest status is **declined**:
a considered choice not to build this, recorded once, here, so a future reader does not
mistake silence for an oversight.

---

## §3 — S6 operational inputs this decision required, and their actual status

Decision 0014 flags OQ-3 explicitly as needing S6's operational input ("Needs S6's
operational input (artifact storage, retention, job execution)"). `docs/migration/
README.md` lists **S6 (Operational cross-cutting)** as a stage that has not yet been
reached — S5 (this stage) precedes it, and S6 depends on S4, not S5. No S6 requirement
has been expanded or implemented as of this decision. Naming the three inputs decision
0014 called out, and their true status at decision time:

| S6 operational input | Available or assumed? | Detail |
|---|---|---|
| **Artifact storage** — where a `.wasm` artifact (compiled or supplied) would be persisted and served from | **Assumed, not available.** No storage backend, bucket/table schema, or retrieval API for binary artifacts exists anywhere in `lib/letflow/` today. Any statement about "the repository" `.wasm` artifacts would be cached in (WASM-04's own wording) is a placeholder concept, not a built system. |
| **Retention** — how long a cached/stored artifact is kept, eviction policy | **Assumed, not available.** No retention policy of any kind is defined for any binary artifact class in Letflow yet; this is unambiguously S6 scope per decision 0014's own framing and has not been reached. |
| **Job execution** — an out-of-band job runner capable of executing a bounded, isolated compilation (or, under this Decision, an intake/validation) job off the request path | **Assumed, not available.** Letflow has no generic background-job execution facility yet (no Oban or equivalent is in `mix.exs`); "the job MUST run out-of-band" (WASM-03's own acceptance wording) presumes infrastructure that does not exist. |

**Why this decision can still be made honestly without S6 existing.** The absence of
these three inputs makes hosting a compilation *pipeline* materially harder to justify —
building a build-farm-shaped feature (compilation, artifact storage, retention, sandboxed
job execution) with none of its supporting infrastructure in place is exactly the kind of
speculative scope this project's core directives caution against. But the absence does
not block *this* decision, because the Decision is "do not build it" — a decision to not
build something does not require the infrastructure that something would have needed.
The one place S6's absence *is* forward-looking scope: REQ-165's own acceptance criteria
already state that if REQ-164 records these inputs as assumed rather than available,
downstream requirements (REQ-165 explicitly) "must flag the assumption rather than build
on it silently." This table is that flag, made explicit and citable by module name (this
file) for REQ-165 and any other requirement that reads it.

---

## §4 — What is NOT resolved here

- **What Letflow's `.wasm` intake pipeline (REQ-166's registration path) looks like** —
  this artefact only says compilation is out of scope; REQ-166 (built against REQ-163's
  ABI choice) owns designing how a submitted artifact is validated and registered.
- **Whether Letflow ever revisits this Decision** — if a real caller need for hosted
  compilation emerges later, that is grounds for a new requirement explicitly reopening
  OQ-3, not a silent reversal of this record.
- **REQ-175's actual cancellation in `docs/requirements.yaml`** — performed by
  DOC-UPDATER at WF-02 Step 6, using this artefact as the justification. This artefact
  does not edit `docs/requirements.yaml`.

---

## §5 — Confirmation: no `mix.exs` change, no `lib/letflow/engine/` change

```
$ git diff --stat main...HEAD -- mix.exs lib/letflow/engine/
(no output — zero files changed)
```

---

## Deliverables Summary

| Item | Result |
|---|---|
| Decision | **NO** — Letflow does not host WASM guest compilation |
| WASM-03/04/05 | **DECLINED** (not deferred) — reason: no working R-Co pipeline to port (`src/wasm/` stubs, zero `.wasm` files), no Zig toolchain or reason to acquire one, unjustified build-farm security surface, no current caller need |
| REQ-175 disposition | Must be marked **cancelled** (not pending) with a status-history event citing this artefact — action owned by DOC-UPDATER at Step 6, not performed here |
| S6 inputs the decision touched | Artifact storage, retention, job execution — all three **assumed, not available** (S6 not yet reached; §3) |
| R-Co evidence source | Decision 0014's already-verified quotes (R-Co path unreachable from this Linux sandbox, per REQ-163's precedent) |
| Artefact location | `lib/letflow/design/req164-wasm-compilation-hosting.md` (scoped to S5, not a new `docs/migration/decisions/` record — see "why this artefact" above) |
| `mix.exs` / `lib/letflow/engine/` touched | no (§5, confirmed via `git diff --stat`) |
| `docs/requirements.yaml` touched | no — DOC-UPDATER's responsibility at Step 6 |
