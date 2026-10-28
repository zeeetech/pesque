#!/bin/sh
set -eu

repo=$(CDPATH='' cd -P "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "$repo/.compose-smoke.XXXXXX")
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ -n "${bundle:-}" ] && [ -f "$bundle/compose.yaml" ]; then
    if ! compose down --volumes --remove-orphans; then
      [ "$status" -ne 0 ] || status=1
    fi
  fi
  if ! rm -rf "$work"; then
    [ "$status" -ne 0 ] || status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
work=$(CDPATH='' cd -P "$work" && pwd)

run_id=${GITHUB_RUN_ID:-local}-$$
image="ghcr.io/zeeetech/pesque:ci-$run_id"
bundle=$work/pesque
mkdir -p "$bundle"

compose() {
  docker compose --project-directory "$bundle" --file "$bundle/compose.yaml" "$@"
}

docker build --tag "$image" "$repo"
sed "s/^name: pesque$/name: pesque-smoke-$run_id/; s/@VERSION@/ci-$run_id/g; s/127.0.0.1:4000:4000/127.0.0.1::4567/; s/name: pesque-data/name: pesque-smoke-data-$run_id/" \
  "$repo/deploy/compose/compose.yaml" >"$bundle/compose.yaml"
cp "$repo/deploy/compose/pesque" "$bundle/pesque"
cp "$repo/pesque.conf.example" "$bundle/pesque.conf.example"
chmod 755 "$bundle/pesque"

"$bundle/pesque" init
printf 'port = 4567\n' >>"$bundle/pesque.conf"
compose up --detach --wait --wait-timeout 60
"$bundle/pesque" config validate
"$bundle/pesque" backup

set -- "$bundle"/backups/pesque-backup-*.tar.gz
[ -f "$1" ] || { printf 'error: no host-visible backup was created\n' >&2; exit 1; }
tar -tzf "$1" >/dev/null
archive=${1##*/}

"$bundle/pesque" restore "$archive" --dry-run
if "$bundle/pesque" restore "$archive"; then
  printf 'error: restore ran while the service was active\n' >&2
  exit 1
fi
[ -n "$(compose ps --quiet pesque)" ] || {
  printf 'error: refused restore stopped the service\n' >&2
  exit 1
}

compose stop pesque
"$bundle/pesque" restore "$archive"
[ -z "$(compose ps --quiet pesque)" ] || {
  printf 'error: restore started the service\n' >&2
  exit 1
}

compose up --detach --wait --wait-timeout 60
compose stop pesque

# This refusal is expected; it must leave the stopped service stopped.
printf 'not a Pesque backup\n' >"$bundle/backups/invalid.tar.gz"
if "$bundle/pesque" restore invalid.tar.gz; then
  printf 'error: invalid restore unexpectedly succeeded\n' >&2
  exit 1
fi
[ -z "$(compose ps --quiet pesque)" ] || {
  printf 'error: refused restore started the service\n' >&2
  exit 1
}

printf 'Compose image smoke test passed\n'
