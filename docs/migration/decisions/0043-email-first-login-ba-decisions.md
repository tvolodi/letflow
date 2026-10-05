# 0043 — Email-first login: BA decisions on the series' open questions (D-A..D-H)

Status: decided by delegation (BA), with ONE item PROPOSED and awaiting legal confirmation
(D-D, the lawful basis and controller). Gates still owed are listed under "Conflicts flagged
for REVIEWER": this record does not claim `REVIEWER` or `SECURITY-REVIEWER` sign-off.

Date: 2026-10-04. Drafted by `DOC-UPDATER` from the BA decisions given to `ORCH` and the
requirement text `REQ-ANALYST` wrote in `docs/requirements.yaml` (REQ-435 trimmed, REQ-437
and REQ-438 amended, REQ-440, REQ-441 and REQ-442 added). Owner: `ORCH`.

Amends (by reference, the form 0038 and 0042 used, not supersession):
`0042-email-first-login-tenant-directory.md` (Decision 3 and Decision 7, Standing
prohibitions 4, 11 and 13, OQ-1, OQ-4, OQ-6, OQ-9) and the design
`lib/letflow/design/req434-email-first-login-directory.md` (the design) at §2.4, §5.3, §5.4,
§7, §10.2, §12.2, §3.7 and Q8. 0042's other decisions and prohibitions stand unchanged.

## Context

The user delegated the open questions of the email-first login series (REQ-434..439) to the
BA's discretion. 0042 and the design are ratified and merged; REQ-436 (limiter) and REQ-439
(client IP) are done. REQ-435, REQ-437 and REQ-438 were registered but not yet built. This
record settles what the BA can settle (D-A..D-C, D-E..D-H), records the BA's position on the
one item the BA cannot settle (D-D) as PROPOSED, and flags where a decision here conflicts
with a ratified item instead of resolving the conflict silently. Where a decision below
conflicts with 0042 or the design, the ratified text stays authoritative until `REVIEWER`
accepts the amendment named here.

## Decisions

### D-A. Disclosure risk appetite: per-tenant mode, Mode B stays the deployment default

**Decision.** Mode B (`:redirect_single`) stays the deployment-wide default. The disclosure
mode becomes configurable per tenant, with the deployment-wide mode as the fallback and the
ceiling. `:uniform_plus_email` (Mode A) is RECOMMENDED for candidate-facing tenants (for
example Bilimbaga exam candidates). Rate limiting stays on in all modes.

**Effective-mode rule (defined over the match set, because the lookup is by email before the
tenant is known).** The single-match 200 (slug and display name) is returned only if there is
exactly ONE active match AND that match's `disclose` flag is true. In every other case the
response is the neutral 202, and the tenant list is emailed as before (a single match in a
uniform tenant is delivered as a list of one, like Mode A). A uniform-tenant address is
therefore byte-identical to an unknown one. `disclose` is computed in the single lookup query
as `(deployment mode is redirect_single) AND COALESCE(tenants.login_disclosure_mode,
'redirect_single') = 'redirect_single'`.

**Fallback and ceiling.** Tenant value NULL means "use the deployment mode" (fallback). A
deployment set to `:uniform_plus_email` forces every tenant uniform whatever its setting
(ceiling). A tenant can opt into uniform; it cannot opt into disclosure the deployment has
switched off. This preserves 0042's configuration-only kill switch.

**Checked against the ratified invariants.** The rule does not break any of them: the
Mode B equivalence class {multi, unknown, malformed, inactive-only, lookup-failure} is only
enlarged by "single match in a uniform tenant"; exactly one database round trip and no early
return stay (the `disclose` flag comes out of the same query; delivery stays one
unconditional off-path submission, so work is constant); the response allowlist is unchanged
(`disclose` is stripped before any body is built); no 401/403 is introduced; the outcome
counter for the uniform-tenant single match is `:accepted`, not `:tenant`. It DOES touch three
ratified wordings, listed under "Conflicts flagged for REVIEWER".

**Where it lives.** Does NOT fit REQ-437's sizing: it needs a schema change on `tenants`, a
platform-admin write path with authorisation and response-shaping checks, and a lookup change
owned by REQ-435. It is its own requirement, **REQ-442** (`depends_on: [REQ-435]`); REQ-437
`depends_on` REQ-442 and consumes the `disclose` flag in `decide/2` and `delivery/2`
(REQ-437 BUILDS item 8 and its per-tenant acceptance criteria). The setting is the nullable
column `tenants.login_disclosure_mode` (CHECK in `uniform_plus_email`, `redirect_single`),
NOT a key in the tenant `:settings` blob: that blob has a closed vocabulary whose values reach
the pre-authentication `GET /api/tenant-config` and a tenant-admin write path, and the mode is
a platform-security attribute a tenant admin must not set or read. Writable only by
`PLATFORM_ADMIN`; never present in any tenant-admin-readable or pre-auth response (INV-2).

**REQ-438 (UI).** The SPA reacts only to the closed response union (200 tenant, 202 accepted,
429, network failure, malformed). A per-tenant mode therefore causes no UI difference beyond
what the response carries; two REQ-438 criteria assert it (no `web/` source references a
disclosure mode; a 202 as a uniform-tenant address would produce renders the unknown-address
neutral DOM, organisation-code control included).

**Consequences.** A candidate-facing tenant can be set to uniform without a deployment-wide
loss of the Mode B UX for other tenants. The operational choice of when to flip a deployment
to uniform (design §12.7 abuse-counter thresholds) and whether Bilimbaga is set by migration
or by an operator action stay operational; REQ-442 ships no tenant-specific data change
(0022 bucket rule). A uniform-tenant user whose address is the only match still depends on the
email path (REQ-441) to learn the tenant; until a real adapter exists that path is inert (0042
OQ-9, see D-B).

### D-B. Mail adapter: a new requirement, REQ-441

**Decision.** A provider-agnostic mail notifier adapter is a NEW requirement, **REQ-441**
(`depends_on: [REQ-437]`, the port is REQ-437's `Letflow.LoginDiscovery.Notifier`,
`deliver_tenant_list/2`). SMTP is the first adapter; a capturing test adapter is reused from
REQ-437's double if it already provides one. Configuration is by environment reference only
(`LETFLOW_MAIL_ADAPTER`, `LETFLOW_SMTP_HOST`, `_PORT`, `_USERNAME`, `_PASSWORD`, `_TLS`,
`LETFLOW_MAIL_FROM`), read once at boot in `config/runtime.exs`; no secret in the repository
(INV-4). Delivery failure handling leaks no enumeration signal: delivery runs in the notifier
task off the request path, so a success, an SMTP rejection, a timeout, a TLS failure and a
raise all leave the HTTP status, headers and body byte-identical; there is NO automatic retry
(a retry loop is an email-bombing amplifier); the per-address `:send` bucket is consumed once
per attempt; the failure is recorded only as a non-identifying counter event
`[:letflow, :login_discovery, :notifier]` with one metadata key `outcome` in
`{:delivered, :failed, :skipped}` and a fixed log line.

**Required before the feature flag can be enabled outside dev.** REQ-444's boot check (D-D)
refuses to boot in a non-dev environment with the mount enabled and the non-delivering
`Noop` adapter (REQ-437 defines the notifier adapter key
`config :letflow, Letflow.LoginDiscovery.Notifier, adapter:`); REQ-441 supplies the real
adapter that satisfies it. This supersedes 0042
Decision 7's "no mail adapter" scope fence for deployments that enable the feature, and
answers the mail-adapter half of OQ-4 and, once delivered, 0042 OQ-9 (the multi-tenant dead
end). The mail LIBRARY (proposal: Swoosh over gen_smtp; alternatives Bamboo, bare gen_smtp)
is chosen by `CODE-DESIGNER` and recorded as its own decision record; this record does not
choose it. Needs network for `mix deps.get`; if unavailable the implementer must say so.

**Out of scope, note only.** The same adapter is expected later to serve invitations and
password recovery. Nothing here builds those and the port is not widened for them.

**Gates.** `SECURITY-REVIEWER` is a hard gate on REQ-441 (new external egress; INV-4, INV-5,
INV-8, INV-9). The `:failed` counter carries no per-address dimension; `SECURITY-REVIEWER`
confirms it is not an oracle.

### D-C. Pepper provisioning: per-environment pepper, key id, dual-read rotation

**Decision.** The HMAC pepper is per-environment, at least 32 random bytes (64 hex characters,
`LETFLOW_LOGIN_DIRECTORY_PEPPER`), from the environment's secrets store, never in the
repository, a fixture, a Dockerfile, a compose file or a handoff. Dev supplies it through an
ordinary environment variable (`.env.example` names the variable with no working value;
`config/test.exs` injects a fixed non-trivial test value). Every directory row carries a
NOT NULL `key_id` column (not part of the primary key) recording the pepper that produced its
`email_key`; the current id is `LETFLOW_LOGIN_DIRECTORY_PEPPER_ID`. During a rotation an
optional previous pepper (`LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS` with
`_PREVIOUS_ID`, both or neither) enables DUAL-READ: the lookup finds rows under either key;
writes and the backfill use the current key only. Boot checks in `config/runtime.exs` use the
same discipline as the master key and echo no value. The rotation runbook is
`docs/runbooks/login-directory-pepper-rotation.md` (planned rotation, emergency rotation,
rollback), together with `mix letflow.login_directory.retire_key` and
`mix letflow.login_directory.key_status`, is **REQ-443** (split from REQ-435 after
`REQ-VALIDATOR` attempt 1; `depends_on: [REQ-435]`). REQ-435 keeps the key-id column, the
pepper and key-id configuration with boot checks, the dual-read lookup and the re-keying
backfill. REQ-437 does not depend on REQ-443; REQ-444 does (a pepper deployed outside dev
needs a rotation procedure before the feature is enabled there).

**Supersedes** design §2.4's "A dual-pepper window is not built", design Q8 (decider `ORCH`)
and 0042 OQ-6 (pepper provisioning and rotation). The rebuild procedure of §2.4 survives only
as the emergency rotation. The interplay with ratified identifiers is a flagged conflict
below, not resolved here.

**Consequences.** Rotation no longer needs a window in which discovery is neutral for
everyone (planned rotation); a leaked pepper is still handled by the emergency path.
An environment without a provisioned pepper cannot enable the feature (boot refusal).
Provisioning is an EXTERNAL dependency (see below).

### D-D. OQ-3 lawful basis and controller: PROPOSED position, hard gate kept and made testable

**Decision.** The BA cannot resolve OQ-3. The BA position is recorded as PROPOSED (below) and
needs legal confirmation; OQ-3 remains the ONE user/legal decision still open in the series.
The hard gate is kept: the feature stays OFF outside dev until a named person confirms. The
gate is made a testable acceptance criterion and a config default rather than a procedure
(**REQ-444**, split from REQ-437 after `REQ-VALIDATOR` attempt 1; `depends_on: [REQ-437,
REQ-441, REQ-443]`; REQ-438 "stays off outside dev"; REQ-437 keeps only the explicit notifier
adapter key `config :letflow, Letflow.LoginDiscovery.Notifier, adapter:`, default `Noop`, that
the gate reads):

1. The flag defaults to false in every non-dev environment config:
   `Letflow.Routers.LoginDiscovery` `enabled` is `config_env() != :prod` in `config/config.exs`
   (already in the tree from REQ-439), no config file sets it true for `:prod`, and the SPA
   build flag `VITE_EMAIL_FIRST_LOGIN` defaults off in every non-dev build.
2. A pure boot check (for example `Letflow.LoginDiscovery.BootCheck.check/4`: env, enabled?,
   confirmation marker, the notifier adapter key's value), called from `config/runtime.exs` AFTER
   `Letflow.Plugs.ClientIp.boot_check/3` (REQ-439's check is left unchanged, as is
   `lib/letflow/plugs/client_ip.ex`): in any environment other than `:dev` and `:test`, with
   the mount enabled, boot REFUSES (raises, echoing no value) unless ALL of: (i) the
   confirmation marker `LETFLOW_LOGIN_DIRECTORY_LEGAL_CONFIRMATION` is set to a non-blank value
   of at least 8 characters; (ii) the configured notifier adapter is on an explicit list of
   delivering adapters (initially `Letflow.LoginDiscovery.Notifier.Smtp` from REQ-441; not
   `Noop`, not the test double); (iii) the pepper and key id of REQ-435 are configured
   (asserted as a precondition, its own boot checks are not re-implemented).
3. The rotation procedure exists: `docs/runbooks/login-directory-pepper-rotation.md`
   (REQ-443) is present, enforced as a repository test; the `depends_on` ordering is the real
   enforcement. The dependency direction is chosen to keep `depends_on` acyclic: REQ-444 depends
   on REQ-441, REQ-441 does not depend on REQ-444.

The marker cannot prove a confirmation happened; it makes enabling without one a deliberate,
auditable act by the operator, who sets it only after a named person has confirmed OQ-3 (the
value is that person's reference and a date; it is never logged). The environment variable
NAME is a proposal; `REVIEWER` or `CODE-DESIGNER` may rename it.

### D-E. Backfill gap: known limitation, optional future requirement (note only)

**Decision.** Keycloak-only accounts that have never logged in to Letflow and are not in a
tenant `users` table are invisible to the directory until their first login (the backfill
source is `users.email` per tenant schema, 0042 RQ-4/OQ-12 default). Such a user gets the
neutral response and falls back to `?realm=`, the stored slug or the default. An optional
future Keycloak-sync requirement (Keycloak Admin API as a source, 0042 Alternative 10) could
close it. This is a NOTE only: no requirement is created. See "Known limitations".

### D-F. Sizing: REQ-435 split into REQ-435 (435a) and REQ-440 (435b)

**Decision.** REQ-435 is split. No suffix convention exists in `docs/requirements.yaml` (ids
are plain integers, the highest on main was REQ-439), so:

| Id | Content | depends_on |
|---|---|---|
| REQ-435 (the 'a' half; trimmed, status pending) | migration with `key_id`, schema module `Letflow.Identity.TenantLoginDirectoryEntry`, context `Letflow.LoginDirectory` (`email_key/1`, `sentinel_key/0`, lookup, `upsert_entry/2`), pepper and key-id handling with boot checks and dual-read, idempotent re-keying backfill task | REQ-434 |
| REQ-440 (new; the 'b' half) | population hooks inside the Identity transactions, the JIT transaction, the explicit `:tenant_id` opt with its fail-closed guard, the removal rule `remove_entry_if_unreferenced/3`, the test-only `login_directory: :skip` opt | REQ-435 |
| REQ-441 (new, D-B) | mail notifier adapter, SMTP first | REQ-437 |
| REQ-442 (new, D-A) | per-tenant disclosure mode | REQ-435 |
| REQ-443 (new, split from REQ-435, D-C) | `retire_key` and `key_status` mix tasks, rotation runbook `docs/runbooks/login-directory-pepper-rotation.md` | REQ-435 |
| REQ-444 (new, split from REQ-437, D-D) | enablement gate: defaults off outside dev, boot refusal without marker, delivering adapter and rotation procedure | REQ-437, REQ-441, REQ-443 |

REQ-437's `depends_on` becomes `[REQ-435, REQ-436, REQ-439, REQ-440, REQ-442]`; REQ-438 stays
after REQ-437. REQ-436 (limiter) and REQ-439 (client IP) are done and untouched. Chain:
434 -> 435 -> 440 and 442 -> 437 (also needs 436, 439) -> 438, 441; 435 -> 443; 444 needs 437,
441 and 443. REQ-437 depends on neither REQ-443 nor REQ-444.

**Known wrinkle.** 0028's "a table lands with its first writer" rule, restated as 0042
Standing prohibition 13, is satisfied only by REQ-435 and REQ-440 landing back to back. Until
REQ-440 is done the backfill is the only writer, so the table is populated once and goes
stale. REQ-437 must NOT be claimed for done before REQ-440.

**PR #2201.** Open PR #2201 (queue Q-944, worker `letflow-4-worker-q944`, branch
`feat/REQ-435-login-directory`, merge held) implements ALL of the former REQ-435 including
the hooks, in one branch. If the whole of it lands as one change, REQ-440's BUILDS are
satisfied by that change and are closed by `RELEASE-VALIDATOR` verification (re-deriving every
REQ-440 acceptance criterion against the merge commit) instead of being re-implemented. This
record and the requirement edits do not touch the PR. The PR was built against the
single-pepper design, so D-C's key id and dual-read may land as a delta on top of it
(flagged below).

### D-G. Keycloak Organizations: deferred

**Decision.** The open question "Keycloak Organizations as an alternative" (0042 OQ-2,
Alternative 3) is converted to: DEFERRED; decide via an ADR when the tenant count grows. The
directory is the abstraction that survives a later move (0042 already guarantees it is
retire-able). The series' scope stays the directory only; no realm migration. Each affected
requirement's open question carries this wording.

### D-H. Documentation tidy

**Decision.** Where the merged design and 0042 still described a ratified item as
"recommendation, pending ratification", the wording is corrected with minimal edits. Done in
this change: the design paragraph after the config table (§7) ("The default is a
recommendation requiring REVIEWER ..." now states the Mode B default was ratified by
`REVIEWER` and `SECURITY-REVIEWER` on 2026-10-04); design §10.2 heading ("recommended
default" now "ratified default"); design Q1 row; 0042 "Accepted bounded inference" ("recommended
default, Mode B" now "ratified default"). One-line "Amended by 0043 D-C" notes were added at
design §2.4 (pepper rotation paragraph) and the Q8 row. Deliberately NOT touched here
because open PR #2201 edits those exact lines: design config table row (`mode:` default, ~line
678), 0042 Decision 3 (~line 88), the RQ-1 row and OQ-1. Anything still saying
"recommendation" for Mode B after #2201 merges is a follow-up.

## Proposed, needs legal confirmation (D-D)

The BA position, verbatim in intent, PROPOSED only and not a legal conclusion:

- The platform operator is the controller for the directory.
- The lawful basis is legitimate interest / contract necessity for login routing.
- Data minimisation is by keyed hash (the directory holds no plaintext email, password, role,
  session, user id or profile field).
- The above is to be written into the privacy notice and the DPA.

Keyed HMACs of email addresses remain personal data while the pepper exists (0042 OQ-3).
Retention remains to be named (the directory's entries are removed in the same transaction as
deactivation, cascade on tenant deletion, and a documented rebuild/erasure procedure; Standing
prohibition 14 binds future deletion paths). A NAMED person (human or organisation) must
confirm the controller, the lawful basis and the retention period before the feature is
enabled outside dev. Until then the gate in D-D holds. OQ-3 is the only remaining user/legal
decision of the series; `ORCH` escalates it and records the answer here and in the enabling
change.

## External dependencies (described only; this repository does not edit them)

These live in the `ai-dala-infra` repository and are outside this change:

1. **Pepper secret.** A secrets-inventory entry for `LETFLOW_LOGIN_DIRECTORY_PEPPER` and
   `LETFLOW_LOGIN_DIRECTORY_PEPPER_ID` per environment (QA, production), and, during a
   rotation, the `_PREVIOUS` pair. Required before the feature can be enabled there; REQ-435's
   boot checks fail closed until provisioned (0042 OQ-6 asked who provisions it).
2. **SMTP credentials and relay.** Entries for `LETFLOW_SMTP_USERNAME` and
   `LETFLOW_SMTP_PASSWORD` and the chosen SMTP relay per environment (0042 OQ-4 asked who owns
   the credentials; the platform operator). Sender-domain SPF/DKIM/DMARC alignment is also an
   infrastructure action.
3. **Confirmation marker.** `LETFLOW_LOGIN_DIRECTORY_LEGAL_CONFIRMATION`, set by the operator
   per environment only after the D-D confirmation.
4. **QA deployment shape.** There is no staging config in this repository; QA runs
   `MIX_ENV=prod`, so the `:prod` defaults and boot checks above are what QA sees. The nginx
   realip directives for QA's vhost (REQ-439) remain an infrastructure action.

## Conflicts flagged for REVIEWER

Each is stated, not resolved. None is claimed settled by this record.

1. **D-C vs design §2.4, Q8 and 0042 OQ-6.** Q8 ("dual-pepper window not built; rebuild
   procedure", decider `ORCH`) and the §2.4 sentence are superseded by D-C; OQ-6 was open.
   `REVIEWER` must accept the supersession (the notes in the design point here).
2. **Key id vs ratified identifiers.** A key id interacts with: the unique `(key, tenant_id)`
   identity (kept: `key_id` is not in the primary key, the pair `(email_key, tenant_id)` stays
   the identity because key bytes already differ per pepper; but one person under two
   peppers is two rows for one tenant); `sentinel_key/0` (design §5.3); `lookup_by_key/1`
   taking one key (§5.4); the per-email limiter key `consume_email(email_key, kind)` (§12.2);
   and the advisory lock derived from `(tenant_id, email_key)` (§3.7). REQ-435 BUILDS item 4
   carries a PROPOSED resolution (key LIST and one `email_key = ANY(keys)` query over DISTINCT
   tenants so the "exactly one match" rule is unaffected; one sentinel per candidate key so
   work is constant per deployment state; limiter buckets on the current key only, so a rotation
   resets per-address buckets once; writers lock on the current key, removal deletes under every
   candidate key). `CODE-DESIGNER`/`REVIEWER` confirm or replace it before REQ-435 starts, and
   amend design §2.4, §3.7, §5.3, §5.4 and §12.2.
3. **PR #2201 was built on a single pepper.** It implements all of the former REQ-435 against
   the pre-D-C design. D-C's key id and dual-read (REQ-435), and the retire/status tasks and runbook (REQ-443), may land as a
   delta on it. REQ-435 and REQ-440 are written so they can be closed by verification of the
   merged PR where it already satisfies them (REQ-440 explicitly).
4. **REQ-442's internal `disclose` boolean vs 0042 Standing prohibition 4 and design §5.4.**
   They say the lookup returns plain maps containing ONLY `slug` and `display_name`. The match
   type becomes `%{slug, display_name, disclose}`; `disclose` is consumed by `decide/2` and
   stripped before any body is built, so the response allowlist is unchanged. `REVIEWER`
   decides whether that reading of "past the query" is acceptable.
5. **0042 Standing prohibition 11.** A change to the disclosure shape is a security change
   needing `SECURITY-REVIEWER` sign-off and an amendment to 0042. Per-tenant selection is not
   a third mode but a new selector; REQ-442 requires `SECURITY-REVIEWER` sign-off (INV-1,
   INV-2, INV-5, INV-6) and THIS record, D-A, is the amending record.
6. **Design §7 / 0042 Decision 3: one deployment-wide mode.** D-A makes it per-tenant, with
   the deployment value as fallback AND ceiling. The ceiling is the conservative reading of
   "deployment-wide default as fallback". If the BA instead meant a tenant may also override a
   uniform deployment default UPWARD (to disclosure), the SQL rule and the kill-switch property
   change and `REVIEWER` must decide. Related: design §7's `decide(mode, result)` becomes
   `decide/2` over the per-match flag, and the §10.2 matrix gains the row "single match in a
   uniform tenant: 202 neutral, one delivery of a list of 1, byte-identical to the Mode B
   neutral group"; the design's Mode A single-match delivery is reused for it.
7. **0042 Standing prohibition 13** ("REQ-435 ships the table together with every writer and
   the backfill; REQ-437 is the reader"). The REQ-435/REQ-440 split amends the letter: the
   table lands with its writers only when the two land back to back; REQ-437 is not claimable
   before REQ-440. See D-F.
8. **REQ-439's `boot_check` is untouched.** D-D's new boot check is a separate pure function
   called after it; `lib/letflow/plugs/client_ip.ex` and REQ-439's tests must show no diff.
   Not a conflict; recorded as a constraint so the new check is not folded into the old one.
9. **No staging config; QA runs `MIX_ENV=prod`; marker name is a proposal.** D-D's "prod/staging
   config" cannot be tested for a staging environment that does not exist: the gate is
   expressed for "any environment other than :dev and :test". The env var name
   `LETFLOW_LOGIN_DIRECTORY_LEGAL_CONFIRMATION` and its 8-character minimum are proposals.
   Also: the mail library choice goes to `CODE-DESIGNER` (D-B), not to this record.


**REVIEWER ruling (REQ-442), 2026-10-05, on conflicts 4-6.** Run WF02-REQ442-20261005.
- Conflict 6 (ceiling): the CEILING reading of D-A is RATIFIED. `disclose = (deployment mode ==
  :redirect_single) AND COALESCE(tenant.login_disclosure_mode, 'redirect_single') ==
  'redirect_single'`. It is the conservative reading of "deployment default as fallback", it
  preserves 0042's configuration-only kill switch, and no tenant can disclose more than the
  deployment allows. An upward override of a uniform deployment is NOT adopted; wanting it later
  needs a new decision record.
- Conflict 4 (internal `disclose`): ACCEPTED, on the constraint that `disclose` is stripped in
  `decide/2` and is absent from every response body; no tenant id, realm id or stored mode leaves
  `LoginDirectory`. An unrecognised stored value read in code is treated as uniform (the column CHECK
  makes it unreachable).
- Conflict 5 (0042 prohibition 11 / Decision 3): ACCEPTED as amended by D-A. The selector is
  PLATFORM_ADMIN-only, audited, and was signed by SECURITY-REVIEWER (INV-1, INV-2, INV-5, INV-6
  PASS; the 0042 amendments ratified).
- Premise correction: REQ-442's text said the setting is "audited as other platform-admin tenant
  updates are". That was wrong: `patch_tenant` and `PATCH /tenants/:slug` wrote no audit entry and no
  platform-level audit sink exists. REQ-442 audits mode changes only, in the target tenant's chain,
  in the same transaction, with the neutral value-free action `tenant.platform_setting.updated`.
  A display_name-only PATCH stays unaudited. Accepted residual: a tenant admin reading `GET /audit`
  can see that some platform setting changed (no name, no value).

10. **0042 Decision 7's "no mail adapter" scope fence.** Decision 7 lists "no mail adapter (a port
   with a non-delivering default adapter ships; the real adapter is a separate decision)" as
   part of the scope fence. D-B/REQ-441 amends it: a real SMTP adapter is built, and
   REQ-444's gate treats it as the precondition for enabling. `REVIEWER` must accept the
   amendment (the port and the non-delivering default from REQ-437 are unchanged).

## Known limitations

- **Keycloak-only accounts (D-E).** An account that exists only in Keycloak, never logged in
  and absent from the tenant `users` table, is not in the directory and gets the neutral
  response until its first login (JIT provisioning writes its entry, REQ-440). Workaround:
  `?realm=`, the stored slug or the default. An optional future Keycloak-sync requirement
  could close it; not scoped.
- **Single-match disclosure** in a redirect_single tenant remains the bounded inference of
  0042 (Standing prohibition 11 gate); uniform tenants avoid it.
- **Email path inert without REQ-441.** Until a real adapter exists, every path that depends
  on email delivery degrades to the neutral response (0042 OQ-9); the D-D boot check keeps the
  feature off in non-dev environments in that state.
- **Hex dependency for REQ-441** requires network for `mix deps.get`.

## Remaining open decision

0042 OQ-3 only (lawful basis and controller; D-D). 0042 OQ-1 is ratified (by `REVIEWER` and
`SECURITY-REVIEWER`); OQ-2 is DEFERRED (D-G); OQ-4 is answered in part (D-B, mail library to
`CODE-DESIGNER`); OQ-6 is answered by D-C subject to the external provisioning dependency.
