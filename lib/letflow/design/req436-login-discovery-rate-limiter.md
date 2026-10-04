# REQ-436 -- Design: the login-discovery rate limiter (implementation-level refinement)

Stage S4. Owner: `CODE-DESIGNER` -> `ELIXIR-DEV`. Status: design only (no implementation code).
Bucket **B** (new modules, one supervised child, no migration, no new env var or secret).

**Authority.** The merged `lib/letflow/design/req434-email-first-login-directory.md` (cited below as
"434") governs where this file and REQ-436's text differ: 434 s0.3 D5, D6, D10, D11, D13, D14;
s12.1-12.5, s12.7; s15.2. This file does not re-decide any of them. It refines them to the level an
implementer needs: exact signatures, ETS row layout, the compare-and-swap primitive, population
counting, the sweep, config and its validation site, telemetry, supervisor placement and test
seams. Every place where refinement had to choose between options is marked **Decision** and every
unresolved matter is in s14 (open questions); nothing is "TBD".

---

## 0. Verified ledger (each item read from the tree in this session)

| # | Fact | Source |
|---|---|---|
| V1 | Existing `Bucket`: GenServer, table `:letflow_public_read_rate_limit`, `:named_table, :public, :set, write_concurrency, read_concurrency`; `consume/3` is `:ets.lookup` then `:ets.insert`, row `{key, tokens :: float, last_refill_ms}`; refusal does not write; no eviction; the GenServer only owns the table | `lib/letflow/plugs/public_read_rate_limit/bucket.ex:29-79` |
| V2 | `PublicReadRateLimit.call/2` reads config per request via `Application.get_env(:letflow, __MODULE__, [])` with inline defaults; on refusal `Response.rate_limited(conn, "rate limit exceeded") |> halt()`. It keys on `conn.remote_ip` and consumes `:global` FIRST (the order this limiter inverts) | `lib/letflow/plugs/public_read_rate_limit.ex:36-52` |
| V3 | `Response.rate_limited/2` -> `send_problem/2` sets only `application/problem+json` and the status; **it sets no `Retry-After` and no security headers** ("Set `Retry-After` on the conn yourself before calling"); `trace_id` in the body comes from `conn.assigns[:trace_id]` | `lib/letflow/api/response.ex:98-122, 181-186` |
| V4 | `Letflow.Plugs.ClientIp` (REQ-439) is merged: assigns `conn.assigns.client_ip` on every request, never rewrites `conn.remote_ip`, never reads `X-Forwarded-For`, reads its trust list per request (not in `init/1`) | `lib/letflow/plugs/client_ip.ex:1-60` |
| V5 | `Infrastructure.init/1` lists `Letflow.Plugs.PublicReadRateLimit.Bucket` at line 229, directly after `Letflow.Metrics.Registry` and before `{Letflow.Admission, []}`; its moduledoc numbers 21 children | `lib/letflow/supervisor/infrastructure.ex:188-330` |
| V6 | `infrastructure_test.exs` asserts an ordered id list and `length(ids) == 20` (`:70-117`); `Letflow.TenantProvisioning.MigrationReplayBoot` returns `:ignore` and so is not a live child, which is why the test counts 20 against the moduledoc's 21. The live count becomes 21 (test) / 22 (moduledoc numbering) | `test/letflow/supervisor/infrastructure_test.exs:70-117` |
| V7 | `:telemetry` is a direct dependency (`{:telemetry, "~> 1.4"}`) | `mix.exs:55` |
| V8 | `test/support/` has no probe router for this; REQ-436 adds one (434 s15.2) | directory listing |
| V9 | The existing test for the public limiter uses unique RFC 5737 documentation addresses and `async: false` to avoid the shared node-wide table | `test/letflow/plugs/public_read_rate_limit_test.exs:1-45` |

Discrepancy recorded, not silently resolved (see Q1): 434 s12.2 says the 429 constructor "sets the
common security headers"; V3 shows `Response.rate_limited/2` sets none and the repo has no shared
"security headers" helper for this mount. This design sets exactly `Retry-After` plus what
`Response.rate_limited/2` already sets, and records the gap.

---

## 1. Files and ownership

| Action | File |
|---|---|
| CREATE | `lib/letflow/plugs/login_discovery_rate_limit.ex` (`Letflow.Plugs.LoginDiscoveryRateLimit`) |
| CREATE | `lib/letflow/plugs/login_discovery_rate_limit/bucket.ex` (`Letflow.Plugs.LoginDiscoveryRateLimit.Bucket`) |
| CHANGE | `lib/letflow/supervisor/infrastructure.ex` (one child + moduledoc list; s9) |
| CHANGE | `test/letflow/supervisor/infrastructure_test.exs` (count 20 -> 21 + id list; s9) |
| CREATE (test) | `test/letflow/plugs/login_discovery_rate_limit_test.exs`, `test/letflow/plugs/login_discovery_rate_limit/bucket_test.exs`, `test/support/login_discovery_probe_router.ex` (s11) |
| UNCHANGED (git diff empty) | `lib/letflow/plugs/auth_pipeline.ex`, `lib/letflow/plugs/api_pipeline.ex`, `lib/letflow/plugs/public_read_rate_limit.ex`, `lib/letflow/plugs/public_read_rate_limit/bucket.ex` and their tests |
| NOT PLANNED (owned by open PR #2201 / not this requirement) | `config/test.exs`, `config/runtime.exs`, `lib/letflow/identity*`, `lib/letflow/login_directory*`, `lib/letflow/routers/identity.ex` |

**Deviation from 434 s15.2, recorded:** 434 lists `config/test.exs` ("suite-friendly capacities")
under "Change". This task's scope forbids touching it (PR #2201). **Decision:** no
`config/*.exs` edit at all. Defaults live in code (the `PublicReadRateLimit` precedent, V2); every
test that needs other capacities sets them with `Application.put_env/3` in `setup` and restores the
prior value in `on_exit`. Because the limiter's table is node-global and shared by async test
modules, every test file in this requirement is `async: false` and uses documentation-range
addresses (V9) so its keys never collide with another file's. No env var, secret or `runtime.exs`
key is added by this requirement (the mount switch and trusted-proxies belong to REQ-437/439).

Cross-module dependencies: `Plug.Conn`, `Letflow.Api.Response` (`rate_limited/2`), `:telemetry`,
`:ets`, `Letflow.Plugs.ClientIp` is a *runtime-optional* upstream only (this module reads the assign
it sets and does not call it). `Bucket` calls the plug module's `config/0` (a runtime call, no
compile-time cycle) so defaults are defined once. No Ecto, no `Repo`, no `LoginDirectory` (that is
REQ-435/437).

---

## 2. Types shared by both modules

```
@type ip_bucket_id ::
        {:v4, :inet.ip4_address()}
        | {:v6_64, {0..65535, 0..65535, 0..65535, 0..65535}}

@type bucket_key ::
        {:login_discovery, :global}
        | {:login_discovery, :ip, ip_bucket_id()}
        | {:login_discovery, :email_hmac, binary()}
        | {:login_discovery, :email_send, binary()}

@type kind :: :global | :ip | :email_hmac | :email_send        # the row's kind tag
@type population :: :ip | :email                               # :email = :email_hmac + :email_send
@type config :: %{atom() => number()}                           # merged defaults + app env, s6
```

`:email_hmac` keys carry the 434 s2 email key (a binary, the HMAC output); `:email_send` keys carry
the same binary. The limiter treats the binary as opaque and never inspects, logs or emits it.

---

## 3. ETS table and row layout

**Table** `:letflow_login_discovery_rate_limit`: `[:named_table, :public, :set, {:write_concurrency,
true}, {:read_concurrency, true}]` (same options as V1), created in `Bucket.init/1`, owned by the
`Bucket` GenServer. Nothing else is stored in it. **Every key it contains is a tuple whose first
element is `:login_discovery`** (acceptance criterion 1): bucket keys per s2 and the two bookkeeping
keys below.

**Bucket row** (4-tuple, keypos 1):

```
{bucket_key(), kind(), tokens_u :: non_neg_integer(), last_ms :: integer()}
```

- `kind` is redundant with the key (`:ip`, `:email_hmac`, `:email_send`, `:global`) and is stored in
  element 2 so a match specification can select by kind without a guard on the key shape.
- `tokens_u` is fixed-point **micro-tokens** (1 token = 1_000_000 `tokens_u`). **Decision:** integer
  state, not the float of V1. Reason: the compare-and-swap (s5) matches the exact tuple that was
  read; integers make "same tuple" exact and the refill arithmetic reproducible by both `consume`
  and the sweep's match-specification guard (s7), with no float-equality or rounding disagreement.
- `last_ms` is the monotonic-millisecond timestamp of the last *admitting* write. A refusal writes
  nothing (as V1), so `last_ms` never advances on refusal.

**Bookkeeping rows** (3-tuples, so they are never matched by a 4-tuple bucket pattern):

| Key | Shape | Purpose |
|---|---|---|
| `{:login_discovery, :count, :ip}` | `{key, :count, n :: non_neg_integer()}` | live-row count of the IP population |
| `{:login_discovery, :count, :email}` | `{key, :count, n :: non_neg_integer()}` | live-row count of the email-kind population |
| `{:login_discovery, :inline_sweep, :at}` | `{key, :inline_sweep, last_ms :: integer()}` | rate-limit marker for inline sweeps (s7.3) |

**Refill arithmetic (integer, shared by `consume`, the sweep guard and the tests).** Let
`rate_u_s = round(refill_per_sec * 1_000_000)` (micro-tokens per second, a positive integer; for the
default `1/900` that is `1111`). For a row `{tokens_u, last_ms}` at time `now_ms`:

- `elapsed_ms = max(now_ms - last_ms, 0)` (a backwards injected clock never *removes* tokens)
- `refilled_u = min(cap_u, tokens_u + div(elapsed_ms * rate_u_s, 1000))` where `cap_u = capacity *
  1_000_000`
- admit when `refilled_u >= 1_000_000`; the new row is `{key, kind, refilled_u - 1_000_000, now_ms}`
- an absent key is a full bucket: `refilled_u = cap_u`.

Truncation by `div` can under-credit less than one micro-token per admitting write; this is
conservative (never over-admits) and below one part in 10^6 of a token. Stated, accepted.

---

## 4. Module `Letflow.Plugs.LoginDiscoveryRateLimit.Bucket`

`use GenServer`. Owns the table and the periodic sweep timer. All hot-path functions below are
plain functions called from the *request* process (no `GenServer.call` round-trip; V1's shape
retained); the GenServer is only the table owner and the sweep clock.

```
@spec start_link(keyword()) :: GenServer.on_start()
  # registers under its module name, like V1

# callbacks
@spec init(keyword()) :: {:ok, %{sweep_interval_ms: pos_integer()}}
  # (1) Letflow.Plugs.LoginDiscoveryRateLimit.validate_config!(Application env) -- raises on violation,
  #     so the child fails to start and application boot fails (s6.2)
  # (2) creates the table (s3), (3) Process.send_after(self(), :sweep, sweep_interval_ms)
@spec handle_info(:sweep, state) :: {:noreply, state}
  # calls sweep(System.monotonic_time(:millisecond)), reschedules; any other message is ignored

@spec consume(bucket_key(), capacity :: pos_integer(), refill_per_sec :: number(),
              now_ms :: integer()) :: :ok | :rate_limited
@spec consume(bucket_key(), pos_integer(), number()) :: :ok | :rate_limited
  # arity 3 defaults now_ms to System.monotonic_time(:millisecond); arity 4 is the test seam

@spec sweep(now_ms :: integer()) :: non_neg_integer()      # rows deleted, all kinds
@spec sweep(now_ms :: integer(), population()) :: non_neg_integer()
@spec size(population()) :: non_neg_integer()              # O(1): reads the count row
@spec token_count(bucket_key(), now_ms :: integer()) :: {:ok, float()} | :absent
  # test/observability helper: effective tokens (refilled_u / 1_000_000) without consuming;
  # needed by the ordering AC ("global token count asserted directly"). Read-only.
@spec table() :: :letflow_login_discovery_rate_limit
```

`consume/3,4` never raises on a missing table beyond the standard `ArgumentError` from `:ets` (a
dead `Bucket` means the application is already coming down; same stance as V1).

### 4.1 Bucket kind -> parameters resolved inside `Bucket`

`consume` is generic over (key, capacity, refill) supplied by the caller, so it does not know the
caps. It reads the two population caps lazily, only when it must create a *new* row, from
`Letflow.Plugs.LoginDiscoveryRateLimit.config/0` (`max_ip_keys`, `max_email_keys`). `sweep/1,2`
needs per-kind capacity and refill and reads them from the same `config/0`. **Decision:** one
config source of truth (the plug module's `config/0`), called at runtime by `Bucket`; the
alternative of passing caps through every `consume` call was rejected because the sweep also needs
them and a second plumbing path invites drift.

---

## 5. `consume/4` algorithm (the compare-and-swap)

**Primitive. Decision: `:ets.select_replace/2`, with `:ets.insert_new/2` for the absent case.**
`select_replace/2` replaces an object *only if it matches a match specification, atomically per
object*, and requires the replacement to keep the key. A match head that is the **exact 4-tuple that
was read** (all four elements as literal terms) plus a body returning the new 4-tuple makes it a
true compare-and-swap: it returns `1` when the row was still exactly the one read and was replaced,
`0` when anyone else changed or deleted it. Alternatives considered and rejected:

- `:ets.update_counter/4`: atomic, but the refill depends on elapsed wall time, so the new value is
  not a pure increment of the stored one; cannot express "min(cap, tokens + f(elapsed)) - 1".
- `:ets.lookup` + `:ets.insert` (V1): the lost-update race that the 434 s12.3 "Race" bullet rejects
  (a burst over capacity is the email-bombing amplification for the per-email and send buckets).
- A `GenServer.call` or an `:ets` lock: serialises the hot path; 434 s12.3 forbids it.
- `:ets.update_element/3`: updates fields atomically but is unconditional, so it cannot detect an
  interleaved writer.

Literal-term caveat for the match head: every element of the stored tuple (atoms, integers,
binaries, nested tuples of integers) is a legal literal in a match head. The key never contains an
atom of the form `:"$N"` or `:_` (the only atoms are the fixed `:login_discovery` tags), and the
binary email key and integer IP groups are literals; so the head is an exact-equality pattern.

**Steps (prose, normative).** Bounded retry constant `@max_cas_attempts` is **8** (a module
attribute, not config: no tuning need exists, and a config key would widen the validated surface).

1. `now_ms` fixed once for the call (arity 3 reads the monotonic clock; arity 4 uses the argument).
2. Loop up to `@max_cas_attempts`:
   1. `:ets.lookup(table, key)`.
   2. **Row present, matching `{key, kind, tokens_u, last_ms}`:** compute `refilled_u` (s3). If
      `refilled_u < 1_000_000` return `:rate_limited` without writing. Otherwise attempt
      `select_replace` of the exact read tuple with `{key, kind, refilled_u - 1_000_000, now_ms}`.
      Result `1` -> return `:ok`. Result `0` -> next attempt (re-read).
   3. **Row absent:** the key is new.
      - `kind == :global`: no cap applies (one fixed row). `insert_new` of `{key, :global,
        cap_u - 1_000_000, now_ms}`; `true` -> `:ok`; `false` (another process inserted first) ->
        next attempt.
      - any other kind: run the **cap gate** (s5.1). If the gate refuses, return `:rate_limited`
        immediately (fail closed; no write). If it admits, `insert_new` of `{key, kind, cap_u -
        1_000_000, now_ms}`; `true` -> `:ok`; `false` -> the reservation is released (s5.1 step 4)
        and next attempt.
3. Attempts exhausted -> return `:rate_limited` (**fail closed**, 434 s12.3). Exhaustion requires 8
   consecutive losing races on one key; in practice only a pathological hot-key storm.

**Concurrency property (acceptance criterion 9).** With a fixed `now_ms` (no refill) and `N`
concurrent callers on one key of capacity `C`, the number of `:ok` results is `<= C`: each `:ok` is
preceded by a successful `select_replace` of the row it read (a strictly decreasing sequence) or by
the single successful `insert_new`, so two callers can never both consume the same token. Exhaustion
turns a would-be extra admit into `:rate_limited`, never into `:ok`.

### 5.1 The cap gate for a new non-global key (race-safe population counting)

**Decision: reserve-then-insert with an `:ets.update_counter/4` count row**, not `:ets.select_count`
at insert time (O(n) per new key, unacceptable at the 100 000 cap under an attack) and not
`:ets.info(table, :size)` (mixes populations and counts the bookkeeping rows, so it cannot bound
each population separately).

`population = :ip` for kind `:ip`; `:email` for `:email_hmac` and `:email_send`. `cap` =
`max_ip_keys` / `max_email_keys`. Steps:

1. `new_count = :ets.update_counter(table, count_key(population), {3, 1}, {count_key, :count, 0})`
   (atomic increment, creating the count row on first use).
2. `new_count <= cap` -> **admit** (a slot is reserved).
3. `new_count > cap` -> the population looks full: decrement `{3, -1}` (release), run the **inline
   sweep** for that population (s7.3; rate-limited), then retry steps 1-2 **once**. If still
   `> cap`, decrement again and **refuse** the new key. The refusal is `:rate_limited`.
4. If the later `insert_new` returns `false` (the key was inserted by a concurrent caller) the
   reservation is released with `{3, -1}` and the CAS loop re-reads the now-present row.
5. A swept/deleted row decrements the count by exactly the number of rows removed (s7.1).

Properties: the reserved count is an *upper bound* on the live row count at every instant (a slot is
counted before its row exists; a row is deleted before its slot is released), so the cap is never
exceeded and the transient error is always on the conservative (refuse) side. When the system is
quiescent the count equals the real per-population row count (tests cross-check `size/1` against
`:ets.select_count` by kind). Residual: a request process killed between steps 1 and `insert_new`
leaks one counted slot until the `Bucket` restarts (table and counters reset together); accepted,
see Q3.

**Cap refusal never evicts a live key.** The inline sweep deletes only rows that are idle (s7).

---

## 6. Module `Letflow.Plugs.LoginDiscoveryRateLimit` (the plug and the config owner)

`@behaviour Plug`. Public surface:

```
@spec init(keyword()) :: keyword()                  # pass-through; reads NO app config (see 6.4)
@spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
@spec consume_email(email_key :: binary(), kind :: :request | :send) :: :ok | :rate_limited
@spec consume_email(binary(), :request | :send, now_ms :: integer()) :: :ok | :rate_limited
@spec send_rate_limited(Plug.Conn.t()) :: Plug.Conn.t()    # sends the 429 AND halts
@spec ip_bucket_id(:inet.ip_address()) :: ip_bucket_id()
@spec client_address(Plug.Conn.t()) :: :inet.ip_address()
@spec config() :: %{...}                            # merged defaults + app env, s6.1
@spec validate_config!(keyword()) :: :ok            # raises ArgumentError on violation
@spec defaults() :: keyword()
```

### 6.1 Config keys (`config :letflow, Letflow.Plugs.LoginDiscoveryRateLimit, ...`)

Defaults are code constants returned by `defaults/0` (434 s12.4); no `config/*.exs` entry is added
(s1). `config/0` merges `Application.get_env(:letflow, __MODULE__, [])` over `defaults/0`
**per call** (cheap map build; tests change it with `put_env`).

| Key | Default | Type | Used by |
|---|---|---|---|
| `global_capacity` | 60 | pos_integer | `call/2` global bucket; sweep (not swept; global is never evicted) |
| `global_refill_per_sec` | 10 | pos number | `call/2`; invariant |
| `ip_capacity` | 10 | pos_integer | `call/2`; sweep of `:ip` rows |
| `ip_refill_per_sec` | 0.5 | pos number | `call/2`; sweep |
| `email_capacity` | 5 | pos_integer | `consume_email(_, :request)`; sweep of `:email_hmac` |
| `email_refill_per_sec` | 1/60 (= 0.016666...) | pos number | same; invariant `T_email` |
| `send_capacity` | 1 | pos_integer | `consume_email(_, :send)`; sweep of `:email_send` |
| `send_refill_per_sec` | 1/900 | pos number | same; invariant `T_send` |
| `max_email_keys` | 50_000 | pos_integer | cap gate; invariant |
| `max_ip_keys` | 100_000 | pos_integer | cap gate |
| `sweep_interval_ms` | 30_000 | pos_integer | `Bucket` timer; invariant |
| `retry_after_seconds` | 60 | pos_integer | `send_rate_limited/1` (constant `Retry-After`) |
| `inline_sweep_min_interval_ms` | 1_000 | pos_integer | inline-sweep throttle (s7.3). **New key beyond 434 s12.4**, added so the cap-full path cannot become an O(n)-per-request CPU amplifier; Q4 |

Float defaults are written as exact rationals in code (`1/60`, `1/900` evaluated) so the derived
`rate_u_s` equals `1000000/60 -> 16667` and `1111` deterministically (`round/1`).

### 6.2 `validate_config!/1` and where it is called

- **Called from:** `Bucket.init/1` (boot-time; a violation raises, the child fails to start, the
  supervisor start fails, the application does not boot) and directly from tests. It takes a
  *keyword/map of overrides* and validates `defaults ++ overrides` so tests can pass partial config.
  Returns `:ok` or raises `ArgumentError`. The message names the offending key(s) and the formula
  terms by name; values are numeric config, not secrets (INV-4 N/A), and no email/IP/key is in
  scope.
- **Checks, in order:**
  1. every capacity and key cap and `sweep_interval_ms` and `retry_after_seconds` is a positive
     integer; every `*_refill_per_sec` is a positive number (`is_number and > 0`);
  2. `max_ip_keys >= ip_capacity` (434 s12.3: "positive and not smaller than `ip_capacity`");
  3. the email-population invariant:
     `max_email_keys >= 2 * (global_capacity + ceil(global_refill_per_sec * (t_email_full_max +
     sweep_interval_ms / 1000)))` with `t_email_full_max = max(email_capacity / email_refill_per_sec,
     send_capacity / send_refill_per_sec)` (seconds). Defaults: `max(300, 900) = 900`; `2 * (60 +
     ceil(10 * 930)) = 18_720 <= 50_000` -> accepted. A test config with `max_email_keys: 1_000`
     violates it (`18_720 > 1_000`) -> raises.
- The IP population has **no** formula (434 s12.3: not bounded by config; bounded by the hard cap).

### 6.3 `call/2` -- exact sequence (runs before the body is read; criterion 6)

Never calls `Plug.Conn.read_body/2` or any `fetch_*` that reads it. Steps:

1. `ip = client_address(conn)`: `conn.assigns[:client_ip]` when it is an `:inet.ip_address()`
   (4-tuple of `0..255` or 8-tuple of `0..65535`), else `conn.remote_ip`. Never a request header
   (so a spoofed `X-Forwarded-For` cannot change the key; 434 s0.3 D11). Total function; a
   malformed assign falls back to `remote_ip` rather than raising (INV-8).
2. `id = ip_bucket_id(ip)`; `Bucket.consume({:login_discovery, :ip, id}, ip_capacity,
   ip_refill_per_sec)`.
   - `:rate_limited` (IP bucket empty **or** `max_ip_keys` cap refusal) -> emit
     `:rate_limited_ip` (s8), `send_rate_limited(conn)`, return. **The global bucket is not
     touched** (criterion 4, D13).
3. Only on `:ok`: `Bucket.consume({:login_discovery, :global}, global_capacity,
   global_refill_per_sec)`.
   - `:rate_limited` -> emit `:rate_limited_global`, `send_rate_limited(conn)`, return.
4. `:ok` -> return `conn` unchanged (no assign added, no header added).

All refusal paths return a halted conn from `send_rate_limited/1`; `call/2` does not call `halt/1`
separately.

### 6.4 `init/1` reads no config

`Plug.Builder` evaluates `init/1` at compile time, before `config/runtime.exs` (the reason
`ClientIp` documents the same, V4). `init/1` is pass-through; `config/0` is read per request in
`call/2` (V2's precedent). A stale compile-time `[]` therefore cannot freeze capacities on a
release.

### 6.5 `consume_email/2,3`

Called by REQ-437's endpoint (kind `:request`, after it computed the email key) and by REQ-437's
notifier task (kind `:send`). Mapping:

| `kind` | bucket key | capacity / refill (config) |
|---|---|---|
| `:request` | `{:login_discovery, :email_hmac, email_key}` | `email_capacity` / `email_refill_per_sec` |
| `:send` | `{:login_discovery, :email_send, email_key}` | `send_capacity` / `send_refill_per_sec` |

The two kinds are independent rows (criterion 10): a consumed `:send` token does not reduce the
`:request` bucket and vice versa. On `:rate_limited` the function emits `:rate_limited_email`
exactly once and returns `:rate_limited`; **the function does not send the response** (the caller
decides and then calls `send_rate_limited/1`, so all three causes share one constructor). The
`:send` refusal is consumed inside the notifier task and its response is already committed, so
`consume_email(_, :send)` emitting `:rate_limited_email` is by design: the counter is "this limiter
refused on a per-address bucket", independent of whether an HTTP response follows (Q5 records this).
`email_key` must be a binary; any other term raises `FunctionClauseError` (caller bug, not input).
Tests that need the clock pass `now_ms` (arity 3).

### 6.6 `send_rate_limited/1` -- the single constructor (criterion 6)

Sequence, no branching on any argument other than the conn: `Plug.Conn.put_resp_header(conn,
"retry-after", Integer.to_string(retry_after_seconds))` -> `Letflow.Api.Response.rate_limited(conn,
"rate limit exceeded")` -> `Plug.Conn.halt/1`. The detail string is a fixed literal; nothing about
the cause (IP/global/email), the email, the IP or the key is passed in or reachable, so the status,
headers and body are byte-identical across the three causes **by construction**. The body's only
variable part is `trace_id` (V3), taken from `conn.assigns[:trace_id]`, independent of cause; the
byte-comparison test sets the same `trace_id` assign on all three conns (or none). The constructor
is the only code in the module that calls `Response.rate_limited`.

### 6.7 `ip_bucket_id/1` table (criterion 5; pure, total over `:inet.ip_address()`)

| Input | Output | Rule |
|---|---|---|
| `{203, 0, 113, 7}` | `{:v4, {203, 0, 113, 7}}` | 4-tuple passes through |
| `{0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107}` (`::ffff:203.0.113.7`) | `{:v4, {203, 0, 113, 7}}` | IPv4-mapped (`::ffff:0:0/96`): groups 1-5 zero and group 6 = `0xFFFF`; group 7 = `a*256+b`, group 8 = `c*256+d` -> `{a,b,c,d}` |
| `{0x2001, 0xDB8, 1, 2, 3, 4, 5, 6}` | `{:v6_64, {0x2001, 0xDB8, 1, 2}}` | any other IPv6 -> first four groups (the /64) |
| `{0x2001, 0xDB8, 1, 2, 9, 9, 9, 9}` | `{:v6_64, {0x2001, 0xDB8, 1, 2}}` | same /64 -> same id as the row above (shared bucket) |
| `{0x2001, 0xDB8, 1, 3, 3, 4, 5, 6}` | `{:v6_64, {0x2001, 0xDB8, 1, 3}}` | different /64 -> different id |
| `{0, 0, 0, 0, 0, 0, 0, 1}` (`::1`) | `{:v6_64, {0, 0, 0, 0}}` | loopback is not mapped; it keys as the `::/64` network |
| `{0, 0, 0, 0, 0, 0xFFFF, 0, 0}` | `{:v4, {0, 0, 0, 0}}` | boundary of the mapped rule |
| `{0, 0, 0, 0, 0, 0, 0xCB00, 0x7107}` (deprecated IPv4-compatible) | `{:v6_64, {0, 0, 0, 0}}` | **not** treated as mapped (only `::ffff:0:0/96`) |

Not mapped (stated, not a gap): NAT64 `64:ff9b::/96`, 6to4 `2002::/16`, Teredo. They key as ordinary
/64s; Q6 notes the residual.

---

## 7. Bounded state: lossless eviction and the sweep

**Decision (434 D5): only lossless eviction.** A row is removed only when its effective tokens equal
`cap_u` (idle, fully refilled), which is behaviourally identical to an absent row (s3). Nothing
else is ever deleted: a live key is never evicted, so no bucket can be refilled faster than its
normal rate.

### 7.1 `sweep(now_ms, population \\ :all)` -- one `:ets.select_delete/2` per kind

For each swept kind (`:ip`; `:email_hmac`; `:email_send`; **never `:global`**) with
`cap_u` and `rate_u_s` from `config/0`, one `select_delete` is issued whose match specification is
a single clause:

- **head:** `{:"$1", kind_literal, :"$2", :"$3"}` (kind literal in element 2 selects the kind; the
  3-tuple bookkeeping rows cannot match a 4-tuple head),
- **guard:** `(now_ms - $3) >= 0` AND `($2 + div((now_ms - $3) * rate_u_s, 1000)) >= cap_u`
  (the same integer formula as s3, so `consume` and sweep agree exactly),
- **result:** `true`.

The return value is the number of deleted objects. **Race-safety:** the guard is evaluated against
each object under that object's lock and the delete is conditional on it, so a concurrent `consume`
that just replaced the row (changing `$2` and `$3`) makes the guard false and the row survives; a
row that becomes eligible a moment after being skipped is simply collected next sweep. There is no
read-then-delete window (this is why `select_delete` with the guard is used rather than a
`lookup`/`delete` per key).

After the deletes for a population, `update_counter(count_key, {3, -deleted})` once per
population (delete first, decrement second: the count only ever over-estimates, s5.1). `:email`
population deletions are the sum of the `:email_hmac` and `:email_send` results.

### 7.2 Timer

`Bucket.init/1` schedules `:sweep` every `sweep_interval_ms`; `handle_info(:sweep, ...)` calls
`sweep(System.monotonic_time(:millisecond))` (all populations) and reschedules with
`Process.send_after`. A sweep crash would crash the `Bucket` (and reset the table); `sweep` is
total over the table's own row shapes so this is not expected (INV-8; Q7 notes the reset
semantics).

### 7.3 Inline sweep (cap gate only)

Called by a request process from the cap gate (s5.1 step 3) for exactly the full population. To
prevent every cap-full request from running an O(n) sweep, it is throttled by the
`{:login_discovery, :inline_sweep, :at}` row: the caller reads `last_ms`; if `now_ms - last_ms <
inline_sweep_min_interval_ms` the inline sweep is skipped (the gate then simply re-checks the count
once and refuses if still full); otherwise the caller claims the slot with `select_replace` (CAS) on
that row (or `insert_new` when absent) and, only if it won, runs `sweep(now_ms, population)`. The
loser skips. Net effect: at most one inline sweep per `inline_sweep_min_interval_ms` per node,
regardless of how many requests hit a full population.

### 7.4 Why this meets the cap acceptance criteria

- **Email population (criterion 7).** Submitting `10 * max_email_keys` distinct keys through
  `consume(key, ..., now_ms)` (cap read from config, set low by `put_env` for the test, with a
  config that passes `validate_config!` or by calling `Bucket.consume` directly, which does not
  validate) can never push `size(:email)` above `max_email_keys`: each new key must reserve a slot
  first (s5.1). The test asserts `size(:email) <= max_email_keys` after each batch and
  `:ets.select_count` by kind agrees.
- **Hot key after unrelated keys idle and swept (criterion 7).** With the injectable clock: fill
  many keys at `t0`, drain one hot key, advance `now_ms` past the longest full-refill window,
  `sweep(now_ms)`. Unrelated keys are gone (`size` drops), the hot key (still not refilled to
  capacity if drained recently enough relative to the injected time) is *not* deleted and remains
  limited; a swept key behaves as a fresh bucket (a `consume` afterwards is `:ok` with full
  capacity). A key at capacity is never deleted *while non-idle*: asserted by consuming from a key,
  sweeping at `last_ms` (no elapsed time), and asserting the row still exists.
- **Two caps (criterion 8).** `max_ip_keys` set small via `put_env`; the (cap+1)th distinct /64 gets
  `:rate_limited` from the IP step, so `call/2` does not reach the global step (global
  `token_count` unchanged, asserted), no existing IP row is deleted (all earlier ids still present),
  and requests from earlier sources are still admitted until their own bucket empties.

---

## 8. Telemetry (434 s0.3 D14, s12.7)

`:telemetry.execute([:letflow, :login_discovery, :outcome], %{count: 1}, %{outcome: outcome})`
with `outcome` exactly one of `:rate_limited_ip`, `:rate_limited_global`, `:rate_limited_email`.
Emitted by this module only: from `call/2` (first two) and from `consume_email/2,3` (third), once
per refusal and **never on admit** (the endpoint emits `:tenant`/`:accepted`/`:not_found`, the gate
`:disabled`; not this requirement). The metadata map has the single key `:outcome`. No email, key,
IP, slug, tenant id or count is placed in measurements or metadata (INV-4). Handler attachment and
`/metrics` wiring are not built here (434 s12.7: the events alone satisfy the requirement; the
`Metrics.Registry` hook is REQ-437's reported choice). The module itself emits no `Logger` call on
any path (criterion 13: nothing in this module can put an email, key or IP in log output).

---

## 9. Supervisor placement

- **Child:** `Letflow.Plugs.LoginDiscoveryRateLimit.Bucket` (bare module, like V1's entry), placed
  **directly after `Letflow.Plugs.PublicReadRateLimit.Bucket`** in `Infrastructure.init/1`
  (currently `infrastructure.ex:229`), before `{Letflow.Admission, []}`. Reason: it is the sibling
  of that child with the same property (leaf, independently startable; its `init/1` creates a fresh
  named ETS table and reads only application config; it calls no other supervised process, no
  `Repo`, no `Registry`). It has **no ordering dependency in either direction**; the position is a
  readability choice. It does not move `Obs.Alerts.TaskSupervisor` (still last), nor
  `SandboxPool.TaskSupervisor` before `SandboxPool`, nor `MigrationReplayBoot` after
  `Ecto.Migrator` (all ordering invariants in the existing moduledoc are untouched).
- **Restart:** default `:permanent` child spec from `use GenServer`; `:one_for_one`, default OTP
  intensity (unchanged). A `Bucket` crash resets both the table and all buckets (a transient
  fail-open for the node, identical to V1's behaviour for `/api/public`; Q7).
- **Moduledoc edits in `infrastructure.ex`:** add a REQ-436 paragraph (moduledoc total 22, same
  style as the REQ-352 paragraph), insert the new child in the numbered list directly after item 7
  and renumber 8-21 to 9-22, and add a "REQ-436: child 8 has no ordering dependency..." bullet
  beside the REQ-352 bullet. Add a child-spec comment at the new entry mirroring the REQ-352 one.
- **Test edits in `infrastructure_test.exs`:** insert `Letflow.Plugs.LoginDiscoveryRateLimit.Bucket`
  directly after `Letflow.Plugs.PublicReadRateLimit.Bucket` in the expected ordered-id list, change
  `assert length(ids) == 20` to `21`, rename the test title "owns the 20 expected children" to 21,
  and extend the file's moduledoc history sentence. No other assertion in that file changes. (V6
  records the pre-existing moduledoc-vs-live-count inconsistency; this change does not "fix" it
  beyond its own insertion.)

---

## 10. Acceptance-criterion traceability

| # | Criterion (abbrev.) | Design element |
|---|---|---|
| 1 | keys namespaced/separate; existing keys unchanged | s3: own table `:letflow_login_discovery_rate_limit`; every key (bucket keys s2 + three bookkeeping keys) begins `:login_discovery`; test: `:ets.tab2list` of the new table asserts the first element of every key, and asserts the old table `:letflow_public_read_rate_limit` has no key whose first element is `:login_discovery`; s1: old `Bucket` untouched |
| 2 | independence both directions (global and per-IP) | s1/s3: different table, different key namespace, no shared state; tests in s11.2 (T2a-T2d) run both directions with real chains |
| 3 | (ip_capacity+1)th request 429; spoofed XFF no effect; global trips independently of any single IP | s6.3 steps 1-3; `client_address/1` reads only the assign/`remote_ip`; test drives many distinct documentation addresses to exhaust global |
| 4 | ordering: IP-first, global untouched by IP-refused requests | s6.3 step 2 returns before step 3; `token_count/2` (s4) reads the global tokens directly: `>= global_capacity - ip_capacity`; second address admitted; no `:rate_limited_global` event captured |
| 5 | IPv6 /64, mapped IPv4 | s6.7 table |
| 6 | identical 429 for IP/global/email; refuse before body read | s6.6 single constructor; s6.3 never reads the body; tests send an unreadable/invalid body through the probe router |
| 7 | bounded state, lossless eviction, injectable clock | s3 integer rows, s5.1 reserve-then-insert, s7.1 sweep, s7.4; `now_ms` params on `consume/4`, `sweep/1`, `consume_email/3`, `token_count/2` |
| 8 | two caps; `validate_config!/1` | s5.1/s7.4 (`max_ip_keys` fail closed without a global token), s6.2 (formula; accept defaults, raise on violation) |
| 9 | CAS never admits more than capacity under concurrency | s5 `select_replace` + `insert_new` + bounded retries failing closed |
| 10 | per-email bucket; independent `:send` kind | s6.5 (two keys, two rows) |
| 11 | outcome counters, no other metadata | s8 |
| 12 | git diff empty on the four named files; existing tests pass unmodified | s1 (no edit planned; verification step in s12) |
| 13 | no email/key/IP in Logger output | s8: no `Logger` call in either module; test `capture_log(level: :debug)` around a full flood asserts the output contains no email, key, or IP string |
| 14 | compile/format/test/boundaries pass | s12 verification commands; `mix letflow.check_boundaries`: only runtime calls between `Bucket` and the plug module and from the plug to `Letflow.Api.Response` (a dependency the existing limiter already has) |

---

## 11. Test seams and test plan outline (for TEST-DESIGNER; not code)

### 11.1 Seams

- **Clock:** `now_ms` argument on `Bucket.consume/4`, `Bucket.sweep/1,2`, `Bucket.token_count/2`,
  `consume_email/3`. `call/2` reads the real monotonic clock; plug-level tests use a tiny
  `*_refill_per_sec` (for example `0.0001`) so elapsed time during a test is negligible, and need
  no injection.
- **Config:** `Application.put_env(:letflow, Letflow.Plugs.LoginDiscoveryRateLimit, overrides)` in
  `setup`, previous value restored in `on_exit`. All files `async: false`.
- **Isolation:** unique RFC 5737 / RFC 3849 documentation addresses per test (`192.0.2.0/24`,
  `198.51.100.0/24`, `203.0.113.0/24`, `2001:db8::/32`); unique email-key binaries per test
  (random bytes). Because the table is node-global and not cleared, tests assert on their own keys
  and on deltas, never on absolute table size, except where the cap test sets `max_*_keys` relative
  to the observed `size/1` at test start.
- **Probe router:** `test/support/login_discovery_probe_router.ex`, a minimal `Plug.Router` whose
  chain is, in order, `plug Letflow.Plugs.ClientIp`, `plug Letflow.Plugs.LoginDiscoveryRateLimit`,
  `plug :match`, `plug :dispatch`, with one `post "/probe"` returning `200` and a `post
  "/probe-email"` that calls `consume_email/2` with a key taken from a test-only header and then
  `send_rate_limited/1` on refusal (so the per-email 429 is produced by the real constructor). It
  contains no body parsing before the limiter (the first-plug rule). REQ-437 re-asserts the real
  chain; this router only proves this module's behaviour.
- **`/api/public` side of independence:** drive the real `Letflow.Router` `/api/public` mount with
  the helpers `PublicReadFixtureSupport` already provides (V9), as the existing limiter test does.

### 11.2 Test cases, mapped to criteria

- **T1 (crit 1):** keys-namespace assertions above; plus a compile-time-free grep-shaped assertion
  is avoided (anti-pattern: a grep AC tripped by moduledoc text); assert on live table contents.
- **T2a/T2b (crit 2, global):** exhaust the login-discovery global bucket (drive `global_capacity +
  1` distinct addresses) then assert a `/api/public` request is not 429; exhaust `/api/public`'s
  global bucket then assert the probe route still serves `200` for a fresh address. **T2c/T2d
  (per-IP):** one address exhausts its login-discovery IP bucket, the same `conn.remote_ip` on
  `/api/public` is not 429; and the reverse. Both directions quoted in the report.
- **T3 (crit 3):** `ip_capacity` 200s then 429; with `x-forwarded-for` set to varying values the
  count is unchanged; with `assigns.client_ip` differing from `remote_ip` the bucket follows the
  assign; with no assign it follows `remote_ip`; global trips from many distinct addresses.
- **T4 (crit 4):** one address sends `10 * global_capacity`; after the first `ip_capacity`
  admissions every request is 429; `token_count(global)` is `>= global_capacity - ip_capacity`; a
  second address is admitted; telemetry capture shows zero `:rate_limited_global` events for it.
- **T5 (crit 5):** s6.7 table as a data-driven test; plus an end-to-end pair of addresses sharing a
  /64 consuming one bucket.
- **T6 (crit 6):** three conns refused by IP, global, email causes (global forced by lowering
  `global_capacity`, email forced via `/probe-email`); compare `resp.status`, the full sorted
  response header list and `resp.resp_body` for equality after fixing `trace_id`; repeat with two
  different emails and assert identical bytes; send an invalid/unreadable body (for example a
  malformed `content-type` and truncated JSON) to a refused source and assert 429 (the body was not
  read).
- **T7 (crit 7):** bucket-level with `max_email_keys` lowered; sweep with injected clock as in
  s7.4; `size/1` vs `:ets.select_count`.
- **T8 (crit 8):** `max_ip_keys` lowered; `validate_config!/1` accepts `[]` (defaults) and raises
  for `[max_email_keys: 1_000]`, for a non-positive capacity and for `max_ip_keys < ip_capacity`.
- **T9 (crit 9):** `Task.async_stream` of `N = 200` `consume/4` calls at one fixed `now_ms` on one
  key with capacity `C = 5` and `max_concurrency` large; the count of `:ok` is `<= 5` (and equals 5
  absent exhaustion; the assertion is `<=`). Repeated 20 times to give the race a chance.
- **T10 (crit 10):** the Nth `consume_email(k, :request)` across different source addresses is
  refused while another key is admitted; `:send` independent (one admit, then refused, request
  bucket unchanged).
- **T11 (crit 11):** attach a telemetry handler (detached in `on_exit`); each cause emits exactly
  one event whose metadata keys equal `[:outcome]` and measurements equal `%{count: 1}`; admitted
  requests emit none.
- **T12 (crit 12):** the existing public-limiter test files run unmodified (command in s12); the
  four-file `git diff main...HEAD -- <paths>` is empty (a CI/RELEASE-VALIDATOR check, not an
  in-suite assertion, per the anti-pattern on `git diff main...HEAD` inside tests).
- **T13 (crit 13):** `ExUnit.CaptureLog.capture_log(level: :debug, fn -> flood end)` and assert the
  captured string contains none of the test's email strings, key bytes (hex or raw) or address
  strings.

---

## 12. Verification commands for ELIXIR-DEV (real output to be quoted)

`mix compile --warnings-as-errors`; `mix format --check-formatted`; `mix test
test/letflow/plugs/login_discovery_rate_limit_test.exs
test/letflow/plugs/login_discovery_rate_limit/bucket_test.exs
test/letflow/plugs/public_read_rate_limit_test.exs test/letflow/supervisor/infrastructure_test.exs`
(the "touched areas"; the full suite is not required for this requirement); `mix
letflow.check_boundaries`; `git diff --stat main...HEAD -- lib/letflow/plugs/auth_pipeline.ex
lib/letflow/plugs/api_pipeline.ex lib/letflow/plugs/public_read_rate_limit.ex
lib/letflow/plugs/public_read_rate_limit/bucket.ex` printing nothing.

---

## 13. Invariants (security-invariants.md)

- **INV-4:** no `Logger` call; telemetry metadata is the closed `outcome` atom; the email key is an
  opaque binary never rendered; `validate_config!/1` messages name config keys and numbers only.
- **INV-5:** the three 429 causes are byte-identical (s6.6); the 429 does not depend on whether the
  address exists (the key is an HMAC, existence is never consulted here).
- **INV-8:** total functions at the edges (`client_address/1` falls back; `ip_bucket_id/1` is total
  over `:inet.ip_address()`); CAS exhaustion and cap-full fail closed; `Bucket` has a single clear
  failure mode (restart resets state, Q7); no unbounded growth (two caps, lossless sweep).
- **Multi-tenancy:** the limiter holds no tenant data and no tenant id; the table is platform-wide
  by design (a public, pre-authentication mount).
- **Multi-node:** per-node table, as 0028 OQ-4 records for `/api/public`.

---

## 14. Open questions (none silently resolved; each has a stated default the implementer follows)

- **Q1 (security headers).** 434 s12.2 says the 429 constructor "sets the common security
  headers"; no such helper exists for this mount (V3). **Default followed:** set only `Retry-After`
  plus what `Response.rate_limited/2` sets. If REQ-437's router chain adds response headers
  (for example a shared header plug), they apply equally to every cause. A shared headers helper is
  REQ-437's to introduce; `REQ-VALIDATOR` / `SECURITY-REVIEWER` to confirm this reading.
- **Q2 (`@max_cas_attempts` value).** 8 is chosen, not derived. Exhaustion fails closed, so a low
  value cannot over-admit. `ELIXIR-DEV` may raise it only with a recorded reason.
- **Q3 (count-slot leak on a killed request process).** Between the reserve (`update_counter`) and
  `insert_new`, a killed process leaks one counted slot until `Bucket` restarts. Default: accepted
  (conservative, refuse-side; requires a kill inside a two-call window; not attacker-triggerable).
  A reconcile step was rejected because it would race with in-flight reservations and could
  under-count (fail open) by up to the in-flight count.
- **Q4 (`inline_sweep_min_interval_ms`).** A config key beyond 434 s12.4's table, added to bound
  the inline-sweep cost (s7.3). Default 1 000 ms. `REQ-VALIDATOR` to accept the addition (it is
  additive and does not change 434's observable behaviour).
- **Q5 (`:rate_limited_email` on the `:send` kind).** `consume_email(_, :send)` emits
  `:rate_limited_email` on refusal, although REQ-437's response is already committed to the
  uniform 202 by then. Default: emit (the counter means "a per-address bucket refused"); REQ-437
  must not also emit it for the same event. 434 s12.7 lists only the three outcomes, so no new
  atom is introduced.
- **Q6 (unmapped IPv6 transition ranges).** NAT64, 6to4 and Teredo key as ordinary /64s (s6.7).
  Aggregation inaccuracy there is a documented limiter-precision residual, not a bypass of the
  caps.
- **Q7 (restart resets state).** A `Bucket` crash recreates the table empty (all buckets full)
  until traffic refills the counts: same trade-off as the existing limiter. Default: accepted;
  `Bucket` has no persistence.
- **Q8 (`config/test.exs`).** 434 s15.2 asks for suite-friendly capacities there; this requirement
  is barred from that file (PR #2201). Default: tests self-configure with `put_env` (s1). If later
  non-limiter suites that traverse the real REQ-437 chain exhaust the default capacities (global 60,
  per-IP 10), REQ-437 (or a follow-up) owns the `config/test.exs` entry.
