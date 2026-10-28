#!/bin/sh
# devices.sh -- nina devices subcommand (tailscale-only).

_do_devices() {
    _dev_sub="${1:-list}"
    case "$_dev_sub" in
        add|edit|rename|remove|update-ip|refresh-ips|rollback|push-vpn|resetall|node-set|node-add|registry-set|hostkey-refresh) shift || true ;;
        -h|--help) _devices_usage >&2; exit 0 ;;
        *) printf '[ERROR] unknown devices subcommand: %s\n' "$_dev_sub" >&2; _devices_usage >&2; exit 1 ;;
    esac
    case "$_dev_sub" in
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
  add <alias> <ip> <user> [port]  register a device manually
  edit <alias>      interactively edit device details
  rename <old> <new>  rename a device alias
  remove <alias> [alias...]  remove devices
  update-ip <alias> <ip>  set a device IP
  refresh-ips       refresh local IP from tun0; peers from tailscale CLI if present
  rollback <alias>  restore ts-devices.db from snapshot
  push-vpn          sync ts-devices.db to all peers
  resetall          wipe ts-devices.db + known_hosts (requires y/N)
  node-set <alias> [user] [port] [os] [kind] [root]  set THIS node identity
  node-add <node-id> <alias> <user> <port> <os> <kind> <root>  register another node
  registry-set <node-id> <alias> [user] [port] [os] [kind] [root]  edit any node
  hostkey-refresh   refresh SSH host keys from all devices
USAGE
}

_devices_list() {
    _remote_only="${1:-0}"
    _db="$BASE/state/ts-devices.db"
    _me="$(node_alias)"

    if [ "$_remote_only" -eq 0 ]; then
        [ -n "$_me" ] || { printf '[ERROR] local node not registered -- run: nina self-register\n' >&2; return 1; }
        [ -f "$_db" ] && [ -s "$_db" ] || { printf '[ERROR] device registry missing or empty: %s\n' "$_db" >&2; return 1; }
        _me_blk="$(blockdb_get "$_db" alias "$_me")"
        [ -n "$_me_blk" ] || { printf '[ERROR] local node %s absent from %s\n' "$_me" "$_db" >&2; return 1; }
        _me_ip="$(blockdb_field "$_me_blk" ip)"
        _me_user="$(blockdb_field "$_me_blk" user)"
        _me_port="$(blockdb_field "$_me_blk" port)"
        [ -n "$_me_port" ] || _me_port=8022
        _me_os="$(blockdb_field "$_me_blk" os)"
        _me_kind="$(platform_type "$_me_os")"
        # Placeholder "-" for empty fields keeps the contract positional:
        # downstream consumers split on whitespace and read $1..$6; an
        # empty IP collapsed the fields and broke every caller.
        printf '%s %s %s %s %s %s\n' "$_me" "${_me_ip:--}" "${_me_user:--}" "$_me_port" "$_me_kind" "${_me_os:--}"
    fi

    [ -f "$_db" ] && [ -s "$_db" ] || return 0

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

    [ -n "$_aliases" ] || return 0
    printf '%s\n' "$_aliases" | while IFS= read -r _alias; do
        [ -n "$_alias" ] || continue
        if [ -n "$_me" ] && [ "$_alias" = "$_me" ]; then continue; fi
        _blk="$(blockdb_get "$_db" alias "$_alias")"
        [ -n "$_blk" ] || continue
        _ip="$(blockdb_field "$_blk" ip)"
        _user="$(blockdb_field "$_blk" user)"
        _port="$(blockdb_field "$_blk" port)"
        [ -n "$_port" ] || _port=8022
        _os="$(blockdb_field "$_blk" os)"
        _kind="$(platform_type "$_os")"
        printf '%s %s %s %s %s %s\n' "$_alias" "${_ip:--}" "${_user:--}" "$_port" "$_kind" "${_os:--}"
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
    _new="$(printf 'alias: %s\nip: %s\nuser: %s\nport: %s\nos: android\nkind: phone\nroot: no\nhostkey: %s\nnode_id: %s\n' "$_alias" "$_ip" "$_user" "$_port" "" "")"
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
    _cur_os="$(blockdb_field "$_row" os)"; _cur_os="${_cur_os:-linux}"
    _cur_kind="$(blockdb_field "$_row" kind)"; _cur_kind="${_cur_kind:-laptop}"
    _cur_root="$(blockdb_field "$_row" root)"; _cur_root="${_cur_root:-no}"
    _new="$(printf 'alias: %s\nip: %s\nuser: %s\nport: %s\nos: %s\nkind: %s\nroot: %s\nhostkey: %s\nnode_id: %s\n' "$_new_alias" "$_new_ip" "$_new_user" "$_new_port" "$_cur_os" "$_cur_kind" "$_cur_root" "${_cur_hk:-}" "${_cur_nid:-}")"
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

    # Registry cloud: pull latest and use its ip field if present. This is
    # the primary path: each node wrote its own ip in self-register, so
    # refresh-ips does not depend on tailscale hostnames matching aliases.
    if [ -f "$REGISTRY_DB" ] && command -v blockdb_get >/dev/null 2>&1; then
        _ri_dir="$(dirname "$REGISTRY_DB")"
        if [ -d "$_ri_dir/.git" ]; then
            ( cd "$_ri_dir" && git pull --rebase origin main >/dev/null 2>&1 ) || true
        fi
    fi
    _aliases_for_reg="$(awk '
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
    printf '%s\n' "$_aliases_for_reg" | while IFS= read -r _alias; do
        [ -n "$_alias" ] || continue
        _blk="$(blockdb_get "$_db" alias "$_alias")"
        [ -n "$_blk" ] || continue
        _blk_nid="$(blockdb_field "$_blk" node_id)"
        [ "$_blk_nid" = "$_my_nid" ] && continue
        _reg_blk="$(registry_row_by_alias "$_alias" 2>/dev/null || true)"
        [ -n "$_reg_blk" ] || continue
        _reg_ip="$(blockdb_field "$_reg_blk" ip)"
        [ -n "$_reg_ip" ] || continue
        _cur_ip="$(blockdb_field "$_blk" ip)"
        [ "$_cur_ip" = "$_reg_ip" ] && continue
        _new="$(printf '%s\n' "$_blk" | awk -v nip="$_reg_ip" '/^ip:/ { print "ip: " nip; next } { print }')"
        blockdb_upsert "$_db" alias "$_alias" "$_new"
        log OK "refresh $_alias (registry): ip -> $_reg_ip"
    done

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
        _cur_ip="$(blockdb_field "$_blk" ip)"
        [ -n "$_cur_ip" ] && continue
        _ip="$(printf '%s' "$_ts_json" | jq -r --arg h "$_alias" '.Peer // {} | to_entries[] | .value | select(.HostName == $h) | .TailscaleIPs[0] // empty' 2>/dev/null | head -1)"
        if [ -z "$_ip" ] || [ "$_ip" = "null" ]; then
            log WARN "refresh $_alias: not in registry nor tailscale status"
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
    has_cmd nya || { log ERROR "nya not found"; exit 1; }
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
            if nya "$_db" "${_alias}:${_remote_path}" >/dev/null 2>&1; then
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
    [ $# -ge 1 ] || { printf 'usage: nina devices node-set <alias> [user] [port] [os] [kind] [root]\n' >&2; exit 1; }
    _alias="$1"
    _user="${2:-u}"
    _port="${3:-8022}"
    _os="${4:-$(detect_os 2>/dev/null || printf 'linux')}"
    _kind="${5:-$(detect_kind 2>/dev/null || printf 'laptop')}"
    _root="${6:-no}"
    if node_alias_set "$_alias" "$_user" "$_port" "$_os" "$_kind" "$_root"; then
        log OK "node identity set: $_alias ($(node_id)) user=$_user port=$_port"
    else
        log WARN "node identity set failed"
    fi
}

_devices_node_add() {
    [ $# -ge 7 ] || { printf 'usage: nina devices node-add <node-id> <alias> <user> <port> <os> <kind> <root>\n' >&2; exit 1; }
    _nid="$1"; _alias="$2"; _user="$3"; _port="$4"; _os="$5"; _kind="$6"; _root="$7"
    if [ -f "$REGISTRY_DB" ] && [ -n "$(blockdb_get "$REGISTRY_DB" node_id "$_nid")" ]; then
        log ERROR "node-id '$_nid' already registered"; exit 1
    fi
    if _registry_write "$_nid" "$_alias" "$_user" "$_port" "$_os" "$_kind" "$_root"; then
        log OK "node added: $_alias ($_nid)"
    else
        log WARN "node add failed: $_alias ($_nid)"
    fi
}

_devices_registry_set() {
    [ $# -ge 2 ] || { printf 'usage: nina devices registry-set <node-id> <alias> [user] [port] [os] [kind] [root]\n' >&2; exit 1; }
    _rs_nid="$1"; _rs_alias="$2"; _rs_user="${3:-u}"; _rs_port="${4:-8022}"; _rs_os="${5:-linux}"; _rs_kind="${6:-laptop}"; _rs_root="${7:-no}"
    if _registry_write "$_rs_nid" "$_rs_alias" "$_rs_user" "$_rs_port" "$_rs_os" "$_rs_kind" "$_rs_root"; then
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
    _status_remote_only=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --remote-only) _status_remote_only=1; shift ;;
            -h|--help)
                cat <<'USAGE'
usage: nina status [--remote-only]

  nina status                 Emit "alias ip user port kind os", one node
                              per line. The FIRST line is always the local
                              node; every following line is a remote node.
                              kind: celular|computador. os: android|debian|...
  nina status --remote-only   Emit remote nodes only, no local line.
                              This is the machine source nya consumes.
USAGE
                return 0 ;;
            *) printf '[ERROR] nina status: unknown argument: %s\n' "$1" >&2; return 2 ;;
        esac
    done
    _devices_list "$_status_remote_only"
}
