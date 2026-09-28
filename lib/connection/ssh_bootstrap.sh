#!/bin/sh
# ssh_bootstrap.sh -- distribute SSH pubkey to every registered tailscale peer.

ssh_key_bootstrap() {
    export NOEMAP_SSH_ROLE=automation

    _key="$HOME/.ssh/id_ed25519"
    _pub="$_key.pub"
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    if [ ! -f "$_key" ]; then
        if has_cmd ssh-keygen; then
            ssh-keygen -t ed25519 -N "" -f "$_key" -C "nina@$(hostname 2>/dev/null || echo node)" >/dev/null 2>&1 \
                && log OK "generated ssh key: $_key" \
                || { log WARN "ssh-keygen failed"; return 0; }
        else
            log WARN "ssh-keygen not found"; return 0
        fi
    fi
    chmod 600 "$_key" 2>/dev/null || true
    [ -f "$_pub" ] || { log WARN "no public key at $_pub"; return 0; }

    _ts_db="$BASE/state/ts-devices.db"
    [ -f "$_ts_db" ] && [ -s "$_ts_db" ] || { log INFO "no peers registered"; return 0; }
    has_cmd nssh || { log INFO "nssh unavailable"; return 0; }

    _pubdata="$(cat "$_pub")"
    _my_alias="$(node_alias 2>/dev/null || true)"
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
    ' "$_ts_db")"

    printf '%s\n' "$_aliases" | while IFS= read -r _ka; do
        [ -n "$_ka" ] || continue
        [ "$_ka" = "$_my_alias" ] && continue
        if nssh "$_ka" "true" </dev/null >/dev/null 2>&1; then
            nssh "$_ka" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && grep -qxF '$_pubdata' ~/.ssh/authorized_keys || printf '%s\n' '$_pubdata' >> ~/.ssh/authorized_keys" </dev/null >/dev/null 2>&1 \
                && log OK "key ensured on $_ka" \
                || log WARN "key append to $_ka failed"
            _remote_pub="$(nssh "$_ka" 'cat ~/.ssh/id_ed25519.pub 2>/dev/null' </dev/null 2>/dev/null || true)"
            if [ -n "$_remote_pub" ]; then
                mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys
                grep -qxF "$_remote_pub" ~/.ssh/authorized_keys 2>/dev/null || printf '%s\n' "$_remote_pub" >> ~/.ssh/authorized_keys
                log OK "remote key from $_ka installed locally"
            fi
        else
            log WARN "peer $_ka unreachable -- manual ssh-copy-id once"
        fi
    done
}
