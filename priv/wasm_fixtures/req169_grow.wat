(module
  (memory (export "memory") 1 10)
  (func (export "grow_by") (param $delta i32) (result i32)
    local.get $delta
    memory.grow))
