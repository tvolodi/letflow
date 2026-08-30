defmodule Letflow.Plugs.HttpMetrics do
  @moduledoc """
  REQ-194 (design `lib/letflow/design/req194-prometheus-metrics.md` §4) --
  request/error instrumentation for `letflow_http_requests_total`/
  `letflow_http_errors_total` (OBS-02 families 5/6).

  Mounted on `Letflow.Router` directly (ahead of `plug(:match)`/`plug(:dispatch)`,
  alongside `Letflow.Plugs.Cors`), so it observes every request Letflow serves except
  `GET /metrics` itself -- scraping `/metrics` is deliberately excluded from its own
  request-count series (a well-known Prometheus self-observation anti-pattern this
  design avoids, design §2).

  `call/2` records `System.monotonic_time/0` on entry, then registers a
  `Plug.Conn.register_before_send/2` callback that runs once dispatch has fully
  resolved (including inside a `forward`-ed sub-router), reads the final
  `conn.status` and `Plug.Router.match_path/1`'s fully-composed route template, and
  calls `:telemetry.execute/3`.

  ## Route-template normalization (design §2)

  `Plug.Router.match_path/1` returns the literal, compile-time path template
  recorded in `conn.private[:plug_route]` at the point each nested router's own
  `:match` plug ran -- `Plug.Router`'s own `append_match_path/2` means a route
  matched inside a `forward`-ed sub-router already comes back fully composed with its
  parent's mount prefix (e.g. `"/api/v1/instances/:id"`), never a bare fragment and
  never the literal request path. Two requests to the same route with different path
  parameters therefore collapse to the exact same `route_template` label value
  structurally, not by a best-effort string transform -- this is what keeps
  cardinality bounded. When no route matched at all, the label falls back to the
  literal constant `"unmatched"`, never the raw unmatched path (which would be
  attacker/client-controlled and unbounded cardinality).

  **Correction to design §2's stated mechanism, verified against real `Plug.Router`
  source rather than assumed (flagged for REVIEWER):** `conn.private[:plug_route]` is
  actually set for EVERY match clause, including a router's own `match _` catch-all
  -- `Plug.Router.__route__/4`'s `extract_path/1` rewrites a bare `_` pattern to the
  literal path `"/*_path"` before it is ever recorded (verified at
  `deps/plug/lib/plug/router.ex:663`), so `Map.has_key?(conn.private, :plug_route)`
  is `true` even on a 404 from a router's own catch-all, and `Plug.Router.match_path/1`
  returns `"/*_path"` (or, nested inside a `forward`, a composed value like
  `"/api/v1/*_path"`) rather than raising. The cardinality-safety property design §2
  wants -- a single, bounded value for every genuinely unmatched request, never the
  raw path -- still holds either way, so this module detects the `"/*_path"` wildcard
  suffix explicitly (at any nesting depth) and maps it to the same literal
  `"unmatched"` constant the design specifies, in addition to the (currently
  unreachable via `Letflow.Router`'s own structure, but kept as a defensive fallback)
  case where `:plug_route` is genuinely absent.

  ## Coupling surface (AC8)

  This is the ONLY call site referencing the `[:letflow, :http, :request]` event name
  and the ONLY module coupling HTTP transport concerns to `:telemetry` -- it never
  references `Letflow.Metrics.Registry` directly:

      grep -rn "Letflow.Metrics.Registry" lib/letflow/plugs/http_metrics.ex
      # -> zero hits
  """

  @behaviour Plug

  @excluded_path_info ["metrics"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: @excluded_path_info} = conn, _opts), do: conn

  def call(conn, _opts) do
    start = System.monotonic_time()

    Plug.Conn.register_before_send(conn, fn conn ->
      route_template = resolve_route_template(conn)
      duration = System.monotonic_time() - start

      :telemetry.execute(
        [:letflow, :http, :request],
        %{duration: duration},
        %{method: conn.method, route_template: route_template, status: conn.status}
      )

      conn
    end)
  end

  # See moduledoc's "Correction to design §2's stated mechanism" section -- both
  # branches collapse to the design's own literal "unmatched" constant, never a raw
  # unbounded path.
  defp resolve_route_template(conn) do
    if Map.has_key?(conn.private, :plug_route) do
      template = Plug.Router.match_path(conn)
      if String.ends_with?(template, "/*_path"), do: "unmatched", else: template
    else
      "unmatched"
    end
  end
end
