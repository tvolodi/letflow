;; REQ-170 -- hanging guest fixture. An unconditional branch back to the top
;; of the loop, identical in shape to req165_hang.wat / req169_hang.wat,
;; duplicated as a permanent, dedicated fixture per this project's
;; established one-fixture-per-requirement convention
;; (req169-wasm-fuel-and-memory-cap.md S5.1). Used by REQ-170's live
;; verification and test suite to prove: (1) Wasmex.call_function/4's own
;; documented timeout does NOT return a clean {:error, _} for this guest --
;; it crashes the caller with an ordinary GenServer.call timeout exit
;; (design S1.1); (2) Letflow.Engine.PluginInterface.invoke/2,3's existing
;; outer supervised-task boundary DOES independently bound the caller's
;; wait regardless (design S1.6).
(module
  (func (export "hang")
    (loop $forever
      br $forever)))
