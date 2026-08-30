defmodule Letflow.Obs do
  @moduledoc """
  Observability subsystem for Letflow.

  The primary public module is `Letflow.Obs.Logger`, which implements the OTP
  `:logger_formatter` behaviour and provides `redact_sensitive/1` and `with_trace/1`
  for use by other subsystems.
  """
end
