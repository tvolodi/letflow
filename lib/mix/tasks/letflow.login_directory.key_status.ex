defmodule Mix.Tasks.Letflow.LoginDirectory.KeyStatus do
  @shortdoc "Prints per-key-id row counts of the platform tenant-login directory (REQ-443)"

  @moduledoc """
  Prints how many `tenant_login_directory` rows carry each pepper key id
  (REQ-443; decision 0043 D-C). Thin wrapper over
  `Letflow.LoginDirectory.KeyRotation.key_status/0`.

  ## Usage

      mix letflow.login_directory.key_status

  Output is key ids and counts only -- never an email, an email key or a pepper.
  The configured current id (and previous id, if any) is marked. Exits non-zero
  on failure. See `docs/runbooks/login-directory-pepper-rotation.md`.
  """

  use Mix.Task

  alias Letflow.LoginDirectory
  alias Letflow.LoginDirectory.KeyRotation

  @impl Mix.Task
  @spec run(argv :: [String.t()]) :: :ok
  def run(_argv) do
    Mix.Task.run("app.start")

    case KeyRotation.key_status() do
      {:ok, rows} ->
        current = current_id()
        previous = previous_id()

        Enum.each(rows, fn {key_id, count} ->
          Mix.shell().info("key id #{key_id}: rows=#{count}#{marker(key_id, current, previous)}")
        end)

        Mix.shell().info("login directory key status: #{length(rows)} key id(s) present")
        :ok

      {:error, :status_failed} ->
        Mix.shell().error("login directory key status: the query failed")
        System.halt(1)
    end
  end

  defp marker(id, id, _previous), do: " (current)"
  defp marker(id, _current, id), do: " (previous)"
  defp marker(_id, _current, _previous), do: ""

  defp current_id do
    case LoginDirectory.current_key_id() do
      {:ok, id} -> id
      _unavailable -> nil
    end
  end

  # Label only; the pepper is never read here.
  defp previous_id do
    with {:ok, keys} <- Application.fetch_env(:letflow, :login_directory_keys),
         %{id: id} when is_binary(id) <- Keyword.get(keys, :previous) do
      id
    else
      _none -> nil
    end
  end
end
