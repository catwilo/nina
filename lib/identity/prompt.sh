#!/bin/sh
# prompt.sh -- interactive identity prompt for this node.
# Rules: name required (no suggestion), user default u, no prose.

_prompt_self_identity() {
    [ -t 1 ] || return 1
    command -v node_alias_set >/dev/null 2>&1 || return 1
    _psi_alias=""
    while [ -z "$_psi_alias" ]; do
        printf "node name: " >&2
        read -r _psi_alias </dev/tty || _psi_alias=""
        case "$_psi_alias" in
            *[!a-zA-Z0-9_-]*|"")
                printf "invalid (a-z 0-9 _ -)\n" >&2; _psi_alias="" ;;
        esac
        [ "${#_psi_alias}" -le 20 ] || { printf "max 20 chars\n" >&2; _psi_alias=""; }
    done
    _psi_user="u"
    _psi_port="8022"
    _psi_os="$(detect_os 2>/dev/null || printf 'linux')"
    _psi_kind="$(detect_kind 2>/dev/null || printf 'laptop')"
    _psi_root="no"
    _psi_ip="$(detect_tailscale_ip 2>/dev/null || true)"
    if node_alias_set "$_psi_alias" "$_psi_user" "$_psi_port" "$_psi_os" "$_psi_kind" "$_psi_root" "$_psi_ip"; then
        printf "%s\n" "$_psi_alias"
        return 0
    fi
    return 1
}
