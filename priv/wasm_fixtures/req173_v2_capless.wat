;; REQ-173 -- companion fixture to req173_v1_capless.wat (see that file's
;; header). Zero imports, same ABI shape, "run" export unconditionally
;; returns 222 -- the same literal req173_v2_gated.wat returns.
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
    i32.const 0)

  (func (export "run") (result i32)
    i32.const 222))
