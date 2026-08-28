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
;;
;; TEST-DESIGNER note (WF02-REQ174-20260828 step-03): the design's §4.1 text
;; omitted the five plugin-ABI exports (`init`/`execute`/`deinit`/
;; `get_capabilities`/`alloc`) that `ModuleRegistry.register/1` requires
;; before `ModuleVersionRegistry.register_version/3` (Test A's call path)
;; will accept ANY module, zero imports or not -- see
;; `req173_v1_capless.wat`'s identical precedent/comment. Added here,
;; zero-import, all constant-returning, so both `register_version/3`
;; (Test A) and `PluginHandler.run_guest/3` (Test B, which never calls
;; `ModuleRegistry.register/1` at all and does not need these exports) can
;; use the exact same fixture bytes.
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

  (func (export "write_marker") (result i32)
    i32.const 0
    i32.const 1
    i32.store8
    i32.const 0)
  (func (export "read_marker") (result i32)
    i32.const 0
    i32.load8_u))
