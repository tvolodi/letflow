# REQ-219 — Layer `Letflow.Application`'s flat 20-child supervision tree

Design for closing ISS-0425 parts 1 and partial-2 (layering + restart-intensity
isolation). Ports no R-Co source. No implementation code below — module
shapes, exact children lists, `@spec`/`@type`-level signatures, and prose
only. The requirement's own text (`docs/requirements.yaml` REQ-219
description) already settled the four decisions this design would
otherwise have had to make (top-level shape, layer membership, per-layer
restart intensity, ordering-constraint preservation) — this design does not
re-open any of them; it turns them into exact file/module contents.

## 0. Inputs read in full before this design

* `lib/letflow/application.ex` (current state, read in full, lines 1–228,
  2026-09-03) — the exact 20-child flat list inside `start/2`
  (lines 26–134), `scheduler_children/0` (173–179),
  `service_task_dispatcher_children/0` (198–204), `http_child/0`
  (206–212), `plugin_registrations_from_config/0` (219–221),
  `skip_migrations?/0` (227). Every child spec shape below is copied
  verbatim from this file, not reconstructed from memory.
* `docs/requirements.yaml` REQ-219 entry — full `description` (4 numbered
  decisions + "not in this requirement" list) and all 10
  `acceptance_criteria`.
* `docs/issues/ISS-0425.yaml` — originating issue framing; confirms
  `:rest_for_one`-at-the-top was only ever a "candidate shape," not a
  commitment, and that REQ-219 deliberately diverges from it.
* `lib/letflow/instance_supervisor.ex` — this codebase's established
  `use DynamicSupervisor` / named-`start_link/1` convention (`start_link(
  init_arg) do DynamicSupervisor.start_link(__MODULE__, init_arg, name:
  __MODULE__) end`, `init/1` calling `DynamicSupervisor.init/1`). The three
  new modules mirror this shape with `use Supervisor` /
  `Supervisor.start_link/3` / `Supervisor.init/2` instead.
* `lib/letflow/scheduler/poller.ex` (moduledoc + `init/1`, lines 1–60+) —
  confirms the zero-delay first-`:tick` mechanism (`Process.send_after(
  self(), :tick, 0)`) that produces the documented crash-loop hazard AC4
  must reproduce, and that config (`Application.get_env/3`) is read fresh
  on every tick/init, which is what makes a `Supervisor.restart_child/2`
  re-read an env override without any code change.
* No `lib/letflow/supervisor/` directory exists yet — the three new
  files are new, not edits to existing ones.

## 1. Three new modules

All three live at `lib/letflow/supervisor/<name>.ex`, matching the
requirement's own stated path (`lib/letflow/supervisor/`) and this
codebase's convention of a directory named after the parent module
(`Letflow.Supervisor.*`) holding one file per submodule, mirroring
`lib/letflow/scheduler/poller.ex` under `Letflow.Scheduler.Poller`.

Each module: `use Supervisor`; a public `start_link/1` taking one
argument (`init_arg`, ignored by all three today — mirrors
`Letflow.InstanceSupervisor`'s own signature exactly) and calling
`Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)`, i.e.
each is registered under its own module name — this is load-bearing for
§4 and §5's test mechanisms below, which restart a specific layer by
name via `Supervisor.terminate_child/2` + `Supervisor.restart_child/2`
against the top-level `Letflow.Supervisor`, and also need
`Process.whereis/1` on the layer supervisor's own name to observe the
restart. A private `@impl true def init/1` building that module's
children list (below) and returning `Supervisor.init(children, opts)`.

### 1.1 `Letflow.Supervisor.Infrastructure` (`lib/letflow/supervisor/infrastructure.ex`)

`init/1` opts: `strategy: :one_for_one` — OTP default restart intensity,
no override (matches decision 3: "no documented incident motivates
changing" this layer's intensity; a crash-looping infra child, e.g.
`Letflow.Repo` itself, should still take the whole app down).

Children, in this **exact** order (copied verbatim from
`application.ex` lines 28–133, only the two `Task.Supervisor`
child-spec identifiers renamed to descriptive layer-internal names for
readability in this design's own prose — the actual child-spec tuples
below MUST be copied byte-for-byte from the current file, not
retyped):

1. `Letflow.Repo`
2. `{Ecto.Migrator, repos: Application.fetch_env!(:letflow, :ecto_repos), skip: skip_migrations?()}`
3. `{Oidcc.ProviderConfiguration.Worker, %{...}}` (the full map literal at
   lines 32–48, unchanged, including the `oidc_config` binding computed
   at the top of `start/2` before the children list — see §2)
4. `{Registry, keys: :unique, name: Letflow.Registry}`
5. `Letflow.Metrics.Registry`
6. `{Letflow.Admission, []}`
7. `Letflow.InstanceSupervisor`
8. `{Task.Supervisor, name: Letflow.SandboxPool.TaskSupervisor}`
9. `{Letflow.SandboxPool, []}`
10. `{Task.Supervisor, name: Letflow.Engine.PluginTaskSupervisor}`
11. `{Letflow.Engine.PluginRegistry, plugin_registrations_from_config()}`
12. `{Task.Supervisor, name: Letflow.Engine.Lua.TaskSupervisor}`
13. `{Task.Supervisor, name: Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor}`
14. `{Task.Supervisor, name: Letflow.Engine.Wasm.CapabilityGateTaskSupervisor}`
15. `{Letflow.Engine.Wasm.ModuleVersionRegistry, name: Letflow.Engine.Wasm.ModuleVersionRegistry}`
16. `{Task.Supervisor, name: Letflow.Engine.Wasm.ModuleVersionRegistryTaskSupervisor}`
17. `{Task.Supervisor, name: Letflow.Obs.Alerts.TaskSupervisor}`

= 17 children, matching AC3's own enumeration (Repo + Migrator + Oidcc
worker + Registry + Metrics.Registry + Admission + InstanceSupervisor +
7 Task.Supervisors + SandboxPool + PluginRegistry +
Wasm.ModuleVersionRegistry = 17).

**Ordering constraints preserved, both now load-bearing at this
module's own `init/1` level (unchanged from today's comments, which
MUST move here verbatim, attached to the same child-spec lines):**

* ISS-0224: item 8 (`SandboxPool.TaskSupervisor`) precedes item 9
  (`{Letflow.SandboxPool, []}`) — unchanged relative order, same
  adjacency as today.
* ISS-0429: item 17 (`Obs.Alerts.TaskSupervisor`) is the LAST child of
  this module, same as today (last item in the flat list's
  infrastructure-ish portion before `scheduler_children()` was
  appended). Its "must precede either Poller's first tick" guarantee
  becomes structural per decision 4(b): `Letflow.Supervisor.Pollers` is
  a **separate supervisor**, started only after `Letflow.
  Supervisor.Infrastructure`'s own `Supervisor.start_link/3` call
  (invoked from `Letflow.Application.start/2`, §2) has returned
  `{:ok, pid}` — which happens only once every one of Infrastructure's
  17 children, including this one, has itself finished starting
  (`Supervisor`'s own sequential-startup guarantee, applied here at the
  top level between sibling supervisors exactly as it already applies
  within one flat list). This is strictly stronger than "list position
  17 out of 20 in one shared list," because no interleaving is possible
  between Infrastructure's last child starting and Pollers' first child
  starting — an entire supervisor boundary sits between them.
  `oidc_config` binding: computed once, before the children list, in
  `Letflow.Application.start/2` today (line 24) — moves to
  `Letflow.Supervisor.Infrastructure.init/1` verbatim (it is used only
  by that module's own Oidcc child spec).

Moduledoc must state (AC8/§7 below): the full list of 17 children in
order; the ISS-0224 and ISS-0429 ordering guarantees verbatim as above;
that `:one_for_one`/OTP-default intensity is unchanged and why (no
incident motivates a change; a crash-looping infra child indicates a
fault severe enough that taking the app down is still correct).

### 1.2 `Letflow.Supervisor.Pollers` (`lib/letflow/supervisor/pollers.ex`)

`init/1` opts: `strategy: :one_for_one, max_restarts: 5, max_seconds: 60`
— see §3 for the full rationale this moduledoc must record verbatim.

Children — exactly the two gated pollers, same gate keys, same
`Application.get_env/3` calls, copied verbatim from
`scheduler_children/0` and `service_task_dispatcher_children/0`:

1. `{Letflow.Scheduler.Poller, []}`, present iff
   `Application.get_env(:letflow, :start_scheduler, true)` is true.
2. `{Letflow.Engine.ServiceTaskDispatcher.Poller, []}`, present iff
   `Application.get_env(:letflow, :start_service_task_dispatcher, true)`
   is true.

`init/1`'s own body builds this two-element list the same way
`scheduler_children/0`/`service_task_dispatcher_children/0` build theirs
today (an `if` per gate, `[]` or a one-element list, concatenated) —
those two private functions relocate into this module unchanged in
logic, only their call site moves from `Letflow.Application.start/2` to
`Letflow.Supervisor.Pollers.init/1`. With both gates false
(`config/test.exs`'s current setting), the children list passed to
`Supervisor.init/2` is `[]` — see §6.

Moduledoc must state (AC8/AC9 below): both gate keys and their
individual independence (REQ-214's own "independent poll cadences,
independent boot gates" framing); the `max_restarts: 5, max_seconds: 60`
override and its rationale verbatim (§3); that this module's
`:one_for_one` intensity is DELIBERATELY looser than the OTP default and
DELIBERATELY isolated from `Letflow.Supervisor.Infrastructure` and
`Letflow.Supervisor.Http` — a sustained crash-loop in either poller
exceeding this budget exits and restarts only this supervisor, never
`Letflow.Repo` or Bandit (the documented incident this requirement
closes, cross-referenced to ISS-0425/ISS-0421/the `scheduler_children/0`
historical comment, which itself relocates here as historical context,
marked superseded-by-structure rather than deleted).

### 1.3 `Letflow.Supervisor.Http` (`lib/letflow/supervisor/http.ex`)

`init/1` opts: `strategy: :one_for_one` — OTP default, unchanged (matches
decision 3, same as Infrastructure).

Children — exactly `http_child/0`'s current body, relocated unchanged:
`{Bandit, plug: Letflow.Router, port: Application.fetch_env!(:letflow,
:http_port)}`, present iff `Application.get_env(:letflow, :start_http,
true)` is true; `[]` otherwise (ISS-0015's own precedent, unchanged).

Moduledoc must state: the `:start_http` gate and ISS-0015's port-
collision rationale for gating it off under test (both already exist as
a comment on today's `http_child/0`, relocate verbatim); that
`:one_for_one`/OTP-default intensity is unchanged and isolated from both
other layers.

## 2. `Letflow.Application.start/2`'s new shape

The `:logger.add_primary_filter/2` call (REQ-190, lines 10–22) stays in
`Letflow.Application.start/2` unchanged — it is not a supervised child
and this requirement does not touch it or its "registered before every
other child" ordering guarantee, which is unaffected by anything below
(it still runs before any of the three new `Supervisor.start_link/3`
calls, exactly as it ran before any of the original 20 children's
`start_link`s).

`start/2`'s new body, after the logger-filter call: a 3-element children
list, `[Letflow.Supervisor.Infrastructure, Letflow.Supervisor.Pollers,
Letflow.Supervisor.Http]`, in that exact order (Infrastructure listed
first is the one fact AC2 depends on — see §1.1's ordering-constraint
paragraph and §4 below), passed to `Supervisor.start_link(children,
strategy: :one_for_one, name: Letflow.Supervisor)` — same top-level
name (`Letflow.Supervisor`) and same call shape
(`Supervisor.start_link/2` with a `strategy`/`name` keyword list) as
today, only the `children` list itself shrinks from 20 flat entries to
these 3 bare module names. No `max_restarts`/`max_seconds` override at
this level (OTP default, 3 restarts/5 seconds) — decision 3 does not
ask for one here, and AC4's own text ("restarted by the top-level
Letflow.Supervisor," singular restart event) is satisfied by the
default budget.

`oidc_config`'s binding (`Application.fetch_env!(:letflow, :oidc)`, line
24) is the only other top-level-`start/2` content that relocates — see
§1.1, it moves into `Letflow.Supervisor.Infrastructure.init/1`, since it
is used only by that module's Oidcc child spec and nothing in
`Letflow.Application.start/2` needs it once the children list is just 3
module names. `plugin_registrations_from_config/0` and
`skip_migrations?/0` (currently private helpers of `Letflow.Application`)
relocate to `Letflow.Supervisor.Infrastructure` as its own private
helpers (each is used only by one of that module's own child specs, the
Oidcc/PluginRegistry/Migrator entries). `scheduler_children/0` and
`service_task_dispatcher_children/0` relocate to `Letflow.
Supervisor.Pollers` as described in §1.2. `http_child/0` relocates to
`Letflow.Supervisor.Http` as described in §1.3. `Letflow.Application`
itself, after this change, has no private helper functions left besides
`start/2` — its own body is: the logger-filter call, then the 3-child
`Supervisor.start_link/2` call, nothing else.

## 3. Restart-intensity override for `Letflow.Supervisor.Pollers`

Exact `init/1` opts, per decision 3: `strategy: :one_for_one,
max_restarts: 5, max_seconds: 60`. Rationale, which the module's own
moduledoc must record VERBATIM (AC8's own text names this exact
requirement): looser than the OTP default (3 restarts/5 seconds) to
tolerate a handful of transient per-tick failures — "a single bad HTTP
dispatch, a single locked row" (decision 3's own phrasing) — without the
supervisor itself exiting, while still bounding a genuine, sustained
crash-loop (the documented `DBConnection.OwnershipError`-under-sandbox
incident `scheduler_children/0`'s own comment and ISS-0421 describe) to
a bounded number of restart attempts before this supervisor (only) exits
and is restarted once by the top-level `Letflow.Supervisor`. Whichever
of the two pollers is looping, the OTHER poller (if also configured to
run) is also torn down and restarted when `Letflow.Supervisor.Pollers`
itself exits and restarts — this is `:one_for_one`'s own sibling-
isolation property applying one level down: within `Pollers`, the two
pollers are peers of each other, so a full-supervisor-level exit (only
reached once the crash-looping one's OWN individual restart budget
inside this shared 5/60 budget is exhausted) restarts both children
together, since restarting the whole supervisor process necessarily
restarts everything under it. This is an accepted, documented
consequence of decision 1's `:one_for_one`-at-two-levels shape, not a
gap — the AC4 test in §5 only asserts `Letflow.Repo`/Infrastructure/Http
survive, never that the OTHER poller survives a sibling's crash-loop,
matching the requirement's own text.

## 4. AC2's ordering-test mechanism — exact design

**Mechanism: a test-only, env-var-injected 1-arity callback that
`Letflow.Supervisor.Pollers.init/1` invokes, if configured, as the very
first expression in its body, passing it the result of
`Process.whereis(Letflow.Obs.Alerts.TaskSupervisor)`.**

Exact shape:

* `Letflow.Supervisor.Pollers.init/1`'s body starts with: read
  `Application.get_env(:letflow, :pollers_init_probe)`. If it is a
  1-arity function (`(pid() | nil -> any())`), call it with
  `Process.whereis(Letflow.Obs.Alerts.TaskSupervisor)` as its sole
  argument, ignoring the callback's return value, before doing anything
  else (before computing the two gated poller entries). If the config
  key is unset (the default — no `config/*.exs` file sets it, satisfying
  AC7's "no config file changes" bar) or not a 1-arity function, this
  step is skipped entirely — zero behavioral difference from today in
  every environment except a test that explicitly sets it. This keeps
  the probe a pure test seam: `mix test`/`dev`/`prod` never set this key,
  so `Letflow.Supervisor.Pollers.init/1`'s production behavior is
  byte-for-byte what §1.2 already specifies.
* **Test procedure** (lives in a new or existing
  `test/letflow/supervisor/pollers_test.exs`, `async: false` — it
  mutates a global `Application.put_env/3` key and restarts a real,
  application-supervised singleton, matching this codebase's own
  `restart_admission!/2` precedent in `test/support/
  admission_test_helpers.ex` for the same class of test):
  1. Capture `test_pid = self()`.
  2. `Application.put_env(:letflow, :pollers_init_probe, fn whereis_result
     -> send(test_pid, {:pollers_init_whereis, whereis_result}) end)`.
     Register `on_exit(fn -> Application.delete_env(:letflow,
     :pollers_init_probe) end)` immediately after, so a failing
     assertion never leaks the override into a later test.
  3. Force `Letflow.Supervisor.Pollers.init/1` to run again on the REAL,
     already-application-booted supervisor tree (the probe must observe
     the actual production startup ordering, not a standalone test
     instance) via `Supervisor.terminate_child(Letflow.Supervisor,
     Letflow.Supervisor.Pollers)` followed by
     `Supervisor.restart_child(Letflow.Supervisor,
     Letflow.Supervisor.Pollers)` — both against the top-level,
     application-registered `Letflow.Supervisor` name, child id
     `Letflow.Supervisor.Pollers` (a bare-module child spec's `id`
     defaults to the module name itself). `restart_child/2` re-invokes
     `Letflow.Supervisor.Pollers.start_link/1`, which re-invokes
     `init/1`, re-running the probe check.
  4. `assert_receive {:pollers_init_whereis, whereis_result}, 1_000`.
  5. `assert whereis_result != nil` — proves
     `Letflow.Obs.Alerts.TaskSupervisor` (the LAST child of `Letflow.
     Supervisor.Infrastructure`, §1.1) was already registered and alive
     at the exact moment `Letflow.Supervisor.Pollers.init/1` ran, i.e.
     the whole of `Letflow.Supervisor.Infrastructure` had already
     finished starting — the AC2 property, observed via a real
     `whereis/1` call at the real moment, not inferred from list
     position alone.
  * Why restarting `Letflow.Supervisor.Pollers` (rather than only
    observing the original application boot) is a valid test of the
    SAME property: `Letflow.Supervisor.Infrastructure` is never
    restarted by this action (the top-level `:one_for_one` strategy only
    restarts the ONE child that exited, `Letflow.Supervisor.Pollers`
    itself, per `terminate_child`/`restart_child`'s own targeted-child
    semantics) — so `Obs.Alerts.TaskSupervisor` stays registered and
    alive throughout, under the exact same "Infrastructure fully started
    before Pollers' own init runs" invariant §1's design guarantees for
    every start of `Letflow.Supervisor.Pollers`, whether it is the
    original application boot or any later restart. The test exercises
    the real, production `init/1` code path (not a stand-in), just
    triggered a second time.

## 5. AC4's crash-loop-isolation-test mechanism — exact design

**Mechanism: a test-only, env-var-gated guard clause at the top of
`Letflow.Scheduler.Poller.handle_info(:tick, state)` that unconditionally
raises when the flag is set — never referenced by any committed
`config/*.exs` file, so it changes production behavior only when a test
explicitly flips it at runtime.**

Exact shape: `Letflow.Scheduler.Poller.handle_info(:tick, state)`'s body
gains one guard as its first expression: if
`Application.get_env(:letflow, :force_poller_crash, false)` is true,
`raise "forced crash for REQ-219 AC4 crash-loop isolation test"`
immediately, before any of the six existing per-tenant operations run.
Default `false`, read fresh per-call (mirrors this module's own existing
"config read fresh on every tick" convention, per its moduledoc) — no
`config/*.exs` file sets this key (AC7's "no config file changes" bar
holds), so every environment that never calls
`Application.put_env(:letflow, :force_poller_crash, true)` is completely
unaffected.

**Test procedure** (same test file/module as §4, `async: false`):

1. `repo_pid_before = Process.whereis(Letflow.Repo)`,
   `pollers_pid_before = Process.whereis(Letflow.Supervisor.Pollers)`.
2. `Application.put_env(:letflow, :start_scheduler, true)` (override
   `config/test.exs`'s `false`, so `Letflow.Supervisor.Pollers.init/1`
   actually includes `Letflow.Scheduler.Poller` on the next restart),
   `Application.put_env(:letflow, :force_poller_crash, true)`. Register
   `on_exit/1` restoring both to `config/test.exs`'s committed values
   (`start_scheduler: false, force_poller_crash: false` — actually
   `Application.delete_env(:letflow, :force_poller_crash)` plus
   `Application.put_env(:letflow, :start_scheduler, false)`) and, as the
   LAST step of `on_exit/1`, restarting `Letflow.Supervisor.Pollers`
   once more (terminate + restart, same mechanism as step 3 below) so it
   comes back up in its normal, non-crashing, gates-false configuration
   for whichever test runs next — leaving a stopped/misconfigured
   singleton for later tests is not acceptable (mirrors
   `restart_admission!/2`'s own "registers an `on_exit/1` that restores
   it" precedent).
3. `Supervisor.terminate_child(Letflow.Supervisor,
   Letflow.Supervisor.Pollers)` then `Supervisor.restart_child(
   Letflow.Supervisor, Letflow.Supervisor.Pollers)` — re-runs `Letflow.
   Supervisor.Pollers.init/1`, which now includes `Letflow.
   Scheduler.Poller` (step 2's override) and that Poller's own `init/1`
   immediately schedules its zero-delay first `:tick`
   (`lib/letflow/scheduler/poller.ex`'s existing, unmodified behavior),
   which then raises immediately per this section's new guard clause.
4. The crash-loop happens FAST (zero-delay tick → immediate raise →
   `Letflow.Scheduler.Poller` restarted by `Letflow.Supervisor.Pollers`
   → its `init/1` re-schedules ANOTHER zero-delay tick → raises again),
   so `max_restarts: 5` is exhausted within a small fraction of the
   `max_seconds: 60` window — OTP's own intensity check triggers on the
   (max_restarts + 1)-th restart attempt within the window, not after
   waiting out the full window's duration, so the test does not sleep
   60 seconds. A short poll-loop (e.g. up to ~2 seconds wall clock, well
   under the crash cadence needed to exhaust 5 restarts) waiting for
   `Process.whereis(Letflow.Supervisor.Pollers)` to become a NEW pid
   (different from `pollers_pid_before`, and non-`nil` — i.e. the
   top-level `Letflow.Supervisor` has already completed its own restart
   of the exited `Letflow.Supervisor.Pollers`) is the completion signal;
   `assert_receive`/`Process.monitor/1` on the pre-crash `Letflow.
   Supervisor.Pollers` pid (captured as `pollers_pid_before`) firing a
   `:DOWN` message is the more direct, non-polling mechanism and is
   preferred: `Process.monitor(pollers_pid_before)` right after step 1,
   then `assert_receive {:DOWN, _ref, :process, ^pollers_pid_before,
   _reason}, 5_000` — proves `Letflow.Supervisor.Pollers` itself
   (not just the inner `Poller`) actually exited, which is the AC4
   property, not merely inferred from a changed `whereis/1` result.
5. `assert Process.whereis(Letflow.Repo) == repo_pid_before` — the
   AC4-mandated assertion: `Letflow.Repo`'s pid is unchanged across the
   induced crash-loop, proving `Letflow.Supervisor.Infrastructure` (and,
   by the same top-level `:one_for_one` isolation, `Letflow.
   Supervisor.Http` where started) was never touched.
6. Optionally, also assert `Process.whereis(Letflow.Supervisor.Pollers)
   != nil` and is a pid different from `pollers_pid_before`, confirming
   the top-level `Letflow.Supervisor` did in fact restart the exited
   layer (not merely leave it down) — directly exercises "restarted by
   the top-level `Letflow.Supervisor`" from AC4's own text.

This is the ONE piece of this design that touches a file
(`lib/letflow/scheduler/poller.ex`) outside the three new supervisor
modules and `application.ex` — flagged explicitly (also in §7) since
ELIXIR-DEV must add this guard clause for AC4 to be testable at all, and
REVIEWER should confirm a single `Application.get_env/3`-gated `raise`,
defaulting to `false` and unreferenced by any config file, is an
acceptable, test-only addition rather than scope creep — it changes no
production behavior in any environment that does not call
`Application.put_env(:letflow, :force_poller_crash, true)`.

## 6. Empty-children-list behavior for `Letflow.Supervisor.Pollers`

Stated explicitly so ELIXIR-DEV does not need to (re)discover it:
`Supervisor.init([], strategy: :one_for_one)` (or, equivalently here,
`Supervisor.init([], strategy: :one_for_one, max_restarts: 5,
max_seconds: 60)`) is valid Elixir/OTP — an empty children list is fully
supported by the `Supervisor` behaviour. `Letflow.
Supervisor.Pollers.start_link/1` returns `{:ok, pid}` exactly as with a
non-empty list; the resulting supervisor process starts, holds zero
children, and stays alive indefinitely doing nothing (no crash, no
warning, no special-cased "empty supervisor" error) until a child is
added dynamically (not done anywhere in this design) or the whole
application stops. This is exactly `config/test.exs`'s current
`:start_scheduler: false, :start_service_task_dispatcher: false` case —
AC4 in REQ-219's list requires this to "start and run with zero children
without error," which is guaranteed by `Supervisor`'s own documented
behavior, not something this design or ELIXIR-DEV needs to special-case.

## 7. Moduledoc content required for REVIEWER sign-off (AC8/AC9)

Each of the three new modules' moduledoc must contain, at minimum (a
REVIEWER checklist, not a suggestion):

* **`Letflow.Supervisor.Infrastructure`**: the full 17-child list in
  order (§1.1); the ISS-0224 ordering guarantee (SandboxPool.
  TaskSupervisor before SandboxPool) verbatim; the ISS-0429 ordering
  guarantee (Obs.Alerts.TaskSupervisor fully started, as the LAST child
  of this supervisor, before `Letflow.Supervisor.Pollers` starts at
  all) verbatim, phrased as a supervisor-boundary guarantee, not a list-
  position guarantee; a note that `Letflow.InstanceSupervisor`'s
  placement here matches its CURRENT behavior (empty `DynamicSupervisor`,
  REQ-045/ISS-0422 unaffected) and is not a claim about which layer it
  belongs in once it gains real children (decision 4(d), left open for a
  future requirement); OTP-default restart intensity and why (no
  documented incident motivates a change here).
* **`Letflow.Supervisor.Pollers`**: both gate keys
  (`:start_scheduler`, `:start_service_task_dispatcher`) and their
  independence; the `max_restarts: 5, max_seconds: 60` override and its
  full rationale verbatim (§3); the documented incident this override
  and the top-level `:one_for_one` split together close (crash-looping
  poller under Ecto sandbox / any sustained per-tick fault no longer
  takes down `Letflow.Repo` or Bandit); the sibling-restart consequence
  noted in §3 (both pollers restart together when this supervisor's own
  budget is exhausted).
* **`Letflow.Supervisor.Http`**: the `:start_http` gate and ISS-0015's
  port-collision-under-test rationale (relocated verbatim from today's
  `http_child/0` comment); OTP-default restart intensity, unchanged.
* **`Letflow.Application`**: its own `@moduledoc` (today `false`) may
  stay `false` — REQ-219 does not require documenting the top-level
  module itself beyond what `start/2`'s own shape (§2) already makes
  self-evident (3 named children, no logic left to explain). REVIEWER's
  sign-off (AC8's own three explicit points) is instead recorded as
  ordinary REVIEWER-role sign-off text at WF-02 Step 2d, confirming:
  (a) the new 3-layer shape does not weaken either ordering guarantee
  above; (b) `Letflow.InstanceSupervisor`'s placement is not itself a
  claim about future children (decision 4(d)); (c) `:one_for_one` over
  `:rest_for_one` at the top level is justified against the actual
  20-child dependency graph (every named-process infra child is looked
  up BY NAME at its call sites, never by stored pid — decision 1's own
  stated reason, restated here for REVIEWER to verify against the real
  code, not assumed).

## 8. Test file/location summary

* `test/letflow/supervisor/infrastructure_test.exs` (new) — AC1, AC3:
  asserts `Letflow.Application`'s own compiled top-level children list
  is exactly the 3 new modules (e.g. via `:supervisor.which_children(
  Letflow.Supervisor)` returning exactly 3 entries with those 3 module
  ids), and that none of the original 20 child ids/names appear as
  DIRECT children of `Letflow.Supervisor` (they are now two levels
  down); asserts `:supervisor.which_children(Letflow.
  Supervisor.Infrastructure)` returns the 17 expected ids in order, and
  a targeted ISS-0224 check (SandboxPool.TaskSupervisor's position
  precedes SandboxPool's).
* `test/letflow/supervisor/pollers_test.exs` (new) — AC2 (§4), AC4 (§5),
  AC7 (empty-children-list-under-`config/test.exs`'s-current-settings,
  §6 — a trivial `Process.whereis(Letflow.Supervisor.Pollers) != nil`
  plus `:supervisor.which_children/1` returning `[]` under the
  suite's own default config, no override needed).
* `test/letflow/supervisor/http_test.exs` (new, small) — AC6: under
  `config/test.exs`'s `start_http: false`, `Letflow.Supervisor.Http`
  starts with zero children (same empty-list argument as §6).
* No change needed to `test/letflow/scheduler/poller_test.exs` beyond
  what §5 already covers in the new `pollers_test.exs` file — REQ-219
  does not require moving `Poller`'s own existing unit tests.
* AC5 (`config/test.exs`/`dev.exs`/`prod.exs` need no changes): verified
  by `mix test` passing under the suite's existing, UNCHANGED
  `config/test.exs` gate settings — no new test needed beyond a
  read-confirmation that none of the three files were touched by this
  change (a `git diff --stat` fact, not a `mix test`-visible property).

## 9. Open questions

* **Q1 — exact wording of the forced-`raise`'s message string (§5)** is
  left to ELIXIR-DEV's discretion; no acceptance criterion constrains
  it, only that it actually raises and is gated off by default.
* **Q2 — whether `Letflow.Supervisor.Pollers`' `on_exit/1` restoration
  (§5 step 2) should itself be factored into a shared `test/support/`
  helper** (mirroring `test/support/admission_test_helpers.ex`'s
  `restart_admission!/2` precedent) rather than inlined per test file —
  left to TEST-DESIGNER; both `pollers_test.exs`'s AC2 and AC4 tests
  restart the same supervisor by the same mechanism, so a shared
  `restart_pollers!/1`-shaped helper (taking the env overrides to apply)
  is likely worth extracting, but this design does not mandate the
  exact helper signature since it carries no behavioral consequence for
  the acceptance criteria themselves.
* **Q3 — REQ-220's dependency on this requirement (`depends_on:
  [REQ-219]`)** confirms REQ-220's own consolidated Task.Supervisor
  rationale doc (its AC1) is written against `Letflow.
  Supervisor.Infrastructure`'s moduledoc (§1.1/§7 above) as the
  "one consolidated list" location — not re-verified further here since
  REQ-220 is out of this requirement's scope, but flagged so
  ELIXIR-DEV/CODE-DESIGNER for REQ-220 knows exactly which file's
  moduledoc to extend rather than creating a second list elsewhere.
