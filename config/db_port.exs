# Resolves the host port Ecto should use for the dev/test PostgreSQL
# container. Evaluated (not import_config'd) from config/dev.exs and
# config/test.exs via Code.eval_file/1 — `import_config` merges config keys
# and cannot return a value, and a plain module here would be recompiled into
# the release, so eval is the fitting tool.
#
# Precedence:
#   1. LETFLOW_DB_PORT in the environment
#   2. LETFLOW_DB_PORT in the untracked .env at the project root — the same
#      file docker compose reads for docker-compose.yml's host-port mapping,
#      so the container and Ecto can never drift apart
#   3. 5462, the original single-workspace default
#
# Why this exists: this repo is checked out into more than one workspace at a
# time (letflow, letflow-2, plus git worktrees), each running its own
# `docker compose up`. A hardcoded host port makes the second workspace's
# container fail to bind. The port is therefore per-workspace local state and
# deliberately not committed. See docs/anti-patterns.md.

dotenv_port = fn ->
  path = Path.expand("../.env", __DIR__)

  with true <- File.exists?(path),
       {:ok, contents} <- File.read(path) do
    contents
    |> String.split(~r/\R/)
    |> Enum.find_value(fn line ->
      case String.split(String.trim(line), "=", parts: 2) do
        ["LETFLOW_DB_PORT", value] -> String.trim(value)
        _ -> nil
      end
    end)
  else
    _ -> nil
  end
end

raw = System.get_env("LETFLOW_DB_PORT") || dotenv_port.() || "5462"

case Integer.parse(raw) do
  {port, ""} ->
    port

  _ ->
    raise """
    LETFLOW_DB_PORT must be an integer TCP port, got: #{inspect(raw)}

    Set it in the environment or in the untracked .env at the project root
    (same file docker-compose.yml reads), e.g.:

        LETFLOW_DB_PORT=5472
    """
end
