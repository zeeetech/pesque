ARG TARGETPLATFORM

# Build stage: compiles deps and the OTP release.
FROM --platform=$TARGETPLATFORM hexpm/elixir:1.20.4-erlang-29.1.1-alpine-3.21.8 AS build

RUN apk add --no-cache build-base git

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config config
COPY priv priv
COPY lib lib
COPY rel rel

RUN mix compile
RUN mix release

# Runtime stage: the release bundles ERTS, so only C libs are needed.
FROM --platform=$TARGETPLATFORM alpine:3.21.8

RUN apk add --no-cache libstdc++ openssl ncurses-libs sqlite-libs ca-certificates gcompat

WORKDIR /app

RUN adduser -D pesque && mkdir -p /data && chown pesque:pesque /data
USER pesque

COPY --from=build --chown=pesque:pesque /app/_build/prod/rel/pesque /app
COPY --chown=pesque:pesque pesque.conf.example /app/pesque.conf.example
COPY --chown=pesque:pesque docker/healthcheck.sh /app/healthcheck.sh
RUN chmod 755 /app/healthcheck.sh /app/bin/server /app/bin/cli

ENV PDS_CONFIG=/data/pesque.conf
# The config file lives on the volume. A release refuses to boot without
# public_url, so mount one (the bundle's `init` writes the example).

VOLUME /data

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
  CMD ["/app/healthcheck.sh"]

CMD ["/app/bin/server"]
