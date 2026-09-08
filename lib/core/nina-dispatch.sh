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

# _do_status -- top-level status listing, migrated from ndevs' _cmd_list
# (bin/ndevs, pre-fusion). Decision 2026-09-07: this is 'nina status', a
# top-level subcommand, NOT 'devices list' as originally planned in
# ARCHITECTURE-nueva.md lines 275-291 -- the doc's devices-tree entry for
# 'list' is superseded by this. Reads devices.db directly; no writes.
_do_status() {
    validate_env
    load_cache
    _db="$BASE/state/devices.db"
    if [ ! -f "$_db" ]; then
        printf '[INFO] no devices registered\n' >&2
        return 0
    fi
    if [ ! -s "$_db" ]; then
        printf '[INFO] no devices registered\n' >&2
        return 0
    fi
    _st_me="$(node_alias 2>/dev/null || printf '')"
    _st_aliases="$(awk '
        BEGIN { RS=""; FS="\n" }
        {
            for (i = 1; i <= NF; i++) {
                colon = index($i, ":")
                if (colon == 0) continue
                fk = substr($i, 1, colon - 1)
                if (fk == "alias") { print substr($i, colon + 2); break }
            }
        }
    ' "$_db" 2>/dev/null)"
    [ -n "$_st_aliases" ] || return 0
    printf '%s\n' "$_st_aliases" | while IFS= read -r _sa; do
        [ -n "$_sa" ] || continue
        _sblk="$(blockdb_get "$_db" alias "$_sa")"
        [ -n "$_sblk" ] || continue
        _sip="$(blockdb_field "$_sblk" ip)"
        _su="$(blockdb_field "$_sblk" user)"
        _sp="$(blockdb_field "$_sblk" port)"
        [ -n "$_sp" ] || _sp=22
        _splat="$(blockdb_field "$_sblk" platform)"
        [ -n "$_splat" ] || _splat="unknown"
        _snid=""
        if [ -f "$REGISTRY_DB" ]; then
            _sreg_blk="$(blockdb_get "$REGISTRY_DB" alias "$_sa")"
            [ -n "$_sreg_blk" ] && _snid="$(blockdb_field "$_sreg_blk" node_id)"
        fi
        if [ -n "$_st_me" ] && [ "$_sa" = "$_st_me" ]; then
            printf 'alias=%s ip=%s user=%s port=%s platform=%s node_id=%s -- this is the local node (%s)\n' "$_sa" "$_sip" "$_su" "$_sp" "$_splat" "${_snid:-?}" "$_splat"
        else
            printf 'alias=%s ip=%s user=%s port=%s platform=%s node_id=%s\n' "$_sa" "$_sip" "$_su" "$_sp" "$_splat" "${_snid:-?}"
        fi
    done
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

# _do_devices -- dispatcher for 'nina devices <subcommand>'
_do_devices() {
    _dev_sub="${1:-list}"
    case "$_dev_sub" in
        list|add|edit|rename|remove|update-ip|rollback|push-vpn|resetall|node-set|node-add|registry-set|hostkey-refresh) shift || true ;;
        -h|--help) _devices_usage >&2; exit 0 ;;
        *) printf '[ERROR] unknown devices subcommand: %s\n' "$_dev_sub" >&2; _devices_usage >&2; exit 1 ;;
    esac

    case "$_dev_sub" in
        list)           _devices_list "$@" ;;
        add)            _devices_add "$@" ;;
        edit)           _devices_edit "$@" ;;
        rename)         _devices_rename "$@" ;;
        remove)         _devices_remove "$@" ;;
        update-ip)      _devices_update_ip "$@" ;;
        rollback)       _devices_rollback "$@" ;;
        push-vpn)       _devices_push_vpn "$@" ;;
        resetall)       _devices_resetall "$@" ;;
        node-set)       _devices_node_set "$@" ;;
        node-add)       _devices_node_add "$@" ;;
        registry-set)   _devices_registry_set "$@" ;;
        hostkey-refresh) _devices_hostkey_refresh "$@" ;;
    esac
}

_devices_usage() {
    cat <<'USAGE'
usage: nina devices <subcommand> [options]

subcommands:
  list              show all registered devices
  add <alias> <ip> <user> [port]  register a new device
  edit <alias>      interactively edit device details
  rename <old> <new>  rename a device alias
  remove <alias>    remove device (may specify multiple)
  update-ip <alias> <newip>  update device IP and verify SSH
  rollback <alias>  restore devices.db from snapshot
  push-vpn          sync devices.db to all Tailscale nodes (100.* IPs)
  resetall          clear all devices, hosts.db, and known_hosts (requires y/N confirmation)
  node-set <alias> [user] [port] [platform]  set THIS node's identity in registry
  node-add <node-id> <alias> <user> <port> <platform>  register another node
  registry-set <node-id> <alias> [user] [port] [platform]  edit any node in registry
  hostkey-refresh   refresh SSH host keys from all devices
USAGE
}

_devices_list() {
    _db="$BASE/state/devices.db"
    if [ ! -f "$_db" ] || [ ! -s "$_db" ]; then
        printf '[INFO] no devices registered\n' >&2
        return 0
    fi
    _me="$(node_alias 2>/dev/null || printf '')"
    _aliases="$(awk '
        BEGIN { RS=""; FS="\n" }
        {
            for (i = 1; i <= NF; i++) {
                colon = index($i, ":")
                if (colon == 0) continue
                fk = substr($i, 1, colon - 1)
                if (fk == "alias") { print substr($i, colon + 2); break }
            }
        }
    ' "$_db" 2>/dev/null)"
    [ -n "$_aliases" ] || return 0
    printf '%s\n' "$_aliases" | while IFS= read -r _alias; do
        [ -n "$_alias" ] || continue
        _blk="$(blockdb_get "$_db" alias "$_alias")"
        [ -n "$_blk" ] || continue
        _ip="$(blockdb_field "$_blk" ip)"
        _user="$(blockdb_field "$_blk" user)"
        _port="$(blockdb_field "$_blk" port)"
        [ -n "$_port" ] || _port=22
        _platform="$(blockdb_field "$_blk" platform)"
        [ -n "$_platform" ] || _platform="unknown"
        _nid=""
        if [ -f "$REGISTRY_DB" ]; then
            _reg_blk="$(blockdb_get "$REGISTRY_DB" alias "$_alias")"
            [ -n "$_reg_blk" ] && _nid="$(blockdb_field "$_reg_blk" node_id)"
        fi
        if [ -n "$_me" ] && [ "$_alias" = "$_me" ]; then
            printf 'alias=%s ip=%s user=%s port=%s platform=%s node_id=%s -- this is the local node (%s)\n' "$_alias" "$_ip" "$_user" "$_port" "$_platform" "${_nid:-?}" "$_platform"
        else
            printf 'alias=%s ip=%s user=%s port=%s platform=%s node_id=%s\n' "$_alias" "$_ip" "$_user" "$_port" "$_platform" "${_nid:-?}"
        fi
    done
}

_devices_add() {
    [ $# -ge 3 ] || { printf 'usage: nina devices add <alias> <ip> <user> [port]\n' >&2; exit 1; }
    _alias="$1"; _ip="$2"; _user="$3"; _port="${4:-22}"
    _db="$BASE/state/devices.db"
    if [ -f "$_db" ] && [ -n "$(blockdb_get "$_db" alias "$_alias")" ]; then
        log ERROR "alias '$_alias' already exists — use edit or rename"; exit 1
    fi
    _snap_path="$DATA/state/snapshots/${_alias}.bak"
    mkdir -p "$DATA/state/snapshots"
    [ -f "$_db" ] && cp -f "$_db" "$_snap_path"
    _add_block="$(printf 'alias: %s\nip: %s\nuser: %s\nport: %s\nhostkey: %s\nnode_id: %s\n' "$_alias" "$_ip" "$_user" "$_port" "" "")"
    blockdb_upsert "$_db" alias "$_alias" "$_add_block"
    log OK "registered '$_alias' ip=$_ip user=$_user port=$_port"
    if reachable_ssh "$_ip" "$_port"; then
        log OK "ssh check: $_ip:$_port reachable"
    else
        log WARN "ssh check: $_ip:$_port not reachable — entry kept; rollback with: nina devices rollback $_alias"
    fi
}

_devices_edit() {
    [ $# -ge 1 ] || { printf 'usage: nina devices edit <alias>\n' >&2; exit 1; }
    _alias="$1"
    _db="$BASE/state/devices.db"
    [ -f "$_db" ] || { printf '[INFO] no devices registered\n' >&2; exit 0; }
    _row="$(blockdb_get "$_db" alias "$_alias")"
    [ -n "$_row" ] || { log ERROR "unknown alias: '$_alias'"; exit 1; }
    _cur_alias="$(blockdb_field "$_row" alias)"
    _cur_ip="$(blockdb_field "$_row" ip)"
    _cur_user="$(blockdb_field "$_row" user)"
    _cur_port="$(blockdb_field "$_row" port)"
    [ -n "$_cur_port" ] || _cur_port=22
    printf '\nEditing device: %s\n' "$_alias" >&2
    _new_alias="$(_prompt_field "alias"  "$_cur_alias")"
    _new_ip="$(_prompt_field    "ip"     "$_cur_ip")"
    _new_user="$(_prompt_field  "user"   "$_cur_user")"
    _new_port="$(_prompt_field  "port"   "$_cur_port")"
    known_hosts_sync_device "$_cur_alias" "$_cur_ip" "$_new_ip"
    _cur_hk="$(blockdb_field "$_row" hostkey)"
    _cur_nid="$(blockdb_field "$_row" node_id)"
    _new_block="$(printf 'alias: %s\nip: %s\nuser: %s\nport: %s\nhostkey: %s\nnode_id: %s\n' "$_new_alias" "$_new_ip" "$_new_user" "$_new_port" "${_cur_hk:-}" "${_cur_nid:-}")"
    if [ "$_new_alias" != "$_cur_alias" ]; then
        blockdb_remove "$_db" alias "$_cur_alias"
    fi
    blockdb_upsert "$_db" alias "$_new_alias" "$_new_block"
    log OK "updated '$_alias' → alias=$_new_alias ip=$_new_ip user=$_new_user port=$_new_port"
}

_devices_rename() {
    [ $# -ge 2 ] || { printf 'usage: nina devices rename <old> <new>\n' >&2; exit 1; }
    _old="$1"; _new="$2"
    _db="$BASE/state/devices.db"
    [ -f "$_db" ] || { printf '[INFO] no devices registered\n' >&2; exit 0; }
    [ -n "$(blockdb_get "$_db" alias "$_old")" ] || { log ERROR "unknown alias: '$_old'"; exit 1; }
    _row="$(blockdb_get "$_db" alias "$_old")"
    _new_block="$(printf '%s\n' "$_row" | awk -v na="$_new" '/^alias:/ { print "alias: " na; next } { print }')"
    blockdb_remove "$_db" alias "$_old"
    blockdb_upsert "$_db" alias "$_new" "$_new_block"
    log OK "renamed '$_old' → '$_new'"
}

_devices_remove() {
    [ $# -ge 1 ] || { printf 'usage: nina devices remove <alias> [alias...]\n' >&2; exit 1; }
    _db="$BASE/state/devices.db"
    [ -f "$_db" ] || { printf '[INFO] no devices registered\n' >&2; exit 0; }
    for _alias in "$@"; do
        _row="$(blockdb_get "$_db" alias "$_alias")"
        if [ -z "$_row" ]; then
            log WARN "unknown alias: '$_alias' — skipping"
            continue
        fi
        _ip="$(blockdb_field "$_row" ip)"
        blockdb_remove "$_db" alias "$_alias"
        known_hosts_remove_ip "$_ip"
        log OK "removed '$_alias' ($_ip) and cleaned known_hosts"
    done
}

_devices_update_ip() {
    [ $# -ge 2 ] || { printf 'usage: nina devices update-ip <alias> <newip>\n' >&2; exit 1; }
    _alias="$1"; _new_ip="$2"
    _db="$BASE/state/devices.db"
    [ -f "$_db" ] || { printf '[INFO] no devices registered\n' >&2; exit 0; }
    _row="$(blockdb_get "$_db" alias "$_alias")"
    [ -n "$_row" ] || { log ERROR "unknown alias: '$_alias'"; exit 1; }
    _old_ip="$(blockdb_field "$_row" ip)"
    _row_user="$(blockdb_field "$_row" user)"
    _row_port="$(blockdb_field "$_row" port)"
    _snap_path="$DATA/state/snapshots/${_alias}.bak"
    mkdir -p "$DATA/state/snapshots"
    [ -f "$_db" ] && cp -f "$_db" "$_snap_path"
    known_hosts_sync_device "$_alias" "$_old_ip" "$_new_ip"
    _row_hk="$(blockdb_field "$_row" hostkey)"
    _row_nid="$(blockdb_field "$_row" node_id)"
    _new_block="$(printf 'alias: %s\nip: %s\nuser: %s\nport: %s\nhostkey: %s\nnode_id: %s\n' "$_alias" "$_new_ip" "$_row_user" "$_row_port" "${_row_hk:-}" "${_row_nid:-}")"
    blockdb_upsert "$_db" alias "$_alias" "$_new_block"
    log OK "updated '$_alias': ip $_old_ip → $_new_ip"
    if reachable_ssh "$_new_ip" "$_row_port"; then
        log OK "ssh check: $_new_ip reachable"
    else
        log WARN "ssh check: $_new_ip not reachable — entry kept; rollback with: nina devices rollback $_alias"
    fi
}

_devices_rollback() {
    [ $# -ge 1 ] || { printf 'usage: nina devices rollback <alias>\n' >&2; exit 1; }
    _alias="$1"
    _db="$BASE/state/devices.db"
    _snap_path="$DATA/state/snapshots/${_alias}.bak"
    [ -f "$_snap_path" ] || { log ERROR "no snapshot for '$_alias' at $_snap_path"; exit 1; }
    cp -f "$_snap_path" "$_db"
    log OK "rolled back devices.db from snapshot '$_alias'"
}

_devices_push_vpn() {
    _db="$BASE/state/devices.db"
    [ -f "$_db" ] || { printf '[INFO] no devices registered\n' >&2; exit 0; }
    has_cmd nscp || { log ERROR "nscp not found"; exit 1; }
    _remote_path="$HOME/.local/share/noemap/state/devices.db"
    _aliases="$(awk '
        BEGIN { RS=""; FS="\n" }
        {
            for (i = 1; i <= NF; i++) {
                colon = index($i, ":")
                if (colon == 0) continue
                fk = substr($i, 1, colon - 1)
                if (fk == "alias") { print substr($i, colon + 2); break }
            }
        }
    ' "$_db" 2>/dev/null)"
    printf '%s\n' "$_aliases" | while IFS= read -r _alias; do
        [ -n "$_alias" ] || continue
        _blk="$(blockdb_get "$_db" alias "$_alias")"
        [ -n "$_blk" ] || continue
        _ip="$(blockdb_field "$_blk" ip)"
        _port="$(blockdb_field "$_blk" port)"
        [ -n "$_port" ] || _port=22
        case "$_ip" in 100.*) ;; *) continue ;; esac
        if ! reachable_ssh "$_ip" "$_port"; then
            log WARN "push to $_alias skipped (unreachable: $_ip:$_port)"
            continue
        fi
        if nscp "$_db" "${_alias}:${_remote_path}" >/dev/null 2>&1; then
            log OK "pushed devices.db -> $_alias ($_ip)"
        else
            log WARN "push to $_alias ($_ip) failed — skipped"
        fi
    done
}

_devices_resetall() {
    printf 'WARNING: this will delete ALL devices, hosts.db, and known_hosts. Continue? [y/N] ' >&2
    read -r _answer </dev/tty || _answer=""
    case "$_answer" in
        [Yy]*) ;;
        *) log INFO "aborted"; exit 0 ;;
    esac
    _db="$BASE/state/devices.db"
    rm -f "$_db" "$DATA/state/hosts.db" "$DATA/state/cache.env" "$KNOWN_HOSTS"
    : > "$_db"
    log OK "reset complete: devices.db + known_hosts + hosts.db + cache cleared"
}

_devices_node_set() {
    [ $# -ge 1 ] || { printf 'usage: nina devices node-set <alias> [user] [port] [platform]\n' >&2; exit 1; }
    _alias="$1"
    if [ -n "${2:-}" ]; then
        _user="$2"
    elif [ -t 0 ]; then
        printf '  user [u]: ' >&2
        read -r _user </dev/tty || _user=""
        [ -n "$_user" ] || _user="u"
    else
        _user="u"
    fi
    _port="${3:-8022}"
    if [ -n "${4:-}" ]; then
        _platform="$4"
    elif [ -t 0 ]; then
        printf '  platform [android]: ' >&2
        read -r _platform </dev/tty || _platform=""
        [ -n "$_platform" ] || _platform="android"
    else
        _platform="android"
    fi
    if node_alias_set "$_alias" "$_user" "$_port" "$_platform"; then
        log OK "node identity set: $_alias ($(node_id)) user=$_user port=$_port platform=$_platform"
    else
        log WARN "node identity set failed or incomplete for: $_alias -- see error above"
    fi
}

_devices_node_add() {
    [ $# -ge 5 ] || { printf 'usage: nina devices node-add <node-id> <alias> <user> <port> <platform>\n' >&2; exit 1; }
    _nid="$1"; _alias="$2"; _user="$3"; _port="$4"; _platform="$5"
    if [ -f "$REGISTRY_DB" ] && [ -n "$(blockdb_get "$REGISTRY_DB" node_id "$_nid")" ]; then
        log ERROR "node-id '$_nid' already registered -- use node-set semantics or edit"; exit 1
    fi
    if _registry_write "$_nid" "$_alias" "$_user" "$_port" "$_platform"; then
        log OK "node added: $_alias ($_nid) user=$_user port=$_port platform=$_platform"
    else
        log WARN "node add failed or incomplete for: $_alias ($_nid) -- see error above"
    fi
}

_devices_registry_set() {
    [ $# -ge 2 ] || { printf 'usage: nina devices registry-set <node-id> <alias> [user] [port] [platform]\n' >&2; exit 1; }
    _rs_nid="$1"; _rs_alias="$2"; _rs_user="${3:-u}"; _rs_port="${4:-8022}"; _rs_platform="${5:-android}"
    if _registry_write "$_rs_nid" "$_rs_alias" "$_rs_user" "$_rs_port" "$_rs_platform"; then
        log OK "registry updated: $_rs_alias ($_rs_nid) user=$_rs_user port=$_rs_port platform=$_rs_platform"
    else
        log WARN "registry update failed or incomplete for: $_rs_alias ($_rs_nid) -- see error above"
    fi
}

_devices_hostkey_refresh() {
    _db="$BASE/state/devices.db"
    [ -f "$_db" ] || { printf '[INFO] no devices registered\n' >&2; exit 0; }
    _aliases="$(awk '
        BEGIN { RS=""; FS="\n" }
        {
            for (i = 1; i <= NF; i++) {
                colon = index($i, ":")
                if (colon == 0) continue
                fk = substr($i, 1, colon - 1)
                if (fk == "alias") { print substr($i, colon + 2); break }
            }
        }
    ' "$_db" 2>/dev/null)"
    printf '%s\n' "$_aliases" | while IFS= read -r _alias; do
        [ -n "$_alias" ] || continue
        _blk="$(blockdb_get "$_db" alias "$_alias")"
        [ -n "$_blk" ] || continue
        _ip="$(blockdb_field "$_blk" ip)"
        _port="$(blockdb_field "$_blk" port)"
        [ -n "$_port" ] || _port=22
        _user="$(blockdb_field "$_blk" user)"
        if ssh-keyscan -t ed25519 -p "$_port" "$_ip" 2>/dev/null | grep -q "^$_ip"; then
            _hk="$(ssh-keyscan -t ed25519 -p "$_port" "$_ip" 2>/dev/null | sed 's/^/hostkey: /')"
            log OK "refreshed hostkey for '$_alias' ($_ip:$_port)"
        else
            log WARN "hostkey refresh failed for '$_alias' ($_ip:$_port)"
        fi
    done
}

_prompt_field() {
    _label="$1"; _current="$2"
    printf '  %s [%s]: ' "$_label" "$_current" >&2
    read -r _val </dev/tty || _val=""
    _val="$(printf '%s' "$_val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$_val" ] && printf '%s\n' "$_current" || printf '%s\n' "$_val"
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
        discover|self-register|seed|fingerprint|register-new|bootstrap-keys|push|status|devices|all) shift || true ;;
        -h|--help) _print_help; exit 0 ;;
        *) _dispatch_usage >&2; exit 1 ;;
    esac

    NOEMAP_FULL_PORTS=0
    NOEMAP_IFACE=""
    _keep_flags=1
    [ "$_sub" = devices ] && _keep_flags=0
    while [ "$_keep_flags" = 1 ] && [ $# -gt 0 ]; do
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
        status)         _do_status ;;
        devices)        _do_devices "$@" ;;
        all)            _do_all ;;
    esac

    log OK "noemap $_sub completed"
}
