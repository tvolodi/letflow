# Design: REQ-025 — Event append (`Store.append`, ES-01/02/03/05/08/DB-03)

**Requirement:** REQ-025 (`docs/requirements.yaml` lines 1042–1100, stage S2,
`depends_on: [REQ-023, REQ-024]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ025-20260817`, WF-02 Step 1
**This document produces:** module/function signatures, the `Ecto.Multi` step sequence,
the locking protocol, the full error taxonomy, the tenant_id derivation mechanism, and
invariants — **no implementation code**. No function bodies, no `.ex` files. Pseudocode
blocks below describe algorithm shape only (matching the convention already established
in `lib/letflow/design/req024-event-type-registry.md` §4.4) — ELIXIR-DEV writes the real
version.

---

## 0. Sources read for this design, and a stated gap

**Letflow project docs, read in full:**

- `docs/requirements.yaml` — REQ-025's full entry (1042–1100), REQ-023 (898–974), REQ-024
  (976–1040), the S2 batch header (795–840).
- `docs/migration/decisions/0003-ecto-schema-strategy.md` — full file, in particular the
  **2026-08-17 addendum** (326–396): "the value written into a table's `tenant_id` column
  is derived by the writing context module from the Postgres schema (`:prefix`) it is
  already writing into for that call — never accepted as a separate, independently-trusted
  field from the caller" (343–353), and its rejection of option (a) — caller-supplied
  `tenant_id` — on attribution-integrity grounds (360–367).
- `docs/agents/instructions/security-invariants.md` — INV-1 (tenant isolation, points at
  the same addendum), INV-7 (no raw-SQL interpolation — favor `Ecto.Query` composition
  over `Repo.query/3`), INV-8 (typed results on every external-I/O path).
- `docs/guides/backend_developer_guide.md` §3.5 (error shapes), §3.6 (SQL parameterization).
- `lib/letflow/design/req023-event-store-schema.md` — full file (1221 lines). Table
  specs (§3), the six schema modules and their **normative "functions that will
  deliberately NOT exist" table** (§5.1), all thirteen invariants INV-EV-1..13 (§6), and
  critically **§2.5**: only three of the six tables (`events`, `events_archive`,
  `instance_projections`) carry a `tenant_id` column; `instance_sequence`,
  `event_payload_store`, `event_idempotency` deliberately do not (§9 below explains why
  this creates an open discrepancy against REQ-025's own acceptance criterion 6).
- `lib/letflow/design/req024-event-type-registry.md` — full file. §4's interface note
  (`validate_payload/3`, not literally `/2`, third argument is `tenant_id`, resolved
  internally to `schema_name` via a DB read against `Registration`) and §4.2's explicit
  statement that `payload` is "a raw, not-yet-decoded JSON string ... matches this
  function's realistic caller — REQ-025's `Store.append/1`(or `/2`)".

**Letflow shipped code, read directly (not assumed):**

- `lib/letflow/event_store/event.ex`, `instance_sequence.ex`, `instance_projection.ex`,
  `idempotency_record.ex`, `stored_payload.ex` — full files. Confirmed directly:
  `Event`/`InstanceProjection` have a `:tenant_id` field; `InstanceSequence` and
  `IdempotencyRecord` do **not**. Confirmed `InstanceProjection.terminal?/1` exists and
  treats exactly `:completed`/`:cancelled` as terminal (`:error` and `:active` are not).
  Confirmed every `insert_changeset/2` signature and required-field list cited in §4/§5
  below against the actual code, not the design doc's account of it.
- `priv/repo/migrations/20260816120002_create_instance_sequence.exs` and
  `…120006_create_event_idempotency.exs` — read directly to confirm at the DDL level
  that neither table has a `tenant_id` column (no `add :tenant_id` line in either file).
- `lib/letflow/event_store/registry.ex` — full file (267 lines). Confirmed
  `register_type/2`, `validate_payload/3`, `get_type/2` are the actual shipped arities
  (not the `/1`/`/2` the requirement text still cites), confirmed `validate_payload/3`'s
  exact error union (`:tenant_not_provisioned`, `:unknown_event_type`,
  `{:payload_validation_failed, [ValidationFailure.t()]}`), and confirmed it resolves
  `schema_name` from `tenant_id` via `Repo.get_by(Registration, tenant_id: tenant_id)` —
  a genuine DB round-trip, not a pure function.
- `lib/letflow/tenant_provisioning.ex` — full file (360 lines). Confirmed
  `schema_name_for_tenant/1`'s exact encoding (`"tenant_" <> String.replace(canonical_uuid,
  "-", "")`, no special-cased default tenant), confirmed `replay_migrations/2`'s
  `tenant_id -> Registration -> schema_name` resolution pattern, confirmed
  `insert_or_fetch_registration/2`'s "re-select after `on_conflict: :nothing`" idiom
  (used below, §6.4, for the idempotency sidecar insert), confirmed
  `tenant_scoped_migrations/0`'s current ten-entry manifest (this requirement adds no
  migration, so no eleventh entry is needed).
- `docs/issues/ISS-0025.yaml` — the security-reviewed analysis (during REQ-027) of the
  same `tenant_id`-population question this requirement also faces, independently
  confirming option (c) — derive from the resolved schema — was the recommended,
  security-reviewed resolution, not an arbitrary pick.

**R-Co source (`event_store.md`'s "append" section, invariants 1–2/4/6–10, "DB tables per
operation", "Concurrency design"): genuinely unreachable on this host.** Per this run's
own instructions, this was re-checked directly, not assumed stale from a prior run:

```
$ find / -maxdepth 3 -iname "R-Co" 2>/dev/null
(no output)
```

PROVENANCE (historical, not current decision authority):
Confirmed absent, exactly as REQ-029's run found. **This design therefore works from
`docs/requirements.yaml`'s REQ-025 entry (a detailed paraphrase of `event_store.md`'s
append section, per the task briefing) plus the extensive direct quotations of
`event_store.md` and `store.zig` already embedded — with line numbers — in
`req023-event-store-schema.md`'s own citations (§3.1–3.6, INV-EV-1..13), which this
design treats as reliable secondary sources since they were themselves produced by
reading the primary R-Co files directly.** Anywhere this design states a specific SQL
protocol shape (the locking mechanism, §6.2) that is *not* directly quoted from one of
those secondary citations, it is flagged explicitly as this design's own construction,
not a verified port — see §6.2's own callout and OQ-3 in §9.

---

## 1. Scope boundary

**In scope:** one new context module, `Letflow.EventStore` (`lib/letflow/event_store.ex`),
exposing `append/2`. No migrations (REQ-023 already shipped all six tables). No changes
to the five `lib/letflow/event_store/*.ex` schema modules or to `Registry` — this design
treats all of them as a fixed, already-verified interface (§0) and works within it.

**Explicitly NOT in scope, not silently dropped:**

PROVENANCE (historical, not current decision authority):
| Not built here | Owned by |
|---|---|
| `read/2`, `read_global/1`, `point_in_time/3`, `archive/1` | REQ-026 |
| The three `platform.zig` sentinel constants (`PLATFORM_INSTANCE_ID` etc.) | REQ-026 |
| Meaningful, engine-driven population of `instance_projections`' engine-owned columns (`definition_id`, `current_nodes`, ...) | EE-01/S3 |
| The HTTP/Plug route layer mapping `is_duplicate` to a 200 vs 201 status | S4 |
| `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` — **built by this requirement**, but lives in and is owned going forward by `Letflow.TenantProvisioning` (REQ-022's module), the same shape of forward cross-module edit REQ-023/024/027/035 already made to `tenant_scoped_migrations/0` | This design, §4 |

---

## 2. Module and file layout

| Module | File | Kind |
|---|---|---|
| `Letflow.EventStore` | `lib/letflow/event_store.ex` | New context module (public API: `append/2`) |
| `Letflow.TenantProvisioning` | `lib/letflow/tenant_provisioning.ex` | **Edited** — one new public function added, §4 |

No new Ecto schema modules. No new struct types beyond the plain result/error shapes in
§5.

---

## 3. The tenant_id-disagreement problem this design must close (read before §4/§5)

The 2026-08-17 addendum to `docs/migration/decisions/0003-ecto-schema-strategy.md`
(§0) settles the *mechanism* (derive `tenant_id` from the resolved schema, never accept
it as an independently-trusted field) but leaves each consuming requirement to decide
its own function signature. This design goes one step further than "derive it
internally": **`append/2`'s `attrs` parameter does not accept a `:tenant_id` key at
all, and if one is present, `append/2` rejects the call outright rather than silently
ignoring or overriding it.**

This is a deliberate strengthening beyond "derive and overwrite," made explicitly to
satisfy REQ-025's own acceptance criterion 6 literally: "not equal to a caller-supplied
`tenant_id` when the two are deliberately made to disagree in a test, **which must fail
loudly (not silently attribute to the wrong tenant) rather than succeed**." Silently
stripping/overriding a caller-supplied `tenant_id` field would make the disagreement
test *succeed* with the correct value quietly winning — which satisfies the "never
disagree" half of the criterion but not the "must fail loudly" half. Rejecting the call
outright satisfies both halves at once, and is strictly simpler to implement and test
than a strip-and-override path. See §5.3's `:tenant_id_not_accepted` error and §6.1
step P0.

---

## 4. `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` (new function this requirement adds)

Per the addendum (§0): "a context module about to write a tenant-scoped row reverses
[`schema_name_for_tenant/1`'s] encoding from the resolved schema name to obtain the
`tenant_id` it stamps on the row." This is a **pure, no-I/O** function — the reverse of
an already-pure function — placed in `Letflow.TenantProvisioning`, next to
`schema_name_for_tenant/1`, per the addendum's own framing ("a small pure
reverse-mapping function next to `schema_name_for_tenant/1`").

```
@spec tenant_id_for_schema_name(schema_name :: String.t()) ::
        {:ok, tenant_id :: Ecto.UUID.t()} | {:error, :invalid_schema_name}
```

**Algorithm (pure, total, no DB access):**

```
tenant_id_for_schema_name(schema_name):
  unless schema_name matches ^"tenant_" <> 32 lowercase hex characters$:
    return {:error, :invalid_schema_name}

  hex = drop the "tenant_" prefix (32 hex chars remain)
  canonical = insert "-" at hex positions 8, 12, 16, 20
              (the exact inverse of schema_name_for_tenant/1's own
              `String.replace(canonical, "-", "")` step)
  # canonical is now shaped like a UUID string, e.g. "3fa8...-....-....-....-............"
  Ecto.UUID.cast(canonical)   # defensive re-validation; cannot fail if the regex
                              # above matched, since schema_name_for_tenant/1 only ever
                              # emits output from an already-`Ecto.UUID.cast/1`-validated
                              # input -- but re-validated here rather than trusted blindly
```

**This is a total, deterministic inverse of `schema_name_for_tenant/1` as shipped**
(`lib/letflow/tenant_provisioning.ex:71–78`) — that function has no special-cased
default-tenant UUID (confirmed §0), so there is no lossy branch to invert incorrectly.
`schema_name_for_tenant/1`'s own moduledoc already documents this "no special case,
uniform `tenant_` <> hex derivation" property, which is exactly what makes the reverse
total rather than partial.

**Placement note, stated explicitly (not left ambiguous):** this function does **not**
query `Registration` and does **not** confirm the tenant is actually provisioned — it is
a pure string transform. Provisioning-existence is checked downstream, for free, by
`Letflow.EventStore.Registry.validate_payload/3`'s own `resolve_schema_name/1` call
(§6.1 step P4) — see §9 OQ-1 for the one scenario this ordering doesn't cover.

**Forward note for REQ-030 (`process_definitions`'s writer, not yet built):** the
addendum (§0) names REQ-030 as the *other* requirement blocked on this same mechanism.
This function is written once, here, for both. REQ-030's own CODE-DESIGNER should call
`Letflow.TenantProvisioning.tenant_id_for_schema_name/1` rather than re-deriving an
equivalent inline — the same "build the shared piece once, cite it from the second
consumer" precedent `tenant_scoped_migrations/0`'s manifest already set across
REQ-023/024/027/035.

---

## 5. Public interface: `Letflow.EventStore.append/2`

### 5.1 Why `/2`, and how the caller supplies the target tenant schema

`append/2(attrs, opts)`, **not** `append/1`. `opts` is a keyword list whose only
required key is `:prefix` — the tenant's physical schema name (a `String.t()`, e.g.
`"tenant_3fa8..."`), matching the exact convention `Letflow.EventStore.Event`'s own
moduledoc mandates (INV-EV-8, `req023-event-store-schema.md`): "every read and write
must pass `prefix: schema_name` explicitly at call time." This is **`:prefix`, not
`tenant_id`** — a deliberate divergence from `Letflow.EventStore.Registry`'s own
`tenant_id`-taking convention (§0), made because:

1. REQ-023's own schema modules (INV-EV-8) already commit every event-store table to a
   `prefix:`-at-call-time contract — matching that is matching an already-settled
   sibling decision, not introducing a new one.
2. `attrs` (§5.2) carries no tenant-identifying field at all (§3) — the *only* channel
   through which this call is tenant-scoped is `opts[:prefix]`, which makes the "derive,
   never accept a second disagreeing source" property (§3) structurally enforced by the
   function's own shape, not just by an internal check.

**Consequence, stated explicitly:** `append/2` therefore performs the *opposite*
resolution direction from `Registry`: it derives `tenant_id` from `:prefix` (pure, §4),
then **passes that derived `tenant_id` on to `Registry.validate_payload/3`** (§6.1 step
P4), which internally re-resolves `schema_name` from that `tenant_id` via its own
`Registration` DB lookup. This is a real, stated inefficiency (a schema-name round trip
through `tenant_id` and back), not a defect — see §9 OQ-2 for why this design accepts it
rather than reaching into `Registry`'s already-merged, sibling-owned code to add a
`schema_name`-accepting overload.

```
@spec append(attrs :: append_attrs(), opts :: [prefix: String.t()]) ::
        {:ok, append_result()} | {:error, append_error()}
```

### 5.2 `attrs` shape

```
@type append_attrs :: %{
        required(:instance_id)     => Ecto.UUID.t(),
        required(:event_type)      => String.t(),
        required(:payload)         => String.t(),   # RAW, not-yet-decoded JSON text --
                                                      # matches Registry.validate_payload/3's
                                                      # own contract (req024 design §4.2)
        required(:actor_id)        => Ecto.UUID.t(),
        required(:idempotency_key) => String.t(),
        optional(:metadata)        => %{optional(String.t()) => String.t()}  # default %{}
      }
```

**No `:tenant_id` key is accepted** (§3). **No `:event_id`, `:created_at`, or
`:sequence_number` key is accepted** — all three are minted/assigned internally
(INV-EV-5, §6.1 step P6; §6.2). If any of these four rejected keys is present in the
map passed to `append/2`, ELIXIR-DEV's implementation must treat this the same way as an
unrecognized key generally would in this codebase's `attrs`-taking functions — **but
`:tenant_id` specifically gets its own named, tested error** (§5.3) precisely because
AC6 requires that exact scenario to fail loudly, not because the other three are less
important; they are listed here so the same rejection logic (§6.1 step P0) covers all
four in one place rather than only the one AC6 happens to name.

### 5.3 `append_error()` — the full StoreError-equivalent set

One distinct, pattern-matchable tag per failure mode REQ-025 names, plus the tags this
design's own tenant-derivation mechanism requires:

```
@type append_error ::
        {:error, :tenant_id_not_accepted}
        # attrs contained a :tenant_id (or "tenant_id") key -- AC6, §3, §6.1 P0.
        | {:error, :invalid_schema_name}
        # opts[:prefix] does not match "tenant_" <> 32 hex chars -- §4, §6.1 P1.
        | {:error, :missing_instance_id}
        | {:error, :missing_actor_id}
        # REQ-025's own named case ("missing actor_id") -- event_store.md ES-01.
        | {:error, :missing_payload}
        | {:error, :invalid_payload}
        # payload absent, or (per Registry's own contract) not a JSON object at the
        # root -- REQ-025's named "invalid/missing payload" case.
        | {:error, :missing_idempotency_key}
        | {:error, :idempotency_key_too_long}
        # REQ-025's named "missing/too-long idempotency key" case -- ES-03's 1..255
        # bound, checked here pre-transaction so the DB-level varchar(255)/
        # validate_length(:idempotency_key, ...) constraint is never the first line
        # of defense.
        | {:error, {:invalid_metadata, metadata_violation()}}
        # REQ-025's named "metadata invalid" case -- ES-08, invariant 9. §6.1 P3.
        | {:error, :tenant_not_provisioned}
        # Propagated from Registry.validate_payload/3 (req024 design §4.2) -- the
        # derived tenant_id has no Registration row.
        | {:error, :unknown_event_type}
        # REQ-025's named "unknown event type" case -- propagated from Registry.
        | {:error, {:payload_validation_failed, [Letflow.EventStore.Registry.ValidationFailure.t()]}}
        # REQ-025's named "payload schema failure" case -- propagated from Registry,
        # covers both a real JSON-Schema mismatch and Registry's own root-type-mismatch
        # shortcut (payload decodes to a non-object).
        | {:error, :instance_not_started}
        # No instance_projections row exists yet for this instance_id -- REVIEWER's
        # Step 2d ruling on OQ-5 (§9 OQ-5): append/2 cannot originate a new instance's
        # projection row; some future EE-01/S3 mechanism (or, for this requirement's own
        # tests, a test fixture's direct Repo.insert) must create the row first. A
        # DISTINCT case from :instance_terminated below -- a missing row is never folded
        # into the terminal-instance path. §6.2 M1.
        | {:error, {:instance_terminated, :completed | :cancelled}}
        # REQ-025's named "terminated instance" case -- invariant 10. §6.2 M1. Only
        # reachable when an instance_projections row DOES exist and its status is
        # terminal; a missing row is always :instance_not_started above instead.
        | {:error, {:sequence_conflict, term()}}
        # Race-condition backstop only -- see §6.2 M2's own note on why this should be
        # unreachable under the locking protocol, and why it is still named rather than
        # left to surface as a raw %Ecto.Changeset{} or exception if it somehow occurs.
        | {:error, Ecto.Changeset.t()}
        # A structural changeset failure this design's own pre-checks didn't already
        # catch (defense in depth -- e.g. instance_id present but not a valid UUID,
        # caught by Ecto.UUID's own cast failure inside Event.insert_changeset/2).
        | {:error, term()}
        # Catch-all for a genuinely unexpected DB error, matching this codebase's
        # established `backend_developer_guide.md` §3.5 convention.

@type metadata_violation ::
        :too_many_entries
        | {:key_too_long, key :: String.t()}
        | {:value_too_long, key :: String.t()}
        | {:non_string_value, key :: String.t()}
```

**`metadata_violation()` reports the first violation found, not an exhaustive list.**
Stated explicitly as a divergence from `Registry.validate_payload/3`'s "report EVERY
failure" behavior (req024 design §4.4): ES-08 (metadata) carries no such "report all"
requirement in REQ-025's text, unlike ES-05 (payload schema, explicitly AC3-tested for
exhaustive reporting). Short-circuiting on the first metadata violation is simpler and
is not contradicted by any acceptance criterion.

### 5.4 `append_result()`

```
@type append_result :: %{
        event: Letflow.EventStore.Event.t(),
        is_duplicate: boolean(),
        sequence_number: pos_integer(),
        global_seq: pos_integer()
      }
```

On a fresh append, `event` is the just-inserted row (with `global_seq` populated by
Postgres's `bigserial`, returned automatically because `Event.global_seq` carries
`read_after_writes: true` — no explicit `returning:` option needed, standard Ecto
behavior). On a duplicate (`is_duplicate: true`), `event` is the **original** row from
the first successful append with that `idempotency_key` (§6.2 M3) — `sequence_number`
and `global_seq` are read off that original row, not freshly computed. The HTTP layer
(S4, out of scope) maps `is_duplicate` to 200 vs 201 — this design only returns the
boolean, per REQ-025's own text (1067–1068).

---

## 6. Behavior, in order

### 6.1 Pre-transaction phase (no `Repo.transaction`/`Ecto.Multi` opened yet)

**Everything in this phase either does zero I/O, or does exactly one read-only DB call
(P4) with no writes attempted anywhere before it.** This is the concrete resolution of
the task's flagged ambiguity: REQ-025's own text lists "Registry-first validation" as
step 3 of a 7-step enumeration inside "one atomic operation (Ecto.Multi or
Repo.transaction)" (1055–1064), but also states invariant 8's "zero rows written on
failure" and separately (invariant 9) says metadata validation happens "before the
transaction opens." **This design takes invariant 8's "before any write" as literally
as invariant 9's explicit "before the transaction opens," and moves both out of the
`Ecto.Multi` entirely** — not merely reordered to be Multi step 1, but run before
`Repo.transaction`/`Ecto.Multi.run` is invoked at all. Reasons, stated so REVIEWER can
evaluate them rather than discover an unexplained reordering:

1. **Literal invariant-8 compliance without relying on rollback semantics.** Inside one
   Ecto.Multi, "zero rows written on failure" would *also* hold if Registry validation
   were Multi step 3 (per the WF-02 task-brief's alternative: "or as the very first step
   inside it with no prior writes") — the whole transaction rolls back atomically on any
   `Multi.run` step returning `{:error, _}`, undoing steps 1–2's writes too. But
   `event_store.md`'s invariant 8 (quoted at `req023-event-store-schema.md:1052`'s own
   citation trail) is phrased as "before any write," which this design reads as
   describing the *execution order*, not merely the *final DB-visible outcome* — the two
   readings coincide for every other validation-error case in this design, but diverge
   specifically here because Registry validation is the one check requiring an actual DB
   round-trip.
2. **Avoids taking `instance_sequence`'s row lock for a call already known to fail.**
   `instance_sequence` is "the hot row every append takes a `SELECT ... FOR UPDATE` on"
   (`instance_sequence.ex`'s own moduledoc, quoting `event_store.md:353–358`) — the most
   contended row in the system. Running Registry validation (a pure read against
   `event_type_registry`, unrelated to `instance_sequence`) before ever acquiring that
   lock means a payload-schema failure never holds up a concurrent, unrelated,
   successful append to the same instance for even the duration of one failed
   validation's round trip.
3. **Symmetry with metadata validation.** Invariant 9 already establishes "no DB
   round-trip on a check we can settle without one" as this requirement's own stated
   design principle for metadata. Extending that same principle to every check that
   doesn't strictly need transactional atomicity with the writes (Registry validation
   needs read-committed consistency with `event_type_registry`, not with `events`) is a
   consistent application of a principle the requirement itself already states, not an
   unrelated one.

**Flagged, not silently decided:** this reordering is a real interpretive choice this
design makes, not a fact read off a source document — see §9 OQ-3. REVIEWER should
re-confirm it if `event_store.md`'s actual "append" section (unreachable on this host,
§0) turns out to state a stricter ordering requirement than what's quoted secondhand.

```
P0. Reject :tenant_id.
    attrs has key :tenant_id (or "tenant_id") -> {:error, :tenant_id_not_accepted}

P1. Derive tenant_id from opts[:prefix].
    tenant_id_for_schema_name(opts[:prefix]) (Letflow.TenantProvisioning, §4)
      {:error, :invalid_schema_name} -> {:error, :invalid_schema_name}
      {:ok, tenant_id} -> continue, bind tenant_id and schema_name = opts[:prefix]

P2. Structural presence checks (pure), in this order, first failure wins:
      attrs[:instance_id] missing or not Ecto.UUID.cast/1-valid -> {:error, :missing_instance_id}
      attrs[:actor_id]    missing or not Ecto.UUID.cast/1-valid -> {:error, :missing_actor_id}
      attrs[:payload]     missing or not a non-empty binary     -> {:error, :missing_payload}
      attrs[:idempotency_key] missing                           -> {:error, :missing_idempotency_key}
      String.length(attrs[:idempotency_key]) > 255               -> {:error, :idempotency_key_too_long}
      attrs[:event_type]  missing or not a non-empty binary     -> {:error, Ecto.Changeset.t()}
        # event_type has no REQ-025-named standalone error case; a missing/empty
        # event_type is left to surface via Event.insert_changeset/2's own
        # validate_required/validate_length at Multi step M4 rather than inventing an
        # unnamed atom -- stated explicitly, not an oversight (§9 OQ-4).

P3. Metadata validation (pure) -- invariant 9, ES-08. metadata = attrs[:metadata] || %{}.
      map_size(metadata) > 50 -> {:error, {:invalid_metadata, :too_many_entries}}
      for each {key, value} in metadata, first violation wins:
        not is_binary(key) -> structurally impossible once metadata is a decoded JSON
                               object (JSON object keys are always strings); not checked
        String.length(key) > 128        -> {:error, {:invalid_metadata, {:key_too_long, key}}}
        not is_binary(value)            -> {:error, {:invalid_metadata, {:non_string_value, key}}}
        String.length(value) > 1024     -> {:error, {:invalid_metadata, {:value_too_long, key}}}

P4. Registry validation -- invariant 8, ES-05. The one DB round-trip in this phase,
    read-only (a SELECT against event_type_registry; no write anywhere yet).
    Letflow.EventStore.Registry.validate_payload(attrs[:event_type], attrs[:payload], tenant_id)
      :ok -> continue
      {:error, :tenant_not_provisioned} -> {:error, :tenant_not_provisioned}
      {:error, :unknown_event_type}     -> {:error, :unknown_event_type}
      {:error, {:payload_validation_failed, failures}} ->
        {:error, {:payload_validation_failed, failures}}

P5. Measure payload size and pre-decode (pure) -- INV-EV-7's "measured at append time."
      payload_bytes: the byte length of the raw payload binary, measured directly from
        the binary attrs supplied -- never derived from the decoded term.
      decoded_payload: the payload binary parsed into its JSON term form. Safe to do
        unconditionally here (no further validation needed) because P4 already proved
        the payload parses to a JSON object.

P6. Mint identity, once (pure) -- INV-EV-5.
      event_id: a freshly generated UUID, minted exactly once per append attempt.
      created_at: the current UTC timestamp, truncated to the column's declared
        microsecond precision.
      Both values are bound once here and reused unchanged everywhere they reappear
      below (the events row, the idempotency-sidecar row, and -- only when the payload
      is oversized -- the event_payload_store row) -- never re-minted per statement.
```

### 6.2 Transactional phase — one `Ecto.Multi`, `prefix: schema_name` on every operation

All operations below execute inside a single `Repo.transaction(multi, [])`
(`Ecto.Multi.new() |> Multi.run(...) |> ...`). Any step returning `{:error, _}` aborts
the **whole** transaction — every write from every earlier step in this list rolls back
atomically, which is what makes M3's "duplicate detected after the sequence was already
incremented" case (below) still honor "zero rows written."

| Step | Multi op | What it does |
|---|---|---|
| M1 `:active_instance_guard` | `Multi.run/3` | §6.2.1 |
| M2 `:assign_sequence` | `Multi.run/3` | §6.2.2 (the locking protocol) |
| M3 `:idempotency` | `Multi.run/3` | §6.2.3 |
| M4 `:insert_event` | `Multi.run/3` (wraps `Repo.insert/2`) | §6.2.4 |
| M5 `:store_oversized_payload` | `Multi.run/3`, conditional | §6.2.5 |
| M6 `:update_projection` | `Multi.run/3` | §6.2.6 |

#### 6.2.1 M1 — Active-instance guard (invariant 10, ES-01)

```
M1 (:active_instance_guard) -- reads the instance_projections row for
attrs.instance_id, targeting the derived tenant schema. A plain, unlocked read; no row
lock is taken here (see the paragraph below for why that's an acceptable gap).

  no row found for this instance_id
    -> fail the step with {:error, :instance_not_started} -- a DISTINCT error case from
       :instance_terminated below, not an implicitly-new/active instance and not folded
       into the terminal-instance branch. append/2 cannot originate a new instance's
       instance_projections row under this requirement's scope; some other mechanism
       (EE-01/S3's future instance-start population, or -- for this requirement's own
       tests -- a test fixture's direct Repo.insert against instance_projections,
       bypassing append/2 entirely) must create the row first. This aborts the whole
       Multi before any write happens anywhere. See §9 OQ-5 for the REVIEWER ruling this
       resolves.

  row found, and its status is terminal (CANCELLED or COMPLETED, per
  InstanceProjection.terminal?/1 as REQ-023's schema design defines it)
    -> fail the step with {:error, {:instance_terminated, status}}, where status is the
       terminal status found -- this aborts the whole Multi before any write happens
       anywhere (AC1). Only reachable when a row DOES exist -- a missing row is always
       :instance_not_started above, never treated as an implicit terminal state.

  row found, and its status is not terminal
    -> succeed, recording :existing_instance
```

Plain `Repo.get/3` — no lock. A concurrent transition to `CANCELLED`/`COMPLETED`
racing this read is bounded by ordinary read-committed isolation; a stronger guarantee
(e.g. locking `instance_projections` for the append's duration) is not requested by any
source this design has access to and is left as OQ-6 (§9), not silently assumed away.

#### 6.2.2 M2 — Sequence assignment: the FOR-UPDATE-equivalent locking protocol (invariant 2/4, ES-02)

**Locking protocol**, three sub-steps, all inside the same DB transaction and therefore
sharing the same lock lifetime — this directly answers the task's request for "the exact
query shape for the FOR UPDATE-equivalent lock, including the insert-if-absent
first-append case." The read/lock step is expressed through Ecto's own query-composition
API (favored over a raw, hand-written SQL string per INV-7's guidance, §0), described
here by what it does rather than by its literal call form:

```
M2 (:assign_sequence) -- three sub-steps, in order:

  (i) Insert-if-absent. Attempt to insert a fresh instance_sequence row for
      attrs.instance_id, using the schema module's own insert changeset (never a bare
      bulk-insert that bypasses changeset validation) -- this covers "first append to a
      new instance" (event_store.md's own named case, quoted at req023's §3.2). The
      insert is configured as an atomic insert-or-ignore keyed on instance_id: if a row
      for this instance_id already exists (because a concurrent racer's own (i) got
      there first, or because this is not the instance's first append), the conflicting
      insert is silently suppressed rather than raising a unique-constraint exception --
      one atomic statement, not a separate existence check followed by a conditional
      insert (which would itself race). When this insert is the one that actually
      creates the row, its next_seq column takes its declared column default of 1 --
      the insert supplies no explicit value for it.

  (ii) Row-lock read. Read the instance_sequence row for attrs.instance_id back,
       acquiring an exclusive row lock (the SELECT ... FOR UPDATE-equivalent read) held
       for the remainder of this DB transaction. This read is guaranteed to find a row,
       because either this transaction's own (i) created it, or some transaction's (i)
       already had. The row's next_seq value, as read here, becomes
       assigned_sequence_number -- this event's sequence number.

  (iii) Increment under the lock. While still holding the lock acquired at (ii), in the
        same transaction, increment the row's stored next_seq column by one. The lock
        is held continuously from (ii) through this step's own commit, so no other
        transaction can read or modify this row in between.

  Step succeeds with assigned_sequence_number.
```

**Concurrency argument (AC2):** two concurrent appends to the same `instance_id`.
Whichever transaction's step (i) commits (or finds the row already present) first is
irrelevant to correctness — both converge on the same row existing before either
reaches step (ii). Step (ii)'s row-lock read is where the actual serialization happens:
the second transaction's `(ii)` **blocks** at
the database level until the first transaction's step (iii) commits (releasing the row
lock) or the whole first transaction rolls back. Only after that does the second
transaction's `(ii)` proceed, and it reads the **post-increment** value the first
transaction's `(iii)` wrote — so the two transactions are guaranteed to read distinct
`next_seq` values at `(ii)`, hence distinct `assigned_sequence_number`s. This is the
standard Postgres "counter row" locking idiom; `uq_event_sequence`
(`(instance_id, sequence_number)`, unique — `req023-event-store-schema.md` §3.1.2) is
the DB-level backstop that would surface as a constraint violation
(`{:error, {:sequence_conflict, changeset}}`, §5.3) if this protocol were ever bypassed
or implemented incorrectly — named explicitly in the error union so a violation here is
a loud, pattern-matchable defect signal rather than a raw unhandled exception (INV-8,
`security-invariants.md`), not because this design expects it to fire under correct
use.

If this environment cannot exercise real Postgres-level lock contention in a test
(TEST-DESIGNER's call, WF-02 Step 3), **this section is the citation** the AC2 fallback
asks for.

#### 6.2.3 M3 — Idempotency check/insert (invariant 4, ES-03)

Reuses the exact "re-select after `on_conflict: :nothing`" idiom already shipped in
`Letflow.TenantProvisioning.insert_or_fetch_registration/2`
(`tenant_provisioning.ex:315–338`) — necessary here for the identical reason: `id` is a
client-generated `binary_id`, so `{:ok, struct}` from an `on_conflict: :nothing` insert
is ambiguous between "really inserted" and "suppressed."

```
M3 (:idempotency) -- two sub-steps:

  (i) Attempted claim. Mint attempted_id, a fresh UUID distinct from event_id, to serve
      as the idempotency-sidecar row's own surrogate primary key. Attempt to insert a
      sidecar row carrying attrs.idempotency_key, event_id (from P6), and created_at
      (from P6), using the schema module's own insert changeset. The insert is
      configured as an atomic insert-or-ignore keyed on idempotency_key, mirroring the
      exact "attempt an insert, then re-select to disambiguate outcome" idiom already
      shipped in Letflow.TenantProvisioning.insert_or_fetch_registration/2
      (tenant_provisioning.ex:315-338) -- necessary here for the identical reason:
      because attempted_id is client-generated rather than DB-assigned, a bare "insert
      succeeded" signal can't by itself distinguish "this row was really inserted" from
      "the insert was silently suppressed by a conflicting idempotency_key."

  (ii) Disambiguate by re-selecting. Look up the sidecar row by attempted_id.

    row found (by attempted_id)
      -> this transaction's own insert really claimed the key -- succeed, recording
         :claimed (a fresh append)

    row not found (by attempted_id)
      -> the key was already claimed by an earlier append; the insert at (i) was
         suppressed. Look up the existing sidecar row by idempotency_key, then look up
         the events row it points at (by that row's event_id/event_created_at) -- both
         needed for append_result()'s is_duplicate: true shape. Fail the step with
         {:error, {:duplicate_idempotency_key, original_event}}, where original_event is
         the event row just looked up.
```

**Why a `duplicate_idempotency_key` result is an `{:error, _}` at the `Multi.run` level,
not treated as `{:ok, _}`:** returning `{:error, _}` here is what makes `Ecto.Multi`
roll back the whole transaction — including M2's already-executed sequence
increment — so a duplicate call consumes **zero** durable rows anywhere, not just zero
`events` rows (AC3's literal requirement: "does not insert a second events row" — this
design satisfies a strictly stronger property: no row anywhere changes at all on a
duplicate). `append/2`'s own top-level result assembly (§6.3) recognizes this specific
transaction-failure shape and converts it into a **successful** return carrying
`is_duplicate: true` — the `{:error, _}` at the `Multi` level and
the `{:ok, _}` at `append/2`'s own boundary are not in tension: one is "did this
database transaction commit," the other is "did the caller's idempotent request
succeed," and they are legitimately different questions with different answers here.

#### 6.2.4 M4 — Insert `events` row (invariant 5/7, ES-01/02/03/05/08)

```
M4 (:insert_event) -- inserts one events row, via the schema module's own insert
changeset, populated as follows:

  payload field: if payload_bytes (P5) is 4096 or fewer, store decoded_payload (P5)
    inline. Otherwise, store the pointer form instead -- a small JSON object whose sole
    key is "$ref" and whose value is event_id (P6) -- per invariant 7.

  every other field is a direct pass-through, with three exceptions: event_id and
    created_at come from P6 (not freshly generated here), sequence_number comes from
    assigned_sequence_number (M2), and tenant_id comes from the value derived at P1 --
    never from anything attrs-supplied (§3). metadata comes from P3's already-defaulted
    value (an empty object when the caller supplied none).

  Step succeeds with the inserted events row.
```

`global_seq` is deliberately never among the fields this insert populates — it is a
`read_after_writes: true` column (confirmed §0), so the DB assigns its value and Ecto
reads it back automatically; the insert changeset's own cast-field list doesn't include
it at all.

#### 6.2.5 M5 — Store oversized payload (invariant 7, `event_payload_store`)

**Conditional step — only included in the `Multi` pipeline at all when
`payload_bytes > 4096`.** Must run after M4: the composite FK
`(event_id, event_created_at) → events(event_id, created_at)` (`on_delete: :restrict`,
`req023-event-store-schema.md` §3.4) requires the `events` row to exist first.

```
M5 (:store_oversized_payload) -- included in the step sequence at all only when
payload_bytes (P5) exceeds 4096; skipped entirely otherwise. Inserts one
event_payload_store row, via the schema module's own insert changeset, carrying:
event_id and event_created_at (both from P6, matching M4's events row exactly, to
satisfy the composite foreign key back to it), payload set to decoded_payload (P5), and
byte_size set to payload_bytes (P5) -- the originally measured size (INV-EV-7), not a
size recomputed from the stored representation.

  Step succeeds with the inserted event_payload_store row.
```

#### 6.2.6 M6 — `instance_projections` update (invariant 6, DB-03)

**This step is update-only — it never creates an `instance_projections` row.** REVIEWER's
Step 2d ruling on OQ-5 (§9) held that row creation is EE-01/S3's "meaningful population
at instance-start" territory, not this requirement's to originate; M1 (§6.2.1) already
guarantees, by the time M6 runs, that a row exists and is non-terminal (M1 fails the
whole `Multi` with `{:error, :instance_not_started}` or `{:error, {:instance_terminated,
status}}` before M6 is ever reached otherwise). M6 therefore uses
`InstanceProjection.update_changeset/2` — the changeset REQ-023 built specifically for
this — never `insert_changeset/2` and never an `on_conflict:`-based upsert.

```
M6 (:update_projection) -- updates the instance_projections row for this instance_id
(guaranteed present and non-terminal by M1), via InstanceProjection.update_changeset/2:

  update last_event_seq (to assigned_sequence_number, M2) and the row's updated-at
  timestamp (to created_at, P6). status and tenant_id are left untouched -- an existing
  row's status must never be overwritten by an ordinary append (status transitions
  belong to EE-01/S3, out of this requirement's scope) and its tenant_id never changes
  for an existing instance.

  This is a plain UPDATE keyed on instance_id, not an upsert -- there is no
  "row absent" branch here; that case was already exhausted by M1.
```

### 6.3 Assembling the top-level result

```
append(attrs, opts) -- runs the pre-transaction phase (§6.1, P0-P6) first, in order,
stopping at the first failure and returning its error immediately without opening a
transaction:

  P0 fails -> return its error as-is
  P1 fails -> return its error as-is
  P2 fails -> return its error as-is
  P3 fails -> return its error as-is
  P4 fails -> return its error as-is

  all of P0-P6 succeed
    -> build the Multi (§6.2, steps M1-M6, conditionally including M5) and run it as one
       database transaction. Then interpret the transaction's outcome:

       every step committed, with M4 having produced an events row and M2 having
       produced a sequence number
         -> return a success carrying: the inserted event, is_duplicate: false, the
            assigned sequence_number, and the event's global_seq

       the transaction aborted specifically because M1 (:active_instance_guard) failed
       with an instance-terminated reason
         -> return {:error, {:instance_terminated, status}}, re-surfacing the status M1
            found (AC1)

       the transaction aborted specifically because M3 (:idempotency) failed with a
       duplicate-idempotency-key reason
         -> this is NOT surfaced as a failure to the caller. Return a success carrying:
            the pre-existing original_event M3 looked up, is_duplicate: true, and that
            event's own sequence_number/global_seq (AC3). (See §6.2.3's closing
            paragraph for why an aborted transaction can still legitimately produce a
            successful append/2 return -- "did this DB transaction commit" and "did the
            caller's idempotent request succeed" are different questions here.)

       the transaction aborted because some step's insert violated a DB constraint
         -> if the violated constraint is instance_sequence's or events' own
            uniqueness guarantee on (instance_id, sequence_number) (the DB-level
            backstop to M2's locking protocol, §6.2.2's concurrency argument), return
            {:error, {:sequence_conflict, <constraint-violation detail>}}. For any other
            constraint violation, return {:error, <constraint-violation detail>}
            unchanged.

       the transaction aborted for any other reason (any step's own named failure not
       covered above)
         -> return that reason as the error, unchanged
```

---

## 7. Required moduledoc content

`Letflow.EventStore`'s `@moduledoc` must state, verbatim in substance (not necessarily
word-for-word):

1. That `tenant_id` is **always** derived from `opts[:prefix]` via
   `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`, never accepted from
   `attrs`, and that `attrs` containing a `:tenant_id` key is a hard error
   (`:tenant_id_not_accepted`) — citing `docs/migration/decisions/0003-ecto-schema-strategy.md`'s
   2026-08-17 addendum by name.
PROVENANCE (historical, not current decision authority):
2. That `event_id`/`created_at` are minted exactly once per call and bound identically
   into `events`, `event_idempotency`, and (conditionally) `event_payload_store` —
   citing INV-EV-5 and the R-Co bug it prevents (`store.zig:623–636`, quoted via
   `req023-event-store-schema.md`).
3. That Registry validation and metadata validation run **before** `Repo.transaction` is
   opened, not as an early `Multi` step — with the reasoning in §6.1 above, so a future
   reader doesn't "fix" this into matching REQ-025's literal 7-item list without reading
   why it was deliberately reordered.
4. That `instance_sequence` and `event_idempotency` carry **no** `tenant_id` column
   (§0, §9 OQ-1) — tenant isolation for those two tables' rows is enforced entirely by
   the Postgres schema (`:prefix`) boundary they're written into, not by a column value.

---

## 8. Invariants

| id | Invariant | Enforced where |
|---|---|---|
| INV-AP-1 | `append/2`'s `attrs` never accepts `:tenant_id`; presence is a hard `{:error, :tenant_id_not_accepted}` | §6.1 P0 |
| INV-AP-2 | `tenant_id` stamped on every row that has the column is always `tenant_id_for_schema_name(opts[:prefix])`'s result — never any other source | §4, §6.2.4 (M4), §6.2.6 (M6) |
| INV-AP-3 | `event_id`/`created_at` minted exactly once per `append/2` call, bound identically into every row referencing them | §6.1 P6; §6.2.3 (M3), §6.2.4 (M4), §6.2.5 (M5) |
| INV-AP-4 | Registry validation and metadata validation complete with zero DB writes attempted before either runs | §6.1 (the whole pre-transaction phase) |
| INV-AP-5 | Two concurrent appends to the same `instance_id` never receive the same `sequence_number` | §6.2.2's locking protocol; `uq_event_sequence` as DB-level backstop |
| INV-AP-6 | A duplicate `idempotency_key` produces zero net row changes anywhere (not just zero `events` rows) and returns the original event with `is_duplicate: true` | §6.2.3 (M3), §6.3 |
| INV-AP-7 | Appending to a `:completed`/`:cancelled` instance writes zero rows across all five tables | §6.2.1 (M1) + whole-`Multi` rollback |
| INV-AP-8 | A payload over 4096 bytes is stored as `{"$ref": "<event_id>"}` in `events.payload` plus a row in `event_payload_store`; `byte_size` is the pre-storage measured length | §6.1 P5, §6.2.4 (M4), §6.2.5 (M5) |
| INV-AP-9 | `instance_sequence` and `event_idempotency` carry no `tenant_id` column; their tenant isolation is enforced solely by the `:prefix` schema boundary, not a column value | §0, §9 OQ-1 |

---

## 9. Open questions — explicitly listed, not silently resolved

**OQ-1 (MAJOR — affects TEST-DESIGNER directly, blocks a literal reading of AC6).**
REQ-025's acceptance criterion 6 names "events, instance_sequence, instance_projections,
the idempotency sidecar" as the four tables whose rows must carry a correctly-derived
`tenant_id`. **This is inconsistent with REQ-023's actual shipped schema**, confirmed
directly against both the Ecto schema modules and the migration DDL (§0):
`instance_sequence` and `event_idempotency` have **no `tenant_id` column at all** — only
`events` and `instance_projections` do (`events_archive` also has one, but is out of
REQ-025's scope). This design does **not** silently narrow the acceptance criterion to
match the schema, and does **not** add a `tenant_id` column to the two tables that lack
one (REQ-023's own §2.5 explicitly reasons through this asymmetry and warns against
"completing" it). Instead: §8's INV-AP-9 states the resolution this design adopts —
tenant isolation for those two tables is enforced by the `:prefix` physical-schema
boundary alone, which is in fact the same guarantee every table in this schema relies on
underneath its `tenant_id` column (REQ-023's own INV-EV-8). **TEST-DESIGNER must adapt
AC6's test accordingly**: for `events`/`instance_projections`, assert the `tenant_id`
column value; for `instance_sequence`/`event_idempotency`, assert instead that the row
is reachable only under the correct `prefix` (a query with the wrong tenant's `prefix`
finds nothing) — a schema-boundary check, not a column check. Reported to REVIEWER as a
requirement-text/shipped-schema mismatch, not resolved unilaterally by silently editing
`docs/requirements.yaml`.

**OQ-2 (MINOR).** `append/2` derives `tenant_id` from `:prefix` and then passes that
`tenant_id` to `Registry.validate_payload/3`, which internally re-resolves `schema_name`
from it via its own DB round-trip (§5.1) — redundant with the `schema_name` `append/2`
already had. Not fixed here: doing so would mean adding a `schema_name`-accepting
overload to `Registry` (REQ-024's already-merged, sibling-owned module), which
REQ-024's own §7.3 already flags as a "left for REVIEWER" fast-follow question, not
something this design should decide unilaterally by editing a merged sibling module.

PROVENANCE (historical, not current decision authority):
**OQ-3 (MINOR, methodological).** §6.1's "move Registry and metadata validation
entirely outside the `Ecto.Multi`" is this design's own interpretation of invariants 8/9
against a requirement-text paraphrase, not a literal quotation of `event_store.md`'s
"append" section (unreachable on this host, §0). If a future run regains access to
R-Co's actual `event_store.md`/`store.zig` and finds a stricter or different ordering
stated there, this section should be re-verified against the primary source rather than
assumed settled by this design's reasoning alone.

**OQ-4 (MINOR).** `event_type` presence/shape has no REQ-025-named standalone error
atom (unlike `actor_id`, `payload`, `idempotency_key`). This design lets a missing/empty
`event_type` surface via `Event.insert_changeset/2`'s ordinary `%Ecto.Changeset{}` path
(§6.1 P2's own note) rather than inventing an unnamed atom. Flagged in case REVIEWER
judges this inconsistent with how the other three structural fields are handled.

**OQ-5 — RESOLVED per REVIEWER's Step 2d ruling
(`handoffs/WF02-REQ025-20260817/step-02d-reviewer.json`), no longer open.** REQ-025's
text says M6 "updates" `instance_projections`; REQ-023's own moduledoc (§7.3 there)
says `instance_projections`' *meaningful population* is EE-01/S3 territory and warns
"do not read this migration as instance-engine work landing early." This design's first
draft read that warning as applying only to the migration/engine-owned-columns boundary
(`definition_id`, `current_nodes`, etc.), and had `append/2` create the bare row
(`instance_id`, `tenant_id`, `status: :active`, `last_event_seq`) on an instance's first
append. **REVIEWER rejected that reading**: REQ-025's own acceptance-criteria text names
"update" only for this table (unlike `instance_sequence`'s explicit insert-if-absent
callout), `InstanceProjection` is the only event-store schema module REQ-023 gave an
`update_changeset/2` (a strong signal REQ-023 anticipated `append/2` only ever updating
this table), and "at instance start" population is explicitly EE-01/S3's job, not a
storage mechanic incidental to appending an event. Resolution, now built into §6.2.1
(M1) and §6.2.6 (M6): `append/2` never originates an `instance_projections` row. A
missing row is a distinct M1 failure, `{:error, :instance_not_started}`, and M6 is
update-only via `InstanceProjection.update_changeset/2`. Some future EE-01/S3 mechanism
(or, for this requirement's own tests, a test fixture's direct `Repo.insert` against
`instance_projections`, bypassing `append/2` entirely — REVIEWER confirmed this is the
correct test strategy) must create the row before any `append/2` call can succeed
against that instance.

**OQ-6 (MINOR).** M1's active-instance guard is a plain (unlocked) read. A stronger
guarantee (locking `instance_projections` for the append's duration, so a concurrent
cancellation can never race a concurrent append) is not requested by any source this
design can verify and is not built here.

---

## 10. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` | `EventStore` → `TenantProvisioning` | **New function this requirement adds** (§4) — a forward edit to a sibling, already-merged module, same shape as REQ-023/024/027/035's edits to `tenant_scoped_migrations/0`. |
| `Letflow.EventStore.Registry.validate_payload/3` | `EventStore` → `Registry` (REQ-024) | Read-only, pre-transaction (§6.1 P4). Consumes `Registry`'s exact shipped error union unchanged. |
| `Letflow.EventStore.{Event, InstanceSequence, InstanceProjection, IdempotencyRecord, StoredPayload}` | `EventStore` → REQ-023's schema modules | Consumes each schema's `insert_changeset/2` for the rows this requirement creates (`Event`, and conditionally `StoredPayload`), plus upsert-via-`insert_changeset/2` + `on_conflict:` for `InstanceSequence`/`IdempotencyRecord` (§6.2.2, §6.2.3) — but `InstanceProjection.update_changeset/2` **is** used for M6 (§6.2.6), per OQ-5's resolution (§9): M6 only ever updates an existing row, never creates one. Adds no new function to any of the six. |
| `Letflow.Repo` | `EventStore` → `Repo` | Every operation passes `prefix: schema_name` explicitly (INV-EV-8); no `@schema_prefix` anywhere. |
| REQ-026 (`read/2`, `archive/1`, not yet built) | REQ-026 → REQ-025 | Consumes `append/2`'s row shapes as its own read/archive targets. Not built or anticipated here. |
| REQ-030 (`process_definitions`'s writer, not yet built) | REQ-030 → this design | Should reuse `tenant_id_for_schema_name/1` (§4's forward note) rather than re-deriving an equivalent. |

---

## 11. Acceptance-criteria traceability

| REQ-025 acceptance criterion | Concrete design element |
|---|---|
| 1. "appending to a terminated instance ... returns an error and writes zero rows across all five involved tables" | §6.2.1 (M1) + whole-`Multi` atomic rollback semantics (§6.2's opening paragraph); INV-AP-7; `{:error, {:instance_terminated, status}}` (§5.3) |
| 2. "two concurrent appends to the same instance_id never receive the same sequence_number ... or ... the FOR UPDATE-equivalent locking code path is cited explicitly" | §6.2.2 — the full three-statement protocol and its concurrency argument; INV-AP-5 |
| 3. "appending twice with the same idempotency_key returns is_duplicate: true ... and does not insert a second events row" | §6.2.3 (M3) + §6.3's `duplicate_idempotency_key` branch; INV-AP-6 (a strictly stronger property: zero net rows anywhere, not just `events`) |
| 4. "a payload that fails REQ-024's validate_payload/2 results in zero rows written to events, instance_sequence, or instance_projections" | §6.1 P4 — runs entirely before the `Multi`/transaction opens, so literally zero writes are ever attempted, not merely rolled back; INV-AP-4 |
| 5. "a payload over 4096 bytes is split into events.payload's $ref pointer form plus an event_payload_store row" | §6.1 P5 (measurement) + §6.2.4 (M4, `$ref` form) + §6.2.5 (M5, the side row); INV-AP-8 |
| 6. "every row append/1(2) writes ... has tenant_id equal to the tenant whose schema the write targeted, derived internally ... which must fail loudly ... rather than succeed" | §3 (the no-`:tenant_id`-accepted design), §4 (the derivation function), §6.1 P0/P1, §6.2.4 (M4), §6.2.6 (M6); INV-AP-1, INV-AP-2, INV-AP-9; **§9 OQ-1 flags the requirement-text/shipped-schema mismatch for the two tables that carry no tenant_id column at all**, with a concrete adapted-test resolution stated, not left ambiguous |

Per OQ-5's resolution (§9), `append/2` never creates an `instance_projections` row —
M1 (§6.2.1) requires one to already exist and be non-terminal before M6 (§6.2.6) can
run. **Every test exercising AC1–AC6 above must therefore pre-seed the target
instance's `instance_projections` row via a direct `Repo.insert` in test setup**
(REVIEWER-confirmed strategy, `step-02d-reviewer.json`), not rely on `append/2` itself
to originate it — TEST-DESIGNER's fixtures are the "some other mechanism" §9/§6.2.1
refer to for this requirement's own coverage.
