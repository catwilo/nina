#!/bin/sh
# self_register.sh -- register this node own identity in ts-devices.db
# and registry.db. Tailscale-only: the canonical IP is detect_tailscale_ip.

_registry_pull_latest() {
    _rpl_dir="$HOME/.nina-registry"
    [ -d "$_rpl_dir/.git" ] || return 0
    ( cd "$_rpl_dir" && git pull --rebase origin main >/dev/null 2>&1 ) || true
}

_self_register() {
    [ -z "${_SELF_REGISTER_DONE:-}" ] || return 0
    _registry_pull_latest

    _self_alias=""
    _self_user=""
    _self_port=""
    _self_platform=""
    if command -v node_registry_row >/dev/null 2>&1; then
        _self_row="$(node_registry_row 2>/dev/null)"
        if [ -n "$_self_row" ]; then
            _self_alias="$(blockdb_field "$_self_row" alias)"
            _self_user="$(blockdb_field "$_self_row" user)"
            _self_port="$(blockdb_field "$_self_row" port)"
            _self_platform="$(blockdb_field "$_self_row" platform)"
        fi
    fi
    if [ -z "$_self_alias" ] && command -v _node_config_load >/dev/null 2>&1; then
        _self_cache_row="$(_node_config_load 2>/dev/null)"
        if [ -n "$_self_cache_row" ]; then
            _self_alias="$(printf "%s\n" "$_self_cache_row" | cut -d"|" -f1)"
            _self_user="$(printf "%s\n"  "$_self_cache_row" | cut -d"|" -f2)"
            _self_port="$(printf "%s\n"  "$_self_cache_row" | cut -d"|" -f3)"
        fi
    fi
    if [ -z "$_self_alias" ]; then
        _self_prompt_rc=1
        if command -v _prompt_self_identity >/dev/null 2>&1; then
            _self_alias="$(_prompt_self_identity)" || _self_prompt_rc=$?
        fi
        if [ -z "$_self_alias" ]; then
            if [ "$_self_prompt_rc" -eq 1 ] && [ ! -t 1 ]; then
                log WARN "no canonical identity -- non-interactive context, run: nina devices node-set <name>"
            else
                log WARN "no canonical identity -- run: nina devices node-set <name>"
            fi
            _SELF_REGISTER_DONE=1
            return 0
        fi
    fi

    _self_user="${_self_user:-u}"
    _self_port="${_self_port:-8022}"
    _self_platform="${_self_platform:-android}"

    _self_tailscale_ip="$(detect_tailscale_ip 2>/dev/null || true)"
    if [ -z "$_self_tailscale_ip" ]; then
        log WARN "tailscale unavailable -- cannot self-register without a canonical IP"
        _SELF_REGISTER_DONE=1
        return 0
    fi

    _self_prev_hk=""
    _self_blk_by_alias="$(blockdb_get "$BASE/state/ts-devices.db" alias "$_self_alias")"
    if [ -n "$_self_blk_by_alias" ]; then
        _self_prev_hk="$(blockdb_field "$_self_blk_by_alias" hostkey)"
    fi

    _ts_db="$BASE/state/ts-devices.db"
    [ -f "$_ts_db" ] || : > "$_ts_db"
    _self_block_ts="$(printf "alias: %s\nip: %s\nuser: %s\nport: %s\nplatform: %s\nhostkey: %s\nnode_id: %s\n" \
        "$_self_alias" "$_self_tailscale_ip" "$_self_user" "$_self_port" "$_self_platform" "${_self_prev_hk:-}" "$(node_id)")"
    blockdb_upsert "$_ts_db" alias "$_self_alias" "$_self_block_ts"
    log OK "self-registered $_self_alias ($_self_tailscale_ip)"

    if command -v node_alias_set >/dev/null 2>&1; then
        node_alias_set "$_self_alias" "$_self_user" "$_self_port" "$_self_platform" || \
            log WARN "node_alias_set failed -- registry.db not updated"
    fi
    if command -v _node_config_save >/dev/null 2>&1; then
        _node_config_save "$_self_alias" "$_self_user" "$_self_port" || \
            log WARN "_node_config_save failed"
    fi
    _SELF_REGISTER_DONE=1
}
