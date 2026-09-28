#!/bin/sh
# seed.sh -- pull other nodes rows from the cloud registry into ts-devices.db.

_seed_from_registry() {
    [ -f "$REGISTRY_DB" ] || return 0
    _ts_db="$BASE/state/ts-devices.db"
    [ -f "$_ts_db" ] || : > "$_ts_db"

    _sfr_own_nid="$(node_id)"
    _sfr_nids="$(session_tmp sfr_nids)"
    awk '
        BEGIN { RS=""; FS="\n" }
        {
            for (i = 1; i <= NF; i++) {
                colon = index($i, ":")
                if (colon == 0) continue
                fk = substr($i, 1, colon - 1)
                if (fk == "node_id") { print substr($i, colon + 2); break }
            }
        }
    ' "$REGISTRY_DB" > "$_sfr_nids" 2>/dev/null

    while IFS= read -r _sfr_nid; do
        [ -n "$_sfr_nid" ] || continue
        [ "$_sfr_nid" = "$_sfr_own_nid" ] && continue

        _sfr_reg_blk="$(blockdb_get "$REGISTRY_DB" node_id "$_sfr_nid")"
        [ -n "$_sfr_reg_blk" ] || continue
        _sfr_alias="$(blockdb_field "$_sfr_reg_blk" alias)"
        [ -n "$_sfr_alias" ] || continue

        _sfr_existing="$(blockdb_get "$_ts_db" node_id "$_sfr_nid")"
        [ -n "$_sfr_existing" ] && continue

        _sfr_user="$(blockdb_field "$_sfr_reg_blk" user)"
        _sfr_port="$(blockdb_field "$_sfr_reg_blk" port)"
        _sfr_platform="$(blockdb_field "$_sfr_reg_blk" platform)"
        _sfr_hk="$(blockdb_field "$_sfr_reg_blk" hostkey)"
        [ -n "$_sfr_user" ] || _sfr_user=u
        [ -n "$_sfr_port" ] || _sfr_port=8022
        [ -n "$_sfr_platform" ] || _sfr_platform=android

        _sfr_block="$(printf 'alias: %s\nip: %s\nuser: %s\nport: %s\nplatform: %s\nhostkey: %s\nnode_id: %s\n' \
            "$_sfr_alias" "" "$_sfr_user" "$_sfr_port" "$_sfr_platform" "${_sfr_hk:-}" "$_sfr_nid")"
        blockdb_upsert "$_ts_db" alias "$_sfr_alias" "$_sfr_block"
        log OK "seeded $_sfr_alias (node $_sfr_nid, ip pending tailscale)"
    done < "$_sfr_nids"
}
