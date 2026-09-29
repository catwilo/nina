#!/bin/sh
# registry.sh -- cloud-backed node identity registry (github.com:catwilo/nina-registry).
#
# _registry_write is the single writer. It refuses to move an alias from
# one node to another UNLESS the existing row is provably this node's:
#   - same node_id (normal update), OR
#   - existing row has empty hostkey (phantom row from a prior install), OR
#   - existing row hostkey equals this node's local hostkey fingerprint.
# A genuine collision (different node_id + different hostkey) aborts with
# a visible error and leaves the branch untouched.

_registry_write() {
    _rw_nid="$1"
    _rw_alias="$2"
    _rw_user="$3"
    _rw_port="$4"
    _rw_platform="$5"
    if [ -z "$_rw_nid" ] || [ -z "$_rw_alias" ] || [ -z "$_rw_user" ] || [ -z "$_rw_port" ] || [ -z "$_rw_platform" ]; then
        printf '[ERROR] _registry_write: node-id, alias, user, port and platform are required\n' >&2
        return 1
    fi
    _identity_registry_warn_once
    _rw_dir="$(dirname "$REGISTRY_DB")"
    mkdir -p "$_rw_dir" 2>/dev/null || true
    [ -f "$REGISTRY_DB" ] || : > "$REGISTRY_DB"

    _rw_branch="chore/registry-${_rw_nid}"
    ( cd "$_rw_dir" && \
      git checkout main 2>/dev/null && \
      git pull --rebase origin main && \
      git checkout -B "$_rw_branch" ) || {
        printf '[ERROR] _registry_write: could not prepare branch %s in %s\n' \
            "$_rw_branch" "$_rw_dir" >&2
        return 1
    }

    _rw_owner_blk="$(blockdb_get "$REGISTRY_DB" alias "$_rw_alias")"
    _rw_owner="$([ -n "$_rw_owner_blk" ] && blockdb_field "$_rw_owner_blk" node_id || printf '')"
    _rw_owner_hk="$([ -n "$_rw_owner_blk" ] && blockdb_field "$_rw_owner_blk" hostkey || printf '')"

    if [ -n "$_rw_owner" ] && [ "$_rw_owner" != "$_rw_nid" ]; then
        _rw_local_hk=""
        if command -v _get_host_key_fingerprint >/dev/null 2>&1; then
            _rw_local_hk="$(_get_host_key_fingerprint 127.0.0.1 "$_rw_port" 2>/dev/null || true)"
        fi
        _rw_can_claim=0
        if [ -z "$_rw_owner_hk" ]; then
            _rw_can_claim=1
            printf '[INFO] _registry_write: reclaiming alias "%s" (existing row has no hostkey -- phantom)\n' \
                "$_rw_alias" >&2
        elif [ -n "$_rw_local_hk" ] && [ "$_rw_local_hk" = "$_rw_owner_hk" ]; then
            _rw_can_claim=1
            printf '[INFO] _registry_write: reclaiming alias "%s" (hostkey matches this node)\n' \
                "$_rw_alias" >&2
        fi
        if [ "$_rw_can_claim" -eq 0 ]; then
            printf '[ERROR] _registry_write: alias "%s" already registered to node %s (hostkey %s) -- genuine collision\n' \
                "$_rw_alias" "$_rw_owner" "$_rw_owner_hk" >&2
            return 1
        fi
        blockdb_remove "$REGISTRY_DB" alias "$_rw_alias"
    fi

    _rw_prev_hk=""
    _rw_prev_row="$(blockdb_get "$REGISTRY_DB" node_id "$_rw_nid")"
    [ -n "$_rw_prev_row" ] && _rw_prev_hk="$(blockdb_field "$_rw_prev_row" hostkey)"

    _rw_hk="$_rw_prev_hk"
    if [ "$_rw_nid" = "$(node_id)" ] && command -v _get_host_key_fingerprint >/dev/null 2>&1; then
        _rw_scanned_hk="$(_get_host_key_fingerprint 127.0.0.1 "$_rw_port" 2>/dev/null)"
        _rw_hk="${_rw_scanned_hk:-$_rw_prev_hk}"
    fi

    _rw_current="$_rw_prev_row"
    _rw_target="$(printf 'node_id: %s\nalias: %s\nuser: %s\nport: %s\nplatform: %s\nhostkey: %s\n' \
        "$_rw_nid" "$_rw_alias" "$_rw_user" "$_rw_port" "$_rw_platform" "${_rw_hk:-}")"

    if [ "$_rw_current" = "$_rw_target" ]; then
        :
    else
        blockdb_upsert "$REGISTRY_DB" node_id "$_rw_nid" "$_rw_target"
        ( cd "$_rw_dir" && \
          git add registry.db && \
          git commit -m "chore(registry): set alias ${_rw_alias} for node ${_rw_nid}" && \
          git push -u origin "$_rw_branch" --force-with-lease && \
          git checkout main && \
          git merge --ff-only "$_rw_branch" && \
          git push origin main && \
          git branch -d "$_rw_branch" && \
          git push origin --delete "$_rw_branch" ) || {
            printf '[ERROR] _registry_write: registry.db written locally but commit/push/merge failed -- resolve manually in %s (branch: %s)\n' \
                "$_rw_dir" "$_rw_branch" >&2
            return 1
        }
    fi

    _distribute_registry
}

node_alias_set() {
    _nas_alias="$1"
    _nas_user="$2"
    _nas_port="$3"
    _nas_platform="$4"
    if [ -z "$_nas_alias" ] || [ -z "$_nas_user" ] || [ -z "$_nas_port" ] || [ -z "$_nas_platform" ]; then
        printf '[ERROR] node_alias_set: alias, user, port and platform are required\n' >&2
        return 1
    fi
    _registry_write "$(node_id)" "$_nas_alias" "$_nas_user" "$_nas_port" "$_nas_platform"
}

registry_row_by_alias() {
    _rrba_alias="$1"
    [ -n "$_rrba_alias" ] || return 0
    _identity_registry_warn_once
    [ -f "$REGISTRY_DB" ] || return 0
    blockdb_get "$REGISTRY_DB" alias "$_rrba_alias"
}

registry_row_by_hostkey() {
    _rrbh_hk="$1"
    [ -n "$_rrbh_hk" ] || return 0
    _identity_registry_warn_once
    [ -f "$REGISTRY_DB" ] || return 0
    blockdb_get "$REGISTRY_DB" hostkey "$_rrbh_hk"
}

_distribute_registry() {
    _dr_devdb="$BASE/state/ts-devices.db"
    [ -f "$REGISTRY_DB" ] || return 0
    has_cmd nssh || { log WARN "nssh not found -- registry not distributed"; return 0; }
    [ -f "$_dr_devdb" ] || return 0
    _dr_local_head="$(cd "$(dirname "$REGISTRY_DB")" 2>/dev/null && git rev-parse HEAD 2>/dev/null)"
    _my_alias="$(node_alias 2>/dev/null || printf '')"
    _dr_aliases="$(awk '
        BEGIN { RS=""; FS="\n" }
        {
            for (i = 1; i <= NF; i++) {
                colon = index($i, ":")
                if (colon == 0) continue
                fk = substr($i, 1, colon - 1)
                if (fk == "alias") { print substr($i, colon + 2); break }
            }
        }
    ' "$_dr_devdb" 2>/dev/null)"
    printf '%s\n' "$_dr_aliases" | while IFS= read -r _na; do
        [ -n "$_na" ] || continue
        [ "$_na" = "$_my_alias" ] && continue
        _nblk="$(blockdb_get "$_dr_devdb" alias "$_na")"
        [ -n "$_nblk" ] || continue
        _nip="$(blockdb_field "$_nblk" ip)"
        _nport="$(blockdb_field "$_nblk" port)"
        [ -n "$_nport" ] || _nport=8022
        [ -n "$_nip" ] || { log WARN "registry -> $_na skipped (no ip)"; continue; }
        if ! reachable_ssh "$_nip" "$_nport"; then
            log WARN "registry -> $_na skipped (unreachable: $_nip:$_nport)"
            continue
        fi
        _dr_remote_head="$(nssh "$_na" "cd ~/.nina-registry 2>/dev/null && git pull --rebase origin main >/dev/null 2>&1 && git rev-parse HEAD 2>/dev/null" 2>/dev/null)"
        if [ -z "$_dr_remote_head" ]; then
            log WARN "registry pull on $_na failed"
            continue
        fi
        if [ -n "$_dr_local_head" ] && [ "$_dr_remote_head" = "$_dr_local_head" ]; then
            log OK "registry synced -> $_na (MATCH $_dr_remote_head)"
        else
            log WARN "registry synced -> $_na (DIFF: local=${_dr_local_head:-?} remote=$_dr_remote_head)"
        fi
    done
}
