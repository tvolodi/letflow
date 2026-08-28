;; REQ-168 -- MemoryGuard test fixture. One exported page of linear memory
;; and a placeholder export, nothing more. Distinct from
;; `req165_trivial.wat` (declares no `memory` export at all -- REQ-165
;; needed no buffer crossing its boundary) because this design's tests need
;; a real `Wasmex.Memory.t()` handle from a real running instance. Mirrors
;; `lib/letflow/design/req168-wasm-memory-isolation.md` §1's own probe
;; fixture and §5.1's exact specification.
(module
  (memory (export "memory") 1)
  (func (export "noop") (result i32) i32.const 0))
