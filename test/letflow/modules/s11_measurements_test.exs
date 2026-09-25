defmodule Letflow.Modules.S11MeasurementsTest do
  use ExUnit.Case, async: true

  @authorization_file Path.expand("../../../lib/letflow/api/authorization.ex", __DIR__)
  @exam_atoms [
    :ExamSessionStart,
    :ExamSessionRead,
    :ExamSessionSave,
    :ExamSessionSubmit,
    :ExamSessionReportEvent,
    :ExamCertificateIssue
  ]

  test "REQ-408 measurement 2: the six exam permission atoms moved out of core authorization" do
    auth_ast =
      @authorization_file
      |> File.read!()
      |> Code.string_to_quoted!()

    atoms = collect_atoms(auth_ast)

    for atom <- @exam_atoms do
      refute atom in atoms,
             "expected #{inspect(atom)} to be absent from core authorization AST outside @moduledoc/@doc"
    end
  end

  defp collect_atoms(ast) do
    case ast do
      {:@, _, [{kind, _, _}]} when kind in [:moduledoc, :doc] -> []
      {:@, _, [{kind, _, _} | _]} when kind in [:moduledoc, :doc] -> []
      {:@, _, _} -> []
      list when is_list(list) -> Enum.flat_map(list, &collect_atoms/1)
      tuple when is_tuple(tuple) -> tuple |> Tuple.to_list() |> Enum.flat_map(&collect_atoms/1)
      atom when is_atom(atom) -> [atom]
      _ -> []
    end
  end
end
