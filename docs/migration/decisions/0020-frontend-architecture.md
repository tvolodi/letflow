# 0020 — Frontend architecture: design-system primitives, tenant-settings vocabulary, and the form-schema split

Status: decided (ratified before this file existed; formalized/backfilled 2026-09-09,
per ISS-0546). Owner: the underlying architecture decision was made by whichever
discovery session filed REQ-272 through REQ-289 on 2026-09-08 (evidenced below); this
record's own authorship (CODE-DESIGNER, WF03-ISS0546-20260909) is a backfill, not a new
decision — see "Backfill provenance" below.

## Question

`docs/frontend/design-system.md` (v0.1, 2026-05-20) existed as a component/token
*specification* but had never been formally ratified as the project's frontend
*architecture direction* — nothing tied it to how the backend's tenant-settings surface,
expression validation, and task form-schema plumbing should relate to it. Three
previously-separate areas needed one coordinating decision:

1. **Backend (D1):** what a tenant may configure (branding/locale), and how authored CEL
   expressions get validated before they reach a client evaluator.
2. **Frontend (D2):** whether to build `design-system.md`'s primitives by hand into
   `web/src/components/ui/`, or adopt a third-party component library instead.
3. **Form-schema (D3):** what role `tasks.form_schema` plays relative to the existing
   server-side validation authority (`variable_schemas`).

## Backfill provenance — why this file is dated 2026-09-09 but describes an earlier decision

This record did not exist when REQ-272 through REQ-289 (8 requirements, filed together
2026-09-08) began citing `docs/migration/decisions/0020-frontend-architecture.md` by
name, with three sub-decision labels (D1/D1a, D2/D2a, D3/D3a) and a numbered
"Sequencing" section, as already-settled authority. `docs/issues/ISS-0546.yaml` documents
the resulting gap: REQ-VALIDATOR checks a requirement's own testability, not whether an
external file it cites resolves on disk, so nothing caught the missing file until
RELEASE-VALIDATOR did, on REQ-272's own re-derivation. Two of the eight citing
requirements (REQ-272, REQ-273) were already built and merged, correctly, against this
decision's content before this file existed at all — they followed the constraints the
phantom citation described, they just could not point at a real file.

The content below is **reconstructed, not invented**: it is required to be consistent
with all 8 citations gathered in `docs/issues/ISS-0546.yaml`'s diagnosis (verbatim quotes
from REQ-272, REQ-273, and GitHub issues #1095–#1100 covering REQ-274, REQ-275, REQ-280,
REQ-287, REQ-288, REQ-289). Where a citation states a fact precisely (e.g. an exact
value, an exact clause label), that fact is carried over verbatim below rather than
paraphrased. Where citations imply structure this record must have (e.g. Sequencing
steps 1–3, 5–7) but no citation actually quotes that structure's content, this record
says so explicitly rather than inventing it — see "What this record does not decide."

### Reconstruction superseded by the original, 2026-09-09

The reconstruction described above did its job: seven requirements were built
correctly against it. It is now **replaced by the original text**, recovered from
the session that authored the decision on 2026-09-08 but never pushed its branch
(`fix/iss-0528-wasm-hang-crlf`) — which is precisely why the pipeline saw a
phantom citation and `ISS-0546` had to reconstruct one.

Nothing in the reconstruction's *conclusions* is reversed here; the original
agrees with all of them, which is itself a useful check on the reconstruction's
quality. What the original restores is the **reasoning** the reconstruction could
not recover from citations alone — and reasoning is what stops a settled question
from being re-litigated:

- the alternatives that were **rejected**, and why — tenant-shipped React
  components as an `INV-1` violation, a general scripting runtime as `0014`'s
  problem, a component library on process rather than technical grounds;
- the **`0014` relationship**, which the reconstruction does not mention at all;
- **D1a's full derivation** — that the first draft banned all client-side
  expression evaluation, that this contradicted `MOB-4`'s `computed` field type,
  and that offline form population is what forced the correction;
- the **MOB-4 / MOB-8 reconciliation**: offline *fill* is in scope, offline
  *submit* is not;
- the **security consequences** for both bootstrap endpoints, including that
  `mobile_tenant_config.ex`'s "the other four are byte-identical" `INV-5`
  argument becomes false and must be rewritten in the same change.

The provenance section above is retained deliberately — the process failure it
records is real and worth keeping.

## Decision

Three decisions, in dependency order.

### D1 — Tenants customise by **data**, never by code

A tenant supplies **declarative configuration**; the platform supplies **all
executable code**. No tenant-authored JavaScript, and no general scripting
runtime, executes in a client. Declarative field logic in the platform's own
closed, pure expression grammar is permitted and is covered in D1a below.
Concretely, a tenant may control:

| Surface | Mechanism | Tenant supplies |
|---|---|---|
| Branding | CSS custom-property overrides on `tokens.css` | app name, logo URL, a small fixed set of brand colours |
| Locale | `locales` / `default_locale` | which of the platform's supported locales apply |
| Feature visibility | feature flags | which optional UI areas are reachable |
| **Screen forms** | **JSON Schema + `x-ui` render hints** | field set, order, labels, validation, widget choice |
| **Field logic** | **`Letflow.Engine.Expr` grammar** (D1a) | `visible_when`, `computed`, cross-field validation — evaluated client-side for interactivity, re-checked server-side on submit |

The tenant-facing vocabulary is **closed**: a tenant selects from widget types,
validators and layouts that the platform has implemented, reviewed and tested. A
tenant cannot introduce a new one. Extending the vocabulary is a platform change
that goes through the normal gate chain.

**"Data, never code" survives D1a, and the reason is worth being precise about.**
An expression in a closed, total, effect-free grammar is data: it cannot loop,
cannot call out, cannot reach anything it was not handed, and terminates on every
input. The platform's evaluator is the code; the tenant's expression is an input
to it, exactly as a JSON Schema is an input to the renderer. What "code" means
here — and what stays rejected — is anything that brings its own control flow and
needs a sandbox to be safe.

**Permitted: declarative field logic in a closed, pure grammar.** Conditional
visibility (`visible_when`), computed fields and cross-field validation are
**in scope**, expressed in the existing `Letflow.Engine.Expr` grammar. See
"Client-side logic and the offline constraint" below for why this is not a
contradiction of the next paragraph, and for the rules that keep it safe.

#### Implementation record: REQ-289 corpus location and schema

1. **Canonical path:** `priv/expr_conformance/corpus.json` — placed in `priv/` so it is
   a first-class OTP artifact accessible via `:code.priv_dir(:letflow)` from Elixir and
   via a deterministic relative filesystem path from TypeScript and Dart consumers.
2. **Companion schema document:** `lib/letflow/design/req289-expr-conformance-corpus.md`
   — the authoritative source for the JSON schema, `$marker` sentinel encoding, the
   closed `grammar_constructs` tag vocabulary, and the failure-kind enum. Implementations
   must read this document for schema semantics; the corpus file contains only data.
3. **REQ-293 and REQ-294 dependency:** both MUST consume `priv/expr_conformance/corpus.json`
   directly and are forbidden from building their own corpus or diverging from it. They
   must not begin implementation before this path exists on `main` (enforced by the
   sequencing in Sequencing step 9 above).
4. **Builtin gate:** `priv/expr_conformance/corpus.json` must cover every name returned
   by `Letflow.Engine.Expr.builtin_function_names/0`. Adding a new builtin to that
   function without a corresponding corpus entry with the matching `builtin:<name>` tag
   will fail `test/letflow/engine/expr_conformance_corpus_test.exs`'s coverage-enumeration
   test, which is the intended gate.
5. **REVIEWER sign-off:** recorded once WF02-REQ289-20260909's real REVIEWER step
   runs against this branch -- the earlier placeholder language here is removed
   because no handoff file for that step was ever committed (see this run's own
   Step 00 investigation).

### D2 / D2a — Frontend: design-system primitives, no component library

**Rejected: a general scripting runtime in the client.** Arbitrary tenant script
— Lua, JS, WASM, anything Turing-complete — stays out. That needs a sandbox,
resource limits and an injection-review gate, i.e. it is `0014`'s problem, not a
form-rendering problem. `0014` decided the scripting runtime is **server-side
only**: its host API is `read_variable`, `write_variable`, `call_service`,
`platform.now`, `platform.fail`, and the record contains no UI hook of any kind.
Putting a *scripting engine* in a client would build a second, unreviewed
execution surface with none of `0014`'s process-boundary protections — and
`0014`'s own live-verified findings (a hanging WASM guest is never interrupted;
the Store wedges permanently; a thread leaks per timeout) are a direct warning
about how that goes. A bounded expression grammar is not that, and the
distinction is the subject of the next section.

**Rejected: tenant-shipped React components** (module federation / remote entry).
A tenant bundle loaded into the SPA shares an origin with platform code, so it
can read the session token and any other tenant's data the user can reach. That
converts a tenant's bundle bug into a cross-tenant breach and is irreconcilable
with **INV-1 (tenant data isolation)**. Not deferred — rejected.

### D1a — Client-side logic and the offline constraint

This clause was added 2026-09-08, after the record's first draft, on user
direction: **the mobile tier must work offline for at least some business form
population.** The first draft reasoned only from the web SPA, where the server is
always reachable and "let the server evaluate it" is therefore free. That
assumption does not survive contact with an offline client, and the correction
matters enough to state rather than quietly patch.

#### The first draft contradicted a shipped MUST

`docs/mobile/requirements.md`'s **MOB-4** — priority MUST — already requires the
form renderer to support *"every platform field type: text, number, boolean,
date, datetime, select, multi-select, reference, file, **computed**, hidden."*
A `computed` field is client-evaluated logic by definition. The first draft's
"no tenant-authored expression language executes in the browser" would have
made MOB-4 unimplementable. MOB-4 is prior, load-bearing, and correct;
this record yields to it.

#### The distinction that makes this safe

"Client-side logic" is not one thing, and collapsing the two is what produced the
overbroad first draft:

| | Bounded expression grammar | General scripting runtime |
|---|---|---|
| Example | `visible_when: "amount > 1000"` | Lua / JS / WASM |
| Termination | Guaranteed — no loops, no recursion, no user functions | Undecidable; needs a watchdog |
| Resource limits | Unnecessary | Mandatory, and `0014` proved they can fail |
| Effects | None — pure function of its inputs | I/O, network, host calls |
| Failure mode | Type error on a known grammar | Arbitrary |
| Reviewable | The grammar is the review | Per-script |

**Letflow already has the left-hand column, and already runs it in the browser.**
`Letflow.Engine.Expr` is a pure CEL-subset evaluator used today for
`:EXCLUSIVE_GATEWAY` edge conditions: variable references, six comparison
operators, `and`/`or`/`not`, literals, binary `+ - * / %`, unary `-`, and eight
**pure** builtins. Its moduledoc records that `now()`, `date_add()` and
`date_diff()` were *deliberately excluded as impure* — the grammar has no clock,
no I/O and no host access at all. `parse/1` and `evaluate/2` are pure functions.
The SPA already ships `web/src/components/canvas/CelExpressionEditor.tsx`, so
tenant-authored expressions in this grammar are an established, reviewed part of
the product; they are simply confined to gateway conditions today.

Extending that same grammar to form fields adds no new class of risk. Inventing a
*second* expression language for forms would.

#### The rule

**Evaluate on the client; validate on the server. Always both, never either
alone.**

- **Client** evaluates `visible_when`, `computed` and cross-field validation for
  *interactivity* — so a field can appear, recompute or flag an error without a
  round trip, and therefore while offline.
- **Server** re-evaluates every one of them on submit, from the pinned schema and
  the authoritative variables, and its answer wins.

The client's evaluation is a **UX affordance with no authority whatsoever**. This
is the same boundary D3 already draws for validation, applied to logic: a hidden
field is not a secret, a computed value is not trusted, and a client-passed
validation is not a validation. **INV-2** is unchanged — a client that lies, is
stale, or was modified can only produce a worse experience for its own user, never
an unauthorised write. A field whose *visibility* is security-relevant must not be
sent to the client at all; the server omits it from the schema. That is a
server-side schema-shaping concern, and it is why the closed grammar is not
allowed to reference anything the client was not already given.

#### Why this beats the first draft's server-evaluated schemas

Server-evaluated schemas — the backend resolving conditions and serving an
already-resolved form — are strictly worse once offline exists, and not much
better online:

1. **They cannot work offline at all.** Resolution requires the server. An
   offline device has a cached schema and no way to resolve it, so every
   conditional field would either vanish or freeze. This alone is decisive given
   MOB-3's airplane-mode launch requirement.
2. **They are a round trip per keystroke online.** A `visible_when` that depends
   on a field the user is currently typing into needs re-resolution on every
   change. That fails **FNFR-02** (visible feedback within 100 ms) on any real
   network.
3. **They do not remove the need for server-side checking.** The server must
   re-validate on submit regardless, so the cost is paid twice.

#### Constraints on the shared grammar

Two renderers, one grammar, no shared code — the SPA is TypeScript, the app is
Dart, and `architecture.md` §5 accepts that deliberately (*"two clients of one
contract"*). That is the standing risk here, and it needs mechanism, not
goodwill:

1. **One grammar, defined once.** `Letflow.Engine.Expr`'s grammar is the
   definition. Neither client may extend it locally. A client that meets an
   expression it cannot evaluate **fails loudly** — MOB-4's `stale-version` state
   is exactly this case — and never silently skips the field or guesses.
2. **A shared conformance suite is the mechanism.** A language-neutral corpus of
   `(expression, variables, expected result)` cases, exported from the Elixir
   implementation's own tests and executed by all three implementations. Without
   it, three evaluators drift and the drift surfaces as a wrong number on a
   customer's form. This is the single most important piece of work this clause
   creates.

   Three things about it this record settles rather than delegating, because a
   requirement author asked and each has exactly one defensible answer:

   - **It is a shipped artefact, not a test fixture.** Three repositories'
     implementations must read it, including a Dart suite in `apps/mobile/` that
     cannot reach into Letflow's `test/fixtures/`. It therefore lives at a
     repository-root path outside any one language's test tree, versioned with
     the grammar it describes.
   - **Expected *failures* are cases, not omissions.** A corpus of only
     successful evaluations cannot test constraint 1 — the fail-loudly rule —
     which is the constraint most likely to be violated silently. Parse failure
     and evaluation failure are **distinct** outcomes: conflating them lets an
     implementation pass by failing at the wrong stage.
   - **It carries a version marker, and clients check it.** Constraint 1 requires
     a client to fail loudly on an expression it cannot evaluate, which is
     unimplementable without a way to *detect* that. The marker is that
     mechanism; without deciding it here, each client would invent its own
     convention and disagree — the same drift by another route.

   The existing `test/fixtures/simulation/differential_corpus.json` (REQ-209) is
   **not** this corpus and is not to be modified: its 15 entries are all boolean
   gateway conditions, so it exercises no arithmetic, none of the eight builtins,
   no non-boolean result — which is precisely what a `computed` field produces —
   and no expected-failure case.
3. **The server stays authoritative on submit**, per the rule above. When the
   server's re-evaluation disagrees with the value a client submitted, **the
   server's value is used and the disagreement is recorded** — it is not an error
   returned to the user, and not a silent overwrite. Not an error, because the
   commonest cause is benign: a stale cached schema, or a variable that changed
   after the form was rendered, and failing the submission would punish a user
   for a race they cannot see. Not silent, because a *persistent* disagreement is
   the signature of the exact drift constraint 2 exists to catch, and it must be
   visible somewhere an operator can find it. A client-supplied value for a
   `computed` or hidden field is therefore an *input to be checked*, never a
   value to be stored on trust.
4. **Offline writes remain out of v1.** MOB-8 is untouched. This clause makes a
   cached form *fillable* offline; it does not make it *submittable* offline. The
   queue-and-reconcile problem MOB-8 defers is a conflict-model problem, and
   nothing here supplies a conflict model.

#### Consequence for the mobile tier

This makes `docs/mobile/architecture.md` §3's third gap — version-pinned task
payloads carrying `{form_id, form_version}` — a **shared** dependency rather than
a mobile-only one. `REQ-126` already ships `form_id`/`form_version`; `REQ-273`
populates the schema and `REQ-286` serves it. The mobile tier needs exactly the
same three things, which is an argument for their design being reviewed with both
clients in view even though S9 is dormant.

### D2 — Build the specified primitives, then migrate pages onto them

`docs/frontend/design-system.md` §7 specifies `Button`, `DataTable`,
`ConfirmDialog`, `Toast`, `JsonEditor`, `DynamicForm`, `StatusBadge` (§5) and
`PageLayout` (§8). **None of them exists.** Verified 2026-09-08:

```
$ for c in Button DataTable PageLayout StatusBadge Toast JsonEditor FilterBar; do
    find web/src -name "$c.tsx"; grep -rl "<$c[ />]" web/src --include=*.tsx; done
(no output — zero files, zero usages)
```

Instead, every page hand-rolls its own table, buttons and layout:
`InstanceBoardPage.tsx` is 527 lines, `TaskInboxPage.tsx` 452 (50 inline
`style={{...}}` objects), `InstanceDetailPage.tsx` 407. 72 files under `web/src`
use inline style objects.

Build the primitives against `tokens.css` (which now exists — `REQ-120`, `done`),
then migrate pages onto them incrementally. `web/src/components/ui/` already
holds the right *kind* of thing (`ConfirmDialog`, `QueryStateBoundary`,
`FetchError`, `SkeletonLayout`) — this extends that directory rather than
inventing a new location.

**Rejected: adopting a component library** (Mantine/Radix/shadcn). It is a
defensible choice on its merits — WCAG 2.1 AA is **FNFR-03**, it is the most
expensive NFR to satisfy by hand, and a library largely provides it. It is
rejected here on process grounds, not technical ones: `REQ-120` settled
`design-system.md` §2 as the single token source of truth **eight requirements
ago**, and swapping the component layer now would reopen it. If the a11y cost of
hand-building proves higher than expected, that is grounds for a *new* record
superseding this clause — not for quietly diverging.

### D3 — Form schemas are the tenant-customisation vehicle, and the backend must populate them

This is the load-bearing half of D1, and the largest actual gap in the system.

The frontend renderer is **already built**:
`web/src/components/forms/DynamicFormRenderer.tsx` takes a JSON-Schema-shaped
`formSchema` prop, compiles it through `parseFormSchema` and
`compileFormSchemaToZod` into a Zod resolver for react-hook-form, and renders via
`FieldFactory`. `fieldRegistry.ts` is an extension point — `FieldFactory` looks
up `fieldRegistry.get(type)` and falls through to the built-in switch on a miss.

The backend column is **already there and always empty**. `lib/letflow/engine/task.ex:70`
declares `field(:form_schema, :map)`, and `lib/letflow/routers/tasks.ex:91-93`
states plainly:

> `form_schema` is unpopulated (always `nil`) in this codebase today

So: a renderer with no data source, and a column with no producer. Close it by
populating `tasks.form_schema` at task activation from
`node.attributes["form_schema"]` — the shape `variable_schema.ex` already
documents as R-Co's behaviour, and the one the task-detail response is already
shaped to carry.

Three constraints on that work:

1. **The schema is a rendering payload, not a validation authority.**
   `lib/letflow/engine/variable_schema.ex` (note: `engine/`, not `definitions/` —
   there is no `lib/letflow/definitions/variable_schema.ex`) is explicit that R-Co
   "never validates submitted output against it," and names three distinct things
   that get conflated —
   `tasks.form_schema` (rendering), `variable_schemas` (real per-variable
   validation, `REQ-109`), and `form_schema_registry` (a search index, out of
   scope). Client-side validation from `form_schema` is a UX affordance;
   **server-side authority stays with `variable_schemas`**. Rendering-payload
   validation must never become the only check — that would be an **INV-2**
   (server-side field authorisation) violation.
2. **`form_schema` is untrusted input.** It is an untyped `:map` reaching a
   renderer. It needs a shape validator on the way in — `lib/letflow/definitions/json_schema_shape.ex`
   already exists for this class of problem.
3. **Version pinning already has a design.** `form_id`/`form_version` ship today
   (`REQ-126`, `lib/letflow/design/req126-form-version-pinning.md`); a schema
   served for a running task must be the pinned version, not the current one.

Custom widgets register in `fieldRegistry` as **platform** code, keyed by a
`x-ui.widget` name a tenant's schema may reference. The tenant names a widget;
the platform decides what that widget is.

**Populating the column and exposing it over HTTP are two separate changes.**
`task_detail_map/3` currently excludes `form_schema` from the 13-key task-detail
response deliberately. Persisting the schema is engine work; adding it to a
response body is response-shaping on a tenant data path, which is
SECURITY-REVIEWER territory (**INV-2**). Doing them in one requirement would
smuggle a reviewed-by-different-people change through a single gate. Persistence
lands first and leaves the response untouched; the exposure is its own
requirement, and until it lands the renderer still receives nothing — that is
expected, not an incomplete implementation.

## Consequences

### The tenant model needs a settings store

`Letflow.Identity.Tenant` has exactly `id`, `slug`, `display_name`, `status`,
`idp_realm_id`, `timestamps()` — no settings, config, branding, locale or JSONB
column. This is already a known, flagged gap;
`lib/letflow/routers/mobile_tenant_config.ex` says so in its own moduledoc:

> every tenant on this backend currently gets identical `locales`/`default_locale`/`branding`
> values — this is a deliberate, explicitly-flagged placeholder (design OQ-1) …
> pending a future requirement that would give tenant branding its own
> schema/migration/admin UI.

**This record is that pending decision.** Tenant settings get a real store, and
`mobile_tenant_config.ex`'s `@default_branding` becomes the fallback rather than
the only answer.

### Both bootstrap endpoints change — as a security change, but not the same change

The two endpoints need **different** work, and conflating them hides the harder
half:

- **`GET /api/tenant-config`** returns `{oidc_authority, client_id}` and **gains a
  key**. Its moduledoc: *"Adding a third key to this response is a security
  change, not a feature."*
- **`GET /api/mobile/tenant-config`** returns `{realm_url, locales,
  default_locale, branding, environment_kind}` and **gains no key at all**. It
  already returns `branding`, `locales` and `default_locale` — as global
  constants. The change is that three existing keys start varying by tenant for
  the first time.

That second case is the more delicate one, because the module's own INV-5
argument is built on the keys *not* varying — `mobile_tenant_config.ex:64` states
that only one of the five fields varies by slug and *"the other four are
byte-identical."* **This work makes that sentence false.** It must be rewritten
in the same change that makes it false; leaving a now-untrue anti-enumeration
argument standing over changed behaviour is precisely the failure this project's
validator chain exists to catch.

Both are therefore **SECURITY-REVIEWER gate work**, under constraints already
documented on those modules:

- **The never-error rule holds.** Both endpoints always return 200. A miss, an
  unprovisioned host, a malformed slug and a database outage must remain
  indistinguishable, or the endpoint becomes a tenant-existence oracle
  (**INV-5**).
- **Public means public.** These are pre-authentication endpoints. Branding is
  disclosed to anyone who can reach the login page — which is acceptable for a
  logo and a colour, and unacceptable for anything else. The allowlist stays
  closed and explicit.
- **A non-default branding block is itself a signal** that a slug is real. This
  is the same unavoidable inference the endpoint already makes with `realm_url`,
  and is bounded by the same reasoning: it is what any user of that tenant sees
  on their own login page.

### Theming works only once pages stop hard-coding colour

The `literal-colour` guard (`web/tests/guards/forbidlist.ts`, `CMP-UI-06`)
already bans hex/rgb/hsl literals — but exempts `web/src/pages/`. That exemption
is why 72 files still carry inline hex. **A tenant's brand colour cannot reach a
hard-coded literal**, so D2's page migration is a precondition for D1's theming,
not a parallel nicety. As pages migrate onto primitives, the `pages/` exemption
should narrow and finally be deleted. Removing it is the completion test for D2.

Note the standing inconsistency this resolves: `--color-brand-600: #228be6`
(`tokens.css`), `primary: #2563EB` (`design-tokens/letflow.tokens.json`,
superseded by `REQ-120`), and `primary_color: "#0B5FFF"`
(`mobile_tenant_config.ex`'s `@default_branding`) are three different blues for
the same role. The platform default must be **one** value, and `REQ-120` already
settled which: `tokens.css`.

**The reconcile belongs to the mobile-endpoint requirement, not the settings-store
one.** Changing `@default_branding` changes a live public endpoint's response
body, so it goes through the same SECURITY-REVIEWER gate as the rest of that
endpoint's change rather than riding along inside a schema migration.

### i18n is now on the critical path

`REQ-127` established there is no locale policy: no i18n library, no supported
locale set, no fallback chain, and 25 bare `.toLocale*()` call sites of which 24
pass no locale argument. A per-tenant `default_locale` that nothing reads is not
a feature. Serving locale per tenant requires an actual i18n layer, and that
needs its own requirement.

### What this record does not change

- **No framework change.** React 18.3.1 + TypeScript + Vite, per `0011`.
- **No new scripting runtime.** `0014` stands unmodified; nothing here puts an
  evaluator in the browser.
- **No change to the guard model.** `web/tests/guards/` stays the frontend's
  validator chain. New primitives are gated by it, and weakening a guard pattern
  to make a change pass remains an anti-pattern.
- **Server-side validation authority is untouched.** `variable_schemas`
  (`REQ-109`) remains the validation source; `form_schema` never becomes one.

## Sequencing

D3's backend half and D2's primitives are independent and can run in parallel.
D1's theming depends on D2's page migration (the colour-literal problem above).

1. **D2a** — build the primitives against `tokens.css`.
2. **D3a** — populate `tasks.form_schema` at activation; validate its shape on
   the way in; serve the pinned version.
3. **D2b** — migrate pages onto the primitives; narrow, then delete, the
   `literal-colour` guard's `pages/` exemption.
4. **D1-settings** — tenant settings store (schema + migration + admin UI).
5. **D1-branding** — branding on both bootstrap endpoints, under
   SECURITY-REVIEWER.
6. **D1-theming** — theming applied from tenant settings; `x-ui` widget
   vocabulary and `fieldRegistry` population.
7. **i18n** — its own requirement, blocking per-tenant `default_locale`.

D1a's field-logic work is its own track, gated on D3a (a schema must exist before
it can carry expressions) and independent of everything else:

8. **D1a-schema** — extend the `x-ui` vocabulary with `visible_when`, `computed`
   and cross-field validation, expressed in `Letflow.Engine.Expr`'s grammar;
   validate expressions at definition time so a bad one fails at authoring, not
   at render.
9. **D1a-conformance** — the language-neutral conformance corpus, exported from
   `Letflow.Engine.Expr`'s own tests. **This precedes any client evaluator.**
   Building a second implementation before the corpus exists is how the two
   drift apart before anyone can measure it.
10. **D1a-web** — a TypeScript evaluator for the grammar, passing the corpus,
    wired into `DynamicFormRenderer`.
11. **D1a-server** — server-side re-evaluation of the same expressions on task
    completion. **This is the authority half and is not optional**; without it
    the client's evaluation is load-bearing, which D1a forbids.
12. **D1a-dart** — the Flutter evaluator, passing the same corpus. S9, dormant
    until the mobile tier activates.

Steps 4–6 are worth building against a real second tenant with visibly different
branding from the start; identical-looking tenants are how a theming bug survives
to production.

**Step 11 must not lag step 10.** A client evaluator shipped without its
server-side counterpart is a validation boundary that exists only in the client —
exactly the INV-2 failure D1a's rule is written to prevent. If they cannot ship
together, ship 11 first: a server that checks expressions no client sends yet is
harmless, while the reverse is not.
