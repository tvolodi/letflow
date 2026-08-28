;; REQ-166 AC3/stage-2 -- all five required function exports and the required
;; `memory` export are correctly shaped (stage 1 passes with zero defects),
;; but the module also imports an unresolved WASI function
;; (`wasi_snapshot_preview1::path_open`). No WASI options are ever supplied
;; by ModuleRegistry.register/1 (design §1.1), so Wasmex.start_link/1's real
;; instantiation attempt (stage 2) fails on this import -- this is the
;; req163 §4 "instantiation-based rejection" case, distinct from any
;; export-shape defect. `Wasmex.Module.compile/2` does not resolve imports
;; (design §1.2), so stage 1 still sees this module as export-clean.
(module
  (import "wasi_snapshot_preview1" "path_open" (func $path_open (param i32) (result i32)))
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
