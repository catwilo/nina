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
    if node_alias_set "$_psi_alias" "$_psi_user" "$_psi_port" android; then
        printf "%s\n" "$_psi_alias"
        return 0
    fi
    return 1
}
