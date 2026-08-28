;; REQ-166 -- otherwise-conforming module where `execute` is exported with its
;; param/result shapes TRANSPOSED relative to the required
;; `(param i32 i32) -> i32` (req163 §3.1 / design §5.2): here it is
;; `(param i32) -> i32 i32`, i.e. exactly {actual_params, actual_results} ==
;; {expected_results, expected_params}. This exists specifically to catch a
;; defect_for/2 mutant that matches the exported signature against
;; {results, params} instead of {params, results} -- a swapped-clause mutant
;; that a fixture merely shorter/longer in arity (like
;; req166_wrong_signature_execute.wat's (param i32) -> i32) does NOT
;; distinguish from correct behaviour, because neither the correct nor the
;; swapped-clause code matches that fixture's actual shape either way, so
;; both report the same {:wrong_signature, ...} defect regardless of the bug.
(module
  (memory (export "memory") 1)
  (func (export "init") (param i32 i32) (result i32)
    i32.const 0)
  (func (export "execute") (param i32) (result i32 i32)
    i32.const 0
    i32.const 0)
  (func (export "deinit"))
  (func (export "get_capabilities") (result i32)
    i32.const 0)
  (func (export "alloc") (param i32) (result i32)
    i32.const 0))
