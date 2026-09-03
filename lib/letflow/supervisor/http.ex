defmodule Letflow.Supervisor.Http do
  @moduledoc """
  REQ-219 (design `req219-supervision-layering.md` §1.3): owns exactly
  `Bandit`, still gated by `:start_http`, under `strategy: :one_for_one`
  with the OTP default restart intensity (3 restarts/5 seconds) --
  unchanged and isolated from `Letflow.Supervisor.Infrastructure` and
  `Letflow.Supervisor.Pollers`.

  ISS-0015 (GH#71): the port was previously a hardcoded literal here, not
  partitioned by MIX_TEST_PARTITION the way config/test.exs's database name
  is -- two concurrent `mix test` runs (the project's two-worktree setup)
  both tried to bind the same TCP port. Fixed by not starting Bandit at all
  under test (config/test.exs sets start_http: false) -- no test drives the
  router over a real socket, it's exercised via Plug.Test conns, so this
  sidesteps the collision entirely rather than just relocating it, and
  shaves the listener's startup cost off every test run. dev/prod keep
  start_http: true (default) with the port read from config
  (config/dev.exs compile-time 4000; config/runtime.exs's PORT env var for
  prod, matching config/prod.exs's own comment that runtime-dependent
  values belong there).
  """

  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    Supervisor.init(http_child(), strategy: :one_for_one)
  end

  defp http_child do
    if Application.get_env(:letflow, :start_http, true) do
      [{Bandit, plug: Letflow.Router, port: Application.fetch_env!(:letflow, :http_port)}]
    else
      []
    end
  end
end
