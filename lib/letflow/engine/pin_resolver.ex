defmodule Letflow.Engine.PinResolver do
  @moduledoc """
  PIN-01..PIN-04 (REQ-059) — dependency pin resolution, recording, and
  inheritance. Ports `src/engine/pin_resolver.zig` (R-Co, 967 lines).

  **Sourcing.** At design and implementation time no read of
  `pin_resolver.zig` was made, and every behavioural claim here traced to
  REQ-059's own requirement text or to already-shipped Letflow code, cited by
  file/line. R-Co has since been read directly (REQ-110 audit, 2026-08-19),
  and that reconstruction did **not** hold on the override path: see the
  OQ-1 resolution below, `docs/issues/ISS-0079.yaml` (GH#298,
  `lib/letflow/design/iss-0079-pin-override-verification.md`) and
  `docs/issues/ISS-0078.yaml` (GH#299). Treat any claim in this moduledoc
  that REQ-110 did not explicitly verify as still unconfirmed against R-Co.
  See `lib/letflow/design/req059-pin-resolver.md`
  (the gate-approved design this module implements) for the full algorithm,
  error taxonomy, and open questions this moduledoc restates the load-bearing
  parts of.

  This module is the mechanism that freezes every versioned dependency an
  instance uses at start time (`resolve/4`), records that frozen set as part
  of the `INSTANCE_STARTED` event payload (`Letflow.Engine.create/2`, not
  this module — see "Persistence" below), and lets replay
  (`Letflow.Engine.Reconstruction`, REQ-053) and child-instance inheritance
  derive the *effective* pin set purely from already-appended events, never
  from a live catalog read.

  ## SCOPE GAP — service_catalog (S6) and PLC-01 (unscoped) are not built

  PIN-01 AC1 (`service_catalog` version resolution) and PIN-01 AC2
  (`module_ref` resolution against PLC-01) are **not satisfiable in Letflow
  today**: this module resolves `catalog_entry` and `module` references only
  against an **injectable** `Lookup` (see `Lookup` below), never a real
  catalog/registry — `src/repository/service_catalog.zig` is **stage S6**
  (operational cross-cutting / repository layer), not yet ported; PLC-01 (the
  process module catalog) is **unscoped to any stage** and does not exist in
  this codebase at all. PIN-03 AC3 (execution proceeds on a pinned version
  after that version is DEPRECATED) is likewise unsatisfiable — there is no
  version/status column on anything in Letflow's catalog-shaped state to
  become DEPRECATED in the first place, the same underlying absence. R-Co
  itself holds PIN-01 and PIN-03 at TESTED rather than RELEASED over this
  identical absence, tracked there as **ISS-0672/GH-306**.

  This module implements the resolution/ordering/recording/inheritance
  MACHINERY against an injectable catalog and module lookup — the same
  pattern `Letflow.Definitions.ServiceScopeValidator` used for its identical
  missing-catalog gap. An unresolvable reference returns a distinct
  `{:unresolved_catalog_ref, ref}` / `{:unresolved_module_ref, ref}` error
  (see `resolve/4`), never a silent no-op or a stub that pretends to
  resolve.

  ## `(node_type, attribute_key)` convention — reused, not invented here

  The two `(node_type, attribute_key)` pairs `resolve/4` walks —
  `("SERVICE_TASK", "service_id")` for `kind: :catalog_entry` and
  `("SUB_PROCESS", "module_ref")` for `kind: :module` — are the same pairing
  `Letflow.Definitions.PromotionPlan.build_entries/6` already uses for its
  own `:service_binding`/`:module_ref` promotion dimensions
  (`lib/letflow/definitions/promotion_plan.ex:234-244`) — this is the only
  other place in the shipped codebase naming which attribute key on which
  node type constitutes a catalog/module reference, and this module reuses
  that pairing verbatim rather than guessing fresh.

  ## Persistence — the event log is the only record (PIN-02 AC3)

  No migration, no `Ecto.Schema`, no DB table is added by this requirement
  anywhere. Every pin fact this module produces is a plain map embedded by
  `Letflow.Engine.create/2` into the `INSTANCE_STARTED` event's payload — see
  that module's `start_instance/5` for the exact call-order this module
  integrates into (pin resolution, then variable validation, then
  inheritance, all *before* `create_snapshot/3`'s first `Repo` write, so a
  failed resolution writes zero rows — PIN-01 AC1/AC4, PIN-02 AC2).

  ## Two different "effective pin set" functions (do not conflate)

  REQ-059's own prose uses "effective pin set" for two distinct
  computations, and this module keeps them as two distinct functions:

    * `merge_effective_pins/3` (plus its caller `reconstruct_effective_pins/2`)
      is the **replay-time** computation — `INSTANCE_STARTED`'s base pin set
      folded with zero or more `INSTANCE_PINS_REBOUND` deltas, pure, no I/O.
    * `apply_inheritance/2` is the **instance-start-time child-inheritance**
      computation — an entirely different job, run once per child instance
      start, not a replay-time fold.

  ## No fallback, ever (PIN-03 AC1/AC5)

  No function anywhere in this module — not `resolve/4`, not
  `merge_effective_pins/3`, not `apply_inheritance/2`, not `pin_for/3` —
  ever queries a catalog/module/variable-schema lookup for a "current" or
  "latest" value as a substitute when a pin is absent. `{:error,
  {:pin_missing, kind, ref}}` (`pin_for/3`) is the only outcome for "no pin
  entry," always.

  ## PIN-03 AC4 — exhausted retry budget, named hook only (no DLQ here)

  R-Co's PIN-03 AC4 routes an exhausted `PinMissing` retry budget to the dead
  letter queue. `OBS-05`'s DLQ is stage S6 (operational cross-cutting), not
  yet ported — REQ-056 flagged this identical gap for its own service-task
  dispatch retries, and this module inherits the same absence rather than
  re-deciding it independently. **No retry loop, no retry budget, and no DLQ
  write of any kind exists in this module** — `pin_for/3` is a single,
  synchronous lookup with no notion of "retry." This module reserves the
  **event type name `PIN_RETRY_EXHAUSTED`** (not emitted by any code in this
  requirement's own scope, and not registered in `Letflow.EventStore.Registry`
  by this requirement) as the documented attachment point a future stage-S6
  DLQ integration hooks onto, once `OBS-05` lands.

  ## Open questions carried from the design doc (not silently resolved)

  See `lib/letflow/design/req059-pin-resolver.md` §9 for the full list
  (OQ-1..OQ-6: what produces `source: :override`; "most recent" vs. "all"
  `INSTANCE_PINS_REBOUND` events; `attrs` vs. `opts` placement; the
  `:parent_instance_id` key name guess against not-yet-built REQ-062;
  `variable_schema_lookup` totality; override vs. inheritance precedence).

  **OQ-1 is RESOLVED as of 2026-08-19** (REQ-110 audit, run
  `WF03-REQ110-20260819`) and no longer open. R-Co's `pin_resolver.zig` was
  read directly and its `source: :override` mechanism **differs materially**
  from the §4.1 design this module implements. R-Co applies overrides as an
  overlay AFTER full resolution and verifies each one against the catalog,
  rejecting any override whose `version` is not the currently-resolvable
  version with `UnresolvedPinOverride` / HTTP 422
  (`pin_resolver.zig:296-299`, `:602-691`, `:189-190`); it rejects
  `kind: module` overrides outright (`:642`) and treats an override naming
  an unreferenced ref as an error rather than a no-op (`:707-723`). This
  module's override mechanism now matches that verify-then-accept shape:
  `resolve_one_ref/4` and `resolve_variable_schema/3` call `lookup` for
  every override before accepting it, and an unverifiable or stray override
  halts resolution with `{:error, {:unresolved_pin_override, ref}}` — see
  `docs/issues/ISS-0079.yaml` (GH#298,
  `lib/letflow/design/iss-0079-pin-override-verification.md`) for the design
  that closed this gap. R-Co additionally sets `source: :override` from a
  SECOND producer this module's design never anticipated: a PIN-05 rebind
  (`pin_resolver.zig:138`, `:156`, tested at `:914`).

  The override-mechanism delta **was repaired** under
  `docs/issues/ISS-0079.yaml` (GH#298,
  `lib/letflow/design/iss-0079-pin-override-verification.md`): every
  override is now verified against `lookup` before acceptance; `kind:
  :module` remains a legal override, verified the same way as
  `catalog_entry` (Letflow's own decision — R-Co's unconditional module
  rejection was a consequence of R-Co having no module catalog at all, not
  a principled rule ported here); a stray override naming a ref outside the
  enumerated pin set is an error, `{:unresolved_pin_override, ref}`; and an
  accepted `variable_schema` override's `resolved_id` is forced to `nil`
  regardless of what the caller supplied, since `variable_schema_lookup`
  has no `resolved_id` of its own to confirm one against. The rebind-
  provenance delta was fixed under `docs/issues/ISS-0078.yaml` (GH#299,
  `lib/letflow/design/iss-0078-pin-rebind-provenance.md`) — `source: :rebound`
  (a distinct value from R-Co's `:override`, not a copy of it), a rebound
  entry's `resolved_id` becomes `nil` (never R-Co's `change.new_version`
  quirk), an unknown-ref rebind entry is appended rather than dropped, and
  `merge_effective_pins/3` (arity 2 → 3) now threads `started_event_id` so
  `source_event_id` is never `nil` for an un-rebound pin — see that design
  doc for the full reasoning "match R-Co exactly" was deliberately not
  assumed to be right for `resolved_id`.

  One further gap surfaced during implementation, not covered by the design
  doc's own OQ list:

    * **OQ-7 (implementation-time finding) — `tenant_id` is not in
      `resolve/4`'s own argument list**, but §4.2 of the design doc requires
      calling `lookup.variable_schema_lookup.(tenant_id, definition.name)`.
      `Letflow.Definitions.ProcessDefinition` carries no `tenant_id` field
      (schema-per-tenant, per `Letflow.Engine`'s own moduledoc "`tenant_id`
      is validated, never persisted"), and `resolve/4`'s specified 4-arg
      shape (`graph`, `definition`, `lookup`, `overrides`) has no other
      source for it either. This implementation passes `nil` as
      `tenant_id` to `variable_schema_lookup` — consistent with
      `default_lookup/0`'s own `variable_schema_lookup` ignoring its
      `tenant_id` argument entirely — and flags this for REVIEWER rather
      than silently inventing a 5th `resolve/4` argument the design's own
      §3 call site (`PinResolver.resolve(graph, definition,
      pin_lookup(attrs, prefix), pin_overrides(attrs))`) does not pass.
  """

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Engine.Reconstruction
  alias Letflow.EventStore.Registry.JsonSchema
  alias Letflow.EventStore.Registry.ValidationFailure

  @typedoc "The dependency category a `pinned_version()`/`effective_pin()` entry names."
  @type kind :: :catalog_entry | :variable_schema | :module

  @typedoc "How a `pinned_version()`/`effective_pin()` entry's version was obtained."
  @type source :: :resolved | :override | :inherited | :rebound

  @typedoc """
  One resolved (or override-substituted, or inherited) dependency pin,
  exactly as embedded into an `INSTANCE_STARTED` (or child) event payload.
  """
  @type pinned_version :: %{
          kind: kind(),
          ref: String.t(),
          resolved_id: String.t() | nil,
          version: String.t(),
          source: source()
        }

  @typedoc "One caller-supplied override entry (§4.1/§4.2 of the design doc)."
  @type override_entry :: %{
          kind: :catalog_entry | :module | :variable_schema,
          ref: String.t(),
          resolved_id: String.t() | nil,
          version: String.t()
        }

  @typedoc """
  One effective pin as derived at replay time (`merge_effective_pins/3`) or
  carried by a parent instance for inheritance purposes
  (`apply_inheritance/2`'s second argument). Distinct from `pinned_version()`
  by the addition of `source_event_id` — a read-side-only field, never
  itself written back into a freshly-built child `pinned_version()` entry.
  """
  @type effective_pin :: %{
          kind: kind(),
          ref: String.t(),
          resolved_id: String.t() | nil,
          version: String.t(),
          source: source(),
          source_event_id: Ecto.UUID.t()
        }

  @typedoc "One PIN-04 AC3 inheritance conflict record."
  @type conflict :: %{
          kind: kind(),
          ref: String.t(),
          child_resolved_version: String.t(),
          inherited_version: String.t()
        }

  @typedoc """
  `{:unresolved_catalog_ref, ref}` and `{:unresolved_module_ref, ref}` are
  the HTTP 422 analogue once an S4 route exists (matching R-Co's own
  `UnresolvedCatalogRef`/`UnresolvedModuleRef`). `{:unresolved_pin_override,
  ref}` (added for GH#298,
  `lib/letflow/design/iss-0079-pin-override-verification.md`) is the same
  HTTP 422 analogue for an override entry that failed verification against
  `lookup`, or that named a `{kind, ref}` outside the enumerated pin set —
  `ref` is always the override's own `ref` field (the value the caller
  supplied), not a pin-set index, so a future 422 response body can echo
  back exactly what the caller named.
  """
  @type resolve_error ::
          {:error, {:unresolved_catalog_ref, ref :: String.t()}}
          | {:error, {:unresolved_module_ref, ref :: String.t()}}
          | {:error, {:unresolved_pin_override, ref :: String.t()}}
          | {:error, {:graph_structure_invalid, term()}}

  defmodule Lookup do
    @moduledoc """
    The injectable dependency `PinResolver.resolve/4` calls instead of a
    concrete catalog/module registry — mirrors
    `Letflow.Definitions.ServiceScopeValidator.Lookup`'s shape exactly,
    three fields instead of two. Plain struct, not `Ecto.Schema`.
    """

    @enforce_keys [:catalog_lookup, :module_lookup, :variable_schema_lookup]
    defstruct [:catalog_lookup, :module_lookup, :variable_schema_lookup]

    @type catalog_lookup_result ::
            {:ok, %{resolved_id: String.t(), version: String.t()}} | {:error, :not_found}
    @type module_lookup_result ::
            {:ok, %{resolved_id: String.t(), version: String.t()}} | {:error, :not_found}
    @type variable_schema_lookup_result ::
            {:ok, %{version: String.t(), json_schema: map() | nil}}

    @type t :: %__MODULE__{
            catalog_lookup: (service_id :: String.t() -> catalog_lookup_result()),
            module_lookup: (module_ref :: String.t() -> module_lookup_result()),
            variable_schema_lookup: (tenant_id :: Ecto.UUID.t() | nil,
                                     process_key :: String.t() ->
                                       variable_schema_lookup_result())
          }
  end

  @doc """
  The inert default `Lookup` a caller supplying none falls back to (design
  doc §4). `catalog_lookup`/`module_lookup` always fail (no default,
  production-ready catalog exists — see the moduledoc's SCOPE GAP);
  `variable_schema_lookup` is the one field that is total by design (§4.2),
  returning an unversioned, unconstrained result rather than an
  `{:error, _}` this type has no case for.

  Any definition with zero `SERVICE_TASK`/`SUB_PROCESS` node references
  continues starting exactly as before this requirement under this default;
  a definition that does reference a `service_id`/`module_ref` fails
  resolution unless the caller supplies a real `Lookup`.
  """
  @spec default_lookup() :: Lookup.t()
  def default_lookup do
    %Lookup{
      catalog_lookup: fn _service_id -> {:error, :not_found} end,
      module_lookup: fn _module_ref -> {:error, :not_found} end,
      variable_schema_lookup: fn _tenant_id, _process_key ->
        {:ok, %{version: "unversioned", json_schema: nil}}
      end
    }
  end

  @doc """
  PIN-01 — enumerates every versioned reference in `graph`/`definition`
  (`("SERVICE_TASK", "service_id")` → `:catalog_entry`, `("SUB_PROCESS",
  "module_ref")` → `:module`, plus exactly one `:variable_schema` entry,
  unconditionally) and resolves each to a `pinned_version()`. An `overrides`
  entry matching an enumerated `{kind, ref}` is **verified against `lookup`
  before being accepted** (GH#298,
  `lib/letflow/design/iss-0079-pin-override-verification.md`, superseding
  this module's earlier verbatim-acceptance behaviour) — an enumerated pin
  with no matching override resolves via `lookup` as before. Returns the
  deterministically-sorted (PIN-01 AC5, `{kind, ref}` ascending — Letflow's
  own deliberately-chosen canonical order, `catalog_entry < module <
  variable_schema`, diverging from R-Co's `PinKind` ordinal order by
  design) list alongside the resolved variable JSON Schema (kept separate
  from `pinned_version()` itself — see the design doc's INV-PIN-5 — so
  `validate_initial_variables/2` can use it without re-deriving it from
  `pins`).

  Halts and returns the first `{:unresolved_catalog_ref, ref}` /
  `{:unresolved_module_ref, ref}` encountered while resolving a
  no-override pin — never a partial list (design doc §4.1). Also halts with
  `{:error, {:unresolved_pin_override, ref}}` for the first `overrides`
  entry that either fails verification against `lookup` or names a `{kind,
  ref}` outside the enumerated pin set entirely.
  """
  @spec resolve(
          graph :: Graph.t(),
          definition :: ProcessDefinition.t(),
          lookup :: Lookup.t(),
          overrides :: [override_entry()]
        ) :: {:ok, [pinned_version()], variable_json_schema :: map() | nil} | resolve_error()
  def resolve(%Graph{} = graph, %ProcessDefinition{} = definition, %Lookup{} = lookup, overrides)
      when is_list(overrides) do
    catalog_refs = collect_refs(graph, "SERVICE_TASK", "service_id")
    module_refs = collect_refs(graph, "SUB_PROCESS", "module_ref")

    with {:ok, catalog_pins} <-
           resolve_refs(catalog_refs, :catalog_entry, lookup.catalog_lookup, overrides),
         {:ok, module_pins} <-
           resolve_refs(module_refs, :module, lookup.module_lookup, overrides),
         {:ok, {variable_schema_pin, json_schema}} <-
           resolve_variable_schema(definition, lookup.variable_schema_lookup, overrides),
         :ok <- check_stray_overrides(overrides, catalog_refs, module_refs, definition.name) do
      pins =
        (catalog_pins ++ module_pins ++ [variable_schema_pin])
        |> sort_pins()

      {:ok, pins, json_schema}
    end
  end

  # Decision 4 -- after every enumerated pin has been processed (steps 1-2
  # of the design's combined control-flow spec), reject the first overrides
  # entry (in `overrides`' own list order) whose {kind, ref} matched no
  # enumerated pin at all. Only reached if resolve_refs/4 and
  # resolve_variable_schema/3 above did not already halt.
  defp check_stray_overrides(overrides, catalog_refs, module_refs, variable_schema_ref) do
    enumerated =
      MapSet.new(
        Enum.map(catalog_refs, &{:catalog_entry, &1}) ++
          Enum.map(module_refs, &{:module, &1}) ++
          [{:variable_schema, variable_schema_ref}]
      )

    overrides
    |> Enum.find(fn override -> not MapSet.member?(enumerated, {override.kind, override.ref}) end)
    |> case do
      nil -> :ok
      %{ref: ref} -> {:error, {:unresolved_pin_override, ref}}
    end
  end

  # §4.1 -- walk nodes in original list order, keep only non-empty string
  # attribute values, dedupe by ref (first occurrence kept for lookup-order
  # purposes only; final order is sort_pins/1's job). The Enum.uniq() here
  # is a deliberate deviation from R-Co (which emits one pin entry per graph
  # node, byte-identical duplicates included) -- GH#298's design doc,
  # disposition (a), confirms this is a strict improvement with no
  # acceptance criterion depending on R-Co's entry count.
  defp collect_refs(%Graph{nodes: nodes}, node_type_string, attribute_key) do
    node_type = String.to_existing_atom(node_type_string)

    nodes
    |> Enum.filter(&(&1.node_type == node_type))
    |> Enum.map(&ref_id(&1.attributes, attribute_key))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp ref_id(attributes, key) when is_map(attributes) do
    case Map.get(attributes, key) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _other -> nil
    end
  end

  defp ref_id(_attributes, _key), do: nil

  defp resolve_refs(refs, kind, lookup_fun, overrides) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
      case resolve_one_ref(ref, kind, lookup_fun, overrides) do
        {:ok, pin} -> {:cont, {:ok, [pin | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pins} -> {:ok, Enum.reverse(pins)}
      {:error, _reason} = error -> error
    end
  end

  # Decision 1/3 -- an override is an overlay applied only after a fresh
  # lookup.(ref) confirms it: accepted only if the lookup succeeds and its
  # `version` matches the override's own `version`. On accept, resolved_id
  # comes from the *lookup result*, never the caller-supplied value
  # (Decision 1's "resolved_id/version come from the fresh lookup" bullet).
  # Any other outcome (not found, or a version mismatch) is
  # {:unresolved_pin_override, ref} -- uniform across :catalog_entry and
  # :module (Decision 3: no categorical kind: :module ban).
  defp resolve_one_ref(ref, kind, lookup_fun, overrides) do
    case find_override(overrides, kind, ref) do
      %{version: version} ->
        case lookup_fun.(ref) do
          {:ok, %{resolved_id: resolved_id, version: ^version}} ->
            {:ok,
             %{
               kind: kind,
               ref: ref,
               resolved_id: resolved_id,
               version: version,
               source: :override
             }}

          _other ->
            {:error, {:unresolved_pin_override, ref}}
        end

      nil ->
        ref
        |> lookup_fun.()
        |> interpret_lookup(kind, ref)
    end
  end

  defp find_override(overrides, kind, ref) do
    Enum.find(overrides, fn override ->
      override.kind == kind and override.ref == ref
    end)
  end

  defp interpret_lookup({:ok, %{resolved_id: resolved_id, version: version}}, kind, ref) do
    {:ok, %{kind: kind, ref: ref, resolved_id: resolved_id, version: version, source: :resolved}}
  end

  defp interpret_lookup({:error, :not_found}, :catalog_entry, ref) do
    {:error, {:unresolved_catalog_ref, ref}}
  end

  defp interpret_lookup({:error, :not_found}, :module, ref) do
    {:error, {:unresolved_module_ref, ref}}
  end

  # §4.2 -- unconditionally exactly one :variable_schema entry.
  #
  # OQ-7 (moduledoc): resolve/4 has no tenant_id in scope, so nil is passed
  # here -- default_lookup/0's own variable_schema_lookup ignores its
  # tenant_id argument entirely, consistent with this. Flagged for REVIEWER.
  #
  # Decision 1/4 (sub-decision) -- an override is verified against a fresh
  # lookup.(nil, process_key) call before being accepted: only `version` is
  # checked (variable_schema_lookup_result carries no resolved_id at all),
  # and the accepted pin's resolved_id is forced to nil unconditionally --
  # never the caller-supplied value -- since there is no lookup-confirmed
  # value to substitute it with. A version mismatch or lookup failure is
  # {:unresolved_pin_override, ref}.
  defp resolve_variable_schema(%ProcessDefinition{name: process_key}, lookup_fun, overrides) do
    case find_override(overrides, :variable_schema, process_key) do
      %{version: version} ->
        case lookup_fun.(nil, process_key) do
          {:ok, %{version: ^version}} ->
            pin = %{
              kind: :variable_schema,
              ref: process_key,
              resolved_id: nil,
              version: version,
              source: :override
            }

            {:ok, {pin, nil}}

          _other ->
            {:error, {:unresolved_pin_override, process_key}}
        end

      nil ->
        {:ok, %{version: version, json_schema: json_schema}} = lookup_fun.(nil, process_key)

        pin = %{
          kind: :variable_schema,
          ref: process_key,
          resolved_id: nil,
          version: version,
          source: :resolved
        }

        {:ok, {pin, json_schema}}
    end
  end

  # §4.3 -- deterministic, load-bearing ordering: {Atom.to_string(kind), ref}
  # ascending ("catalog_entry" < "module" < "variable_schema"). This is
  # Letflow's own deliberately-chosen canonical order (GH#298,
  # `lib/letflow/design/iss-0079-pin-override-verification.md`, disposition
  # b) -- it diverges from R-Co's PinKind enum ordinal order by design, not
  # by accident, and must not be "corrected" toward R-Co's order later.
  defp sort_pins(pins) do
    Enum.sort_by(pins, fn %{kind: kind, ref: ref} -> {Atom.to_string(kind), ref} end)
  end

  @doc """
  PIN-01 AC3 — validates `initial_variables` against the single
  `variable_schema` pin's JSON Schema (`resolve/4`'s third return value),
  reusing `Letflow.EventStore.Registry.JsonSchema.validate/2` directly
  (REQ-024) rather than a second implementation. `variable_json_schema ==
  nil` (no schema registered — the `default_lookup/0` case) is `:ok`
  unconditionally, no constraint.
  """
  @spec validate_initial_variables(
          initial_variables :: map(),
          variable_json_schema :: map() | nil
        ) ::
          :ok
          | {:error, {:variable_schema_violation, [ValidationFailure.t()]}}
  def validate_initial_variables(initial_variables, nil) when is_map(initial_variables) do
    :ok
  end

  def validate_initial_variables(initial_variables, variable_json_schema)
      when is_map(initial_variables) and is_map(variable_json_schema) do
    case JsonSchema.validate(initial_variables, variable_json_schema) do
      [] -> :ok
      failures -> {:error, {:variable_schema_violation, failures}}
    end
  end

  @doc """
  PIN-04 AC1/AC5/AC7 — the **replay-time** effective pin set: seeds one
  `effective_pin()` per `instance_started_pinned_versions` entry
  (`source_event_id` from the caller-supplied `INSTANCE_STARTED` event id —
  see `reconstruct_effective_pins/2`), then folds every
  `INSTANCE_PINS_REBOUND` event in `pins_rebound_events` (caller's
  responsibility to pass pre-sorted by ascending `sequence_number` — this
  function trusts input order, matching `Reconstruction.fold_events/3`'s own
  discipline), applying each changed `{ref, new_version}` entry the rebind
  event's payload carries. Pure — zero I/O.

  Folds **all** `INSTANCE_PINS_REBOUND` events found, not just the most
  recent one (design doc §6, flagged OQ-2: REQ-060's own delta-only payload
  shape means folding only the single most-recent event would silently lose
  earlier rebinds of other refs).

  A rebound entry's `resolved_id` becomes `nil` (never `change.new_version`,
  never left at its pre-rebind value) and its `source` becomes `:rebound` —
  `PinRebind`'s payload never re-verifies a rebind against a catalog, so
  `nil` is the only `resolved_id` that doesn't assert a false identity; see
  `lib/letflow/design/iss-0078-pin-rebind-provenance.md` Decisions 1-2. An
  entry naming a `{kind, ref}` absent from the base set is **appended**, not
  dropped (Decision 3) — defensive-only, since PIN-05's own `UnknownPinRef`
  gate prevents this in normal operation.
  """
  @spec merge_effective_pins(
          instance_started_pinned_versions :: [pinned_version()],
          pins_rebound_events :: [%{event_id: Ecto.UUID.t(), payload: map()}],
          started_event_id :: Ecto.UUID.t()
        ) :: [effective_pin()]
  def merge_effective_pins(
        instance_started_pinned_versions,
        pins_rebound_events,
        started_event_id
      )
      when is_list(instance_started_pinned_versions) and is_list(pins_rebound_events) do
    base =
      Enum.map(instance_started_pinned_versions, fn pin ->
        %{
          kind: normalize_kind(pin[:kind] || pin["kind"]),
          ref: pin[:ref] || pin["ref"],
          resolved_id: pin[:resolved_id] || pin["resolved_id"],
          version: pin[:version] || pin["version"],
          source: normalize_source(pin[:source] || pin["source"]),
          source_event_id: started_event_id
        }
      end)

    Enum.reduce(pins_rebound_events, base, &apply_rebind_event/2)
  end

  defp apply_rebind_event(%{event_id: event_id, payload: payload}, effective_pins) do
    entries = payload["entries"] || payload[:entries] || []

    Enum.reduce(entries, effective_pins, fn entry, acc ->
      kind = normalize_kind(entry["kind"] || entry[:kind])
      ref = entry["ref"] || entry[:ref]
      new_version = entry["new_version"] || entry[:new_version]

      if Enum.any?(acc, &(&1.kind == kind and &1.ref == ref)) do
        Enum.map(acc, fn pin ->
          if pin.kind == kind and pin.ref == ref do
            %{
              pin
              | version: new_version,
                resolved_id: nil,
                source: :rebound,
                source_event_id: event_id
            }
          else
            pin
          end
        end)
      else
        acc ++
          [
            %{
              kind: kind,
              ref: ref,
              resolved_id: nil,
              version: new_version,
              source: :rebound,
              source_event_id: event_id
            }
          ]
      end
    end)
  end

  defp normalize_kind(kind) when is_atom(kind), do: kind
  defp normalize_kind("catalog_entry"), do: :catalog_entry
  defp normalize_kind("module"), do: :module
  defp normalize_kind("variable_schema"), do: :variable_schema

  defp normalize_source(source) when is_atom(source), do: source
  defp normalize_source("resolved"), do: :resolved
  defp normalize_source("override"), do: :override
  defp normalize_source("inherited"), do: :inherited
  defp normalize_source("rebound"), do: :rebound

  @doc """
  PIN-04 AC1/AC7 — obtains an instance's effective pin set purely from its
  own event stream: calls `Reconstruction.read_full_log/3` (widened to
  public/`@doc false` by this requirement, following the exact precedent
  `Engine.advance_until_stable/4` etc. already set — no new
  events/`events_archive` query is written here) with `min_sequence_number:
  1` **always** (pins are never captured in an `instance_state_snapshots`
  row, so a pin read must always walk the full log, regardless of what
  REQ-054's snapshot-aware replay would use for *state* replay), filters for
  `INSTANCE_STARTED`/`INSTANCE_PINS_REBOUND`, and folds via
  `merge_effective_pins/3`.

  AC7 ("issues zero reads against any catalog or module registry") is
  satisfied by construction: this function accepts no `Lookup.t()` parameter
  at all — there is no capability to call a catalog/module lookup anywhere
  in this call path.

  `{:ok, []}` (instance genuinely has no events) is mapped to
  `{:error, :instance_not_found}`, matching `Reconstruction`'s own existence
  convention.
  """
  @spec reconstruct_effective_pins(instance_id :: Ecto.UUID.t(), opts :: [prefix: String.t()]) ::
          {:ok, [effective_pin()]} | {:error, :instance_not_found} | {:error, term()}
  def reconstruct_effective_pins(instance_id, opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    case Reconstruction.read_full_log(instance_id, prefix, 1) do
      {:ok, []} ->
        {:error, :instance_not_found}

      {:ok, events} ->
        case Enum.find(events, &(&1.event_type == "INSTANCE_STARTED")) do
          nil ->
            {:error, :instance_not_found}

          started_event ->
            instance_started_pinned_versions = extract_pinned_versions(started_event)

            pins_rebound_events =
              events
              |> Enum.filter(&(&1.event_type == "INSTANCE_PINS_REBOUND"))
              |> Enum.map(&%{event_id: &1.event_id, payload: &1.payload})

            {:ok,
             merge_effective_pins(
               instance_started_pinned_versions,
               pins_rebound_events,
               started_event.event_id
             )}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp extract_pinned_versions(%{payload: payload}) do
    payload["pinned_versions"] || payload[:pinned_versions] || []
  end

  @doc """
  PIN-04 AC2/AC3 — child instance pin inheritance, run once at instance
  start (distinct from `merge_effective_pins/3` — see moduledoc).

  `parent_pins == nil` (root instance, no parent): `own_pins` returned
  unchanged, `{:ok, own_pins, []}`.

  `parent_pins` given: every `{kind, ref}` in `parent_pins` absent from
  `own_pins` is added with `source: :inherited` (parent's `resolved_id`/
  `version`, no `source_event_id` — this builds a fresh child
  `pinned_version()`, not a read-side `effective_pin()`). Every `{kind,
  ref}` present in both, with matching versions, is kept as-is (agreement is
  not inheritance). Every `{kind, ref}` present in both with **differing**
  versions: the **inherited** version wins — `own_pins`' entry is replaced,
  `source: :inherited` — and a `conflict()` is recorded (PIN-04 AC3,
  inheritance wins even over a caller-supplied `:override`, per the design
  doc's OQ-6 literal reading of "inheritance wins" with no stated
  exception). Result is re-sorted per `resolve/4`'s own ordering.
  """
  @spec apply_inheritance(own_pins :: [pinned_version()], parent_pins :: [effective_pin()] | nil) ::
          {:ok, [pinned_version()], [conflict()]}
  def apply_inheritance(own_pins, nil) when is_list(own_pins) do
    {:ok, own_pins, []}
  end

  def apply_inheritance(own_pins, parent_pins)
      when is_list(own_pins) and is_list(parent_pins) do
    own_by_key = Map.new(own_pins, &{{&1.kind, &1.ref}, &1})

    {merged_own, conflicts} =
      Enum.reduce(own_pins, {[], []}, fn own_pin, {acc, conflicts_acc} ->
        case find_parent_pin(parent_pins, own_pin.kind, own_pin.ref) do
          nil ->
            {[own_pin | acc], conflicts_acc}

          parent_pin when parent_pin.version == own_pin.version ->
            {[own_pin | acc], conflicts_acc}

          parent_pin ->
            inherited_pin = %{
              kind: own_pin.kind,
              ref: own_pin.ref,
              resolved_id: parent_pin.resolved_id,
              version: parent_pin.version,
              source: :inherited
            }

            conflict = %{
              kind: own_pin.kind,
              ref: own_pin.ref,
              child_resolved_version: own_pin.version,
              inherited_version: parent_pin.version
            }

            {[inherited_pin | acc], [conflict | conflicts_acc]}
        end
      end)

    inherited_additions =
      parent_pins
      |> Enum.reject(fn parent_pin ->
        Map.has_key?(own_by_key, {parent_pin.kind, parent_pin.ref})
      end)
      |> Enum.map(fn parent_pin ->
        %{
          kind: parent_pin.kind,
          ref: parent_pin.ref,
          resolved_id: parent_pin.resolved_id,
          version: parent_pin.version,
          source: :inherited
        }
      end)

    merged = sort_pins(Enum.reverse(merged_own) ++ inherited_additions)

    {:ok, merged, Enum.reverse(conflicts)}
  end

  defp find_parent_pin(parent_pins, kind, ref) do
    Enum.find(parent_pins, &(&1.kind == kind and &1.ref == ref))
  end

  @doc """
  PIN-03 AC1/AC5 — no-fallback runtime accessor over an already-obtained
  pin/effective-pin set. Not called anywhere in this requirement's own
  integration — the accessor a future caller (e.g. REQ-056's service-task
  dispatch) uses so it never has occasion to invent its own "fall back to
  the catalog's current version" logic. Plain find by `{kind, ref}`; absent
  → `{:error, {:pin_missing, kind, ref}}`, always — never a substitute
  value.
  """
  @spec pin_for(pins :: [pinned_version()] | [effective_pin()], kind :: kind(), ref :: String.t()) ::
          {:ok, pinned_version() | effective_pin()} | {:error, {:pin_missing, kind(), String.t()}}
  def pin_for(pins, kind, ref) when is_list(pins) do
    case Enum.find(pins, &(&1.kind == kind and &1.ref == ref)) do
      nil -> {:error, {:pin_missing, kind, ref}}
      pin -> {:ok, pin}
    end
  end
end
