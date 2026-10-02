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

ENV PHX_SERVER=true

VOLUME /data

EXPOSE 4000

CMD ["/app/bin/pesque", "start"]
