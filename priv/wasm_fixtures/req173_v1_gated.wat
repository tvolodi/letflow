;; REQ-173 -- design SS8.2's "v1" hot-reload fixture. Imports ONLY
;; env.platform_call_service (the exact 6-i32-param/1-result signature
;; capability_gate.ex's @known_imports table already declares, unchanged).
;; Also declares the five plugin-ABI exports (init/execute/deinit/
;; get_capabilities/alloc) plus memory, per req163 SS3.1/3.2, so that
;; ModuleRegistry.register/1's stage-1 static export/signature check passes
;; cleanly -- see test/specs/REQ-173.md's "Blocking finding" section for why
;; stage 2 (the real instantiation attempt) still rejects this module today.
;;
;; Its "run" export calls platform_call_service with the fixed service_id
;; "gate" (embedded via a data segment) and an empty payload (payload_len=0),
;; discards the result, and unconditionally returns the i32 literal 111. It
;; does NOT import write_variable, so it can never observe/exercise
;; "var:write" -- design SS8.2/SS8.3's disjoint-capability argument.
(module
  (import "env" "platform_call_service"
    (func $platform_call_service (param i32 i32 i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 2)

  (data (i32.const 0) "gate")

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
    (call $platform_call_service
      (i32.const 0) (i32.const 4)     ;; service_id_ptr/len -- "gate"
      (i32.const 0) (i32.const 0)     ;; payload_ptr/len -- none (optional arg)
      (i32.const 1024) (i32.const 256)) ;; out_ptr/out_cap
    drop
    i32.const 111))
