#!/bin/sh
# install.sh  nina installer (symlink model)
#
# Symlinks tools, libs, and managed config files directly from the repo
# checkout, so updates to these files (code, ssh_config) are reflected
# immediately without re-running install.sh. The repo must remain present
# at the checked-out path; deleting it will break the installation.
#
#   Termux : symlink bin/* → $PREFIX/bin, lib/* → ~/.local/share/nina/lib
#   Debian : symlink bin/* → ~/.local/bin, lib/* → ~/.local/share/nina/lib
#   config : symlink config/ssh_config → ~/.local/share/nina/config/ssh_config
#   state  : real files (devices.db, cache.env) remain in ~/.local/share/nina/state
#
# Usage:
#   sh install.sh                     -- install/update nina (idempotent)
#   sh install.sh -h | --help         -- show this help
#
# Idempotent: safe to re-run. state/devices.db stays user-owned, never overwritten.


set -eu

log()  { printf '[%s] %s\n' "$1" "$2"; }
fail() { log ERROR "$1"; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

_usage() {
    cat <<USAGE
usage: install.sh [command]

commands:
  (none)              install/update nina (idempotent, default)
  -h, --help          show this help
USAGE
}


# ---------------------------------------------------------------------------
# Top-level dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
    -h|--help)
        _usage
        exit 0
        ;;
    "")
        _do_install
        ;;
    *)
        log ERROR "unknown command: $1"
        _usage
        exit 1
        ;;
esac
