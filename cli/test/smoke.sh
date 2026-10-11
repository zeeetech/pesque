#!/bin/sh
# End-to-end smoke for the pesque CLI against a real compose stack (spec §9).
#
# Needs: docker with the compose plugin, and curl. Builds nothing: it uses the
# published image (or PESQUE_BUILD=1 to build from source first). Not run in
# CI; run it by hand from the repo root:
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
export PESQUE_HOSTNAME="${PESQUE_HOSTNAME:-localhost}"
export PDS_MODE=conformant_single

echo '==> setup'
"$cli" setup --yes

echo '==> doctor'
"$cli" doctor

echo '==> account create'
ACCOUNT_PASSWORD="${SMOKE_PASSWORD:-smoke-test-password-1}" "$cli" account create \
  --handle "alice.$PESQUE_HOSTNAME" --email alice@example.com

echo '==> account list'
"$cli" account list

echo '==> backup'
"$cli" backup --out "$work"
archive="$(ls -t "$work"/pesque-backup-*.tar.gz 2>/dev/null | head -1 || true)"
[ -n "$archive" ] || { echo "no backup archive found in $work"; exit 1; }

echo '==> restore'
"$cli" restore "$archive"

echo '==> update'
"$cli" update

echo '==> down'
"$cli" down

echo "smoke ok"
