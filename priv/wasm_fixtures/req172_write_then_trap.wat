;; REQ-172 -- test fixture for the "write_variable then guest trap" discard-arm
;; scenario (design §3.4/§8, checklist item 2). Imports ONLY write_variable (a
;; genuine `unreachable` trap needs no host callback at all) so a manifest granting
;; just "var:write" is sufficient to instantiate.
;;
;; `write_then_trap` stages a write via the real `write_variable` host function, then
;; executes `unreachable` -- a genuine guest trap, no host callback involved in the
;; trap itself. Reused for two distinct tests (design §11 checklist items 2 and 4's
;; last bullet): (a) the write-then-trap discard-arm test (asserting
;; take_staged_writes/0, called from the test process, observes %{}), and (b) the
;; guest-trap-vs-fail distinguishability test (asserting the fail-signal pdict key is
;; ABSENT after a genuine trap, unlike after platform.fail).
(module
  (import "env" "write_variable"
    (func $write_variable (param i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 2)

  (func (export "write_then_trap")
        (param $name_ptr i32) (param $name_len i32)
        (param $value_ptr i32) (param $value_len i32)
    local.get $name_ptr
    local.get $name_len
    local.get $value_ptr
    local.get $value_len
    call $write_variable
    drop
    unreachable))
