# ── Stage 1: Build the Elixir release ──────────────────────────────────────
# Pinned to match this project's `mix.exs` (elixir: "~> 1.14") and the
# same builder image the sibling letflow-queue repo's deploy/Dockerfile
# uses, for toolchain parity across the two deployed apps.
FROM elixir:1.17-otp-27 AS builder

ENV MIX_ENV=prod \
    LANG=C.UTF-8

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# Fetch and compile deps first so dependency changes don't bust the cache
# for every source change.
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod
RUN mix deps.compile

COPY lib lib
COPY priv priv
RUN mix compile

RUN mix release

# ── Stage 2: minimal runtime image ──────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

# openssl/libncurses/locales are the standard runtime deps for a compiled
# Erlang/OTP release; ca-certificates for outbound TLS (OIDC provider
# discovery over HTTPS once a real issuer replaces the placeholder).
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# Non-root user to run the release.
RUN groupadd --gid 1000 letflow && \
    useradd --uid 1000 --gid letflow --shell /bin/sh --create-home letflow

WORKDIR /app
RUN chown -R letflow:letflow /app

COPY --from=builder --chown=letflow:letflow /app/_build/prod/rel/letflow ./

USER letflow

# RELEASE_NAME is exported automatically by the generated bin/letflow boot
# script (standard Mix.Release behavior) — this is what
# Letflow.Application.skip_migrations?/0 checks to run Ecto.Migrator only
# inside a release, not in local `mix run`/`mix test`. Nothing to set here.

# Internal port the app listens on (hardcoded in lib/letflow/application.ex's
# Bandit child, not env-configurable today). nginx on the host reverse-proxies
# to this via the compose file's host-port binding — see
# deploy/docker-compose.*.yml and deploy/nginx/*.conf.
EXPOSE 4000

CMD ["bin/letflow", "start"]
