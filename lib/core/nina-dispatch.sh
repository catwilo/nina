#!/usr/bin/env bash
# noemap-dispatch -- subcommand dispatcher for noemap (noemap#502).
# Sourced modules and BASE are already exported by the caller (bin/noemap).
# Each subcommand takes the same global lock as the legacy pipeline to
# avoid races between nodes writing devices.db/registry.db from an
# isolated single-subcommand invocation (confirmed 2026-09-06).

_HOST_LIST_CACHE="$BASE/state/host_list.cache"
_STALE_CANDIDATES_CACHE="$BASE/state/stale_candidates.cache"

_dispatch_lock_wrap() {
    init_session
    trap 'release_lock; cleanup_session' EXIT
    trap 'release_lock; cleanup_session; trap - INT;  kill -INT  "$$"' INT
    trap 'release_lock; cleanup_session; trap - TERM; kill -TERM "$$"' TERM
    ensure_dirs
    acquire_lock
}

_save_host_list_cache() {
    if [ -n "${HOST_LIST:-}" ]; then
        printf '%s\n' "$HOST_LIST" > "$_HOST_LIST_CACHE"
    else
        : > "$_HOST_LIST_CACHE"
    fi
}

_load_host_list_cache() {
    if [ -s "$_HOST_LIST_CACHE" ]; then
        HOST_LIST="$(cat "$_HOST_LIST_CACHE")"
    else
        HOST_LIST=""
    fi
}

_save_stale_candidates_cache() {
    if [ -n "${_STALE_ALIAS_CANDIDATES:-}" ]; then
        printf '%s\n' $_STALE_ALIAS_CANDIDATES | tr ' ' '\n' > "$_STALE_CANDIDATES_CACHE"
    else
        : > "$_STALE_CANDIDATES_CACHE"
    fi
}

_load_stale_candidates_cache() {
    if [ -s "$_STALE_CANDIDATES_CACHE" ]; then
        _STALE_ALIAS_CANDIDATES="$(tr '\n' ' ' < "$_STALE_CANDIDATES_CACHE")"
    else
        _STALE_ALIAS_CANDIDATES=""
    fi
}

# _require_prior_step name cache_file -- if cache_file is missing/empty,
# ask interactively whether to run the named prior subcommand first.
# On "no" (or non-interactive), exit 1 without doing anything.
_require_prior_step() {
    _rp_step="$1"; _rp_cache="$2"
    [ -s "$_rp_cache" ] && return 0

    if [ ! -t 0 ]; then
        log ERROR "'$_rp_step' has not run yet (no cached state) -- non-interactive context, run: noemap $_rp_step"
        exit 1
    fi

    printf 'noemap: this step needs "%s" to have run first. Run it now? [y/N] ' "$_rp_step" >&2
    read -r _rp_ans </dev/tty || _rp_ans=""
    case "$_rp_ans" in
        [Yy]*)
            case "$_rp_step" in
                discover) _do_discover ;;
                *) log ERROR "no auto-run defined for '$_rp_step'"; exit 1 ;;
            esac
            ;;
        *)
            log INFO "aborted -- run 'noemap $_rp_step' first"
            exit 1
            ;;
    esac
}

_do_discover() {
    validate_env
    load_cache
    detect_iface
    detect_network
    discover_hosts
    _save_host_list_cache
    _save_stale_candidates_cache
    if [ -n "${HOST_LIST:-}" ]; then
        log OK "discover: $(printf '%s\n' "$HOST_LIST" | wc -l | tr -d ' ') host(s) -- cached for 'noemap fingerprint'"
    else
        log INFO "discover: no hosts found"
    fi
}

_do_self_register() {
    validate_env
    load_cache
    detect_network
    _self_register
}

_do_seed() {
    validate_env
    load_cache
    _seed_from_registry
}

_do_fingerprint() {
    validate_env
    load_cache
    detect_network
    _require_prior_step discover "$_HOST_LIST_CACHE"
    _load_host_list_cache
    _load_stale_candidates_cache
    [ -n "${HOST_LIST:-}" ] || { log INFO "no hosts to fingerprint"; return 0; }
    fingerprint_hosts
    _purge_unrescued_stale_aliases
    save_cache
    render_output
    render_active_hosts
    log OK "fingerprint complete -- run 'noemap register-new' for any unregistered hosts"
}

_do_register_new() {
    validate_env
    load_cache
    prompt_new_hosts
}

_do_bootstrap_keys() {
    validate_env
    load_cache
    ssh_key_bootstrap "$BASE/state/devices.db"
}

_do_push() {
    validate_env
    load_cache
    detect_network
    sync_devices_to_nodes
}

_do_all() {
    validate_env
    load_cache
    detect_iface
    detect_network
    discover_hosts
    [ -n "${HOST_LIST:-}" ] || {
        log WARN "no hosts found -- nothing to fingerprint"
        render_output
        render_registered_devices
        sync_devices_to_nodes
        return 0
    }
    fingerprint_hosts
    _purge_unrescued_stale_aliases
    save_cache
    render_output
    prompt_new_hosts
    render_connect
    render_active_hosts
    ssh_key_bootstrap "$BASE/state/devices.db"
    sync_devices_to_nodes
}

_dispatch_usage() {
    cat <<'USAGE'
usage: noemap <subcommand> [options]

subcommands:
  discover        find live SSH hosts on the LAN (does not touch devices.db)
  self-register   register this node's own identity in devices.db/registry.db
  seed            pull other nodes' rows from the cloud registry
  fingerprint     classify hosts found by 'discover', write hosts.db
  register-new    interactively register hosts found by 'fingerprint'
  bootstrap-keys  distribute SSH keys to registered hosts
  push            sync devices.db to all registered nodes
  all             run the full pipeline (default when no subcommand given)

options (apply to 'all' and 'discover' unless noted):
  --ports         show all probed ports per host
  -i <iface>      force network interface
  -h, --help      full usage for all tools in this suite
USAGE
}

noemap_dispatch() {
    _sub="${1:-all}"
    case "$_sub" in
        discover|self-register|seed|fingerprint|register-new|bootstrap-keys|push|all) shift || true ;;
        -h|--help) _print_help; exit 0 ;;
        *) _dispatch_usage >&2; exit 1 ;;
    esac

    NOEMAP_FULL_PORTS=0
    NOEMAP_IFACE=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --ports)    NOEMAP_FULL_PORTS=1 ;;
            -f|--fresh) ndevs --resetall ;;
            -i)         shift; [ -n "${1:-}" ] || { printf '[ERROR] -i requires an interface name\n' >&2; exit 1; }; NOEMAP_IFACE="$1" ;;
            -i*)        NOEMAP_IFACE="${1#-i}" ;;
            -h|--help)  _print_help; exit 0 ;;
            *)
                printf '[ERROR] unknown option: %s\n' "$1" >&2
                _dispatch_usage >&2
                exit 1
                ;;
        esac
        shift
    done
    export NOEMAP_FULL_PORTS
    export NOEMAP_IFACE

    _dispatch_lock_wrap
    log INFO "noemap $_sub starting (base=$BASE)"

    case "$_sub" in
        discover)       _do_discover ;;
        self-register)  _do_self_register ;;
        seed)           _do_seed ;;
        fingerprint)    _do_fingerprint ;;
        register-new)   _do_register_new ;;
        bootstrap-keys) _do_bootstrap_keys ;;
        push)           _do_push ;;
        all)            _do_all ;;
    esac

    log OK "noemap $_sub completed"
}
