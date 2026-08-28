;; REQ-172 -- test fixture for AC5 ("a guest that attempts to catch or ignore its
;; own fail STILL yields a failed outcome and does not run to completion"), the WASM
;; analogue of REQ-161's `pcall`-wrapped-continuation test (design §5.2/§5.3, §11
;; checklist item 4). Core WebAssembly has no `pcall`/`catch` construct at all (design
;; §5.2), so the adversarial shape here is different in KIND, not merely translated:
;; a guest whose own control flow, if `fail` ever returned normally, would go on to
;; make a second, independently-observable host call (`write_variable`, staging a
;; distinguishable marker) and then return a distinguishable literal (777) -- neither
;; of which this fixture's author (the test) ever expects to observe, since
;; `platform.fail`'s call aborts the entire guest `execute` call in flight (design
;; §5.2) before control could ever return to this function body.
(module
  (import "env" "fail"
    (func $fail (param i32 i32 i32 i32)))
  (import "env" "write_variable"
    (func $write_variable (param i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 2)

  (func (export "fail_then_continue")
        (param $reason_ptr i32) (param $reason_len i32)
        (param $details_ptr i32) (param $details_len i32)
        (param $marker_name_ptr i32) (param $marker_name_len i32)
        (param $marker_value_ptr i32) (param $marker_value_len i32)
        (result i32)
    local.get $reason_ptr
    local.get $reason_len
    local.get $details_ptr
    local.get $details_len
    call $fail

    ;; Unreachable in practice -- $fail never returns (design §5.2). If it somehow
    ;; did, this would stage a second, distinguishable write AND return a
    ;; distinguishable literal, either of which the test asserts is never observed.
    local.get $marker_name_ptr
    local.get $marker_name_len
    local.get $marker_value_ptr
    local.get $marker_value_len
    call $write_variable
    drop
    i32.const 777))
