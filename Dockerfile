# Build stage: compiles deps and the OTP release.
FROM hexpm/elixir:1.20.4-erlang-29.1.1-alpine-3.21.8 AS build

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

RUN mix compile
RUN mix release

# Runtime stage: the release bundles ERTS, so only C libs are needed.
FROM alpine:3.21.8

RUN apk add --no-cache libstdc++ openssl ncurses-libs sqlite-libs ca-certificates

WORKDIR /app

RUN adduser -D pesque && mkdir -p /data && chown pesque:pesque /data
USER pesque

COPY --from=build --chown=pesque:pesque /app/_build/prod/rel/pesque ./
COPY --chown=pesque:pesque pesque.conf.example /app/pesque.conf.example

ENV PDS_DATA_DIR=/data
ENV PDS_PORT=4000
# The config file lives on the volume, so mounting one file configures the
# container. Missing is fine: everything can come from the environment.
ENV PDS_CONFIG=/data/pesque.conf

VOLUME /data

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -q -O /dev/null "http://localhost:${PDS_PORT:-4000}/xrpc/_health" || exit 1

CMD ["/app/bin/pesque", "start"]
