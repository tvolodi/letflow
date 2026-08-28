(module
  (func (export "hang")
    (loop $forever
      br $forever)))
