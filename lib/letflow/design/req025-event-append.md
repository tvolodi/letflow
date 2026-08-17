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
        | {:error, {:instance_terminated, :completed | :cancelled}}
        # REQ-025's named "terminated instance" case -- invariant 10. §6.2 M1.
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

P5. Measure payload size and pre-decode (pure).
    payload_bytes = byte_size(attrs[:payload])       # INV-EV-7's "measured at append time"
    decoded_payload = Jason.decode!(attrs[:payload])  # safe: P4 already proved this
                                                       # decodes to a JSON object

P6. Mint identity, once (pure) -- INV-EV-5.
    event_id   = Ecto.UUID.generate()
    created_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    # Bound identically into events, event_idempotency, and (if oversized)
    # event_payload_store at M3/M4/M5 below -- never regenerated per statement.
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
M1(repo, _changes):
  projection = repo.get(InstanceProjection, attrs.instance_id, prefix: schema_name)
  case projection do
    nil ->
      {:ok, :new_instance}
      # No row yet -- a brand-new instance's first-ever append. Not terminated by
      # definition. See §6.2.6 and §9 OQ-5 for why M6 must therefore be able to
      # CREATE this row, not only update one that already exists.
    %InstanceProjection{status: status} ->
      if InstanceProjection.terminal?(status) do
        {:error, {:instance_terminated, status}}
      else
        {:ok, :existing_instance}
      end
  end
```

Plain `Repo.get/3` — no lock. A concurrent transition to `CANCELLED`/`COMPLETED`
racing this read is bounded by ordinary read-committed isolation; a stronger guarantee
(e.g. locking `instance_projections` for the append's duration) is not requested by any
source this design has access to and is left as OQ-6 (§9), not silently assumed away.

#### 6.2.2 M2 — Sequence assignment: the FOR-UPDATE-equivalent locking protocol (invariant 2/4, ES-02)

**Exact query shape**, three statements, all inside the same DB transaction and
therefore sharing the same lock lifetime — this directly answers the task's request for
"the exact query shape for the FOR UPDATE-equivalent lock, including the
insert-if-absent first-append case," expressed via idiomatic `Ecto.Query` (favored over
raw `Repo.query/3` per INV-7's guidance, §0) rather than hand-written SQL:

```
M2(repo, _changes):
  # (i) Insert-if-absent -- "First append to a new instance" (event_store.md's own
  #     named case, quoted at req023's §3.2). Uses the schema module's own
  #     insert_changeset/2 (never a bare Repo.insert_all bypassing changeset
  #     validation), on_conflict: :nothing so a losing racer's insert is a silent no-op
  #     rather than a unique_constraint exception.
  repo.insert(
    InstanceSequence.insert_changeset(%InstanceSequence{}, %{instance_id: attrs.instance_id}),
    on_conflict: :nothing,
    conflict_target: :instance_id,
    prefix: schema_name
  )
  # next_seq's own column default (1) fires here since insert_changeset/2's attrs
  # supply no :next_seq -- matches InstanceSequence's migration default exactly.

  # (ii) Row-lock read -- Ecto.Query's `lock:` option, NOT Repo.query/3.
  locked_row =
    from(s in InstanceSequence, where: s.instance_id == ^attrs.instance_id, lock: "FOR UPDATE")
    |> repo.one(prefix: schema_name)
  assigned_sequence_number = locked_row.next_seq

  # (iii) Increment under the lock acquired by (ii) -- same transaction, same row,
  #       lock held continuously from (ii) through (iii)'s commit.
  from(s in InstanceSequence, where: s.instance_id == ^attrs.instance_id)
  |> repo.update_all([inc: [next_seq: 1]], prefix: schema_name)

  {:ok, assigned_sequence_number}
```

**Concurrency argument (AC2):** two concurrent appends to the same `instance_id`.
Whichever transaction's step (i) commits (or finds the row already present) first is
irrelevant to correctness — both converge on the same row existing before either
reaches step (ii). Step (ii)'s `SELECT ... FOR UPDATE` (via `lock: "FOR UPDATE"`) is
where the actual serialization happens: the second transaction's `(ii)` **blocks** at
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
M3(repo, changes):
  attempted_id = Ecto.UUID.generate()   # the sidecar row's own surrogate id, distinct
                                         # from event_id
  {:ok, inserted_or_suppressed} =
    repo.insert(
      IdempotencyRecord.insert_changeset(%IdempotencyRecord{id: attempted_id}, %{
        idempotency_key: attrs.idempotency_key,
        event_id: event_id,            # minted at P6
        event_created_at: created_at   # minted at P6
      }),
      on_conflict: :nothing,
      conflict_target: :idempotency_key,
      returning: true,
      prefix: schema_name
    )

  if repo.get(IdempotencyRecord, attempted_id, prefix: schema_name) do
    {:ok, :claimed}   # really inserted -- this is a fresh append
  else
    # Suppressed: idempotency_key already claimed by an earlier append. Fetch the
    # pre-existing record, then the event it points at -- both needed for
    # append_result()'s is_duplicate: true shape.
    existing = repo.get_by!(IdempotencyRecord, [idempotency_key: attrs.idempotency_key], prefix: schema_name)
    original_event =
      repo.get_by!(Event, [event_id: existing.event_id, created_at: existing.event_created_at], prefix: schema_name)
    {:error, {:duplicate_idempotency_key, original_event}}
  end
```

**Why a `duplicate_idempotency_key` result is an `{:error, _}` at the `Multi.run` level,
not treated as `{:ok, _}`:** returning `{:error, _}` here is what makes `Ecto.Multi`
roll back the whole transaction — including M2's already-executed sequence
increment — so a duplicate call consumes **zero** durable rows anywhere, not just zero
`events` rows (AC3's literal requirement: "does not insert a second events row" — this
design satisfies a strictly stronger property: no row anywhere changes at all on a
duplicate). `append/2`'s own top-level function (§6.3) pattern-matches this specific
`Ecto.Multi.transaction/2` failure shape and converts it into a **successful**
`{:ok, %{is_duplicate: true, ...}}` return — the `{:error, _}` at the `Multi` level and
the `{:ok, _}` at `append/2`'s own boundary are not in tension: one is "did this
database transaction commit," the other is "did the caller's idempotent request
succeed," and they are legitimately different questions with different answers here.

#### 6.2.4 M4 — Insert `events` row (invariant 5/7, ES-01/02/03/05/08)

```
M4(repo, _changes):
  payload_field =
    if payload_bytes <= 4096 do
      decoded_payload                          # inline storage
    else
      %{"$ref" => event_id}                    # pointer form, invariant 7
    end

  attrs_for_insert = %{
    event_id: event_id,                # P6
    created_at: created_at,            # P6
    instance_id: attrs.instance_id,
    event_type: attrs.event_type,
    payload: payload_field,
    actor_id: attrs.actor_id,
    sequence_number: assigned_sequence_number,   # M2
    idempotency_key: attrs.idempotency_key,
    metadata: metadata,                # P3, defaulted to %{}
    tenant_id: tenant_id               # P1 -- derived, never attrs-supplied (§3)
  }

  repo.insert(Event.insert_changeset(%Event{}, attrs_for_insert), prefix: schema_name)
```

`global_seq` is never in `attrs_for_insert` — `Event.insert_changeset/2`'s own
`@cast_fields` doesn't include it (confirmed §0), matching `read_after_writes: true`'s
requirement that the DB assign it.

#### 6.2.5 M5 — Store oversized payload (invariant 7, `event_payload_store`)

**Conditional step — only included in the `Multi` pipeline at all when
`payload_bytes > 4096`.** Must run after M4: the composite FK
`(event_id, event_created_at) → events(event_id, created_at)` (`on_delete: :restrict`,
`req023-event-store-schema.md` §3.4) requires the `events` row to exist first.

```
M5(repo, _changes):
  repo.insert(
    StoredPayload.insert_changeset(%StoredPayload{}, %{
      event_id: event_id,              # P6, same value as M4's events row
      event_created_at: created_at,    # P6, same value as M4's events row
      payload: decoded_payload,        # P5
      byte_size: payload_bytes         # P5 -- the ORIGINAL measured size, INV-EV-7,
                                        # not octet_length of the stored jsonb
    }),
    prefix: schema_name
  )
```

#### 6.2.6 M6 — `instance_projections` update (invariant 6, DB-03)

**This step must both create the row (a brand-new instance's first append, M1 found no
row) and update it (every subsequent append to the same instance) — a genuine
`insert-if-absent-else-update` (UPSERT), not a bare `UPDATE`.** REQ-025's own text says
only "update" (1077–1078), but nothing else in this project's current scope (§1's table:
EE-01/S3 owns only the *engine-driven columns*, not row creation) creates this row
before the first event of a new instance is appended — see §9 OQ-5 for why this design
resolves the gap this way rather than leaving `append/2` unable to record the very first
event of any instance. `InstanceProjection.insert_changeset/2` already exists in
REQ-023's shipped schema specifically to make this possible (confirmed §0).

```
M6(repo, changes):
  repo.insert(
    InstanceProjection.insert_changeset(%InstanceProjection{}, %{
      instance_id: attrs.instance_id,
      tenant_id: tenant_id,                        # P1 -- derived, never attrs-supplied
      status: :active,
      last_event_seq: assigned_sequence_number      # M2
    }),
    on_conflict: [set: [last_event_seq: assigned_sequence_number, updated_at: created_at]],
    conflict_target: :instance_id,
    prefix: schema_name
  )
  # on_conflict's :set list deliberately omits :status and :tenant_id -- an existing
  # row's status/tenant_id must never be overwritten by an ordinary append (status
  # transitions are EE-01/S3's concern; tenant_id never changes for an existing
  # instance).
```

### 6.3 Assembling the top-level result

```
append(attrs, opts):
  with :ok <- check_no_tenant_id(attrs),                                   # P0
       {:ok, tenant_id} <- tenant_id_for_schema_name(opts[:prefix]),       # P1
       :ok <- validate_structure(attrs),                                   # P2
       :ok <- validate_metadata(attrs[:metadata] || %{}),                  # P3
       :ok <- Registry.validate_payload(attrs.event_type, attrs.payload, tenant_id) do  # P4
    # P5/P6 computed here (pure), then the Multi (§6.2) is built and run:
    case Repo.transaction(build_multi(...)) do
      {:ok, %{insert_event: event, assign_sequence: seq}} ->
        {:ok, %{event: event, is_duplicate: false, sequence_number: seq, global_seq: event.global_seq}}

      {:error, :active_instance_guard, {:instance_terminated, status}, _changes} ->
        {:error, {:instance_terminated, status}}

      {:error, :idempotency, {:duplicate_idempotency_key, original_event}, _changes} ->
        {:ok, %{event: original_event, is_duplicate: true,
                sequence_number: original_event.sequence_number,
                global_seq: original_event.global_seq}}

      {:error, _failed_step, %Ecto.Changeset{} = changeset, _changes} ->
        if unique_violation?(changeset, :instance_id) or unique_violation?(changeset, :sequence_number) do
          {:error, {:sequence_conflict, changeset}}
        else
          {:error, changeset}
        end

      {:error, _failed_step, reason, _changes} ->
        {:error, reason}
    end
  else
    {:error, _reason} = error -> error
  end
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

**OQ-5 (MAJOR — a real scope-boundary judgment call, not a minor detail).** REQ-025's
text says M6 "updates" `instance_projections`; REQ-023's own moduledoc (§7.3 there)
says `instance_projections`' *meaningful population* is EE-01/S3 territory and warns
"do not read this migration as instance-engine work landing early." This design reads
that warning as applying to the migration/engine-owned-columns boundary specifically
(`definition_id`, `current_nodes`, etc. — REQ-023's own §3.3 list), **not** as forbidding
`append/2` from creating the bare row (`instance_id`, `tenant_id`, `status: :active`,
`last_event_seq`) that its own writes need to exist. Without this, no instance could
ever receive its first event at all under current scope, since nothing else creates
this row. **REVIEWER should explicitly confirm this reading** rather than this design's
own judgment call standing unchallenged — if REVIEWER disagrees, `append/2` would need
an entirely different contract (e.g. refusing to append to an instance with no
pre-existing projection row), which is a materially different, not incrementally
different, design.

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
| `Letflow.EventStore.{Event, InstanceSequence, InstanceProjection, IdempotencyRecord, StoredPayload}` | `EventStore` → REQ-023's schema modules | Consumes every `insert_changeset/2` (and `InstanceProjection.update_changeset/2` is deliberately **not** used — M6 uses `insert_changeset/2` plus `on_conflict:`, not a separate update path) exactly as shipped; adds no new function to any of the six. |
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
