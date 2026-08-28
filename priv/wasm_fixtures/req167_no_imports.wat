;; REQ-167 -- a module with no imports at all, used to confirm an
;; over-supplied, unused whitelist entry is inert (design §1.2 probe 3): a
;; manifest granting capabilities this module never uses must still
;; instantiate cleanly, since `imports:` describes what a module MAY reach,
;; not what it MUST reach.
(module
  (memory (export "memory") 1))
