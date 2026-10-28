# Configured host-side command for the NixOS module. Systemd owns lifecycle;
# this command forwards domain work to the same image and enforces only the
# cold restore precondition.
image=@IMAGE@
container=@CONTAINER@
service=@SERVICE@
data_dir=@DATA_DIR@
config_file=@CONFIG_FILE@
backup_dir=@BACKUP_DIR@
user_spec=@USER_SPEC@
newline=$(printf '\nx')
newline=${newline%x}

die() {
  code=$1
  shift
  printf 'error: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'USAGE'
usage: pesque <command> [arguments]

  backup                            write an archive under the backup directory
  restore ARCHIVE_NAME [--dry-run]  restore cold from the backup directory
  health                            check the running container without starting it
  <domain command>                  run a command in a one-off container

Lifecycle belongs to systemd:
  sudo systemctl stop pesque
  sudo systemctl start pesque
  journalctl -u pesque -f
USAGE
}

need_docker() {
  command -v docker >/dev/null 2>&1 || die 3 "docker is required for this deployment"
  docker info >/dev/null 2>&1 || die 3 "the Docker daemon is not running"
}

run_container() {
  need_docker
  if [ -t 0 ] && [ -t 1 ]; then
    tty=-it
  else
    tty=-i
  fi
  # tty is one of the two fixed values above.
  # shellcheck disable=SC2086
  docker run --rm $tty \
    --user "$user_spec" \
    --workdir /data \
    --env PDS_CONFIG=/data/pesque.conf \
    --env PDS_DATA_DIR=/data \
    --env PDS_SERVE=false \
    --env HOME=/data \
    --volume "$data_dir:/data" \
    --volume "$config_file:/data/pesque.conf:ro" \
    --volume "$backup_dir:/backups" \
    --entrypoint /app/bin/pesque \
    "$@"
}

run_domain() {
  verb=$1
  shift

  case "$verb" in
    migrate)
      if [ "${MIGRATE_PLC_TOKEN+x}" = x ]; then
        run_container --env MIGRATE_PLC_TOKEN "$image" eval 'Pesque.Cli.main()' migrate "$@"
      else
        run_container "$image" eval 'Pesque.Cli.main()' migrate "$@"
      fi
      ;;
    account)
      if [ "${PDS_PUBLIC_IP+x}" = x ]; then
        run_container --env PDS_PUBLIC_IP "$image" eval 'Pesque.Cli.main()' account "$@"
      else
        run_container "$image" eval 'Pesque.Cli.main()' account "$@"
      fi
      ;;
    *)
      run_container "$image" eval 'Pesque.Cli.main()' "$verb" "$@"
      ;;
  esac
}

wait_healthy() {
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    if state=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null); then
      case "$state" in
        healthy) return 0 ;;
        unhealthy | none) return 1 ;;
        starting) ;;
        *) return 1 ;;
      esac
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  return 1
}

backup() {
  if [ "$#" -eq 0 ]; then
    :
  elif [ "$#" -eq 2 ] && [ "$1" = --out ] && [ "$2" = /backups ]; then
    :
  else
    die 2 "the NixOS module writes backups only to $backup_dir (container path: /backups)"
  fi

  printf 'Backups: %s on host, /backups in container\n' "$backup_dir"
  run_container "$image" eval 'Pesque.Cli.main()' backup --out /backups
}

restore() {
  if [ "$#" -eq 1 ] && { [ "$1" = --help ] || [ "$1" = -h ]; }; then
    printf 'usage: pesque restore ARCHIVE_NAME [--dry-run]\n'
    return
  fi

  dry_run=0
  case "$#" in
    1) archive=$1 ;;
    2)
      [ "$2" = --dry-run ] || die 2 "usage: pesque restore ARCHIVE_NAME [--dry-run]"
      archive=$1
      dry_run=1
      ;;
    *) die 2 "usage: pesque restore ARCHIVE_NAME [--dry-run]" ;;
  esac
  case "$archive" in
    '' | . | .. | -* | */* | *"$newline"*)
      die 2 "ARCHIVE_NAME must be a filename directly inside $backup_dir"
      ;;
  esac
  [ -f "$backup_dir/$archive" ] || die 1 "backup archive not found: $backup_dir/$archive"
  container_archive=/backups/$archive

  if [ "$dry_run" -eq 0 ] && systemctl is-active --quiet "$service"; then
    die 3 "$service is active; stop it with 'sudo systemctl stop $service' before restore"
  fi

  run_container "$image" eval 'Pesque.Cli.main()' restore "$container_archive" ||
    return $?
}

main() {
  [ "$#" -gt 0 ] || { usage; return 2; }
  command=$1
  shift

  case "$command" in
    --help | -h | help) usage ;;
    backup) backup "$@" ;;
    restore) restore "$@" ;;
    health)
      [ "$#" -eq 0 ] || die 2 "usage: pesque health"
      need_docker
      wait_healthy || die 3 "$service did not become healthy within 60 seconds"
      printf 'healthy\n'
      ;;
    *) run_domain "$command" "$@" ;;
  esac
}

main "$@"
