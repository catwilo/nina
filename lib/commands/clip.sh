#!/bin/sh
# clip.sh -- nina clip subcommand.

# _clip_get -- migrate from bin/nclip (pre-fusion). Copies a remote file to
# the local clipboard via SSH cat + clipso. Soft dependency: clipso.
_clip_get() {
    [ $# -eq 1 ] || { printf 'usage: nina clip get <alias:/remote/path>\n' >&2; exit 1; }
    _target="$1"
    case "$_target" in
        *:*) ;;
        *) log ERROR "clip get requires alias:/path notation (got: $_target)"; exit 1 ;;
    esac
    _alias="${_target%%:*}"
    _remote_path="${_target#*:}"
    _row="$(resolve_device "$_alias" "$BASE/state")"
    _ip="$(printf '%s\n'   "$_row" | cut -d'|' -f1)"
    _user="$(printf '%s\n' "$_row" | cut -d'|' -f2)"
    _port="$(printf '%s\n' "$_row" | cut -d'|' -f3)"
    _user="$(_ensure_user "$_alias" "$DB" "$_user")"
    [ -n "$_user" ] || { log ERROR "no user configured for \"$_alias\""; exit 1; }
    _safe_path="$(printf '%s' "$_remote_path" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")"
    _ssh_cat() {
        if [ -f "$CFG" ]; then
            ssh -F "$CFG" -p "$_port" -o ConnectTimeout=5 "${_user}@${_ip}" "cat ${_safe_path}"
        else
            ssh -p "$_port" -o ConnectTimeout=5 "${_user}@${_ip}" "cat ${_safe_path}"
        fi
    }
    CLIPSO="${CLIPSO_BIN:-$(command -v clipso 2>/dev/null || echo "$HOME/unix-toolkit-tools/clipso/clipso.sh")}"
    if [ -x "$CLIPSO" ]; then
        _tmp="$(mktemp "${TMPDIR:-/tmp}/nina-clip-get.XXXXXX")"
        trap 'rm -f "$_tmp"' EXIT INT TERM
        if ! _ssh_cat > "$_tmp"; then
            log ERROR "SSH transfer failed -- check host, port, key auth, and path"
            exit 1
        fi
        "$CLIPSO" < "$_tmp"
    else
        log WARN "clipso not found at $CLIPSO -- printing file to stdout instead"
        log WARN "set CLIPSO_BIN or install clipso at ~/unix-toolkit-tools/clipso/clipso.sh to enable clipboard"
        _ssh_cat
    fi
}


# _clip_send -- migrate from bin/nclip-send (pre-fusion). Sends local stdin
# to a remote device clipboard. Default TCP/ncat; --ssh forces SSH transport.
_clip_send() {
    TCP_PORT="${CLIP_TCP_PORT:-9988}"
    _alias="${1:-}"
    _mode="${CLIP_MODE:-tcp}"
    case "$_alias" in
        --ssh) _mode="ssh"; shift; _alias="${1:-}" ;;
        '')    printf 'usage: <cmd> | nina clip send [--ssh] <alias>\n' >&2; exit 1 ;;
    esac
    [ -n "$_alias" ] || { printf 'usage: <cmd> | nina clip send [--ssh] <alias>\n' >&2; exit 1; }
    _row="$(resolve_device "$_alias" "$BASE/state")"
    _ip="$(printf '%s\n'   "$_row" | cut -d'|' -f1)"
    _user="$(printf '%s\n' "$_row" | cut -d'|' -f2)"
    _port="$(printf '%s\n' "$_row" | cut -d'|' -f3)"
    [ -n "$_ip" ] && [ -n "$_user" ] || { log ERROR "could not resolve alias: $_alias"; exit 1; }
    _tmp="$(mktemp "${TMPDIR:-/tmp}/nina-clip-send.XXXXXX")"
    trap 'rm -f "$_tmp"' EXIT INT TERM
    cat > "$_tmp"
    [ -s "$_tmp" ] || { log ERROR "empty input -- nothing to send"; exit 1; }
    _send_nc() {
        [ -n "$_ip" ] || return 1
        if command -v nc >/dev/null 2>&1; then
            case "$(nc -h 2>&1)" in
                *-N*) nc -N "$_ip" "$TCP_PORT" < "$_tmp" ;;
                *)    nc "$_ip" "$TCP_PORT" < "$_tmp" ;;
            esac
        elif command -v ncat >/dev/null 2>&1; then
            ncat "$_ip" "$TCP_PORT" < "$_tmp"
        else
            return 1
        fi
    }
    _send_ssh() {
        if [ -f "$CFG" ]; then
            ssh -F "$CFG" -p "$_port" -o ConnectTimeout=5 -o BatchMode=yes \
                -o ControlMaster=auto -o ControlPath="$HOME/.ssh/cm/%r@%h:%p" -o ControlPersist=4h \
                "${_user}@${_ip}" 'PATH=$HOME/.local/bin:$PATH CLIPSO_NO_SUMMARY=1 clipso' < "$_tmp" 2>/dev/null
        else
            ssh -p "$_port" -o ConnectTimeout=5 -o BatchMode=yes \
                -o ControlMaster=auto -o ControlPath="$HOME/.ssh/cm/%r@%h:%p" -o ControlPersist=4h \
                "${_user}@${_ip}" 'PATH=$HOME/.local/bin:$PATH CLIPSO_NO_SUMMARY=1 clipso' < "$_tmp" 2>/dev/null
        fi
    }
    if [ "$_mode" = "ssh" ]; then
        if _send_ssh; then
            :
        else
            log ERROR "SSH transfer failed; check host, port, key auth, remote clipso"
            exit 1
        fi
    else
        if _send_nc 2>/dev/null; then
            :
        else
            log ERROR "TCP transfer failed; check nina clip serve start on dst, or retry with --ssh"
            exit 1
        fi
    fi
}


# _clip_set -- migrate from bin/nclip-set (pre-fusion). Defines clipboard
# direction src->dst, starts listener on dst, runs smoke-test.
_clip_set() {
    [ $# -eq 2 ] || { printf 'usage: nina clip set <src-alias> <dst-alias>\n' >&2; exit 1; }
    _src="$1"; _dst="$2"
    [ "$_src" != "$_dst" ] || { log ERROR "src and dst must differ (got: $_src)"; exit 1; }
    CONF="$BASE/state/clip-dir.conf"
    resolve_device "$_src" "$BASE/state" >/dev/null
    resolve_device "$_dst" "$BASE/state" >/dev/null
    mkdir -p "$(dirname "$CONF")"
    _tmp_conf="$(mktemp "${TMPDIR:-/tmp}/clip-dir.XXXXXX")"
    {
        printf '# nina clip direction\n'
        printf 'CLIP_SRC=%s\n' "$_src"
        printf 'CLIP_DST=%s\n' "$_dst"
    } > "$_tmp_conf"
    mv -f "$_tmp_conf" "$CONF"
    printf '[OK]    direction written: %s -> %s\n' "$_src" "$_dst" >&2
    _self_alias="$(node_alias 2>/dev/null || true)"
    if [ "$_self_alias" = "$_dst" ]; then
        if ! _clip_serve start >/dev/null 2>&1; then
            log ERROR "failed to start clip serve locally on '$_dst'"
            exit 1
        fi
        printf '[OK]    clip serve started locally on %s (self)\n' "$_dst" >&2
    elif [ -z "$_self_alias" ]; then
        log ERROR "local node identity unresolved -- run nina self-register first"
        exit 1
    else
        if ! nssh "$_dst" 'nina clip serve start' >/dev/null 2>&1; then
            log ERROR "failed to start clip serve on '$_dst'"
            exit 1
        fi
        printf '[OK]    clip serve started on %s\n' "$_dst" >&2
    fi
    _token="nina-clip-test-$$-$(date +%s)"
    if ! printf '%s' "$_token" | _clip_send "$_dst" >/dev/null 2>&1; then
        log ERROR "smoke-test send failed (src '$_src' -> dst '$_dst')"
        exit 1
    fi
    if [ "$_self_alias" = "$_dst" ]; then
        _got="$(cat "${XDG_CACHE_HOME:-$HOME/.cache}/clipso/last" 2>/dev/null || true)"
    else
        _got="$(nssh "$_dst" 'cat "${XDG_CACHE_HOME:-$HOME/.cache}/clipso/last"' 2>/dev/null || true)"
    fi
    if [ "$_got" = "$_token" ]; then
        printf '[OK]    smoke-test PASS  %s -> %s\n' "$_src" "$_dst" >&2
        exit 0
    else
        log ERROR "smoke-test FAIL  sent '$_token' but dst returned '$_got'"
        exit 1
    fi
}
_clip_clear() {
    CONF="$BASE/state/clip-dir.conf"
    if [ -f "$CONF" ]; then
        _old_dst="$(. "$CONF" 2>/dev/null; printf '%s' "${CLIP_DST:-}")"
        if [ -n "$_old_dst" ]; then
            _self_alias="$(node_alias 2>/dev/null || true)"
            if [ "$_self_alias" = "$_old_dst" ]; then
                _clip_serve stop >/dev/null 2>&1 || true
                printf '[OK]    clip serve stopped on %s\n' "$_old_dst" >&2
            else
                if nssh "$_old_dst" 'nina clip serve stop' >/dev/null 2>&1; then
                    printf '[OK]    clip serve stopped on %s\n' "$_old_dst" >&2
                else
                    printf '[WARN]  could not stop clip serve on %s\n' "$_old_dst" >&2
                fi
            fi
        fi
    fi
    rm -f "$CONF"
    printf '[OK]    direction cleared\n' >&2
}


# _clip_tunnel -- migrate from bin/nclip-listen socket mode (pre-fusion).
# Manages the Unix-socket listener exposed via SSH RemoteForward.
_clip_tunnel() {
    SOCK="${CLIP_FORWARD_SOCK:-$HOME/.nina-clip.sock}"
    CLIP_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/clipso/last"
    _clip_cmd=""
    if command -v termux-clipboard-set >/dev/null 2>&1; then
        _clip_cmd="termux-clipboard-set"
    elif command -v pbcopy >/dev/null 2>&1; then
        _clip_cmd="pbcopy"
    elif command -v wl-copy >/dev/null 2>&1; then
        _clip_cmd="wl-copy"
    else
        printf '[ERROR] no clipboard tool found (termux-clipboard-set / pbcopy / wl-copy)\n' >&2
        exit 1
    fi
    _is_running() { tmux has-session -t nina-clip-tunnel 2>/dev/null; }
    _start() {
        if _is_running; then
            printf '[INFO]  clip tunnel already running (tmux session nina-clip-tunnel)\n' >&2
            return 0
        fi
        rm -f "$SOCK"
        mkdir -p "$(dirname "$CLIP_CACHE")"
        _loop='while true; do
            _tmp_clip="${TMPDIR:-/tmp}/nina-clip-recv.$$"
            python3 -c "
import socket,sys
p=sys.argv[1];o=sys.argv[2]
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,524288)
s.bind(p);s.listen(1)
c,_=s.accept();d=b\"\"
while True:
    chunk=c.recv(65536)
    if not chunk:break
    d+=chunk
c.close();s.close()
open(o,\"wb\").write(d)
" "$SOCK" "$_tmp_clip" 2>/dev/null || true
            if [ -s "$_tmp_clip" ]; then
                cp "$_tmp_clip" "$CLIP_CACHE"
                setsid "$_clip_cmd" < "$_tmp_clip" 2>/dev/null || "$_clip_cmd" < "$_tmp_clip" || true
            fi
            rm -f "$_tmp_clip"
        done'
        _inner="export SOCK=$(printf %q "$SOCK") CLIP_CACHE=$(printf %q "$CLIP_CACHE") _clip_cmd=$(printf %q "$_clip_cmd"); ${_loop}"
        tmux new-session -d -s nina-clip-tunnel "$_inner"
        printf '[OK]    clip tunnel started (tmux session nina-clip-tunnel, sock %s)\n' "$SOCK" >&2
    }
    _stop() {
        if ! _is_running; then
            printf '[INFO]  clip tunnel not running\n' >&2
            rm -f "$SOCK"
            return 0
        fi
        tmux kill-session -t nina-clip-tunnel 2>/dev/null || true
        rm -f "$SOCK"
        printf '[OK]    clip tunnel stopped (tmux session nina-clip-tunnel)\n' >&2
    }
    _status() {
        if _is_running; then
            printf '[OK]    running  tmux session=nina-clip-tunnel  sock=%s\n' "$SOCK" >&2
            [ -S "$SOCK" ] && printf '[OK]    socket exists\n' >&2 || printf '[WARN]  socket missing -- RemoteForward not active?\n' >&2
        else
            printf '[INFO]  not running\n' >&2
        fi
    }
    case "${1:-}" in
        start)   _start ;;
        stop)    _stop ;;
        restart) _stop; _start ;;
        status)  _status ;;
        *) printf 'usage: nina clip tunnel <start|stop|restart|status>\n' >&2; exit 1 ;;
    esac
}


# _clip_serve -- migrate from bin/nclip-listen TCP mode (pre-fusion).
# Manages the TCP/ncat listener on port 9988, independent of any SSH session.
_clip_serve() {
    TCP_PORT="${CLIP_TCP_PORT:-9988}"
    CLIP_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/clipso/last"
    _clip_cmd=""
    if command -v termux-clipboard-set >/dev/null 2>&1; then
        _clip_cmd="termux-clipboard-set"
    elif command -v pbcopy >/dev/null 2>&1; then
        _clip_cmd="pbcopy"
    elif command -v wl-copy >/dev/null 2>&1; then
        _clip_cmd="wl-copy"
    else
        printf '[ERROR] no clipboard tool found (termux-clipboard-set / pbcopy / wl-copy)\n' >&2
        exit 1
    fi
    _is_running() { tmux has-session -t nina-clip-serve 2>/dev/null; }
    _start() {
        if ! command -v ncat >/dev/null 2>&1; then
            printf '[ERROR] ncat not found  TCP mode requires ncat\n' >&2
            return 1
        fi
        if _is_running; then
            printf '[INFO]  clip serve already running (tmux session nina-clip-serve)\n' >&2
            return 0
        fi
        mkdir -p "$(dirname "$CLIP_CACHE")"
        _tcp_loop='while true; do
            _tcp_tmp="${TMPDIR:-/tmp}/nina-clip-tcp-recv.$$"
            ncat -l 0.0.0.0 $TCP_PORT > "$_tcp_tmp" 2>/dev/null || true
            if [ -s "$_tcp_tmp" ]; then
                cp "$_tcp_tmp" "$CLIP_CACHE"
                setsid "$_clip_cmd" < "$_tcp_tmp" 2>/dev/null || "$_clip_cmd" < "$_tcp_tmp" || true
            fi
            rm -f "$_tcp_tmp"
        done'
        _inner="export TCP_PORT=$(printf %q "$TCP_PORT") CLIP_CACHE=$(printf %q "$CLIP_CACHE") _clip_cmd=$(printf %q "$_clip_cmd"); ${_tcp_loop}"
        tmux new-session -d -s nina-clip-serve "$_inner"
        printf '[OK]    clip serve started (tmux session nina-clip-serve, port %s)\n' "$TCP_PORT" >&2
    }
    _stop() {
        if ! _is_running; then
            printf '[INFO]  clip serve not running\n' >&2
            return 0
        fi
        tmux kill-session -t nina-clip-serve 2>/dev/null || true
        pkill -f "ncat -l $TCP_PORT" 2>/dev/null || true
        printf '[OK]    clip serve stopped (tmux session nina-clip-serve)\n' >&2
    }
    _status() {
        if _is_running; then
            printf '[OK]    running  tmux session=nina-clip-serve  port=%s\n' "$TCP_PORT" >&2
        else
            printf '[INFO]  not running\n' >&2
        fi
    }
    case "${1:-}" in
        start)   _start ;;
        stop)    _stop ;;
        restart) _stop; _start ;;
        status)  _status ;;
        *) printf 'usage: nina clip serve <start|stop|restart|status>\n' >&2; exit 1 ;;
    esac
}


_do_clip() {
    _clip_sub="${1:-}"
    case "$_clip_sub" in
        get|send|set|clear|status|tunnel|serve) shift || true ;;
        -h|--help) _clip_usage >&2; exit 0 ;;
        *) printf '[ERROR] unknown clip subcommand: %s\n' "$_clip_sub" >&2; _clip_usage >&2; exit 1 ;;
    esac
    case "$_clip_sub" in
        get)    _clip_get "$@" ;;
        send)   _clip_send "$@" ;;
        set)    _clip_set "$@" ;;
        clear)  _clip_clear ;;
        status) _clip_status ;;
        tunnel) _clip_tunnel "$@" ;;
        serve)  _clip_serve "$@" ;;
    esac
}
_clip_status() {
    CONF="$BASE/state/clip-dir.conf"
    if [ -f "$CONF" ]; then
        printf '[OK]    direction config:\n' >&2
        cat "$CONF"
    else
        printf '[INFO]  no direction set (%s missing)\n' "$CONF" >&2
    fi
}
_clip_usage() {
    cat <<'USAGE'
usage: nina clip <subcommand> [options]

subcommands:
  get <alias:/remote/path>   copy a remote file to the local clipboard
  send [--ssh] <alias>       send stdin to a remote clipboard (TCP by default)
  set <src-alias> <dst-alias>  define clipboard direction and smoke-test
  clear                      clear direction config and stop listeners
  status                     show direction config
  tunnel <start|stop|restart|status>  manage the SSH RemoteForward listener
  serve <start|stop|restart|status>   manage the TCP/ncat listener (port 9988)
USAGE
}
