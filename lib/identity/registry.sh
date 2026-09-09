#!/bin/sh
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
        printf '[ERROR] _registry_write: could not prepare branch %s in %s -- aborting before any write\n' \
            "$_rw_branch" "$_rw_dir" >&2
        return 1
    }

    _rw_owner_blk="$(blockdb_get "$REGISTRY_DB" alias "$_rw_alias")"
    _rw_owner="$([ -n "$_rw_owner_blk" ] && blockdb_field "$_rw_owner_blk" node_id || printf '')"
    if [ -n "$_rw_owner" ] && [ "$_rw_owner" != "$_rw_nid" ]; then
        printf '[ERROR] _registry_write: alias "%s" already registered to node %s\n' \
            "$_rw_alias" "$_rw_owner" >&2
        return 1
    fi

    _rw_prev_hk=""
    _rw_prev_row="$(blockdb_get "$REGISTRY_DB" node_id "$_rw_nid")"
    [ -n "$_rw_prev_row" ] && _rw_prev_hk="$(blockdb_field "$_rw_prev_row" hostkey)"

    _rw_hk="$_rw_prev_hk"
    if [ "$_rw_nid" = "$(node_id)" ] && command -v _get_host_key_fingerprint >/dev/null 2>&1; then
        _rw_scanned_hk="$(_get_host_key_fingerprint 127.0.0.1 "$_rw_port" 2>/dev/null)"
        # keep previous value if this run's scan produced nothing (best-effort)
        _rw_hk="${_rw_scanned_hk:-$_rw_prev_hk}"
    fi

    _rw_current="$_rw_prev_row"
    _rw_target="$(printf 'node_id: %s\nalias: %s\nuser: %s\nport: %s\nplatform: %s\nhostkey: %s\n' \
        "$_rw_nid" "$_rw_alias" "$_rw_user" "$_rw_port" "$_rw_platform" "${_rw_hk:-}")"

    if [ "$_rw_current" = "$_rw_target" ]; then
        # no local change to commit, but other nodes may still need the
        # point-(5) handshake trigger below -- do not return early.
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

# node_alias_set ALIAS USER PORT PLATFORM -- create or update THIS node's registry
# row. Thin wrapper over _registry_write using this machine's own node_id
# (guarantees local hostkey scanning applies). See _registry_write for
# the full contract.
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


# registry_row_by_alias ALIAS -- full registry.db block for the given alias
# (cloud source of truth), or empty if REGISTRY_DB missing or alias unknown.
# Complements node_registry_row(), which looks up by node_id (this node's
# own identity); this looks up any OTHER node by its alias.
registry_row_by_alias() {
    _rrba_alias="$1"
    [ -n "$_rrba_alias" ] || return 0
    _identity_registry_warn_once
    [ -f "$REGISTRY_DB" ] || return 0
    blockdb_get "$REGISTRY_DB" alias "$_rrba_alias"
}

# registry_row_by_hostkey HOSTKEY -- full registry.db block for the given
# SSH host key fingerprint (cloud source of truth), or empty if REGISTRY_DB
# missing or no node has that hostkey recorded. Twin of registry_row_by_alias,
# used to resolve a genuinely-new-to-this-node host that already has a row
# in the cloud registry under a different node, without SSH auth.
registry_row_by_hostkey() {
    _rrbh_hk="$1"
    [ -n "$_rrbh_hk" ] || return 0
    _identity_registry_warn_once
    [ -f "$REGISTRY_DB" ] || return 0
    blockdb_get "$REGISTRY_DB" hostkey "$_rrbh_hk"
}

# _distribute_registry -- ensure every known node's ~/.noemap-registry clone
# is up to date via nssh + git pull, skipping self. Called after every
# registry change so identity is never stale. Shared by node_alias_set()
# here and ndevs --node-add/--registry-set (bin/ndevs) -- single source of
# truth, moved here from bin/ndevs (ut#443 follow-up, noemap#448).
# REDESIGN (noemap#447/#448 investigation): the previous implementation
# nssh-copied a raw file to ~/.local/share/noemap/state/registry.db, which
# is NOT the path ndevs/identity.sh actually read (REGISTRY_DB default is
# ~/.noemap-registry/registry.db, the git-backed repo). That left remote
# nodes' real registry stuck on old commits (old pipe format, stale
# aliases), even though the copied file looked fine. Correct mechanism:
# have each remote node pull its own git clone, then verify convergence by
# comparing HEAD commit hashes -- printing an explicit MATCH/DIFF per node
# instead of a bare OK that hides a stale clone.
_distribute_registry() {
    _dr_devdb="$(_identity_statedir)/devices.db"
    [ -f "$REGISTRY_DB" ] || return 0
    has_cmd nssh || { log WARN "nssh not found -- registry not distributed"; return 0; }
    [ -f "$_dr_devdb" ] || return 0
    _dr_local_head="$(cd "$(dirname "$REGISTRY_DB")" 2>/dev/null && git rev-parse HEAD 2>/dev/null)"
    _my_alias="$(node_alias 2>/dev/null || printf '')"
    _dr_fail_count="$(mktemp "${TMPDIR:-/tmp}/distribute-registry-fails.XXXXXX")"
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
        [ -n "$_nport" ] || _nport=22
        if command -v is_local_ip >/dev/null 2>&1 && is_local_ip "$_nip"; then continue; fi
        case "$_nip" in 127.*|localhost) continue ;; esac
        if ! reachable_ssh "$_nip" "$_nport"; then
            log WARN "registry -> $_na skipped (unreachable: $_nip:$_nport)"
            continue
        fi
        _dr_remote_head="$(nssh "$_na" "cd ~/.nina-registry 2>/dev/null && git pull --rebase origin main >/dev/null 2>&1 && git rev-parse HEAD 2>/dev/null" 2>/dev/null)"
        if [ -z "$_dr_remote_head" ]; then
            log WARN "registry pull on $_na failed or repo not cloned -- skipped"
            printf 'x' >> "$_dr_fail_count"
            continue
        fi
        if [ -n "$_dr_local_head" ] && [ "$_dr_remote_head" = "$_dr_local_head" ]; then
            log OK "registry synced -> $_na (MATCH $_dr_remote_head)"
            # Point (5): bidirectional handshake in one run -- if the remote
            # node's own row in this (now-confirmed-current) REGISTRY_DB has
            # no hostkey yet, trigger its own node-set remotely via nssh so
            # it self-registers without a manual step on that machine. Uses
            # user/port already known locally in devices.db for that alias
            # (the credentials this node uses to reach it); node_alias_set
            # on the remote side is idempotent (no-op if already current).
            _dr_remote_hk_blk="$(blockdb_get "$REGISTRY_DB" alias "$_na")"
            _dr_remote_hk="$([ -n "$_dr_remote_hk_blk" ] && blockdb_field "$_dr_remote_hk_blk" hostkey || printf '')"
            if [ -z "$_dr_remote_hk" ]; then
                _dr_nuser="$(blockdb_field "$_nblk" user)"; _dr_nuser="${_dr_nuser:-u}"
                if nssh "$_na" "command -v nina >/dev/null 2>&1 && nina devices node-set '$_na' '$_dr_nuser' '$_nport'" >/dev/null 2>&1; then
                    log OK "triggered remote hostkey registration on $_na"
                else
                    log WARN "could not trigger remote hostkey registration on $_na -- run 'nina devices node-set $_na' there manually"
                fi
            fi
        else
            log WARN "registry synced -> $_na (DIFF: local=${_dr_local_head:-?} remote=$_dr_remote_head)"
            printf 'x' >> "$_dr_fail_count"
        fi
    done
    _dr_fails="$(wc -c < "$_dr_fail_count" 2>/dev/null || printf 0)"
    rm -f "$_dr_fail_count"
    [ "${_dr_fails:-0}" -eq 0 ]
}
