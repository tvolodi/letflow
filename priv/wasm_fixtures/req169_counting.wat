(module
  (memory (export "memory") 1)
  (func (export "count_forever")
    (local $i i32)
    (local.set $i (i32.const 0))
    (loop $again
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (i32.store (i32.const 0) (local.get $i))
      (br $again))))
