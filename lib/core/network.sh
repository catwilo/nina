#!/bin/sh
# network.sh -- reachability checks, host key fingerprints, known_hosts hygiene.

reachable_ssh() {
    _rs_ip="$1"; _rs_port="${2:-22}"
    has_cmd nc || return 0
    nc -z -w5 "$_rs_ip" "$_rs_port" >/dev/null 2>&1
}

reachable_cloud() {
    has_cmd ping || return 0
    ping -c 1 -W 3 github.com >/dev/null 2>&1
}

_get_host_key_fingerprint() {
    _hk_ip="$1"; _hk_port="${2:-22}"
    has_cmd ssh-keyscan || return 0
    has_cmd ssh-keygen  || return 0
    ssh-keyscan -p "$_hk_port" -T 3 "$_hk_ip" 2>/dev/null \
        | ssh-keygen -lf - 2>/dev/null \
        | awk "{print \$2; exit}"
}

KNOWN_HOSTS="$HOME/.local/share/nina/known_hosts"

known_hosts_remove_ip() {
    _ip="$1"
    [ -f "$KNOWN_HOSTS" ] || return 0
    if has_cmd ssh-keygen; then
        ssh-keygen -R "$_ip" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
    fi
    log INFO "known_hosts: removed entries for $_ip"
}

known_hosts_sync_device() {
    _alias="$1"; _old_ip="$2"; _new_ip="$3"
    if [ "$_old_ip" != "$_new_ip" ]; then
        log INFO "device $_alias IP changed: $_old_ip -> $_new_ip"
        known_hosts_remove_ip "$_old_ip"
    fi
}
