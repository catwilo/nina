#!/bin/sh
# devices.sh -- nina devices (nodes.db, tailscale-only).

_do_devices() {
    _dev_sub="${1:-list}"
    case "$_dev_sub" in
        list|all|add|edit|rename|remove|update-ip|refresh-ips|suspend|resume|node-set|node-add|registry-set|hostkey-refresh) shift || true ;;
        -h|--help) _devices_usage >&2; exit 0 ;;
        *) printf '[ERROR] unknown devices subcommand: %s\n' "$_dev_sub" >&2; _devices_usage >&2; exit 1 ;;
    esac
    case "$_dev_sub" in
        list) _devices_list ;;
        all)  _devices_all ;;
        node-set)     _devices_node_set "$@" ;;
        node-add)     _devices_node_add "$@" ;;
        registry-set) _devices_registry_set "$@" ;;
        *) (
            case "$_dev_sub" in
                add)             _devices_add "$@" ;;
                edit)            _devices_edit "$@" ;;
                rename)          _devices_rename "$@" ;;
                remove)          _devices_remove "$@" ;;
                update-ip)       _devices_update_ip "$@" ;;
                refresh-ips)     _devices_refresh_ips ;;
                suspend)         _devices_set_state "${1:-}" suspended suspend ;;
                resume)          _devices_set_state "${1:-}" active resume ;;
                hostkey-refresh) _devices_hostkey_refresh ;;
            esac
        )
        _dev_rc=$?
        [ "$_dev_rc" -eq 0 ] && _nodes_commit_push "chore(nodes): $_dev_sub $*"
        return $_dev_rc ;;
    esac
}

_devices_usage() {
    cat <<'USAGE'
usage: nina devices <subcommand> [options]

subcommands:
  list              emit active remote nodes + local (nya consumes this)
  all               list every node with its state
  add <alias> <ip> <user> [port]  register manually
  edit <alias>      interactive edit
  rename <old> <new>  rename alias
  remove <alias> [alias...]  remove devices
  update-ip <alias> <ip>  set device IP
  refresh-ips       refresh local IP from tun0; peers from tailscale CLI
  suspend <alias>   mark suspended (excluded from nina status)
  resume <alias>    mark active again
  node-set <alias> [user] [port] [os] [kind] [root]  set THIS node identity
  node-add <node-id> <alias> <user> <port> <os> <kind> <root>  register another node
  registry-set <node-id> <alias> [user] [port] [os] [kind] [root]  edit any node
  hostkey-refresh   refresh SSH host keys
USAGE
}

_devices_emit() {
    _de_alias="$1"; _de_ip="$2"; _de_user="$3"; _de_port="$4"; _de_os="$5"; _de_state="${6:-}"
    _de_kind="$(platform_type "$_de_os")"
    [ -n "$_de_port" ] || _de_port=8022
    if [ -n "$_de_state" ]; then
        printf '%s %s %s %s %s %s %s\n' "$_de_alias" "${_de_ip:--}" "${_de_user:--}" "$_de_port" "$_de_kind" "${_de_os:--}" "$_de_state"
    else
        printf '%s %s %s %s %s %s\n' "$_de_alias" "${_de_ip:--}" "${_de_user:--}" "$_de_port" "$_de_kind" "${_de_os:--}"
    fi
}

_devices_require_db() {
    [ -f "$NODES_DB" ] && [ -s "$NODES_DB" ] && return 0
    [ "${1:-}" = quiet ] || printf '[ERROR] nodes.db missing or empty: %s\n' "$NODES_DB" >&2
    return 1
}

_devices_list() {
    _skip_local="${1:-0}"
    _devices_require_db || return 1
    _me="$(node_alias)"
    if [ "$_skip_local" -eq 0 ]; then
        [ -n "$_me" ] || { printf '[ERROR] local node not registered -- run: nina self-register\n' >&2; return 1; }
        _me_blk="$(blockdb_get "$NODES_DB" alias "$_me")"
        [ -n "$_me_blk" ] || { printf '[ERROR] local node %s absent from %s\n' "$_me" "$NODES_DB" >&2; return 1; }
        _devices_emit "$_me" \
            "$(blockdb_field "$_me_blk" ip)" \
            "$(blockdb_field "$_me_blk" user)" \
            "$(blockdb_field "$_me_blk" port)" \
            "$(blockdb_field "$_me_blk" os)"
    fi
    blockdb_aliases "$NODES_DB" | while IFS= read -r _alias; do
        [ -n "$_alias" ] || continue
        [ -n "$_me" ] && [ "$_alias" = "$_me" ] && continue
        _blk="$(blockdb_get "$NODES_DB" alias "$_alias")"
        [ -n "$_blk" ] || continue
        _st="$(blockdb_field "$_blk" state)"; _st="${_st:-active}"
        [ "$_st" = "active" ] || continue
        _devices_emit "$_alias" \
            "$(blockdb_field "$_blk" ip)" \
            "$(blockdb_field "$_blk" user)" \
            "$(blockdb_field "$_blk" port)" \
            "$(blockdb_field "$_blk" os)"
    done
}
_devices_all() {
    _devices_require_db || return 1
    blockdb_aliases "$NODES_DB" | while IFS= read -r _alias; do
        [ -n "$_alias" ] || continue
        _blk="$(blockdb_get "$NODES_DB" alias "$_alias")"
        [ -n "$_blk" ] || continue
        _st="$(blockdb_field "$_blk" state)"; _st="${_st:-active}"
        _devices_emit "$_alias" \
            "$(blockdb_field "$_blk" ip)" \
            "$(blockdb_field "$_blk" user)" \
            "$(blockdb_field "$_blk" port)" \
            "$(blockdb_field "$_blk" os)" \
            "$_st"
    done
}

_devices_add() {
    [ $# -ge 3 ] || { printf 'usage: nina devices add <alias> <ip> <user> [port]\n' >&2; exit 1; }
    _alias="$1"; _ip="$2"; _user="$3"; _port="${4:-8022}"
    if [ -f "$NODES_DB" ] && [ -n "$(blockdb_get "$NODES_DB" alias "$_alias")" ]; then
        log ERROR "alias '$_alias' already exists -- use edit or rename"; exit 1
    fi
    blockdb_upsert "$NODES_DB" alias "$_alias" "$(printf 'alias: %s\nip: %s\nuser: %s\nport: %s\nos: android\nkind: phone\nroot: no\nhostkey: \nnode_id: \nstate: active\n' "$_alias" "$_ip" "$_user" "$_port")"
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
    [ -f "$NODES_DB" ] || { printf '[INFO] no devices registered\n' >&2; return 0; }
    _row="$(blockdb_get "$NODES_DB" alias "$_alias")"
    [ -n "$_row" ] || { log ERROR "unknown alias: '$_alias'"; exit 1; }
    _cur_alias="$(blockdb_field "$_row" alias)"
    _cur_ip="$(blockdb_field "$_row" ip)"
    _cur_user="$(blockdb_field "$_row" user)"
    _cur_port="$(blockdb_field "$_row" port)"; [ -n "$_cur_port" ] || _cur_port=8022
    printf '\nEditing device: %s\n' "$_alias" >&2
    _new_alias="$(_prompt_field "alias" "$_cur_alias")"
    _new_ip="$(_prompt_field "ip" "$_cur_ip")"
    _new_user="$(_prompt_field "user" "$_cur_user")"
    _new_port="$(_prompt_field "port" "$_cur_port")"
    _new="$(printf '%s\n' "$_row" | awk -v a="$_new_alias" -v i="$_new_ip" -v u="$_new_user" -v p="$_new_port" '
        /^alias:/ { print "alias: " a; next }
        /^ip:/    { print "ip: " i;    next }
        /^user:/  { print "user: " u;  next }
        /^port:/  { print "port: " p;  next }
        { print }
    ')"
    [ "$_new_alias" != "$_cur_alias" ] && blockdb_remove "$NODES_DB" alias "$_cur_alias"
    blockdb_upsert "$NODES_DB" alias "$_new_alias" "$_new"
    log OK "updated '$_alias' -> alias=$_new_alias ip=$_new_ip"
}

_devices_rename() {
    [ $# -ge 2 ] || { printf 'usage: nina devices rename <old> <new>\n' >&2; exit 1; }
    _old="$1"; _new="$2"
    [ -f "$NODES_DB" ] || { printf '[INFO] no devices registered\n' >&2; return 0; }
    _row="$(blockdb_get "$NODES_DB" alias "$_old")"
    [ -n "$_row" ] || { log ERROR "unknown alias: '$_old'"; exit 1; }
    blockdb_remove "$NODES_DB" alias "$_old"
    blockdb_upsert "$NODES_DB" alias "$_new" \
        "$(printf '%s\n' "$_row" | awk -v na="$_new" '/^alias:/ { print "alias: " na; next } { print }')"
    log OK "renamed '$_old' -> '$_new'"
}

_devices_remove() {
    [ $# -ge 1 ] || { printf 'usage: nina devices remove <alias> [alias...]\n' >&2; exit 1; }
    [ -f "$NODES_DB" ] || { printf '[INFO] no devices registered\n' >&2; return 0; }
    for _alias in "$@"; do
        _row="$(blockdb_get "$NODES_DB" alias "$_alias")"
        if [ -z "$_row" ]; then log WARN "unknown alias: '$_alias' -- skipping"; continue; fi
        _ip="$(blockdb_field "$_row" ip)"
        _port="$(blockdb_field "$_row" port)"; [ -n "$_port" ] || _port=8022
        blockdb_remove "$NODES_DB" alias "$_alias"
        [ -n "$_ip" ] && known_hosts_remove_ip "$_ip" "$_port"
    done
}

_devices_update_ip() {
    [ $# -ge 2 ] || { printf 'usage: nina devices update-ip <alias> <newip>\n' >&2; exit 1; }
    _alias="$1"; _new_ip="$2"
    [ -f "$NODES_DB" ] || { printf '[INFO] no devices registered\n' >&2; return 0; }
    _row="$(blockdb_get "$NODES_DB" alias "$_alias")"
    [ -n "$_row" ] || { log ERROR "unknown alias: '$_alias'"; exit 1; }
    _old_ip="$(blockdb_field "$_row" ip)"
    _port="$(blockdb_field "$_row" port)"; [ -n "$_port" ] || _port=8022
    known_hosts_sync_device "$_alias" "$_old_ip" "$_new_ip" "$_port"
    blockdb_upsert "$NODES_DB" alias "$_alias" \
        "$(printf '%s\n' "$_row" | awk -v nip="$_new_ip" '/^ip:/ { print "ip: " nip; next } { print }')"
    log OK "updated '$_alias': ip $_old_ip -> $_new_ip"
}

_devices_refresh_ips() {
    [ -f "$NODES_DB" ] && [ -s "$NODES_DB" ] || { log WARN "no nodes.db -- nothing to refresh"; return 0; }
    _dir="$(dirname "$NODES_DB")"
    if [ -d "$_dir/.git" ]; then
        ( cd "$_dir" && git pull --rebase origin main >/dev/null 2>&1 ) || true
    fi
    _my_nid="$(node_id)"
    _my_ip="$(detect_tailscale_ip 2>/dev/null || true)"
    if [ -n "$_my_ip" ]; then
        blockdb_aliases "$NODES_DB" | while IFS= read -r _alias; do
            [ -n "$_alias" ] || continue
            _blk="$(blockdb_get "$NODES_DB" alias "$_alias")"
            [ -n "$_blk" ] || continue
            [ "$(blockdb_field "$_blk" node_id)" = "$_my_nid" ] || continue
            blockdb_upsert "$NODES_DB" alias "$_alias" \
                "$(printf '%s\n' "$_blk" | awk -v nip="$_my_ip" '/^ip:/ { print "ip: " nip; next } { print }')"
            log OK "refresh $_alias (local): ip -> $_my_ip"
        done
    else
        log WARN "no tailscale IP on tun0 -- local row not updated"
    fi
    has_cmd tailscale || { log INFO "tailscale CLI not available -- peer IPs unchanged"; return 0; }
    has_cmd jq || { log WARN "jq missing -- peer refresh skipped"; return 0; }
    _ts_json="$(tailscale status --json 2>/dev/null)"
    [ -n "$_ts_json" ] || { log WARN "tailscale status --json empty"; return 0; }
    blockdb_aliases "$NODES_DB" | while IFS= read -r _alias; do
        [ -n "$_alias" ] || continue
        _blk="$(blockdb_get "$NODES_DB" alias "$_alias")"
        [ -n "$_blk" ] || continue
        [ "$(blockdb_field "$_blk" node_id)" = "$_my_nid" ] && continue
        [ -n "$(blockdb_field "$_blk" ip)" ] && continue
        _ip="$(printf '%s' "$_ts_json" | jq -r --arg h "$_alias" '.Peer // {} | to_entries[] | .value | select(.HostName == $h) | .TailscaleIPs[0] // empty' 2>/dev/null | head -1)"
        if [ -z "$_ip" ] || [ "$_ip" = "null" ]; then
            log WARN "refresh $_alias: not in tailscale status"; continue
        fi
        blockdb_upsert "$NODES_DB" alias "$_alias" \
            "$(printf '%s\n' "$_blk" | awk -v nip="$_ip" '/^ip:/ { print "ip: " nip; next } { print }')"
        log OK "refresh $_alias: ip -> $_ip"
    done
}
# _nodes_commit_push <message> -- persist nodes.db: stage, commit, rebase onto
# origin/main, push, then fan out to every active peer. No-op when nothing
# changed.
_nodes_commit_push() {
    _ncp_msg="$1"
    _ncp_dir="$(dirname "$NODES_DB")"
    ( cd "$_ncp_dir" && git add nodes.db && git diff --cached --stat )
    if ( cd "$_ncp_dir" && git diff --cached --quiet ); then
        log INFO "nodes.db unchanged -- nothing to push"
        return 0
    fi
    ( cd "$_ncp_dir" && git commit -m "$_ncp_msg" ) || {
        log ERROR "commit failed -- nodes.db not persisted"; return 1
    }
    ( cd "$_ncp_dir" && git pull --rebase origin main ) || {
        log ERROR "pull --rebase failed -- nodes.db committed locally, push pending"; return 1
    }
    ( cd "$_ncp_dir" && git push origin main ) || {
        log ERROR "push failed -- nodes.db committed locally"; return 1
    }
    _distribute_registry
}

_devices_set_state() {
    _ss_alias="$1"; _ss_state="$2"; _ss_cmd="$3"
    [ -n "$_ss_alias" ] || { printf 'usage: nina devices %s <alias>\n' "$_ss_cmd" >&2; exit 1; }
    [ -f "$NODES_DB" ] || { log ERROR "nodes.db missing"; exit 1; }
    _ss_blk="$(blockdb_get "$NODES_DB" alias "$_ss_alias")"
    [ -n "$_ss_blk" ] || { log ERROR "unknown alias: '$_ss_alias'"; exit 1; }
    blockdb_upsert "$NODES_DB" alias "$_ss_alias" \
        "$(printf '%s\n' "$_ss_blk" | awk -v s="$_ss_state" '
            BEGIN { found=0 }
            /^state:/ { print "state: " s; found=1; next }
            { print }
            END { if (!found) print "state: " s }
        ')"
    log OK "$_ss_alias: $_ss_state"
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
    if [ -f "$NODES_DB" ] && [ -n "$(blockdb_get "$NODES_DB" node_id "$_nid")" ]; then
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
    _nid="$1"; _alias="$2"; _user="${3:-u}"; _port="${4:-8022}"; _os="${5:-linux}"; _kind="${6:-laptop}"; _root="${7:-no}"
    if _registry_write "$_nid" "$_alias" "$_user" "$_port" "$_os" "$_kind" "$_root"; then
        log OK "registry updated: $_alias ($_nid)"
    else
        log WARN "registry update failed: $_alias ($_nid)"
    fi
}

_devices_hostkey_refresh() {
    [ -f "$NODES_DB" ] || { printf '[INFO] no devices registered\n' >&2; return 0; }
    blockdb_aliases "$NODES_DB" | while IFS= read -r _alias; do
        [ -n "$_alias" ] || continue
        _blk="$(blockdb_get "$NODES_DB" alias "$_alias")"
        [ -n "$_blk" ] || continue
        _ip="$(blockdb_field "$_blk" ip)"
        _port="$(blockdb_field "$_blk" port)"; [ -n "$_port" ] || _port=8022
        [ -n "$_ip" ] || { log WARN "hostkey refresh skipped for '$_alias' (no ip)"; continue; }
        _hk="$(_get_host_key_fingerprint "$_ip" "$_port" 2>/dev/null || true)"
        if [ -n "$_hk" ]; then
            blockdb_upsert "$NODES_DB" alias "$_alias" \
                "$(printf '%s\n' "$_blk" | awk -v nhk="$_hk" '/^hostkey:/ { print "hostkey: " nhk; next } { print }')"
            log OK "refreshed hostkey for '$_alias' ($_ip:$_port)"
        else
            log WARN "hostkey refresh failed for '$_alias' ($_ip:$_port)"
        fi
    done
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
                              node; every following line is an ACTIVE remote
                              node. Suspended nodes are omitted.
  nina status --remote-only   Emit remote active nodes only, no local line.
                              This is the machine source nya consumes.
                              Use `nina devices all` to see suspended nodes.
USAGE
                return 0 ;;
            *) printf '[ERROR] nina status: unknown argument: %s\n' "$1" >&2; return 2 ;;
        esac
    done
    if [ "$_status_remote_only" -eq 0 ]; then
        _check_local_suspended
        _devices_list 0
    else
        _devices_list 1
    fi
}
# _check_local_suspended -- warn + prompt when this node is suspended.
_check_local_suspended() {
    _cls_me="$(node_alias)"
    [ -n "$_cls_me" ] || return 0
    [ -f "$NODES_DB" ] || return 0
    _cls_blk="$(blockdb_get "$NODES_DB" alias "$_cls_me")"
    [ -n "$_cls_blk" ] || return 0
    [ "$(blockdb_field "$_cls_blk" state)" = "suspended" ] || return 0
    printf '[WARN] este nodo (%s) figura como suspended en nodes.db\n' "$_cls_me" >&2
    [ -t 0 ] && [ -t 1 ] || return 0
    printf 'encender este nodo ahora? [y/N]: ' >&2
    _cls_ans=""
    read -r _cls_ans </dev/tty || _cls_ans=""
    case "$_cls_ans" in
        [yY]|[yY][eE][sS]|[sS]) _devices_set_state "$_cls_me" active resume ;;
        *) : ;;
    esac
}
