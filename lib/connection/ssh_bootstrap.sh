#!/bin/sh
# ssh_bootstrap.sh -- distribute SSH pubkey to every registered tailscale peer.
#
# Self-contained: loads its own dependencies so any caller (nina, install.sh)
# can invoke ssh_key_bootstrap without pre-sourcing other modules.

_ssh_bootstrap_load_deps() {
    command -v blockdb_get >/dev/null 2>&1 && \
    command -v node_alias  >/dev/null 2>&1 && return 0
    _sbd_here="$(cd "$(dirname "$0")" && pwd)"
    for _sbd_mod in core/util.sh core/blockdb.sh core/network.sh identity/identity.sh; do
        for _sbd_root in "$_sbd_here/.." "$HOME/.local/share/nina/lib"; do
            [ -f "$_sbd_root/$_sbd_mod" ] || continue
            # shellcheck source=/dev/null
            . "$_sbd_root/$_sbd_mod"
            break
        done
    done
}
_ssh_bootstrap_load_deps

ssh_key_bootstrap() {
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

    _db="$NODES_DB"
    [ -f "$_db" ] && [ -s "$_db" ] || { log INFO "no peers registered"; return 0; }
    has_cmd nya || { log INFO "nya unavailable"; return 0; }

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
    ' "$_db")"

    # Fan-out paralelo por peer: cada worker maneja un nodo (probe TCP,
    # append del pubkey local, fetch del pubkey remoto) y escribe un
    # archivo de resultado por peer. El padre agrega los resultados en
    # orden estable. El append al authorized_keys LOCAL se hace en el
    # padre (despues del wait) porque workers concurrentes competirian
    # por el mismo archivo sin lock.
    _sig_dir="$(mktemp -d "${TMPDIR:-/tmp}/nina-bootstrap.XXXXXX")"
    _remote_pubs_dir="$_sig_dir/pubs"
    mkdir -p "$_remote_pubs_dir"
    printf '%s\n' "$_aliases" > "$_sig_dir/aliases"

    _pids=""
    while IFS= read -r _ka; do
        [ -n "$_ka" ] || continue
        [ "$_ka" = "$_my_alias" ] && continue
        _ka_blk="$(blockdb_get "$_db" alias "$_ka")"
        [ -n "$_ka_blk" ] || continue
        _ka_st="$(blockdb_field "$_ka_blk" state)"; _ka_st="${_ka_st:-active}"
        [ "$_ka_st" = "active" ] || continue
        _ka_ip="$(blockdb_field "$_ka_blk" ip 2>/dev/null || true)"
        _ka_port="$(blockdb_field "$_ka_blk" port 2>/dev/null || true)"
        [ -n "$_ka_port" ] || _ka_port=22
        _ka_user="$(blockdb_field "$_ka_blk" user 2>/dev/null || true)"
        [ -n "$_ka_user" ] || _ka_user=u
        _rc_file="$_sig_dir/$_ka.rc"
        _pub_file="$_remote_pubs_dir/$_ka.pub"

        (
            if [ -z "$_ka_ip" ] || ! reachable_ssh "$_ka_ip" "$_ka_port"; then
                printf 'unreachable\t%s\t%s\t%s\t%s\n' "$_ka" "$_ka_ip" "$_ka_port" "$_ka_user" > "$_rc_file"
                exit 0
            fi
            if nya "$_ka" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && grep -qxF '$_pubdata' ~/.ssh/authorized_keys || printf '%s\n' '$_pubdata' >> ~/.ssh/authorized_keys" </dev/null >/dev/null 2>&1; then
                _remote_pub="$(nya "$_ka" 'cat ~/.ssh/id_ed25519.pub 2>/dev/null' </dev/null 2>/dev/null || true)"
                if [ -n "$_remote_pub" ]; then
                    printf '%s\n' "$_remote_pub" > "$_pub_file"
                    printf 'ok\t%s\n' "$_ka" > "$_rc_file"
                else
                    printf 'ok-no-pub\t%s\n' "$_ka" > "$_rc_file"
                fi
            else
                printf 'auth-failed\t%s\t%s\t%s\t%s\n' "$_ka" "$_ka_ip" "$_ka_port" "$_ka_user" > "$_rc_file"
            fi
        ) &
        _pids="$_pids $!"
    done < "$_sig_dir/aliases"

    for _p in $_pids; do
        wait "$_p" || true
    done

    # Agregar resultados en orden estable (alfabetico por alias).
    # find|sort a archivo: <(...) es bash-only, el modulo corre bajo sh.
    find "$_sig_dir" -maxdepth 1 -name '*.rc' -print | sort > "$_sig_dir/rc-list"
    while IFS= read -r _rc; do
        [ -f "$_rc" ] || continue
        IFS=$'\t' read -r _st _a _ip _port _user < "$_rc"
        case "$_st" in
            ok)
                log OK "key ensured on $_a"
                _pf="$_remote_pubs_dir/$_a.pub"
                if [ -s "$_pf" ]; then
                    mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys
                    _rp="$(cat "$_pf")"
                    grep -qxF "$_rp" ~/.ssh/authorized_keys 2>/dev/null || printf '%s\n' "$_rp" >> ~/.ssh/authorized_keys
                    log OK "remote key from $_a installed locally"
                fi
                ;;
            ok-no-pub)
                log OK "key ensured on $_a"
                ;;
            auth-failed)
                log WARN "peer $_a reachable but key auth failed -- run once:"
                log WARN "  ssh-copy-id -p ${_port:-8022} ${_user:-u}@${_ip}"
                ;;
            unreachable)
                log WARN "peer $_a unreachable (${_ip}:${_port})"
                ;;
        esac
    done < "$_sig_dir/rc-list"

    rm -rf "$_sig_dir"
}
