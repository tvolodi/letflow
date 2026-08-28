;; REQ-171 -- test fixture for Letflow.Engine.Wasm.HostApi's read-path host
;; functions (read_variable, log, now, uuid). Exports memory and one guest
;; function per host function under test, each a thin guest-side re-export
;; forwarding the guest's own arguments verbatim to the corresponding
;; `env.*` import -- this lets the Elixir test driver control every
;; pointer/length pair directly via `Wasmex.call_function/4`, and read the
;; guest's own linear memory afterward from the test's own process (no
;; re-entrancy concern -- design §9).
(module
  (import "env" "read_variable"
    (func $read_variable (param i32 i32 i32 i32) (result i32)))
  (import "env" "log"
    (func $log (param i32 i32 i32 i32 i32 i32)))
  (import "env" "now"
    (func $now (param i32 i32) (result i32)))
  (import "env" "uuid"
    (func $uuid (param i32 i32) (result i32)))

  (memory (export "memory") 2)

  (func (export "call_read_variable")
        (param $name_ptr i32) (param $name_len i32)
        (param $out_ptr i32) (param $out_cap i32)
        (result i32)
    local.get $name_ptr
    local.get $name_len
    local.get $out_ptr
    local.get $out_cap
    call $read_variable)

  (func (export "call_log")
        (param $level_ptr i32) (param $level_len i32)
        (param $message_ptr i32) (param $message_len i32)
        (param $context_ptr i32) (param $context_len i32)
    local.get $level_ptr
    local.get $level_len
    local.get $message_ptr
    local.get $message_len
    local.get $context_ptr
    local.get $context_len
    call $log)

  (func (export "call_now")
        (param $out_ptr i32) (param $out_cap i32)
        (result i32)
    local.get $out_ptr
    local.get $out_cap
    call $now)

  (func (export "call_uuid")
        (param $out_ptr i32) (param $out_cap i32)
        (result i32)
    local.get $out_ptr
    local.get $out_cap
    call $uuid))
