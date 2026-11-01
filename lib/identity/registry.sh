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
    _rw_os="$5"
    _rw_kind="$6"
    _rw_root="$7"
    _rw_ip="${8:-}"
    if [ -z "$_rw_nid" ] || [ -z "$_rw_alias" ] || [ -z "$_rw_user" ] || [ -z "$_rw_port" ] || [ -z "$_rw_os" ] || [ -z "$_rw_kind" ] || [ -z "$_rw_root" ]; then
        printf '[ERROR] _registry_write: node-id, alias, user, port, os, kind and root are required\n' >&2
        return 1
    fi
    _identity_registry_warn_once
    _rw_dir="$(dirname "$NODES_DB")"
    mkdir -p "$_rw_dir" 2>/dev/null || true
    [ -f "$NODES_DB" ] || : > "$NODES_DB"

    _rw_branch="chore/registry-${_rw_nid}"
    ( cd "$_rw_dir" && \
      git checkout main 2>/dev/null && \
      git pull --rebase origin main && \
      git checkout -B "$_rw_branch" ) || {
        printf '[ERROR] _registry_write: could not prepare branch %s in %s\n' \
            "$_rw_branch" "$_rw_dir" >&2
        return 1
    }

    _rw_owner_blk="$(blockdb_get "$NODES_DB" alias "$_rw_alias")"
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
        blockdb_remove "$NODES_DB" alias "$_rw_alias"
    fi

    _rw_prev_hk=""
    _rw_prev_row="$(blockdb_get "$NODES_DB" node_id "$_rw_nid")"
    _rw_prev_state="$(blockdb_field "$_rw_prev_row" state)"
    _rw_state="${_rw_prev_state:-active}"
    [ -n "$_rw_prev_row" ] && _rw_prev_hk="$(blockdb_field "$_rw_prev_row" hostkey)"

    _rw_hk="$_rw_prev_hk"
    if [ "$_rw_nid" = "$(node_id)" ] && command -v _get_host_key_fingerprint >/dev/null 2>&1; then
        _rw_scanned_hk="$(_get_host_key_fingerprint 127.0.0.1 "$_rw_port" 2>/dev/null)"
        _rw_hk="${_rw_scanned_hk:-$_rw_prev_hk}"
    fi

    _rw_current="$_rw_prev_row"
    _rw_target="$(printf 'node_id: %s\nalias: %s\nuser: %s\nport: %s\nos: %s\nkind: %s\nroot: %s\nhostkey: %s\nip: %s\nstate: %s\n' \
        "$_rw_nid" "$_rw_alias" "$_rw_user" "$_rw_port" "$_rw_os" "$_rw_kind" "$_rw_root" "${_rw_hk:-}" "${_rw_ip:-}" "$_rw_state")"

    if [ "$_rw_current" = "$_rw_target" ]; then
        :
    else
        blockdb_upsert "$NODES_DB" node_id "$_rw_nid" "$_rw_target"
        ( cd "$_rw_dir" && \
          git add nodes.db && \
          git commit -m "chore(registry): set alias ${_rw_alias} for node ${_rw_nid}" && \
          git push -u origin "$_rw_branch" --force-with-lease && \
          git checkout main && \
          git merge --ff-only "$_rw_branch" && \
          git push origin main && \
          git branch -d "$_rw_branch" && \
          git push origin --delete "$_rw_branch" ) || {
            printf '[ERROR] _registry_write: nodes.db written locally but commit/push/merge failed -- resolve manually in %s (branch: %s)\n' \
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
    _nas_os="$4"
    _nas_kind="$5"
    _nas_root="$6"
    _nas_ip="${7:-}"
    if [ -z "$_nas_alias" ] || [ -z "$_nas_user" ] || [ -z "$_nas_port" ] || [ -z "$_nas_os" ] || [ -z "$_nas_kind" ] || [ -z "$_nas_root" ]; then
        printf '[ERROR] node_alias_set: alias, user, port, os, kind and root are required\n' >&2
        return 1
    fi
    _registry_write "$(node_id)" "$_nas_alias" "$_nas_user" "$_nas_port" "$_nas_os" "$_nas_kind" "$_nas_root" "$_nas_ip"
}

registry_row_by_alias() {
    _rrba_alias="$1"
    [ -n "$_rrba_alias" ] || return 0
    _identity_registry_warn_once
    [ -f "$NODES_DB" ] || return 0
    blockdb_get "$NODES_DB" alias "$_rrba_alias"
}


_distribute_registry() {
    [ -f "$NODES_DB" ] || return 0
    has_cmd nya || { log WARN "nya not found -- nodes.db not distributed"; return 0; }
    has_cmd python3 || { log WARN "python3 not found -- cannot summarize distribution"; return 0; }
    _dr_json="$(nya -m json @all "cd ~/.nina-registry && git pull --rebase origin main")" || true
    _dr_out="$(printf '%s' "$_dr_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not d.get("workers"):
    print("EMPTY")
    sys.exit(0)
bad = [w["alias"] for w in d["workers"] if w.get("exit", 0) != 0]
print(" ".join(bad))
')"
    if [ "$_dr_out" = "EMPTY" ]; then
        log INFO "no active peers -- nodes.db distribution deferred"
    elif [ -n "$_dr_out" ]; then
        log WARN "nodes.db NOT converged on: $_dr_out -- rerun when reachable"
    else
        log OK "nodes.db distributed to every active peer"
    fi
}
