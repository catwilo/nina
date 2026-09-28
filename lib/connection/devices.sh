#!/bin/sh
# devices.sh -- resolve a device alias to connection details.
#
# Tailscale-only: the only source is ts-devices.db.
# registry.db remains authoritative for user/port when it has a row.

resolve_device() {
    _alias="$1"
    _db_dir="$2"

    _ts_db="$_db_dir/ts-devices.db"
    [ -f "$_ts_db" ] || { log ERROR "ts-devices.db missing at $_ts_db"; exit 1; }

    _blk="$(blockdb_get "$_ts_db" alias "$_alias" 2>/dev/null || true)"
    [ -n "$_blk" ] || { log ERROR "unknown device alias: '$_alias'"; exit 1; }

    _ip="$(blockdb_field "$_blk" ip)"
    _user="$(blockdb_field "$_blk" user)"
    _port="$(blockdb_field "$_blk" port)"
    [ -n "$_ip" ] || { log ERROR "empty IP for '$_alias' in $_ts_db"; exit 1; }

    if command -v is_local_ip >/dev/null 2>&1 && is_local_ip "$_ip"; then
        log ERROR "refusing self-targeted handshake: '$_alias' resolves to this node ($_ip)"
        exit 1
    fi

    if command -v registry_row_by_alias >/dev/null 2>&1; then
        _cloud_blk="$(registry_row_by_alias "$_alias")"
        if [ -n "$_cloud_blk" ]; then
            _cloud_port="$(blockdb_field "$_cloud_blk" port)"
            _cloud_user="$(blockdb_field "$_cloud_blk" user)"
            [ -n "$_cloud_port" ] && _port="$_cloud_port"
            [ -n "$_cloud_user" ] && _user="$_cloud_user"
        fi
    fi
    [ -n "$_port" ] || _port=8022

    printf '%s|%s|%s\n' "$_ip" "${_user:-}" "$_port"
}

resolve_device_platform() {
    _rdp_alias="$1"
    _rdp_dir="$2"

    if command -v registry_row_by_alias >/dev/null 2>&1; then
        _rdp_blk="$(registry_row_by_alias "$_rdp_alias")"
        if [ -n "$_rdp_blk" ]; then
            _rdp_plat="$(blockdb_field "$_rdp_blk" platform)"
            [ -n "$_rdp_plat" ] && { printf '%s\n' "$_rdp_plat"; return 0; }
        fi
    fi
    _rdp_db="$_rdp_dir/ts-devices.db"
    if [ -f "$_rdp_db" ]; then
        _rdp_blk="$(blockdb_get "$_rdp_db" alias "$_rdp_alias" 2>/dev/null || true)"
        if [ -n "$_rdp_blk" ]; then
            _rdp_plat="$(blockdb_field "$_rdp_blk" platform)"
            [ -n "$_rdp_plat" ] && { printf '%s\n' "$_rdp_plat"; return 0; }
        fi
    fi
    printf '\n'
}

_ensure_user() {
    _eu_alias="$1"
    _eu_db="$2"
    _eu_user="$3"

    case "$_eu_user" in
        ''|user) ;;
        *) printf '%s\n' "$_eu_user"; return 0 ;;
    esac

    if command -v registry_row_by_alias >/dev/null 2>&1; then
        _eu_cloud_blk="$(registry_row_by_alias "$_eu_alias")"
        if [ -n "$_eu_cloud_blk" ]; then
            _eu_cloud_user="$(blockdb_field "$_eu_cloud_blk" user)"
            if [ -n "$_eu_cloud_user" ]; then
                _eu_cur="$(blockdb_get "$_eu_db" alias "$_eu_alias")"
                if [ -n "$_eu_cur" ]; then
                    _eu_new="$(printf '%s\n' "$_eu_cur" | awk -v nu="$_eu_cloud_user" '/^user:/ { print "user: " nu; next } { print }')"
                    blockdb_upsert "$_eu_db" alias "$_eu_alias" "$_eu_new"
                fi
                printf '%s\n' "$_eu_cloud_user"
                return 0
            fi
        fi
    fi

    printf '%s\n' "${_eu_user:-u}"
}

resolve_scp_target() {
    _val="$1"
    _db="$2"

    case "$_val" in
        *:*)
            _alias="${_val%%:*}"
            _path="${_val#*:}"
            _blk="$(blockdb_get "$_db" alias "$_alias")"
            if [ -z "$_blk" ]; then
                printf '%s\n' "$_val"
                return 0
            fi
            _ip="$(blockdb_field "$_blk" ip)"
            _user="$(blockdb_field "$_blk" user)"
            if command -v is_local_ip >/dev/null 2>&1 && [ -n "$_ip" ] && is_local_ip "$_ip"; then
                log ERROR "refusing self-targeted transfer: '$_alias' resolves to this node ($_ip)"
                exit 1
            fi
            [ -n "$_ip" ] || { log ERROR "missing IP for alias '$_alias'"; exit 1; }
            _user="$(_ensure_user "$_alias" "$_db" "$_user")"
            [ -n "$_user" ] || { log ERROR "no user for '$_alias'"; exit 1; }
            printf '%s@%s:%s\n' "$_user" "$_ip" "$_path"
            ;;
        *)
            printf '%s\n' "$_val"
            ;;
    esac
}
