;; REQ-166 AC1 -- otherwise-conforming module with the `execute` export
;; removed. Used to assert register/1 rejects with
;; {:error, {:invalid_abi, defects}} naming {:missing, "execute"}.
(module
  (memory (export "memory") 1)
  (func (export "init") (param i32 i32) (result i32)
    i32.const 0)
  (func (export "deinit"))
  (func (export "get_capabilities") (result i32)
    i32.const 0)
  (func (export "alloc") (param i32) (result i32)
    i32.const 0))
