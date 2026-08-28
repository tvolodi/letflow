;; REQ-166 AC2 -- otherwise-conforming module with the `alloc` export removed.
(module
  (memory (export "memory") 1)
  (func (export "init") (param i32 i32) (result i32)
    i32.const 0)
  (func (export "execute") (param i32 i32) (result i32)
    i32.const 0)
  (func (export "deinit"))
  (func (export "get_capabilities") (result i32)
    i32.const 0))
