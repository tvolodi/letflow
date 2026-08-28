;; REQ-174 -- per-invocation isolation test fixture. One exported page of
;; linear memory plus two exports that make the isolation property
;; observable from the host: `write_marker` writes a fixed non-zero byte
;; to a fixed offset, and `read_marker` reads it back without mutating
;; anything. Linear memory is zero-initialized by the Wasm spec at
;; instantiation, so byte 0 reads 0 on a fresh instance and 1 only after
;; `write_marker` has run on that same instance -- the observable signal
;; `lib/letflow/design/req174-wasm-instance-pooling-or-decline.md` §4.1
;; specifies. Mirrors `req168_memory.wat`'s precedent of one exported page
;; plus a minimal export set.
(module
  (memory (export "memory") 1)
  (func (export "write_marker") (result i32)
    i32.const 0
    i32.const 1
    i32.store8
    i32.const 0)
  (func (export "read_marker") (result i32)
    i32.const 0
    i32.load8_u))
