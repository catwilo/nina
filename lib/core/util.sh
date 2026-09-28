#!/bin/sh
# util.sh -- logging, command checks, session temp, atomic write, dirs, env.

log() {
    _lvl="$1"; shift; _msg="$*"
    _ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '?')"
    printf '[%s] %s\n' "$_lvl" "$_msg" >&2
    if [ -n "${BASE:-}" ]; then
        _log="${BASE}/logs/nina.log"
        _log_size=0
        if [ -f "$_log" ]; then _log_size="$(wc -c < "$_log" 2>/dev/null || printf '0')"; fi
        if [ "$_log_size" -gt 204800 ]; then mv -f "$_log" "${_log}.1" 2>/dev/null || true; fi
        printf '%s [%s] %s\n' "$_ts" "$_lvl" "$_msg" >> "$_log" 2>/dev/null || true
    fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
    has_cmd "$1" || { log ERROR "missing hard dependency: $1"; exit 1; }
}

SESSION_TMP_DIR=""

init_session() {
    if [ -n "$SESSION_TMP_DIR" ] && [ -d "$SESSION_TMP_DIR" ]; then return 0; fi
    SESSION_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nina.XXXXXX")" || {
        log ERROR "cannot create session temp dir"; exit 1
    }
    trap 'cleanup_session' EXIT
    trap 'cleanup_session; trap - INT;  kill -INT  "$$"' INT
    trap 'cleanup_session; trap - TERM; kill -TERM "$$"' TERM
}

cleanup_session() {
    if [ -n "$SESSION_TMP_DIR" ] && [ -d "$SESSION_TMP_DIR" ]; then rm -rf "$SESSION_TMP_DIR"; fi
    SESSION_TMP_DIR=""
}

session_tmp() { printf '%s/%s\n' "$SESSION_TMP_DIR" "${1:-tmp}"; }

atomic_write() {
    _target="$1"
    _dir="$(dirname "$_target")"
    _tmp="${_dir}/.nina_tmp.$(basename "$_target").$$"
    cat > "$_tmp" || { rm -f "$_tmp"; return 1; }
    if [ ! -s "$_tmp" ]; then
        rm -f "$_tmp"; log WARN "atomic_write: empty content"; return 1
    fi
    mv -f "$_tmp" "$_target" || { rm -f "$_tmp"; log ERROR "atomic_write: mv failed"; return 1; }
}

ensure_dirs() {
    mkdir -p "$BASE/state" "$BASE/logs" "$BASE/config" "$BASE/tmp"
}

validate_env() {
    for _cmd in awk sed grep cut ssh; do require_cmd "$_cmd"; done
    if ! has_cmd scp; then log WARN "scp not found -- nscp unavailable"; fi
}
