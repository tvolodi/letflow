;; REQ-172 -- test fixture for the "write_variable then platform.fail" discard-arm
;; scenario (design §2.3/§3.4/§8, checklist item 2's fifth arm, `write_then_fail`).
;; Imports write_variable and fail.
;;
;; `write_then_fail` stages a write via the real `write_variable` host function, then
;; unconditionally calls `fail` -- the simplest of the five discard arms, since `fail`
;; needs no adversarial trigger (unlike the trap/fuel/memory-cap/hang arms).
(module
  (import "env" "write_variable"
    (func $write_variable (param i32 i32 i32 i32) (result i32)))
  (import "env" "fail"
    (func $fail (param i32 i32 i32 i32)))

  (memory (export "memory") 2)

  (func (export "write_then_fail")
        (param $name_ptr i32) (param $name_len i32)
        (param $value_ptr i32) (param $value_len i32)
        (param $reason_ptr i32) (param $reason_len i32)
        (param $details_ptr i32) (param $details_len i32)
    local.get $name_ptr
    local.get $name_len
    local.get $value_ptr
    local.get $value_len
    call $write_variable
    drop
    local.get $reason_ptr
    local.get $reason_len
    local.get $details_ptr
    local.get $details_len
    call $fail))
