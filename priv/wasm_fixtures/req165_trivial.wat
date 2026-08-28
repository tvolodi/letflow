;; REQ-165 -- trivial guest fixture. Proves the wasmex toolchain and the
;; Elixir process boundary, nothing more. Deliberately NOT WASM-02's
;; four-export ABI (init/execute/deinit/get_capabilities + alloc) -- that is
;; REQ-166's scope. No `memory` export either: `answer`'s signature returns a
;; bare i32, so no string/buffer payload crosses the boundary.
(module
  (func (export "answer") (result i32)
    i32.const 42))
