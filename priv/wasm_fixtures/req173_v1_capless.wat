;; REQ-173 -- companion fixture to req173_v1_gated.wat/req173_v2_gated.wat,
;; used ONLY where the test needs a module that ACTUALLY passes
;; ModuleRegistry.register/1 (see test/specs/REQ-173.md's "Blocking finding"
;; -- any module declaring even one import is unconditionally rejected by
;; register/1's stage-2 real-instantiation check, which always runs
;; Wasmex.start_link/1 with an empty import table, never a manifest-derived
;; one). Zero imports, all five plugin-ABI exports plus memory (so stage 1
;; AND stage 2 both pass), "run" export unconditionally returns 111 -- the
;; same literal req173_v1_gated.wat returns, so the two fixture pairs stay
;; visually paired for whoever reads this test file next to the gated one.
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
    i32.const 111))
