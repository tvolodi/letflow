# Resolves the host port Oidcc/the dev issuer URL should use for the
# dev/test Keycloak container. Evaluated (not import_config'd) from
# config/dev.exs and config/test.exs via Code.eval_file/1, mirroring
# config/db_port.exs's shape exactly -- same precedence, same guard, same
# reason.
#
# Precedence:
#   1. LETFLOW_KEYCLOAK_PORT in the environment
#   2. LETFLOW_KEYCLOAK_PORT in the untracked .env at the project root -- the
#      same file docker compose reads for docker-compose.yml's host-port
#      mapping, so the container and the configured issuer can never drift
#      apart
#   3. 8082, the default (see docker-compose.yml's keycloak service comment
#      for why: avoids R-Co's own 8081/5432/5433)
#
# Why this exists: this repo is checked out into more than one workspace at a
# time (letflow, letflow-2, plus git worktrees), each potentially running its
# own `docker compose up`. A hardcoded host port makes the second workspace's
# container fail to bind. The port is therefore per-workspace local state and
# deliberately not committed. See config/db_port.exs (identical pattern,
# first instance) and docs/anti-patterns.md.

dotenv_port = fn ->
  path = Path.expand("../.env", __DIR__)

  with true <- File.exists?(path),
       {:ok, contents} <- File.read(path) do
    contents
    |> String.split(~r/\R/)
    |> Enum.find_value(fn line ->
      case String.split(String.trim(line), "=", parts: 2) do
        ["LETFLOW_KEYCLOAK_PORT", value] -> String.trim(value)
        _ -> nil
      end
    end)
  else
    _ -> nil
  end
end

raw = System.get_env("LETFLOW_KEYCLOAK_PORT") || dotenv_port.() || "8082"

case Integer.parse(raw) do
  {port, ""} ->
    port

  _ ->
    raise """
    LETFLOW_KEYCLOAK_PORT must be an integer TCP port, got: #{inspect(raw)}

    Set it in the environment or in the untracked .env at the project root
    (same file docker-compose.yml reads), e.g.:

        LETFLOW_KEYCLOAK_PORT=8082
    """
end
