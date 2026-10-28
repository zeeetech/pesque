#!/bin/sh
set -eu

# Release eval loads runtime config but does not start the app, so the probe
# uses the same resolved port without triggering migrations or job recovery.
resolved=$(
  /app/bin/pesque eval \
    'IO.write("PESQUE_HEALTH_PORT=" <> to_string(Application.fetch_env!(:pesque, :port)))'
)
port=$(printf '%s\n' "$resolved" | sed -n 's/^PESQUE_HEALTH_PORT=//p' | tail -n 1)
case "$port" in
  '' | *[!0-9]*) exit 1 ;;
esac

exec wget -q -O /dev/null "http://127.0.0.1:$port/xrpc/_health"
