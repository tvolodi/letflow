;; REQ-172 -- test fixture for the "write_variable then a guest's own reactive
;; platform.fail after observing a capped memory.grow" discard-arm scenario (design
;; §3.4, "restated honestly" -- memory.grow beyond the cap does NOT trap on its own,
;; WASM-10's own correction, decision 0014). Imports write_variable and fail.
;;
;; `write_then_grow_and_fail` stages a write via `write_variable`, attempts
;; `memory.grow` by the guest-supplied `$grow_delta` (the Elixir test chooses a delta
;; that exceeds the configured `memory_cap_bytes`, so this always returns Wasm's own
;; `-1` growth-failure sentinel under that config -- exactly mirroring
;; `req169_grow.wat`'s own `grow_by` shape), drops the sentinel, then unconditionally
;; calls `fail` -- this fixture's own authored behavior (design §3.4: "this arm is
;; mechanically the fail arm, triggered specifically following an observed cap
;; violation"), not a host-provided memory-cap failure signal (none exists, per
;; ResourceLimits' own live-verified finding, REQ-169).
;;
;; Memory is declared with headroom (10 pages max) well above any `memory_cap_bytes`
;; value the test configures via `Letflow.Engine.Wasm.ResourceLimits.build_store/1`'s
;; own `StoreLimits`, which is the mechanism that actually enforces the cap (not this
;; module's own max-pages declaration -- mirrors req169_grow.wat's identical
;; precedent of declaring more headroom than any StoreLimits config under test).
(module
  (import "env" "write_variable"
    (func $write_variable (param i32 i32 i32 i32) (result i32)))
  (import "env" "fail"
    (func $fail (param i32 i32 i32 i32)))

  (memory (export "memory") 1 10)

  (func (export "write_then_grow_and_fail")
        (param $name_ptr i32) (param $name_len i32)
        (param $value_ptr i32) (param $value_len i32)
        (param $grow_delta i32)
        (param $reason_ptr i32) (param $reason_len i32)
        (param $details_ptr i32) (param $details_len i32)
    local.get $name_ptr
    local.get $name_len
    local.get $value_ptr
    local.get $value_len
    call $write_variable
    drop
    local.get $grow_delta
    memory.grow
    drop
    local.get $reason_ptr
    local.get $reason_len
    local.get $details_ptr
    local.get $details_len
    call $fail))
