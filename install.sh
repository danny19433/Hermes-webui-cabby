#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$APP_DIR/docker-compose.yml}"
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
  docker_cli compose -f "$COMPOSE_FILE" --project-name "$PROJECT_NAME" config >/dev/null
}

compose_up() {
  info "Starting containers with docker compose up -d..."
  docker_cli compose -f "$COMPOSE_FILE" --project-name "$PROJECT_NAME" up -d
  docker_cli compose -f "$COMPOSE_FILE" --project-name "$PROJECT_NAME" ps
}

main() {
  ensure_linux
  ensure_root_runner
  install_docker_if_needed
  start_docker_daemon
  validate_compose_file
  compose_up
}

main "$@"
