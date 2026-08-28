;; REQ-173 -- design SS8.2's "v2" hot-reload fixture. Imports ONLY
;; env.write_variable (the exact 4-i32-param/1-result signature
;; capability_gate.ex's @known_imports table already declares, unchanged).
;; Also declares the five plugin-ABI exports plus memory (req163 SS3.1/3.2),
;; for the same stage-1-passes-cleanly reason req173_v1_gated.wat's header
;; explains.
;;
;; Its "run" export calls write_variable with a fixed name/value (embedded
;; via data segments), discards the result, and unconditionally returns the
;; i32 literal 222. It never calls platform_call_service and never blocks --
;; only req173_v1_gated.wat's "run" export blocks, per design SS8.1.
(module
  (import "env" "write_variable"
    (func $write_variable (param i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 2)

  (data (i32.const 0) "x")
  (data (i32.const 100) "1")

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
    (call $write_variable
      (i32.const 0) (i32.const 1)    ;; name_ptr/len -- "x"
      (i32.const 100) (i32.const 1)) ;; value_ptr/len -- JSON "1"
    drop
    i32.const 222))
