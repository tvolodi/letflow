;; REQ-167 AC1/T1 -- a module importing ONLY "env"/"platform_call_service"
;; (the exact signature capability_gate.ex's @known_imports table gives it,
;; (i32,i32)->i32), no other imports at all. Under a manifest granting only
;; "var:read" (which whitelists "env"/"read_variable", not this import),
;; build_import_table/1 produces a table with no "platform_call_service" key
;; at all, so Wasmex.start_link/1's real instantiation attempt must fail via
;; the unresolved-import crash shape -- this is WASM-06's own literal
;; acceptance-criterion scenario: "module declaring var:read only cannot
;; import platform_call_service".
(module
  (import "env" "platform_call_service" (func $platform_call_service (param i32 i32) (result i32)))
  (memory (export "memory") 1))
