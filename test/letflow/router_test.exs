defmodule Letflow.RouterTest do
  @moduledoc """
  Tests for `Letflow.Router` (REQ-046, `test/specs/REQ-046.md`).

  Router-level end-to-end tests via `Plug.Test`, per
  `docs/guides/test_developer_guide.md` §2 ("test/letflow/*_test.exs exercising
  Letflow.Router end to end ... coverage target: every documented HTTP endpoint") and
  the `Plug.Test` convention already established in
  `test/letflow/plugs/tenant_status_test.exs`. No database dependency: every route this
  module currently exposes (`GET /health`, the 404 catch-all) is DB-free by design (the
  health check's own inline comment states this explicitly), so plain `ExUnit.Case` is
  used rather than `Letflow.DataCase`.

  REQ-046 removed three routes (`POST /instances`, `POST /instances/:id/actions`,
  `GET /instances/:id`) that used to call `Letflow.InstanceSupervisor.start_instance/1`
  and `Letflow.ProcessInstance.*` — both now deleted. Cases 2-4 below are regression
  coverage for that deletion: run against the pre-REQ-046 router they would not have
  seen a clean 404 at all, they would have hit a runtime `UndefinedFunctionError`
  (wrapped as a 500 by Plug's error handling), since the routes existed but called
  functions that no longer compiled. Passing here proves the routes were cleanly
  removed, not left dangling.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  @opts Letflow.Router.init([])

  defp call(conn), do: Letflow.Router.call(conn, @opts)

  test "GET /health returns 200 and status ok" do
    conn = conn(:get, "/health") |> call()

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
  end

  test "POST /instances now falls through to 404" do
    conn =
      conn(:post, "/instances", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == %{"error" => "not_found"}
  end

  test "POST /instances/:id/actions now falls through to 404" do
    id = Ecto.UUID.generate()

    conn =
      conn(:post, "/instances/#{id}/actions", Jason.encode!(%{action: "approve"}))
      |> put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == %{"error" => "not_found"}
  end

  test "GET /instances/:id now falls through to 404" do
    id = Ecto.UUID.generate()

    conn = conn(:get, "/instances/#{id}") |> call()

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == %{"error" => "not_found"}
  end

  test "an arbitrary unknown route still 404s" do
    conn = conn(:get, "/definitely/not/a/route") |> call()

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == %{"error" => "not_found"}
  end
end
