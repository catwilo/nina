#!/bin/sh
# ssh_bootstrap.sh -- SSH key generation + bidirectional handshake distribution.
#
# Extracted from install.sh (noemap#15 original) so it can also run from
# scan.sh (noemap#289) at the end of a normal noemap discovery run, not
# only during installation.
#
# Requires: has_cmd, log (util.sh); blockdb_get/blockdb_list/blockdb_field
# (blockdb.sh); nssh on PATH; optionally is_local_ip (identity.sh) to skip
# self.
#
# ssh_key_bootstrap devices_db_path -- generates ~/.ssh/id_ed25519 if
# missing, distributes the public key to every reachable-without-password
# node in devices_db_path, prints manual ssh-copy-id instructions for
# nodes still needing first-time setup, then verifies the final handshake
# per alias.
ssh_key_bootstrap() {
    _skb_devdb="$1"

    export NOEMAP_SSH_ROLE=automation

    _skb_key="$HOME/.ssh/id_ed25519"
    _skb_pub="$_skb_key.pub"

    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    if [ ! -f "$_skb_key" ]; then
        if has_cmd ssh-keygen; then
            ssh-keygen -t ed25519 -N "" -f "$_skb_key" -C "noemap@$(hostname 2>/dev/null || echo node)" >/dev/null 2>&1 \
                && log OK "generated ssh key: $_skb_key" \
                || { log WARN "ssh-keygen failed -- skipping key bootstrap"; return 0; }
        else
            log WARN "ssh-keygen not found -- skipping key bootstrap"; return 0
        fi
    else
        log INFO "ssh key already present: $_skb_key"
    fi
    chmod 600 "$_skb_key" 2>/dev/null || true
    [ -f "$_skb_pub" ] || { log WARN "no public key at $_skb_pub -- skipping distribution"; return 0; }

    [ -f "$_skb_devdb" ] && [ -s "$_skb_devdb" ] || { log INFO "no nodes registered -- key distribution skipped"; return 0; }
    has_cmd nssh || { log INFO "nssh unavailable -- key distribution skipped"; return 0; }

    _skb_pubdata="$(cat "$_skb_pub")"
    _skb_need_manual=""

    _skb_aliases="$(blockdb_list "$_skb_devdb" | awk '
        BEGIN { RS=""; FS="\n" }
        {
            for (i = 1; i <= NF; i++) {
                colon = index($i, ":")
                if (colon == 0) continue
                fk = substr($i, 1, colon - 1)
                if (fk == "alias") { print substr($i, colon + 2); break }
            }
        }
    ')"
    while IFS= read -r _skb_a; do
        [ -n "$_skb_a" ] || continue
        _skb_blk="$(blockdb_get "$_skb_devdb" alias "$_skb_a")"
        [ -n "$_skb_blk" ] || continue
        _skb_self="$(node_alias 2>/dev/null || printf '')"
        if [ -n "$_skb_self" ] && [ "$_skb_a" = "$_skb_self" ]; then continue; fi
        _skb_ip="$(blockdb_field "$_skb_blk" ip)"
        if command -v is_local_ip >/dev/null 2>&1 && is_local_ip "$_skb_ip"; then continue; fi
        if nssh "$_skb_a" "true" >/dev/null 2>&1; then
            nssh "$_skb_a" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && grep -qxF '$_skb_pubdata' ~/.ssh/authorized_keys || printf '%s\n' '$_skb_pubdata' >> ~/.ssh/authorized_keys" >/dev/null 2>&1 \
                && log OK "key ensured on $_skb_a" \
                || log WARN "key append to $_skb_a failed"

            # Bidirectional: fetch remote's public key and add to LOCAL
            # authorized_keys so the remote can reach us without password.
            _remote_pub="$(nssh "$_skb_a" 'cat ~/.ssh/id_ed25519.pub 2>/dev/null' </dev/null 2>/dev/null || true)"
            if [ -n "$_remote_pub" ]; then
                mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys
                grep -qxF "$_remote_pub" ~/.ssh/authorized_keys 2>/dev/null || printf '%s\n' "$_remote_pub" >> ~/.ssh/authorized_keys
                log OK "remote key from $_skb_a installed locally"
            fi
        else
            # nssh failed (key not yet accepted). Try ssh-copy-id using the
            # authoritative port and user from the SAME block used by nssh
            # (never a guessed default), then re-try via nssh. Only if both
            # fail is this node added to the manual-setup list.
            _skb_port="$(blockdb_field "$_skb_blk" port)"; _skb_port="${_skb_port:-8022}"
            _skb_user="$(blockdb_field "$_skb_blk" user)"; _skb_user="${_skb_user:-u}"
            _skb_target="${_skb_user}@${_skb_ip}"
            _skb_manual_line="ssh-copy-id -p ${_skb_port} -i ${_skb_pub} ${_skb_target}"
            if has_cmd ssh-copy-id && ssh-copy-id -p "$_skb_port" -i "$_skb_pub" "$_skb_target" >/dev/null 2>&1; then
                log OK "key installed on $_skb_a via ssh-copy-id"
                # Re-attempt bidirectional exchange now that key auth works.
                if nssh "$_skb_a" "true" >/dev/null 2>&1; then
                    _remote_pub="$(nssh "$_skb_a" 'cat ~/.ssh/id_ed25519.pub 2>/dev/null' </dev/null 2>/dev/null || true)"
                    if [ -n "$_remote_pub" ]; then
                        mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys
                        grep -qxF "$_remote_pub" ~/.ssh/authorized_keys 2>/dev/null || printf '%s\n' "$_remote_pub" >> ~/.ssh/authorized_keys
                        log OK "remote key from $_skb_a installed locally"
                    fi
                    continue
                fi
            fi
            _skb_need_manual="$_skb_need_manual $_skb_a"
            _SKB_MANUAL_LINES="${_SKB_MANUAL_LINES:-}${_skb_manual_line}\n"
        fi
    done <<EOF_SKB1
$_skb_aliases
EOF_SKB1

    if [ -n "$_skb_need_manual" ]; then
        log WARN "nodes needing first-time key setup:$_skb_need_manual"
        printf '%b' "${_SKB_MANUAL_LINES:-}"
    fi

    while IFS= read -r _skb_a2; do
        [ -n "$_skb_a2" ] || continue
        _skb_blk2="$(blockdb_get "$_skb_devdb" alias "$_skb_a2")"
        [ -n "$_skb_blk2" ] || continue
        _skb_self2="$(node_alias 2>/dev/null || printf '')"
        if [ -n "$_skb_self2" ] && [ "$_skb_a2" = "$_skb_self2" ]; then
            log OK "handshake $_skb_a2: self (skipped)"
            continue
        fi
        _skb_ip2="$(blockdb_field "$_skb_blk2" ip)"
        if command -v is_local_ip >/dev/null 2>&1 && is_local_ip "$_skb_ip2"; then
            log OK "handshake $_skb_a2: self-ip (skipped)"
            continue
        fi
        if nssh "$_skb_a2" "true" >/dev/null 2>&1; then
            log OK "handshake $_skb_a2: OK"
        else
            log WARN "handshake $_skb_a2: needs setup"
        fi
    done <<EOF_SKB2
$_skb_aliases
EOF_SKB2
}
