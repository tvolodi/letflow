;; REQ-172 -- test fixture for the "write_variable then fuel exhaustion" discard-arm
;; scenario (design §3.4/§8, checklist item 2). Imports ONLY write_variable -- fuel
;; exhaustion is a property of the Store's fuel budget (Letflow.Engine.Wasm.
;; ResourceLimits, REQ-169), not of any host callback, so no other import is needed.
;;
;; `write_then_loop_forever` stages a write via the real `write_variable` host
;; function, then enters an unconditional infinite loop identical in shape to
;; `req169_hang.wat`/`req169_counting.wat` -- with `consume_fuel: true` (REQ-169's
;; `ResourceLimits.build_store/1`, always on) and a fuel budget armed immediately
;; before the call, this loop traps with "all fuel consumed by WebAssembly" well
;; before it could ever hang the test.
(module
  (import "env" "write_variable"
    (func $write_variable (param i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 2)

  (func (export "write_then_loop_forever")
        (param $name_ptr i32) (param $name_len i32)
        (param $value_ptr i32) (param $value_len i32)
    local.get $name_ptr
    local.get $name_len
    local.get $value_ptr
    local.get $value_len
    call $write_variable
    drop
    (loop $again
      br $again)))
