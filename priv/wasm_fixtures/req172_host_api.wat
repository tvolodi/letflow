;; REQ-172 -- test fixture for Letflow.Engine.Wasm.HostApi's write-path host
;; functions (write_variable, call_service, fail). Mirrors req171_host_api.wat's
;; established pattern exactly: one guest export per host function under test, each a
;; thin guest-side re-export forwarding the guest's own arguments verbatim to the
;; corresponding `env.*` import -- this lets the Elixir test driver (in particular
;; the shared parity harness, test/support/host_api_parity.ex) control every
;; pointer/length pair directly via `Wasmex.call_function/4`, and read the guest's own
;; linear memory afterward from the test's own process (no re-entrancy concern,
;; design §9 of req171's own design, restated here).
(module
  (import "env" "write_variable"
    (func $write_variable (param i32 i32 i32 i32) (result i32)))
  (import "env" "platform_call_service"
    (func $platform_call_service (param i32 i32 i32 i32 i32 i32) (result i32)))
  (import "env" "fail"
    (func $fail (param i32 i32 i32 i32)))

  (memory (export "memory") 2)

  (func (export "call_write_variable")
        (param $name_ptr i32) (param $name_len i32)
        (param $value_ptr i32) (param $value_len i32)
        (result i32)
    local.get $name_ptr
    local.get $name_len
    local.get $value_ptr
    local.get $value_len
    call $write_variable)

  (func (export "call_call_service")
        (param $service_id_ptr i32) (param $service_id_len i32)
        (param $payload_ptr i32) (param $payload_len i32)
        (param $out_ptr i32) (param $out_cap i32)
        (result i32)
    local.get $service_id_ptr
    local.get $service_id_len
    local.get $payload_ptr
    local.get $payload_len
    local.get $out_ptr
    local.get $out_cap
    call $platform_call_service)

  (func (export "call_fail")
        (param $reason_ptr i32) (param $reason_len i32)
        (param $details_ptr i32) (param $details_len i32)
    local.get $reason_ptr
    local.get $reason_len
    local.get $details_ptr
    local.get $details_len
    call $fail))
