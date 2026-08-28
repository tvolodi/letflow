;; REQ-172 -- test fixture for the "write_variable then wall-clock timeout" discard
;; -arm scenario (design §2.3/§3.4/§9.1). Imports ONLY write_variable -- the hang
;; itself needs no host callback (identical shape to req165_hang.wat/req169_hang.wat/
;; req170_hang.wat), so no other import is needed.
;;
;; `write_then_hang` stages a write via the real `write_variable` host function, then
;; enters the same unconditional infinite loop every other hang fixture in this suite
;; uses. Per design §2.3/§9.1: a wall-clock-timed-out call does NOT trap and does NOT
;; get its Wasmex instance process explicitly stopped -- the process (and the
;; instance's own native execution) is abandoned, leaked, never handed to any future
;; caller that could ever read its process dictionary. This fixture exists to prove
;; that abandonment property specifically for a guest that staged a write first,
;; which no pre-existing REQ-169/170 fixture does (none of them call write_variable).
(module
  (import "env" "write_variable"
    (func $write_variable (param i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 2)

  (func (export "write_then_hang")
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
