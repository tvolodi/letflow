;; REQ-171 -- a minimal fixture importing ONLY the two :none-gated host
;; functions (now, uuid), no read_variable/log import at all. Used to prove
;; the :none-sentinel mechanism (design §4.1) independently: a module
;; declaring only these two imports instantiates successfully under an
;; EMPTY manifest, since `now`/`uuid` are always installed regardless of
;; `manifest.capabilities`'s contents -- unlike `req171_host_api.wat`
;; (which also imports read_variable/log, and therefore requires those two
;; capabilities granted for instantiation to succeed at all, per WASM's
;; import-table-membership-is-the-gate architecture, REQ-167).
(module
  (import "env" "now" (func $now (param i32 i32) (result i32)))
  (import "env" "uuid" (func $uuid (param i32 i32) (result i32)))

  (memory (export "memory") 2)

  (func (export "call_now")
        (param $out_ptr i32) (param $out_cap i32)
        (result i32)
    local.get $out_ptr
    local.get $out_cap
    call $now)

  (func (export "call_uuid")
        (param $out_ptr i32) (param $out_cap i32)
        (result i32)
    local.get $out_ptr
    local.get $out_cap
    call $uuid))
