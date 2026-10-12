#!/bin/sh
# install.sh  nina installer (symlink model)
#
# Symlinks tools, libs, and managed config files directly from the repo
# checkout, so updates to these files (code, ssh_config) are reflected
# immediately without re-running install.sh. The repo must remain present
# at the checked-out path; deleting it will break the installation.
#
#   Termux : symlink bin/* → $PREFIX/bin, lib/* → ~/.local/share/nina/lib
#   Debian : symlink bin/* → ~/.local/bin, lib/* → ~/.local/share/nina/lib
#   config : symlink config/ssh_config → ~/.local/share/nina/config/ssh_config
#   state  : real files (devices.db, cache.env) remain in ~/.local/share/nina/state
#
# Usage:
#   sh install.sh                     -- install/update nina (idempotent)
#   sh install.sh -h | --help         -- show this help
#
# Idempotent: safe to re-run. state/devices.db stays user-owned, never overwritten.


set -eu

log()  { printf '[%s] %s\n' "$1" "$2"; }
fail() { log ERROR "$1"; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

_usage() {
    cat <<USAGE
usage: install.sh [command]

commands:
  (none)              install/update nina (idempotent, default)
  -h, --help          show this help
USAGE
}

# ---------------------------------------------------------------------------
# install -- full idempotent install/update (default command)
# ---------------------------------------------------------------------------
_do_install() {

# ---------------------------------------------------------------------------
# Resolve install destinations
# ---------------------------------------------------------------------------
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/bin" ]; then
    BINDIR="$PREFIX/bin"          # Termux
else
    BINDIR="$HOME/.local/bin"     # Debian / generic
fi
DATADIR="$HOME/.local/share/nina"
LIBDIR="$DATADIR/lib"
STATEDIR="$DATADIR/state"
CFGDIR="$DATADIR/config"

log INFO "tools -> $BINDIR"
log INFO "libs  -> $LIBDIR"

mkdir -p "$BINDIR" "$LIBDIR" "$STATEDIR" "$CFGDIR" "$DATADIR/logs"
chmod 700 "$DATADIR"


# ---------------------------------------------------------------------------
# Registry bootstrap (nina identity/hostkey trust -- load-bearing, hard-fail)
#   Clones the git-backed master registry so this node can read cloud-
#   registered node identities/hostkeys. Without it, node_alias()/
#   registry_row_by_hostkey() silently degrade to empty (identity.sh),
#   causing spurious alias prompts and password fallback instead of
#   hostkey-based trust. Idempotent: skipped if already cloned.
# ---------------------------------------------------------------------------
REGISTRY_DIR="$HOME/.nina-registry"
if [ ! -d "$REGISTRY_DIR/.git" ]; then
    log INFO "cloning nina registry..."
    git clone git@github.com:catwilo/nina-registry.git "$REGISTRY_DIR" \
        || fail "registry clone failed -- nina requires it for identity/hostkey trust. Run manually: git clone git@github.com:catwilo/nina-registry.git $REGISTRY_DIR"
    log OK "registry cloned: $REGISTRY_DIR"
else
    log INFO "registry already cloned: $REGISTRY_DIR"
fi
# ---------------------------------------------------------------------------
# Symlink lib/ as a single directory (source of truth stays the repo).
# lib/ is now organized in subfolders (core/identity/discovery/misc); a
# per-file *.sh glob here would silently link nothing.
# ---------------------------------------------------------------------------
rm -rf "$LIBDIR"
ln -sf "$SCRIPT_DIR/lib" "$LIBDIR"
log INFO "libs linked"

# ---------------------------------------------------------------------------
# Symlink readme.txt (help text, read at runtime by _print_help)
# ---------------------------------------------------------------------------
if [ -f "$SCRIPT_DIR/readme.txt" ]; then
    ln -sf "$SCRIPT_DIR/readme.txt" "$DATADIR/readme.txt"
    log INFO "readme.txt linked"
else
    log WARN "readme.txt not found in repo -- nina -h will fail until present"
fi

# ---------------------------------------------------------------------------
# Symlink tools to BINDIR (executable bit already set in the repo)
# ---------------------------------------------------------------------------
# Files whose name starts with "_" (e.g. bin/_bootstrap) are internal helpers
# sourced by the binary via its own directory, NOT commands meant to be on
# PATH. Skipping them avoids colliding with same-named helpers from other
# toolkit repos (debux, gya), which would otherwise overwrite each other in
# BINDIR and cause a binary to source the wrong bootstrap.
for _b in "$SCRIPT_DIR"/bin/*; do
    [ -f "$_b" ] || continue
    _name="$(basename "$_b")"
    case "$_name" in *.bak) continue ;; _*) continue ;; esac
    ln -sf "$_b" "$BINDIR/$_name"
done
log INFO "tools linked"

# ---------------------------------------------------------------------------
# Seed user data (never overwrite existing)
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Symlink managed config (Include ~/.ssh/config in ssh_config already
# covers per-user overrides, so the file itself stays fully repo-managed).
# ---------------------------------------------------------------------------
if [ -f "$SCRIPT_DIR/config/ssh_config" ]; then
    ln -sf "$SCRIPT_DIR/config/ssh_config" "$CFGDIR/ssh_config"
    log INFO "ssh_config linked"
fi

if [ ! -f "$STATEDIR/devices.db" ]; then
    : > "$STATEDIR/devices.db"
    log INFO "devices.db initialised (empty)"
else
    log INFO "devices.db left intact"
fi

: > "$STATEDIR/cache.env"
log INFO "cache cleared"

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
log INFO "checking dependencies..."
_missing=""
for _cmd in awk sed grep cut ping ssh; do
    has "$_cmd" || _missing="$_missing $_cmd"
done
if ! has ip && ! has ifconfig; then _missing="$_missing ip/ifconfig"; fi
[ -z "$_missing" ] || log WARN "MISSING hard deps:$_missing  nina will not work"
has nmap || {
    log WARN "nmap not found  attempting to install..."

    _nmap_cmd=""
    if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/bin" ]; then
        _nmap_cmd="pkg install -y nmap"
    elif has apt-get; then
        _nmap_cmd="sudo apt-get install -y nmap"
    fi

    if [ -n "$_nmap_cmd" ]; then
        if eval "$_nmap_cmd" 2>/dev/null; then
            log OK "nmap installed"
        else
            fail "nmap install failed -- nina requires nmap. Run manually: $_nmap_cmd"
        fi
    else
        fail "nmap not found and no package manager detected. Install nmap manually and re-run."
    fi

    # Verify nmap is now available
    has nmap || fail "nmap still not found after install attempt"
}
has scp   || log WARN "scp not found  transferencia directa no disponible"
has ncat || {
    log WARN "ncat not found  nclip TCP listener unavailable"

    _ncat_cmd=""
    if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/bin" ]; then
        _ncat_cmd="pkg install -y ncat"
    elif has apt-get; then
        _ncat_cmd="sudo apt-get install -y ncat"
    fi
    if [ -n "$_ncat_cmd" ]; then
        if [ -t 0 ]; then
            printf 'install ncat now? [y/N] '
            read -r _ncat_ans
            case "$_ncat_ans" in
                y|Y) eval "$_ncat_cmd" && log OK "ncat installed" || log WARN "ncat install failed -- run manually: $_ncat_cmd" ;;
                *) log INFO "skipping ncat install" ;;
            esac
        else
            log INFO "non-interactive  skipping ncat install, run manually: $_ncat_cmd"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Patch shell rc: export NOEMAP_DATA + aliases (PATH already covers BINDIR)
# ---------------------------------------------------------------------------
DETECTED_SHELL=sh; RC_FILE="$HOME/.profile"
if has zsh; then DETECTED_SHELL=zsh; RC_FILE="$HOME/.zshrc"
elif has bash; then DETECTED_SHELL=bash; RC_FILE="$HOME/.bashrc"; fi
case "${SHELL:-}" in
    */zsh)  DETECTED_SHELL=zsh;  RC_FILE="$HOME/.zshrc"  ;;
    */bash) DETECTED_SHELL=bash; RC_FILE="$HOME/.bashrc" ;;
esac
log INFO "shell rc: $RC_FILE"

MARKER="# >>> nina"
if grep -qF "$MARKER" "$RC_FILE" 2>/dev/null; then
    log INFO "rc already patched  skipping"
else
    [ -f "$RC_FILE" ] || touch "$RC_FILE"
    cat >> "$RC_FILE" << RC_BLOCK

$MARKER
export NOEMAP_DATA="$DATADIR"
alias nm='nina'
alias nd='nina devices'
# <<< nina
RC_BLOCK
    log OK "patched: $RC_FILE"
fi

# ---------------------------------------------------------------------------
# Ensure BINDIR on PATH (only if missing; respects versioned-dotfile symlinks)
# ---------------------------------------------------------------------------
case ":$PATH:" in
    *":$BINDIR:"*) log INFO "PATH already includes $BINDIR" ;;
    *)
        if [ -L "$RC_FILE" ]; then
            log WARN "$RC_FILE is a symlink (versioned dotfile)  add manually: export PATH=\"$BINDIR:\$PATH\""
        else
            printf '\nexport PATH="%s:$PATH"  # nina bindir\n' "$BINDIR" >> "$RC_FILE"
            log OK "added $BINDIR to PATH in $RC_FILE"
        fi
        ;;
esac

# ---------------------------------------------------------------------------
# clipso (best-effort)
# ---------------------------------------------------------------------------
CLIPSO_INSTALL="${HOME}/unix-toolkit-tools/clipso/install.sh"
if [ -f "$CLIPSO_INSTALL" ]; then
    log INFO "installing clipso..."
    bash "$CLIPSO_INSTALL" || log WARN "clipso install failed"
else
    log WARN "clipso install.sh not found  clipboard features may be limited"
fi

# ---------------------------------------------------------------------------
# SSH key bootstrap (nina#15)
#   1. Generate ~/.ssh/id_ed25519 (no passphrase) if missing -- required for
#      non-interactive nya between nodes. No passphrase by design: these keys
#      are used by automation, an agent prompt would break the unattended flow.
#   2. Distribute our public key to every node reachable WITHOUT a password
#      (reuse the already-trusted SSH channel). Idempotent append to the
#      remote authorized_keys -- never duplicates.
#   3. For nodes not yet reachable passwordless, print the exact ssh-copy-id
#      command to run once (first-time bootstrap of a new node).
#   4. Verify the handshake to each node and report OK / needs-setup.
# ---------------------------------------------------------------------------
# _ensure_nya -- garantiza que nya este disponible antes del bootstrap de
# claves. nya es dependencia runtime de nina (toda comunicacion remota pasa
# por ella desde la purga de nssh/nscp). Si nya no esta en PATH, clona el
# repo desde GitHub en $TOOLS_DIR y corre su install.sh.
#
# Idempotente: si nya ya esta, no hace nada. Silencioso en exito.
# ---------------------------------------------------------------------------
_ensure_nya() {
    if has nya; then
        log INFO "nya already installed"
        return 0
    fi

    log INFO "nya not found -- installing (dependency for remote calls)"
    _nya_tools_dir="${TOOLS_DIR:-$HOME/unix-toolkit-tools}"
    _nya_repo="$_nya_tools_dir/nya"

    if [ -d "$_nya_repo/.git" ]; then
        log INFO "nya repo already cloned at $_nya_repo -- pulling"
        git -C "$_nya_repo" pull --rebase origin main >/dev/null 2>&1 \
            || log WARN "nya pull failed -- continuing with current checkout"
    else
        log INFO "cloning nya into $_nya_repo"
        mkdir -p "$_nya_tools_dir"
        git clone git@github.com:catwilo/nya.git "$_nya_repo" >/dev/null 2>&1 \
            || { log ERROR "nya clone failed -- install it manually: git clone git@github.com:catwilo/nya.git $_nya_repo && bash $_nya_repo/install.sh"; return 1; }
    fi

    if [ -x "$_nya_repo/install.sh" ]; then
        bash "$_nya_repo/install.sh" >/dev/null 2>&1 \
            || { log ERROR "nya install.sh failed -- run manually: bash $_nya_repo/install.sh"; return 1; }
    else
        log ERROR "nya install.sh not found at $_nya_repo/install.sh"
        return 1
    fi

    has nya || { log ERROR "nya still not in PATH after install"; return 1; }
    log OK "nya installed"
}

# ---------------------------------------------------------------------------
ssh_key_bootstrap() {
    # Internal calls: never prompt for a password (nya usa BatchMode=yes
    # por default en sus invocaciones ssh).

    _key="$HOME/.ssh/id_ed25519"
    _pub="$_key.pub"

    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    if [ ! -f "$_key" ]; then
        if has ssh-keygen; then
            ssh-keygen -t ed25519 -N "" -f "$_key" -C "nina@$(hostname 2>/dev/null || echo node)" >/dev/null 2>&1 \
                && log OK "generated ssh key: $_key" \
                || { log WARN "ssh-keygen failed -- skipping key bootstrap"; return 0; }
        else
            log WARN "ssh-keygen not found -- skipping key bootstrap"; return 0
        fi
    else
        log INFO "ssh key already present: $_key"
    fi
    chmod 600 "$_key" 2>/dev/null || true
    [ -f "$_pub" ] || { log WARN "no public key at $_pub -- skipping distribution"; return 0; }

    _devdb="$STATEDIR/devices.db"
    [ -f "$_devdb" ] && [ -s "$_devdb" ] || { log INFO "no nodes registered -- key distribution skipped"; return 0; }
    _ensure_nya || { log WARN "nya unavailable -- key distribution skipped"; return 0; }

    # blockdb.sh must load before identity.sh, which calls blockdb_get/
    # blockdb_field internally.
    if [ -f "$LIBDIR/core/blockdb.sh" ]; then
        # shellcheck source=/dev/null
        . "$LIBDIR/core/blockdb.sh"
    fi
    # Load is_local_ip so we never try to SSH into ourselves (local IPs are
    # dynamic/router-assigned; enumerated live via ifconfig in identity.sh).
    if [ -f "$LIBDIR/identity/identity.sh" ]; then
        # shellcheck source=/dev/null
        . "$LIBDIR/identity/identity.sh"
    fi

    _pubdata="$(cat "$_pub")"
    _need_manual=""
    # iterate registered aliases (skip self handled by nya/devices content)
    _skb_aliases1="$(blockdb_list "$_devdb" | awk '
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
    while IFS= read -r _ka; do
        [ -n "$_ka" ] || continue
        _skb_blk1="$(blockdb_get "$_devdb" alias "$_ka")"
        [ -n "$_skb_blk1" ] || continue
        _kip="$(blockdb_field "$_skb_blk1" ip)"
        if command -v is_local_ip >/dev/null 2>&1 && is_local_ip "$_kip"; then continue; fi
        # reachable passwordless? (BatchMode: never prompts)
        if nya "$_ka" "true" </dev/null >/dev/null 2>&1; then
            # idempotent append: only add if not already present
            nya "$_ka" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && grep -qxF '$_pubdata' ~/.ssh/authorized_keys || printf '%s\n' '$_pubdata' >> ~/.ssh/authorized_keys" </dev/null >/dev/null 2>&1 \
                && log OK "key ensured on $_ka" \
                || log WARN "key append to $_ka failed"

            # Bidirectional: fetch remote's public key and add to LOCAL
            # authorized_keys so the remote can reach us without password.
            _remote_pub="$(nya "$_ka" 'cat ~/.ssh/id_ed25519.pub 2>/dev/null' </dev/null 2>/dev/null || true)"
            if [ -n "$_remote_pub" ]; then
                mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys
                grep -qxF "$_remote_pub" ~/.ssh/authorized_keys 2>/dev/null || printf '%s\n' "$_remote_pub" >> ~/.ssh/authorized_keys
                log OK "remote key from $_ka installed locally"
            fi
        else
            _need_manual="$_need_manual $_ka"
        fi
    done <<EOF_SKB1
$_skb_aliases1
EOF_SKB1

    if [ -n "$_need_manual" ]; then
        log WARN "nodes needing first-time key setup:$_need_manual"
        for _m in $_need_manual; do
            printf '    run once:  ssh-copy-id -i %s %s\n' "$_pub" "$_m"
        done
    fi

    # final handshake verification
    _skb_aliases2="$(blockdb_list "$_devdb" | awk '
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
    while IFS= read -r _ka; do
        [ -n "$_ka" ] || continue
        _skb_blk2="$(blockdb_get "$_devdb" alias "$_ka")"
        [ -n "$_skb_blk2" ] || continue
        _kip="$(blockdb_field "$_skb_blk2" ip)"
        if command -v is_local_ip >/dev/null 2>&1 && is_local_ip "$_kip"; then continue; fi
        if nya "$_ka" "true" </dev/null >/dev/null 2>&1; then
            log OK "handshake $_ka: OK"
        else
            log WARN "handshake $_ka: needs setup"
        fi
    done <<EOF_SKB2
$_skb_aliases2
EOF_SKB2
}
ssh_key_bootstrap

# ---------------------------------------------------------------------------
# Post-install verification: prove an installed tool resolves its libs.
# ---------------------------------------------------------------------------
if NOEMAP_DATA="$DATADIR" "$BINDIR/nina" status >/dev/null 2>&1; then
    log OK "post-install check passed (nina runs standalone)"
else
    fail "post-install check FAILED  nina could not run from $BINDIR (libs at $LIBDIR?)"
fi

printf '\n'
log OK "nina installed  tools in $BINDIR, libs in $LIBDIR"
printf '  Repo is now deletable; tools run standalone.\n'
printf '  Run: nina   Devices: nina devices\n\n'

}

# ---------------------------------------------------------------------------
# Top-level dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
    -h|--help)
        _usage
        exit 0
        ;;
    "")
        _do_install
        ;;
    *)
        log ERROR "unknown command: $1"
        _usage
        exit 1
        ;;
esac
