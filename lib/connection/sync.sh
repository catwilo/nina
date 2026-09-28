#!/bin/sh
# sync.sh -- push ts-devices.db to every registered peer over tailscale.

sync_devices_to_nodes() {
    export NOEMAP_SSH_ROLE=automation
    _self_register

    _ts_db="$BASE/state/ts-devices.db"
    [ -f "$_ts_db" ] && [ -s "$_ts_db" ] || return 0
    has_cmd nssh || { log WARN "nssh not found -- skipping sync"; return 0; }

    _remote_db="$HOME/.local/share/nina/state/ts-devices.db"
    _sdn_aliases="$(session_tmp sdn_aliases)"
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
    ' "$_ts_db" > "$_sdn_aliases" 2>/dev/null

    _sdn_tmp="$(session_tmp sdn_pairs)"
    : > "$_sdn_tmp"
    while IFS= read -r _sdn_alias; do
        [ -n "$_sdn_alias" ] || continue
        [ "$_sdn_alias" = "$(node_alias 2>/dev/null)" ] && continue
        _sdn_blk="$(blockdb_get "$_ts_db" alias "$_sdn_alias")"
        [ -n "$_sdn_blk" ] || continue
        _sdn_ip="$(blockdb_field "$_sdn_blk" ip)"
        [ -n "$_sdn_ip" ] && printf '%s|%s\n' "$_sdn_alias" "$_sdn_ip" >> "$_sdn_tmp"
    done < "$_sdn_aliases"

    while IFS='|' read -r _sa _sip; do
        [ -n "$_sa" ] || continue
        if nssh "$_sa" "mkdir -p ~/.local/share/nina/state && cat > $_remote_db" < "$_ts_db"; then
            log OK "synced ts-devices.db -> $_sa"
        else
            log WARN "sync to $_sa failed"
        fi
    done < "$_sdn_tmp"
}
