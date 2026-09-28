#!/bin/sh
# output.sh -- tailscale-only render helpers.

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    _C_RESET='\033[0m'; _C_CYAN='\033[0;36m'; _C_GREEN='\033[0;32m'
    _C_YELLOW='\033[1;33m'; _C_BOLD='\033[1m'; _C_DIM='\033[2m'
else
    _C_RESET='' _C_CYAN='' _C_GREEN='' _C_YELLOW='' _C_BOLD='' _C_DIM=''
fi

render_registered_devices() {
    _ts_db="$BASE/state/ts-devices.db"
    [ -f "$_ts_db" ] && [ -s "$_ts_db" ] || return 0

    printf "${_C_BOLD}${_C_CYAN}  REGISTERED DEVICES${_C_RESET}\n\n"
    _local_alias="$(node_alias 2>/dev/null || true)"

    awk '
        BEGIN { RS=""; FS="\n" }
        {
            for (i = 1; i <= NF; i++) {
                colon = index($i, ":")
                if (colon == 0) continue
                fk = substr($i, 1, colon - 1)
                if (fk == "alias") { print substr($i, colon + 2); break }
            }
        }
    ' "$_ts_db" | while IFS= read -r _rrd_alias; do
        [ -n "$_rrd_alias" ] || continue
        _rrd_blk="$(blockdb_get "$_ts_db" alias "$_rrd_alias")"
        [ -n "$_rrd_blk" ] || continue
        _rrd_ip="$(blockdb_field "$_rrd_blk" ip)"
        _rrd_user="$(blockdb_field "$_rrd_blk" user)"; _rrd_user="${_rrd_user:-u}"
        _rrd_port="$(blockdb_field "$_rrd_blk" port)"; _rrd_port="${_rrd_port:-8022}"
        if [ -n "$_local_alias" ] && [ "$_rrd_alias" = "$_local_alias" ]; then
            printf "  ${_C_GREEN}alias=%s${_C_RESET} ip=%s port=%s user=%s (this node)\n" \
                "$_rrd_alias" "$_rrd_ip" "$_rrd_port" "$_rrd_user"
        else
            printf "  alias=%s ip=%s port=%s user=%s\n" \
                "$_rrd_alias" "$_rrd_ip" "$_rrd_port" "$_rrd_user"
        fi
    done
    printf '\n'
}

render_connect() {
    _ts_db="$BASE/state/ts-devices.db"
    [ -f "$_ts_db" ] && [ -s "$_ts_db" ] || return 0
    _ex="$(awk '
        BEGIN { RS=""; FS="\n" }
        {
            for (i = 1; i <= NF; i++) {
                colon = index($i, ":")
                if (colon == 0) continue
                fk = substr($i, 1, colon - 1)
                if (fk == "alias") { print substr($i, colon + 2); exit }
            }
        }
    ' "$_ts_db")"
    _ex="${_ex:-<alias>}"
    printf "${_C_BOLD}${_C_CYAN}  CONNECT${_C_RESET}  ${_C_DIM}(replace %s with any alias)${_C_RESET}\n\n" "$_ex"
    printf "  %-12s  %s\n" "shell"     "nssh $_ex"
    printf "  %-12s  %s\n" "cmd"       "nssh $_ex uname -a"
    printf "  %-12s  %s\n" "copy from" "nscp $_ex:/remote/path ./"
    printf "  %-12s  %s\n" "copy to"   "nscp ./file $_ex:/remote/"
    printf "  %-12s  %s\n" "clipboard" "nina clip get $_ex:/remote/file"
    printf '\n'
}
