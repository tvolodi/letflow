;; REQ-166 -- otherwise-conforming module where `execute` is exported with the
;; wrong signature: `(param i32) -> i32` instead of the required
;; `(param i32 i32) -> i32` (req163 §3.1 / design §5.2). Exercises the
;; `{:wrong_signature, name, expected: _, actual: _}` export_defect() branch,
;; distinct from `{:missing, name}`.
(module
  (memory (export "memory") 1)
  (func (export "init") (param i32 i32) (result i32)
    i32.const 0)
  (func (export "execute") (param i32) (result i32)
    i32.const 0)
  (func (export "deinit"))
  (func (export "get_capabilities") (result i32)
    i32.const 0)
  (func (export "alloc") (param i32) (result i32)
    i32.const 0))
