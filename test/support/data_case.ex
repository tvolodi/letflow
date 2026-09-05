defmodule Letflow.DataCase do
  @moduledoc """
  Test case that checks out a sandboxed Ecto connection, so tests can
  hit real Postgres without leaking state between runs.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Letflow.Repo
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Letflow.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, {:shared, self()})
    end

    Process.put(:letflow_data_case_shared_mode?, !tags[:async])

    :ok
  end
end
