;; REQ-166 AC2 -- otherwise-conforming module with TWO required exports
;; removed simultaneously (`init` and `get_capabilities`). Used to assert
;; register/1's stage-1 check collects ALL defects in one pass rather than
;; stopping at the first missing export
;; (design §5.1 step 5 / §5.2's non-stop-on-first requirement).
(module
  (memory (export "memory") 1)
  (func (export "execute") (param i32 i32) (result i32)
    i32.const 0)
  (func (export "deinit"))
  (func (export "alloc") (param i32) (result i32)
    i32.const 0))
