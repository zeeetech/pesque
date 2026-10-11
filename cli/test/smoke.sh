#!/bin/sh
# End-to-end smoke for the pesque CLI against a real compose stack.
#
# Needs: docker with the compose plugin, and curl. Builds nothing: it uses the
# published image (or PESQUE_BUILD=1 to build from source first). This is a
# manual smoke, run by hand from the repo root; CI does not run it:
#
#   cli/test/smoke.sh
#
set -eu

root="$(cd "$(dirname "$0")/../.." && pwd)"
cli="$root/cli/zig-out/bin/pesque"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

command -v docker >/dev/null 2>&1 || { echo "smoke needs docker"; exit 1; }
docker info >/dev/null 2>&1 || { echo "smoke needs docker running"; exit 1; }
[ -x "$cli" ] || { echo "smoke needs the CLI built: (cd cli && zig build)"; exit 1; }

# A scratch install dir: the compose files come from the repo, the state (.env,
# backup archives) stays in $work.
cp "$root/docker-compose.yml" "$work/"
[ -f "$root/docker-compose.build.yml" ] && cp "$root/docker-compose.build.yml" "$work/"
cp "$root/Caddyfile" "$work/"
cd "$work"

export PESQUE_ROOT="$work"
# The CLI reads the hostname and mode from PDS_HOSTNAME / PDS_MODE.
export PDS_HOSTNAME="${PDS_HOSTNAME:-localhost}"
export PDS_MODE=conformant_single

echo '==> setup'
# setup creates the first account, which is the domain handle in this mode;
# its email is prompted (by hand), the password comes from the environment.
ACCOUNT_PASSWORD="${SMOKE_PASSWORD:-smoke-test-password-1}" "$cli" --yes setup

echo '==> doctor'
"$cli" doctor

echo '==> account list'
# No separate `account create` here: in conformant_single the handle under
# this server is exactly the one setup just created, so a second create with
# it is refused.
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
