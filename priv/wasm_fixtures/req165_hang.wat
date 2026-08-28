;; REQ-165 -- hanging guest fixture. An unconditional branch back to the top
;; of the loop, with `consume_fuel` left at its documented default `false`,
;; so nothing internal to Wasmtime bounds this loop -- it genuinely never
;; returns on its own. Used to prove PluginInterface.invoke/3's own
;; supervised-task timeout (not wasmex's internal interrupt) is what
;; terminates a hang.
(module
  (func (export "hang")
    (loop $forever
      br $forever)))
