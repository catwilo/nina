#!/bin/sh
# dispatch.sh -- top-level subcommand router (nina).

_dispatch_lock_wrap() {
    init_session
    trap 'release_lock; cleanup_session' EXIT
    trap 'release_lock; cleanup_session; trap - INT;  kill -INT  "$$"' INT
    trap 'release_lock; cleanup_session; trap - TERM; kill -TERM "$$"' TERM
    ensure_dirs
    acquire_lock
}

_dispatch_usage() {
    cat <<USAGE
usage: nina <subcommand> [options]

subcommands:
  self-register   register this node identity in ts-devices.db/registry.db
  seed            pull other nodes rows from the cloud registry
  bootstrap-keys  distribute SSH keys to registered peers
  push            sync ts-devices.db to all registered peers
  status          list devices and mark the local node
  devices         manage registered devices
  clip            clipboard forwarding
  all             run the full pipeline (default)

options:
  -h, --help      show this help
USAGE
}

nina_dispatch() {
    _sub="${1:-all}"
    case "$_sub" in
        self-register|seed|bootstrap-keys|push|status|devices|clip|all) shift || true ;;
        -h|--help) _print_help; exit 0 ;;
        *) _dispatch_usage >&2; exit 1 ;;
    esac

    _dispatch_lock_wrap
    log INFO "nina $_sub starting (base=$BASE)"

    case "$_sub" in
        self-register)  _do_self_register ;;
        seed)           _do_seed ;;
        bootstrap-keys) _do_bootstrap_keys ;;
        push)           _do_push ;;
        status)         _do_status ;;
        devices)        _do_devices "$@" ;;
        clip)           _do_clip "$@" ;;
        all)            _do_all ;;
    esac

    log OK "nina $_sub completed"
}
