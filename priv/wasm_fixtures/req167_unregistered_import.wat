;; REQ-167 T5 -- a module importing a host function the registry has NEVER
;; heard of at all ("env"/"totally_unregistered_function"), distinct from
;; both known-registry names ("read_variable", "platform_call_service").
;; Proves the whitelist is a genuine, generic mechanism (build_import_table/1
;; can never produce an entry for a descriptor absent from @known_imports,
;; design §4) rather than a validator that merely special-cases the two
;; named acceptance-criterion imports by name -- this import is denied
;; identically for EVERY manifest, including the maximally-permissive one
;; that grants every capability this registry currently defines.
(module
  (import "env" "totally_unregistered_function" (func $unreg (param i32 i32) (result i32)))
  (memory (export "memory") 1))
