;; REQ-166 -- a fully-conforming WASM-02 module: all five required function
;; exports (init/execute/deinit/get_capabilities/alloc, req163 §3.1) plus the
;; required `memory` export (req163 §3.2), all correctly shaped per
;; lib/letflow/design/req166-wasm-module-abi-validation.md §5.2's table. No
;; imports at all, so stage 2's real instantiation attempt succeeds cleanly.
(module
  (memory (export "memory") 1)
  (func (export "init") (param i32 i32) (result i32)
    i32.const 0)
  (func (export "execute") (param i32 i32) (result i32)
    i32.const 0)
  (func (export "deinit"))
  (func (export "get_capabilities") (result i32)
    i32.const 0)
  (func (export "alloc") (param i32) (result i32)
    i32.const 0))
