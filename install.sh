#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$APP_DIR/docker-compose.yml}"
ENV_FILE="${ENV_FILE:-$APP_DIR/.env}"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(basename "$APP_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')}"

SUDO_CMD=()

info() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_root() {
  "${SUDO_CMD[@]}" "$@"
}

ensure_linux() {
  case "$(uname -s)" in
    Linux*) ;;
    *)
      die "This installer targets Linux/WSL. On Windows, install Docker Desktop first, then run this script inside WSL."
      ;;
  esac
}

ensure_root_runner() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO_CMD=()
    return
  fi

  if command_exists sudo; then
    SUDO_CMD=(sudo)
    return
  fi

  die "Root permission is required. Re-run as root or install sudo."
}

load_os_release() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  else
    die "Cannot detect Linux distribution because /etc/os-release is missing."
  fi
}

sync_system_clock() {
  if ! command_exists apt-get; then
    return
  fi

  info "Checking system clock before apt operations..."
  info "Current UTC time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

  if command_exists timedatectl; then
    run_root timedatectl set-ntp true >/dev/null 2>&1 ||
      warn "Could not enable NTP with timedatectl. If apt reports time errors, fix the host clock manually."
  else
    warn "timedatectl is not available. If apt reports time errors, fix the host clock manually."
  fi

  if command_exists systemctl; then
    run_root systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
    run_root systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
  elif command_exists service; then
    run_root service systemd-timesyncd restart >/dev/null 2>&1 || true
  fi

  if command_exists timedatectl; then
    local attempt
    local synced

    for attempt in $(seq 1 5); do
      synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
      if [ "$synced" = "yes" ]; then
        info "System clock is synchronized."
        return
      fi

      sleep 1
    done
  fi

  warn "System clock may not be synchronized yet. If apt fails with 'Release file ... is not valid yet', run: sudo timedatectl set-ntp true"
}

install_docker_with_apt() {
  local repo_id="${ID:-}"
  local codename="${VERSION_CODENAME:-}"

  case "$repo_id" in
    ubuntu|debian) ;;
    *)
      die "Automatic Docker install via apt supports Ubuntu/Debian only. Install Docker manually for this distro, then re-run."
      ;;
  esac

  if [ -z "$codename" ] && command_exists lsb_release; then
    codename="$(lsb_release -cs)"
  fi

  [ -n "$codename" ] || die "Cannot detect distribution codename for Docker apt repository."

  info "Installing Docker Engine and Docker Compose plugin from Docker apt repository..."
  run_root apt-get update
  run_root apt-get install -y ca-certificates curl gnupg
  run_root install -m 0755 -d /etc/apt/keyrings

  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL "https://download.docker.com/linux/$repo_id/gpg" | run_root gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    run_root chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
    "$(dpkg --print-architecture)" "$repo_id" "$codename" |
    run_root tee /etc/apt/sources.list.d/docker.list >/dev/null

  run_root apt-get update
  run_root apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_compose_with_package_manager() {
  load_os_release

  if command_exists apt-get; then
    if [ "${ID:-}" != "ubuntu" ] && [ "${ID:-}" != "debian" ]; then
      die "Docker is installed, but Compose plugin is missing. Please install docker-compose-plugin for this distro, then re-run."
    fi

    info "Installing Docker Compose plugin..."
    run_root apt-get update
    run_root apt-get install -y docker-compose-plugin
    return
  fi

  die "Docker is installed, but Compose plugin is missing and no supported package manager was detected."
}

install_docker_if_needed() {
  if command_exists docker; then
    info "Docker is already installed."
  else
    load_os_release

    if command_exists apt-get; then
      install_docker_with_apt
    else
      die "Docker is not installed. This script can auto-install Docker on Ubuntu/Debian only."
    fi
  fi

  if docker compose version >/dev/null 2>&1; then
    info "Docker Compose plugin is ready."
  else
    install_compose_with_package_manager
  fi
}

ensure_app_files() {
  info "Creating data directories..."
  mkdir -p "$APP_DIR/hermes-data" "$APP_DIR/open-webui-data"

  if [ ! -f "$ENV_FILE" ]; then
    info "Creating .env template..."
    printf 'API_SERVER_KEY=\n' >"$ENV_FILE"
  elif ! grep -q '^API_SERVER_KEY=' "$ENV_FILE"; then
    info "Adding API_SERVER_KEY to .env..."
    printf '\nAPI_SERVER_KEY=\n' >>"$ENV_FILE"
  fi

  if ! grep -Eq '^API_SERVER_KEY=.+$' "$ENV_FILE"; then
    warn "API_SERVER_KEY is empty. Please fill it in before containers start."

    if command_exists nano; then
      nano "$ENV_FILE"
    else
      warn "nano is not installed. Edit this file manually: $ENV_FILE"
    fi
  fi

  grep -Eq '^API_SERVER_KEY=.+$' "$ENV_FILE" || die "API_SERVER_KEY is still empty in $ENV_FILE"
}

start_docker_daemon() {
  if docker info >/dev/null 2>&1 || run_root docker info >/dev/null 2>&1; then
    info "Docker daemon is running."
    return
  fi

  info "Starting Docker daemon..."
  if command_exists systemctl; then
    run_root systemctl enable --now docker || true
  fi

  if ! docker info >/dev/null 2>&1 && ! run_root docker info >/dev/null 2>&1 && command_exists service; then
    run_root service docker start || true
  fi

  if docker info >/dev/null 2>&1; then
    SUDO_CMD=()
    info "Docker daemon is running."
    return
  fi

  run_root docker info >/dev/null 2>&1 || die "Docker daemon is not running. Start Docker, then re-run this script."
}

docker_cli() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    run_root docker "$@"
  fi
}

validate_compose_file() {
  [ -f "$COMPOSE_FILE" ] || die "Compose file not found: $COMPOSE_FILE"
  [ -s "$COMPOSE_FILE" ] || die "Compose file is empty: $COMPOSE_FILE"

  info "Validating Docker Compose file..."
  docker_cli compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" --project-name "$PROJECT_NAME" config >/dev/null
}

wait_for_container() {
  local container_name="$1"
  local attempt

  for attempt in $(seq 1 30); do
    if [ "$(docker_cli inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || true)" = "true" ]; then
      return 0
    fi

    sleep 2
  done

  die "Container is not running: $container_name"
}

configure_hermes_model() {
  info "Starting Hermes before model setup..."
  docker_cli compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" --project-name "$PROJECT_NAME" up -d hermes
  wait_for_container hermes

  info "Opening Hermes model setup..."
  docker_cli exec -it hermes hermes model
}

compose_up() {
  configure_hermes_model

  info "Starting containers with docker compose up -d..."
  docker_cli compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" --project-name "$PROJECT_NAME" up -d
  docker_cli compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" --project-name "$PROJECT_NAME" ps
}

main() {
  ensure_linux
  ensure_root_runner
  sync_system_clock
  ensure_app_files
  install_docker_if_needed
  start_docker_daemon
  validate_compose_file
  compose_up
}

main "$@"
