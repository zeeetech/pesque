#!/bin/sh
# End-to-end smoke for the pesque CLI against a real docker container.
#
# Needs: docker and curl. Builds nothing: it uses the published image (point
# PESQUE_IMAGE at a locally built one to test source). This is a manual smoke,
# run by hand from the repo root; CI does not run it:
#
#   cli/test/smoke.sh
#
# The CLI creates the container itself (`pesque up`) from the settings in the
# environment below, so there is no compose file and no hand-written docker run.
set -eu

root="$(cd "$(dirname "$0")/../.." && pwd)"
cli="$root/cli/zig-out/bin/pesque"
work="$(mktemp -d)"
container="pesque-smoke-$$"
trap 'docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

command -v docker >/dev/null 2>&1 || { echo "smoke needs docker"; exit 1; }
docker info >/dev/null 2>&1 || { echo "smoke needs docker running"; exit 1; }
[ -x "$cli" ] || { echo "smoke needs the CLI built: (cd cli && zig build)"; exit 1; }

# The container the CLI manages, its data and its config all live under $work,
# so the smoke leaves nothing behind but the pulled image.
export PESQUE_BACKEND=docker
export PESQUE_CONTAINER="$container"
export PESQUE_DATA="$work/data"
export PESQUE_PUBLISH=127.0.0.1:4000:4000
mkdir -p "$work/data"

cat >"$work/pesque.conf" <<EOF
hostname = localhost
mode = single
url_scheme = http
EOF
export PESQUE_CONFIG="$work/pesque.conf"

echo '==> up'
# Creates the container (docker run -d), since none exists yet.
"$cli" up

echo '==> doctor'
# Against localhost the federation preflight is informational; the point is
# that the one-off reaches the container's data and PDS_* world.
"$cli" doctor || true

echo '==> account create'
# Prompts for the password with echo off. In single the server
# handle is the hostname, so the first account uses it.
"$cli" account create --handle localhost --email smoke@example.com

echo '==> account list'
"$cli" account list

echo '==> backup'
"$cli" backup --out "$work"
# shellcheck disable=SC2012  # the glob is ours; newest archive wins
archive="$(ls -t "$work"/pesque-backup-*.tar.gz 2>/dev/null | head -1 || true)"
[ -n "$archive" ] || { echo "no backup archive found in $work"; exit 1; }

echo '==> restore'
"$cli" restore "$archive"

echo '==> update'
"$cli" update

echo '==> down'
"$cli" down

echo "smoke ok"
