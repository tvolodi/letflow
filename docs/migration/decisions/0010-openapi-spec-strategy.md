# 0010 — OpenAPI spec strategy (OQ-2): defer to S6

Status: decided (REQ-084). Owner: ELIXIR-DEV.

## Question

PROVENANCE (historical, not current decision authority):
`docs/migration/stage-4-api-surface.md`'s OQ-2: R-Co hand-builds and serves an OpenAPI
spec from `src/api/openapi/` (7 modules) plus `routes/openapi.zig`. Does Letflow (a)
hand-build the equivalent, (b) adopt the `open_api_spex` Hex package, or (c) defer spec
generation to S6 and serve no spec in S4? Flagged by `stage-4-api-surface.md` itself as
"Flag to REVIEWER before building; do not decide it inside a route requirement," since
`open_api_spex` is Phoenix-oriented and adopting it would touch
`decisions/0001-web-framework.md`'s framing directly.

**R-Co source, reverified directly against the live tree (not copied from the
requirement filing):**

PROVENANCE (historical, not current decision authority):
```
src/api/openapi/builder.zig          235
src/api/openapi/mod.zig                6
src/api/openapi/model.zig             59
src/api/openapi/path_registry.zig     46
src/api/openapi/schema_registry.zig  290
src/api/openapi/serialize.zig        346
src/api/openapi/version_source.zig    10
                                    -----
  7 modules                          992
src/api/routes/openapi.zig           158
```

**Correction to `stage-4-api-surface.md`'s table:** already applied by an earlier pass
during the 2026-08-19 requirement expansion (the table's OpenAPI row at line 45 already
reads `7 | 992`, with the explanatory note at lines 55-58 crediting REQ-084 as the
correction's owner) — this record is that correction's deliverable landing, not a
duplicate fix. The stale figure the table previously carried was 6 modules / 1,286
lines.

## Dependency on REQ-065 (OQ-0)

This decision is downstream of, not independent of, `decisions/0001-web-framework.md`'s
2026-08-20 addendum: **Plug/Bandit stands; Phoenix is not adopted.** That addendum
names OQ-2 explicitly as one of the two open questions proceeding "against this
addendum's Plug/Bandit conclusion as their now-settled premise rather than an open
question."

`open_api_spex` is built around Phoenix conventions — its ergonomic value (automatic
operation-spec generation from `Phoenix.Controller` actions via
`OpenApiSpex.ControllerSpecs`' `operation/2` macros, and route discovery via
`Phoenix.Router`) assumes a Phoenix router and controller layer that does not exist
under the Plug/Bandit outcome 0001 settled on. The library's lower-level pieces (a
`Plug` for serving the compiled spec, manually-authored `OpenApiSpex.Operation` structs)
are usable outside Phoenix, but at that point the library is contributing little beyond
JSON-Schema struct definitions and a spec-serving plug — the actual per-route operation
authoring, which is the bulk of the 992-line R-Co surface this question is about, would
still be hand-written, one operation at a time, gaining none of the macro-driven
generation that is `open_api_spex`'s actual reason to exist under Phoenix. Adopting it
here would mean carrying a Phoenix-shaped dependency for a fraction of its value, or
fighting it to use only the fraction that fits Plug/Bandit — not a clean fit either way.
**`open_api_spex` is not selected**, and no reconciliation with 0001's addendum is
needed beyond stating why it was ruled out.

## Decision

**Defer OpenAPI spec generation to S6. No spec is hand-built, no library is adopted,
and no spec is served in S4.**

## Reasoning

**(a) No consumer exists today.** `web/` is S4/S8's only client, and S8 owns its
integration — grepped `web/` and `mix.exs` directly: no reference to
`open_api_spex`, no `json_schema`/`openapi` spec-consumption code exists anywhere in
this tree today. A spec built now — whether by hand or via a struggling-to-fit library
— has no reader until S8, which makes the full 992-line R-Co port (or an equivalent
hand-built Elixir surface of comparable size) pure carried cost with a payoff that is
several stages away and not yet designed against.

PROVENANCE (historical, not current decision authority):
**(b) Drift risk, and what avoids it.** A hand-built spec that is not generated from
the actual mounted routes goes stale silently the moment a route's shape changes and
the spec isn't updated in lockstep — this is precisely the failure mode R-Co's
`path_registry.zig` (46 lines, a dedicated module for keeping the spec's path table in
sync with the real route table) exists to prevent. Building a hand-maintained spec now,
across S4's ~20 route requirements each written by a separate agent turn, multiplies
that drift surface by every one of those requirements rather than concentrating it in
one later, deliberately-designed pass. Deferring avoids this risk entirely rather than
mitigating it: there is no spec to drift if none is built yet. When S6 does build one,
whatever mechanism is chosen there should be **route-derived** (generated from the
actual `Plug.Router`/sub-router route table, not hand-transcribed) — naming that
constraint now is this record's contribution to that future decision, even though
selecting the mechanism itself is out of scope here.

PROVENANCE (historical, not current decision authority):
**(c) No Elixir equivalent to `schema_registry.zig` exists yet.** Checked directly:
no `open_api_spex` dependency in `mix.exs`, and no Ecto-schema-to-JSON-Schema
generation tooling exists anywhere in `lib/` today (the `json_schema` references that
do exist, in `lib/letflow/definitions/graph.ex` and
`lib/letflow/definitions/sub_process_interface.ex`, are workflow pin/variable schema
validation — an unrelated, pre-existing concern, not API spec generation).
`schema_registry.zig`'s 290 lines are R-Co's answer to turning its own struct
definitions into JSON-Schema fragments; Letflow's equivalent would need to reason from
Ecto schemas instead, which is a genuinely separate design question (do Ecto's
`__schema__/1` reflection functions carry enough type information to auto-derive a
JSON-Schema fragment, or does every schema need a hand-written one?) that this record
does not need to answer, because deferring means it does not need answering yet.

**Combined**, (a)+(b)+(c) point the same direction: there is no reader, hand-building
now maximizes rather than minimizes drift risk, and neither adopting a library nor
hand-building has a ready answer for the schema-generation piece today. Deferring costs
nothing S4 needs and avoids committing to an approach before S8's actual consumption
shape (what `web/` needs from the spec, if anything beyond documentation) is known.

## Ownership of execution

PROVENANCE (historical, not current decision authority):
**S6** owns the eventual OpenAPI spec work, alongside the rest of S6's operational
cross-cutting scope (the same stage `docs/migration/README.md` and other S4
requirements — e.g. REQ-068's `rate_limit.zig`/`quota_enforcement.zig` scope
boundary — already point deferred cross-cutting concerns toward). No S6 requirement is
numbered yet; this record does not invent one, consistent with this repo's own
precedent for naming a future stage as the owner without fabricating a requirement ID
ahead of that stage's expansion. Whichever future requirement performs the port should
be written against **this** record's Decision (defer, don't hand-build, don't adopt
`open_api_spex` under a Plug/Bandit router) rather than re-opening the question.

## Scope

This record adds no `mix.exs` dependency and changes no `lib/` code — confirmed via
`git diff --stat` against `origin/main`, which shows only `docs/` files touched by this
requirement.
