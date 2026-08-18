defmodule Letflow.InstanceSupervisor do
  @moduledoc """
  `DynamicSupervisor` reserved for per-process-instance processes.

  Currently supervises no children. REQ-045 resolved the S3 running-instance shape to
  a plain transactional context module (`Letflow.Engine.create/2`), not a supervised
  process, so there is nothing for this supervisor to own yet. It is deliberately
  retained rather than deleted, per `Letflow.Engine`'s own moduledoc (REQ-045 AC5):
  "`instance_supervisor.ex` is generalized, not superseded ... its `DynamicSupervisor`
  shape is confirmed still correct in principle for whichever later S3 requirement
  (REQ-056/REQ-057) does need a supervised process." REQ-046 does not reverse that
  recorded decision — see `lib/letflow/design/req046-process-instance-retirement.md`
  §2 for the full reasoning.

  `start_instance/1` was removed by REQ-046 alongside `Letflow.ProcessInstance`'s own
  deletion (its only caller). A real `start_instance/1` is added back by whichever of
  REQ-056/REQ-057 introduces the first supervised instance process, against that
  requirement's own child spec — not reconstructed speculatively here.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
