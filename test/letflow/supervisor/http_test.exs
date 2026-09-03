defmodule Letflow.Supervisor.HttpTest do
  @moduledoc """
  REQ-219 (design `req219-supervision-layering.md` §8) AC6: under
  `config/test.exs`'s `start_http: false`, `Letflow.Supervisor.Http` starts
  with zero children -- read-only against the already-running,
  application-supervised singleton, safe `async: true`.
  """

  use ExUnit.Case, async: true

  test "Letflow.Supervisor.Http has zero children under config/test.exs's start_http: false" do
    refute Application.get_env(:letflow, :start_http, true)

    assert Supervisor.which_children(Letflow.Supervisor.Http) == []
  end
end
