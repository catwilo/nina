#!/bin/sh
# devices.sh -- nina devices subcommand (tailscale-only).

_do_devices() {
    _dev_sub="${1:-list}"
    case "$_dev_sub" in
        list|add|edit|rename|remove|update-ip|refresh-ips|rollback|push-vpn|resetall|node-set|node-add|registry-set|hostkey-refresh) shift || true ;;
        -h|--help) _devices_usage >&2; exit 0 ;;
        *) printf '[ERROR] unknown devices subcommand: %s\n' "$_dev_sub" >&2; _devices_usage >&2; exit 1 ;;
    esac
    case "$_dev_sub" in
        list)            _devices_list "$@" ;;
        add)             _devices_add "$@" ;;
        edit)            _devices_edit "$@" ;;
        rename)          _devices_rename "$@" ;;
        remove)          _devices_remove "$@" ;;
        update-ip)       _devices_update_ip "$@" ;;
        refresh-ips)     _devices_refresh_ips ;;
        rollback)        _devices_rollback "$@" ;;
        push-vpn)        _devices_push_vpn ;;
        resetall)        _devices_resetall ;;
        node-set)        _devices_node_set "$@" ;;
        node-add)        _devices_node_add "$@" ;;
        registry-set)    _devices_registry_set "$@" ;;
        hostkey-refresh) _devices_hostkey_refresh ;;
    esac
}

_devices_usage() {
    cat <<'USAGE'
usage: nina devices <subcommand> [options]

subcommands:
  list              show all registered devices (ts-devices.db)
  add <alias> <ip> <user> [port]  register a device manually
  edit <alias>      interactively edit device details
  rename <old> <new>  rename a device alias
  remove <alias> [alias...]  remove devices
  update-ip <alias> <ip>  set a device IP
  refresh-ips       refresh local IP from tun0; peers from tailscale CLI if present
  rollback <alias>  restore ts-devices.db from snapshot
  push-vpn          sync ts-devices.db to all peers
  resetall          wipe ts-devices.db + known_hosts (requires y/N)
  node-set <alias> [user] [port] [platform]  set THIS node identity
  node-add <node-id> <alias> <user> <port> <platform>  register another node
  registry-set <node-id> <alias> [user] [port] [platform]  edit any node
  hostkey-refresh   refresh SSH host keys from all devices
USAGE
}

_devices_list() {
    _db="$BASE/state/ts-devices.db"
    [ -f "$_db" ] && [ -s "$_db" ] || { printf '[INFO] no devices registered\n' >&2; return 0; }
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
        [ -n "$_port" ] || _port=8022
        _platform="$(blockdb_field "$_blk" platform)"
        [ -n "$_platform" ] || _platform="unknown"
        _nid="$(blockdb_field "$_blk" node_id)"
        _marker=""
        [ -n "$_me" ] && [ "$_alias" = "$_me" ] && _marker=" -- this is the local node"
        printf 'alias=%s ip=%s user=%s port=%s platform=%s node_id=%s%s\n' "$_alias" "$_ip" "$_user" "$_port" "$_platform" "${_nid:-?}" "$_marker"
    done
}

_devices_add() {
    [ $# -ge 3 ] || { printf 'usage: nina devices add <alias> <ip> <user> [port]\n' >&2; exit 1; }
    _alias="$1"; _ip="$2"; _user="$3"; _port="${4:-8022}"
    _db="$BASE/state/ts-devices.db"
    if [ -f "$_db" ] && [ -n "$(blockdb_get "$_db" alias "$_alias")" ]; then
        log ERROR "alias '$_alias' already exists -- use edit or rename"; exit 1
    fi
    _snap_path="$BASE/state/snapshots/${_alias}.bak"
    mkdir -p "$BASE/state/snapshots"
    [ -f "$_db" ] && cp -f "$_db" "$_snap_path"
    _new="$(printf 'alias: %s\nip: %s\nuser: %s\nport: %s\nplatform: android\nhostkey: %s\nnode_id: %s\n' "$_alias" "$_ip" "$_user" "$_port" "" "")"
    blockdb_upsert "$_db" alias "$_alias" "$_new"
    log OK "registered '$_alias' ip=$_ip user=$_user port=$_port"
    if reachable_ssh "$_ip" "$_port"; then
        log OK "ssh check: $_ip:$_port reachable"
    else
        log WARN "ssh check: $_ip:$_port not reachable"
    fi
}

_devices_edit() {
    [ $# -ge 1 ] || { printf 'usage: nina devices edit <alias>\n' >&2; exit 1; }
    _alias="$1"
    _db="$BASE/state/ts-devices.db"
    [ -f "$_db" ] || { printf '[INFO] no devices registered\n' >&2; exit 0; }
    _row="$(blockdb_get "$_db" alias "$_alias")"
    [ -n "$_row" ] || { log ERROR "unknown alias: '$_alias'"; exit 1; }
    _cur_alias="$(blockdb_field "$_row" alias)"
    _cur_ip="$(blockdb_field "$_row" ip)"
    _cur_user="$(blockdb_field "$_row" user)"
    _cur_port="$(blockdb_field "$_row" port)"
    [ -n "$_cur_port" ] || _cur_port=8022
    printf '\nEditing device: %s\n' "$_alias" >&2
    _new_alias="$(_prompt_field "alias" "$_cur_alias")"
    _new_ip="$(_prompt_field "ip" "$_cur_ip")"
    _new_user="$(_prompt_field "user" "$_cur_user")"
    _new_port="$(_prompt_field "port" "$_cur_port")"
    _cur_hk="$(blockdb_field "$_row" hostkey)"
    _cur_nid="$(blockdb_field "$_row" node_id)"
    _cur_plat="$(blockdb_field "$_row" platform)"; _cur_plat="${_cur_plat:-android}"
    _new="$(printf 'alias: %s\nip: %s\nuser: %s\nport: %s\nplatform: %s\nhostkey: %s\nnode_id: %s\n' "$_new_alias" "$_new_ip" "$_new_user" "$_new_port" "$_cur_plat" "${_cur_hk:-}" "${_cur_nid:-}")"
    [ "$_new_alias" != "$_cur_alias" ] && blockdb_remove "$_db" alias "$_cur_alias"
    blockdb_upsert "$_db" alias "$_new_alias" "$_new"
    log OK "updated '$_alias' -> alias=$_new_alias ip=$_new_ip"
}

_devices_rename() {
    [ $# -ge 2 ] || { printf 'usage: nina devices rename <old> <new>\n' >&2; exit 1; }
    _old="$1"; _new="$2"
    _db="$BASE/state/ts-devices.db"
    [ -f "$_db" ] || { printf '[INFO] no devices registered\n' >&2; exit 0; }
    [ -n "$(blockdb_get "$_db" alias "$_old")" ] || { log ERROR "unknown alias: '$_old'"; exit 1; }
    _row="$(blockdb_get "$_db" alias "$_old")"
    _new_block="$(printf '%s\n' "$_row" | awk -v na="$_new" '/^alias:/ { print "alias: " na; next } { print }')"
    blockdb_remove "$_db" alias "$_old"
    blockdb_upsert "$_db" alias "$_new" "$_new_block"
    log OK "renamed '$_old' -> '$_new'"
}

_devices_remove() {
    [ $# -ge 1 ] || { printf 'usage: nina devices remove <alias> [alias...]\n' >&2; exit 1; }
    _db="$BASE/state/ts-devices.db"
    [ -f "$_db" ] || { printf '[INFO] no devices registered\n' >&2; exit 0; }
    for _alias in "$@"; do
        _row="$(blockdb_get "$_db" alias "$_alias")"
        if [ -z "$_row" ]; then
            log WARN "unknown alias: '$_alias' -- skipping"
            continue
        fi
        _ip="$(blockdb_field "$_row" ip)"
        blockdb_remove "$_db" alias "$_alias"
        [ -n "$_ip" ] && known_hosts_remove_ip "$_ip"
        log OK "removed '$_alias'"
    done
}

_devices_update_ip() {
    [ $# -ge 2 ] || { printf 'usage: nina devices update-ip <alias> <newip>\n' >&2; exit 1; }
    _alias="$1"; _new_ip="$2"
    _db="$BASE/state/ts-devices.db"
    [ -f "$_db" ] || { printf '[INFO] no devices registered\n' >&2; exit 0; }
    _row="$(blockdb_get "$_db" alias "$_alias")"
    [ -n "$_row" ] || { log ERROR "unknown alias: '$_alias'"; exit 1; }
    _old_ip="$(blockdb_field "$_row" ip)"
    known_hosts_sync_device "$_alias" "$_old_ip" "$_new_ip"
    _new="$(printf '%s\n' "$_row" | awk -v nip="$_new_ip" '/^ip:/ { print "ip: " nip; next } { print }')"
    blockdb_upsert "$_db" alias "$_alias" "$_new"
    log OK "updated '$_alias': ip $_old_ip -> $_new_ip"
}

_devices_refresh_ips() {
    _db="$BASE/state/ts-devices.db"
    [ -f "$_db" ] && [ -s "$_db" ] || { log WARN "no ts-devices.db -- nothing to refresh"; return 0; }

    _my_nid="$(node_id)"
    _my_ip="$(detect_tailscale_ip 2>/dev/null || true)"

    if [ -n "$_my_ip" ]; then
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
        ' "$_db")"
        printf '%s\n' "$_aliases" | while IFS= read -r _alias; do
            [ -n "$_alias" ] || continue
            _blk="$(blockdb_get "$_db" alias "$_alias")"
            [ -n "$_blk" ] || continue
            _blk_nid="$(blockdb_field "$_blk" node_id)"
            [ "$_blk_nid" = "$_my_nid" ] || continue
            _new="$(printf '%s\n' "$_blk" | awk -v nip="$_my_ip" '/^ip:/ { print "ip: " nip; next } { print }')"
            blockdb_upsert "$_db" alias "$_alias" "$_new"
            log OK "refresh $_alias (local): ip -> $_my_ip"
        done
    else
        log WARN "no tailscale IP on tun0 -- local row not updated"
    fi

    has_cmd tailscale || { log INFO "tailscale CLI not available -- peer IPs unchanged"; return 0; }
    has_cmd jq || { log WARN "jq missing -- peer refresh skipped"; return 0; }

    _ts_json="$(tailscale status --json 2>/dev/null)"
    [ -n "$_ts_json" ] || { log WARN "tailscale status --json empty"; return 0; }

    awk '
        BEGIN { RS=""; FS="\n" }
        {
            for (i = 1; i <= NF; i++) {
                colon = index($i, ":")
                if (colon == 0) continue
                fk = substr($i, 1, colon - 1)
                if (fk == "alias") { print substr($i, colon + 2); break }
            }
        }
    ' "$_db" | while IFS= read -r _alias; do
        [ -n "$_alias" ] || continue
        _blk="$(blockdb_get "$_db" alias "$_alias")"
        [ -n "$_blk" ] || continue
        _blk_nid="$(blockdb_field "$_blk" node_id)"
        [ "$_blk_nid" = "$_my_nid" ] && continue
        _ip="$(printf '%s' "$_ts_json" | jq -r --arg h "$_alias" '.Peer // {} | to_entries[] | .value | select(.HostName == $h) | .TailscaleIPs[0] // empty' 2>/dev/null | head -1)"
        if [ -z "$_ip" ] || [ "$_ip" = "null" ]; then
            log WARN "refresh $_alias: not in tailscale status"
            continue
        fi
        _new="$(printf '%s\n' "$_blk" | awk -v nip="$_ip" '/^ip:/ { print "ip: " nip; next } { print }')"
        blockdb_upsert "$_db" alias "$_alias" "$_new"
        log OK "refresh $_alias: ip -> $_ip"
    done
}

_devices_rollback() {
    [ $# -ge 1 ] || { printf 'usage: nina devices rollback <alias>\n' >&2; exit 1; }
    _alias="$1"
    _db="$BASE/state/ts-devices.db"
    _snap="$BASE/state/snapshots/${_alias}.bak"
    [ -f "$_snap" ] || { log ERROR "no snapshot for '$_alias'"; exit 1; }
    cp -f "$_snap" "$_db"
    log OK "rolled back ts-devices.db from snapshot '$_alias'"
}

_devices_push_vpn() {
    _db="$BASE/state/ts-devices.db"
    [ -f "$_db" ] || { printf '[INFO] no devices registered\n' >&2; exit 0; }
    has_cmd nscp || { log ERROR "nscp not found"; exit 1; }
    _remote_path="$HOME/.local/share/nina/state/ts-devices.db"
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
    _my_alias="$(node_alias 2>/dev/null || true)"
    printf '%s\n' "$_aliases" | while IFS= read -r _alias; do
        [ -n "$_alias" ] || continue
        [ "$_alias" = "$_my_alias" ] && continue
        _blk="$(blockdb_get "$_db" alias "$_alias")"
        [ -n "$_blk" ] || continue
        _ip="$(blockdb_field "$_blk" ip)"
        _port="$(blockdb_field "$_blk" port)"
        [ -n "$_port" ] || _port=8022
        [ -n "$_ip" ] || { log WARN "push to $_alias skipped (no ip)"; continue; }
        if reachable_ssh "$_ip" "$_port"; then
            if nscp "$_db" "${_alias}:${_remote_path}" >/dev/null 2>&1; then
                log OK "pushed ts-devices.db -> $_alias ($_ip)"
            else
                log WARN "push to $_alias ($_ip) failed"
            fi
        else
            log WARN "push to $_alias skipped (unreachable: $_ip:$_port)"
        fi
    done
}

_devices_resetall() {
    printf 'WARNING: delete ts-devices.db and known_hosts. Continue? [y/N] ' >&2
    read -r _ans </dev/tty || _ans=""
    case "$_ans" in
        [Yy]*) ;;
        *) log INFO "aborted"; exit 0 ;;
    esac
    _db="$BASE/state/ts-devices.db"
    rm -f "$_db" "$KNOWN_HOSTS"
    : > "$_db"
    log OK "reset complete: ts-devices.db + known_hosts cleared"
}

_devices_node_set() {
    [ $# -ge 1 ] || { printf 'usage: nina devices node-set <alias> [user] [port] [platform]\n' >&2; exit 1; }
    _alias="$1"
    _user="${2:-u}"
    _port="${3:-8022}"
    _platform="${4:-android}"
    if node_alias_set "$_alias" "$_user" "$_port" "$_platform"; then
        log OK "node identity set: $_alias ($(node_id)) user=$_user port=$_port"
    else
        log WARN "node identity set failed"
    fi
}

_devices_node_add() {
    [ $# -ge 5 ] || { printf 'usage: nina devices node-add <node-id> <alias> <user> <port> <platform>\n' >&2; exit 1; }
    _nid="$1"; _alias="$2"; _user="$3"; _port="$4"; _platform="$5"
    if [ -f "$REGISTRY_DB" ] && [ -n "$(blockdb_get "$REGISTRY_DB" node_id "$_nid")" ]; then
        log ERROR "node-id '$_nid' already registered"; exit 1
    fi
    if _registry_write "$_nid" "$_alias" "$_user" "$_port" "$_platform"; then
        log OK "node added: $_alias ($_nid)"
    else
        log WARN "node add failed: $_alias ($_nid)"
    fi
}

_devices_registry_set() {
    [ $# -ge 2 ] || { printf 'usage: nina devices registry-set <node-id> <alias> [user] [port] [platform]\n' >&2; exit 1; }
    _rs_nid="$1"; _rs_alias="$2"; _rs_user="${3:-u}"; _rs_port="${4:-8022}"; _rs_platform="${5:-android}"
    if _registry_write "$_rs_nid" "$_rs_alias" "$_rs_user" "$_rs_port" "$_rs_platform"; then
        log OK "registry updated: $_rs_alias ($_rs_nid)"
    else
        log WARN "registry update failed: $_rs_alias ($_rs_nid)"
    fi
}

_devices_hostkey_refresh() {
    _db="$BASE/state/ts-devices.db"
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
        [ -n "$_port" ] || _port=8022
        [ -n "$_ip" ] || { log WARN "hostkey refresh skipped for '$_alias' (no ip)"; continue; }
        _hk="$(_get_host_key_fingerprint "$_ip" "$_port" 2>/dev/null || true)"
        if [ -n "$_hk" ]; then
            _new="$(printf '%s\n' "$_blk" | awk -v nhk="$_hk" '/^hostkey:/ { print "hostkey: " nhk; next } { print }')"
            blockdb_upsert "$_db" alias "$_alias" "$_new"
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

_do_status() {
    _devices_list
}
