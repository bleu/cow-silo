#!/usr/bin/env bash
set -euo pipefail

readonly revision="233c400c446c0d3c6f7a898892332818296b6053"
readonly repository="https://github.com/cowdao-grants/offline-mode.git"
readonly project_root="$(git rev-parse --show-toplevel)"
readonly offline_root="${COW_SILO_OFFLINE_DIR:-${project_root}/.cache/cow-offline}"

require_checkout() {
  if [[ ! -d "${offline_root}/.git" ]]; then
    echo "Run '$0 bootstrap' first." >&2
    exit 1
  fi
}

case "${1:-}" in
  bootstrap)
    if [[ ! -d "${offline_root}/.git" ]]; then
      mkdir -p "$(dirname "${offline_root}")"
      git clone --recurse-submodules "${repository}" "${offline_root}"
    fi
    git -C "${offline_root}" fetch origin "${revision}"
    git -C "${offline_root}" checkout --detach "${revision}"
    git -C "${offline_root}" submodule update --init --recursive
    npm --prefix "${offline_root}" install
    ;;
  up)
    require_checkout
    docker compose --project-directory "${offline_root}" up -d
    ;;
  down)
    require_checkout
    docker compose --project-directory "${offline_root}" down
    ;;
  status)
    require_checkout
    docker compose --project-directory "${offline_root}" ps
    ;;
  logs)
    require_checkout
    docker compose --project-directory "${offline_root}" logs -f "${2:-driver}"
    ;;
  *)
    echo "Usage: $0 {bootstrap|up|down|status|logs [service]}" >&2
    exit 2
    ;;
esac
