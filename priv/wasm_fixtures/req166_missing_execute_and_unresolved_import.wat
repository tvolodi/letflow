;; REQ-166 -- stage-gating guard: this module has BOTH a stage-1 defect
;; (the `execute` export is missing entirely, matching
;; req166_missing_execute.wat's fixture shape) AND, if stage 2 were ever
;; reached, would ALSO fail there (imports the unresolved
;; `wasi_snapshot_preview1::path_open`, matching
;; req166_unresolved_import.wat's import). It exists to catch a gating
;; mutant that lets stage 2 (the real `Wasmex.start_link/1` instantiation
;; attempt) run even when stage 1 (`check_exports/1`) already found a
;; defect: design §5.1 requires stage 2 to run ONLY once stage 1 is clean,
;; so a conforming implementation must report ONLY
;; {:error, {:invalid_abi, [{:missing, "execute"}]}} for this module and
;; must never reach, let alone report, an {:instantiation_failed, ...}
;; result for it.
(module
  (import "wasi_snapshot_preview1" "path_open" (func $path_open (param i32) (result i32)))
  (memory (export "memory") 1)
  (func (export "init") (param i32 i32) (result i32)
    i32.const 0)
  (func (export "deinit"))
  (func (export "get_capabilities") (result i32)
    i32.const 0)
  (func (export "alloc") (param i32) (result i32)
    i32.const 0))
