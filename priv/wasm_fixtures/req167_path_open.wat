;; REQ-167 AC3/T3 -- a module importing req163-wasm-abi-choice.md §4's named
;; concrete filesystem surface, "wasi_snapshot_preview1"/"path_open", with
;; the real 9-parameter/1-result WASI Preview 1 core-module signature. No
;; manifest content can ever grant this import: capability_gate.ex's
;; @known_imports registry has zero filesystem-shaped entries, and
;; start_instance/2 never supplies a `wasi:` option to Wasmex.start_link/1
;; (design §2/§7) -- so this import is unresolved under ANY manifest,
;; including the maximally-permissive one that grants every capability this
;; registry defines. Deliberately does NOT use the literal string
;; "wasi:filesystem/types" (WASM-07's own unreplaced acceptance text) --
;; that is a WASI Preview 2 component-model interface identifier with no
;; meaning under core-module linking; asserting rejection of that literal
;; name would be a false pass (see capability_gate.ex's moduledoc, AC4).
(module
  (import "wasi_snapshot_preview1" "path_open"
    (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (memory (export "memory") 1))
