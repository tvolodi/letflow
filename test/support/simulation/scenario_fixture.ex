defmodule Letflow.Simulation.ScenarioFixture do
  @moduledoc """
  REQ-206 test-support module: YAML-file → `Letflow.Simulation.Scenario.t()` parser.

  Reads a scenario YAML file and returns a `%Letflow.Simulation.Scenario{}` struct
  with closed-vocabulary enum fields converted via a static lookup map — the same
  "no arbitrary atom creation from YAML content" discipline as
  `Letflow.Simulation.Runner`'s own `:custom` precondition registry, implemented
  here via a compile-time map rather than `String.to_existing_atom/1` (which depends
  on runtime atom-table state, fragile under lazy module loading).

  An unrecognized `via`, `severity`, `check`, or `verification.method` value raises
  `ArgumentError` at load time (closed-vocabulary fail-loud at fixture-authoring time).

  Scope: parses exactly the YAML shape authored by REQ-206's own synthetic
  fixture corpus (`test/fixtures/simulation/swiftroute/scenarios/`).
  """

  alias Letflow.Simulation.Scenario

  @via_atoms %{"api" => :api, "gui" => :gui, "skip" => :skip}
  @severity_atoms %{"MINOR" => :minor, "MAJOR" => :major, "BLOCKER" => :blocker}
  @check_atoms %{
    "process_definition_active" => :process_definition_active,
    "no_pending_instances" => :no_pending_instances,
    "custom" => :custom
  }
  @method_atoms %{
    "task_assigned" => :task_assigned,
    "instance_state" => :instance_state,
    "audit_event" => :audit_event,
    "audit_event_ordering" => :audit_event_ordering
  }

  @doc """
  Reads and parses the YAML file at `path` into a `%Scenario{}` struct.

  Raises `ArgumentError` on unrecognized `via`, `severity`, `check`, or
  `verification.method` values. All other YAML keys pass through unchanged.
  """
  @spec load!(path :: String.t()) :: Scenario.t()
  def load!(path) do
    raw = YamlElixir.read_from_file!(path)
    build_scenario(raw)
  end

  # ── struct assembly ────────────────────────────────────────────────────────

  defp build_scenario(raw) do
    %Scenario{
      id: Map.fetch!(raw, "id"),
      company_id: Map.fetch!(raw, "company_id"),
      process_id: Map.fetch!(raw, "process_id"),
      actors: Map.get(raw, "actors", %{}),
      preconditions: Enum.map(Map.get(raw, "preconditions", []), &build_precondition/1),
      steps: Enum.map(Map.get(raw, "steps", []), &build_step/1),
      expected_outcomes: Enum.map(Map.get(raw, "expected_outcomes", []), &build_outcome/1),
      unbuilt_feature: build_unbuilt_feature(Map.get(raw, "unbuilt_feature"))
    }
  end

  defp build_precondition(%{"check" => check_str} = raw) do
    check = fetch_atom!("check", check_str, @check_atoms)
    base = %{check: check}

    case Map.get(raw, "args") do
      nil -> base
      args -> Map.put(base, :args, args)
    end
  end

  defp build_step(%{"via" => via_str} = raw) do
    via = fetch_atom!("via", via_str, @via_atoms)

    step = %{
      via: via,
      action: Map.get(raw, "action", "")
    }

    step = maybe_put(step, :params, Map.get(raw, "params"))
    step = maybe_put(step, :produces, Map.get(raw, "produces"))
    step = maybe_put(step, :actor, Map.get(raw, "actor"))
    step = maybe_put(step, :note, Map.get(raw, "note"))

    case Map.get(raw, "severity") do
      nil ->
        step

      sev_str ->
        sev = fetch_atom!("severity", sev_str, @severity_atoms)
        Map.put(step, :severity, sev)
    end
  end

  defp build_outcome(%{"verification" => %{"method" => method_str, "args" => args}}) do
    method = fetch_atom!("verification.method", method_str, @method_atoms)
    %{verification: %{method: method, args: args}}
  end

  defp build_unbuilt_feature(nil), do: nil
  defp build_unbuilt_feature(%{"reason" => reason}), do: %{reason: reason}
  defp build_unbuilt_feature(val) when is_binary(val), do: %{reason: val}

  # ── helpers ────────────────────────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch_atom!(field, value, lookup_map) do
    case Map.fetch(lookup_map, value) do
      {:ok, atom} ->
        atom

      :error ->
        raise ArgumentError,
              "unrecognized value for #{field}: #{inspect(value)} " <>
                "(expected one of: #{Enum.join(Map.keys(lookup_map), ", ")})"
    end
  end
end
