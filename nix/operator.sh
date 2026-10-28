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

require_mount() {
  mountpoint -q "$1" || die 3 "required mount is not available: $1"
}

require_storage() {
  :
@STORAGE_CHECKS@
}

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

docker_run() {
  if [ -t 0 ] && [ -t 1 ]; then
    set -- -it "$@"
  else
    set -- -i "$@"
  fi
  docker run --rm "$@"
}

run_container() {
  need_docker
  require_storage
  docker_run \
    --user "$user_spec" \
    --workdir /data \
    --env PDS_CONFIG=/data/pesque.conf \
    --env HOME=/data \
    --mount "type=bind,source=$data_dir,target=/data" \
    --mount "type=bind,source=$config_file,target=/data/pesque.conf,readonly" \
    --mount "type=bind,source=$backup_dir,target=/backups" \
    --entrypoint /app/bin/cli \
    "$@"
}

run_domain() {
  verb=$1
  shift

  case "$verb" in
    migrate)
      if [ "${MIGRATE_PLC_TOKEN+x}" = x ]; then
        run_container --env MIGRATE_PLC_TOKEN "$image" migrate "$@"
      else
        run_container "$image" migrate "$@"
      fi
      ;;
    account)
      run_container "$image" account "$@"
      ;;
    *)
      run_container "$image" "$verb" "$@"
      ;;
  esac
}

check_health() {
  if ! state=$(docker inspect --format '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null); then
    return 1
  fi
  [ "$state" = "true healthy" ]
}

assert_stopped() {
  need_docker
  if ! state=$(systemctl show --property=ActiveState --value "$service"); then
    die 3 "could not query $service state; restore was not run"
  fi
  [ "$state" = inactive ] ||
    die 3 "$service is $state; stop it with 'sudo systemctl stop $service' before restore"

  if ! running=$(docker ps --quiet --filter "name=^/${container}$"); then
    die 3 "could not query the service container; restore was not run"
  fi
  [ -z "$running" ] || die 3 "the service container is running; restore was not run"
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
  run_container "$image" backup --out /backups
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

  if [ "$dry_run" -eq 0 ]; then
    assert_stopped
    run_container "$image" restore "$container_archive" ||
      return $?
  else
    run_container "$image" restore --dry-run "$container_archive" ||
      return $?
  fi
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
      check_health || die 3 "$service is not running and healthy"
      printf 'healthy\n'
      ;;
    *) run_domain "$command" "$@" ;;
  esac
}

main "$@"
