defmodule Mix.Tasks.Letflow.LoginDirectory.RetireKey do
  @shortdoc "Deletes the login-directory rows of a retired pepper key id (REQ-443)"

  @moduledoc """
  Deletes every `tenant_login_directory` row carrying a retired pepper key id
  (REQ-443; decision 0043 D-C). Thin wrapper over
  `Letflow.LoginDirectory.KeyRotation.retire_key/2`.

  ## Usage

      mix letflow.login_directory.retire_key --key-id ID [--dry-run]

  `--key-id` is required (`[a-z0-9_-]`, 1..32 characters). The task refuses the
  CURRENT key id and an id with no rows, and exits non-zero on any refusal or
  failure. `--dry-run` counts what would be deleted and deletes nothing. Prints
  the key id and a row count only -- never an email, an email key or a pepper.
  Run it only after `mix letflow.backfill_login_directory` has re-keyed every
  user; see `docs/runbooks/login-directory-pepper-rotation.md`.
  """

  use Mix.Task

  alias Letflow.LoginDirectory.KeyRotation

  @impl Mix.Task
  @spec run(argv :: [String.t()]) :: :ok
  def run(argv) do
    {opts, _rest, invalid} =
      OptionParser.parse(argv, strict: [key_id: :string, dry_run: :boolean])

    key_id = Keyword.get(opts, :key_id)

    if invalid != [] or is_nil(key_id) do
      fail("usage: mix letflow.login_directory.retire_key --key-id ID [--dry-run]")
    end

    Mix.Task.run("app.start")

    case KeyRotation.retire_key(key_id, dry_run: Keyword.get(opts, :dry_run, false)) do
      {:ok, %{rows: rows, dry_run: true}} ->
        Mix.shell().info("dry run: #{rows} row(s) would be deleted for key id #{key_id}")
        :ok

      {:ok, %{rows: rows}} ->
        Mix.shell().info("retired key id #{key_id}: #{rows} row(s) deleted")
        :ok

      {:error, :invalid_key_id} ->
        fail("refused: the key id must match [a-z0-9_-]{1,32}")

      {:error, :current_key_id} ->
        fail("refused: that is the current key id")

      {:error, :not_found} ->
        fail("refused: no rows carry that key id")

      {:error, :pepper_unavailable} ->
        fail("the login directory pepper configuration is missing")

      {:error, :retire_failed} ->
        fail("the retire failed; nothing is reported beyond this")
    end
  end

  defp fail(message) do
    Mix.shell().error("login directory retire_key: #{message}")
    System.halt(1)
  end
end
