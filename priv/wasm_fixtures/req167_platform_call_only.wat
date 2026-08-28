;; REQ-167 AC1/T1 -- a module importing ONLY "env"/"platform_call_service"
;; (the exact signature capability_gate.ex's @known_imports table gives it),
;; no other imports at all. Under a manifest granting only "var:read" (which
;; whitelists "env"/"read_variable", not this import), build_import_table/1
;; produces a table with no "platform_call_service" key at all, so
;; Wasmex.start_link/1's real instantiation attempt must fail via the
;; unresolved-import crash shape -- this is WASM-06's own literal
;; acceptance-criterion scenario: "module declaring var:read only cannot
;; import platform_call_service".
;;
;; REQ-172 design §6.2 -- this import's declared signature is updated from the
;; REQ-167 illustrative 2-param placeholder ((i32,i32)->i32) to the real
;; 6-param shape capability_gate.ex's @known_imports now declares for
;; "platform_call_service" (REQ-172 design §4.1/§6.1), so this fixture's
;; instantiation-when-granted test continues to assert against the import
;; table's real, current declared type rather than a signature this
;; requirement has replaced.
(module
  (import "env" "platform_call_service"
    (func $platform_call_service (param i32 i32 i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1))
