#!/bin/sh
# fingerprint.sh — SSH port detection and device database management
#
# Reads HOST_LIST (SSH-filtered by scan.sh).
# Probes open SSH ports per host, classifies type, stores to hosts.db.
# New host registration happens post-display in output.sh → prompt_new_hosts.
#
# Design:
#   • Fast mode (default): type classification via port heuristic only.
#     No banner grabs, no nmap -sV — safe and fast in Termux/no-root.
#   • Deep mode (--deep): adds SSH banner via nmap -sV to distinguish
#     Termux/Android from Debian/Ubuntu on port 22.
#   • Self-IP is excluded (scan.sh filters it, double-checked here).
#   • IP changes are handled automatically (known_hosts cleaned).

HOSTS_DB="$BASE/state/hosts.db"
DEVICES_DB="$BASE/state/devices.db"

_FP_SSH_PORTS="22,8022,2222"

# ---------------------------------------------------------------------------
# DB structural validation
# ---------------------------------------------------------------------------
_validate_db() {
    _db="$1"
    [ -f "$_db" ] || return 0
    awk -F'|' '
        /^[[:space:]]*$/ { next }
        /^#/             { next }
        NF < 2           { exit 1 }
    ' "$_db"
}

# ---------------------------------------------------------------------------
# SSH port detection per host
# ---------------------------------------------------------------------------
_detect_ssh_port() {
    _ip="$1"
    _fp_nmap_out="$2"

    if [ -s "$_fp_nmap_out" ]; then
        _p="$(awk -v host="$_ip" '
            /Nmap scan report for / { in_host = ($NF == host) }
            in_host && /\/tcp.*open/ {
                split($1, a, "/")
                print a[1]; exit
            }
        ' "$_fp_nmap_out")"
        [ -n "$_p" ] && { printf '%s\n' "$_p"; return 0; }
    fi

    for _p in 22 8022 2222; do
        nc -z -w 2 "$_ip" "$_p" >/dev/null 2>&1 && { printf '%s\n' "$_p"; return 0; }
    done
    printf '22\n'
}

# ---------------------------------------------------------------------------
# SSH banner grab (deep mode only)
# ---------------------------------------------------------------------------
_get_ssh_banner() {
    _bip="$1"; _bport="$2"
    # Fiable y nativo: leer la cadena de identificacion del protocolo SSH
    # directo del socket (bash /dev/tcp). El servidor la envia al conectar.
    # Linux trae sufijo de distro (OpenSSH_x Debian-...); macOS va bare.
    _b="$(timeout 4 bash -c 'exec 3<>/dev/tcp/'"$_bip"'/'"$_bport"' && head -1 <&3' 2>/dev/null)"
    [ -n "$_b" ] && { printf '%s' "$_b"; return 0; }
    # Fallback: nmap si el socket directo fallo
    has_cmd nmap || return 0
    nmap -Pn -n -sV --version-intensity 5 \
        --host-timeout 5s -p "$_bport" "$_bip" 2>/dev/null \
    | awk '/open.*ssh/{ print; exit }'
}

# ---------------------------------------------------------------------------
# Type classification
#
# Fast mode: port heuristic only.
#   8022  → android-ssh  (Termux default port)
#   2222  → linux-ssh    (common non-root Linux sshd)
#   22    → linux-ssh    (generic; use --deep to distinguish Termux)
#
# Deep mode (NOEMAP_DEEP=1): adds SSH banner to distinguish Termux from
#   Debian/Ubuntu on port 22.
# ---------------------------------------------------------------------------
_detect_type() {
    _ttl="$1"; _ssh_port="$2"; _ip="${3:-}"

    case "$_ttl" in
        128|127) printf 'windows'; return ;;
        255)     printf 'router';  return ;;
    esac

    [ -z "$_ssh_port" ] && { printf 'linux'; return; }

    case "$_ssh_port" in
        8022) printf 'android-ssh'; return ;;
        2222) printf 'linux-ssh';   return ;;
    esac

    # Fast passive banner grab (free, no login). Distros self-identify;
    # macOS ships a bare "OpenSSH_x.y" with no platform suffix.
    _banner="$(_get_ssh_banner "$_ip" "$_ssh_port" 2>/dev/null || true)"
    case "$_banner" in
        *[Uu]buntu*|*[Dd]ebian*|*[Aa]lpine*|*[Aa]rch*|*[Ff]edora*|*[Rr]aspbian*|*[Mm]int*|*[Gg]entoo*|*[Ss][Uu][Ss][Ee]*|*armbian*)
            printf 'linux-ssh'; return ;;
    esac

    # Bare OpenSSH + Unix TTL: macOS is the typical LAN match, since Linux
    # almost always carries a distro suffix (caught above).
    case "$_banner" in
        SSH-2.0-OpenSSH_[0-9]*)
            case "$_ttl" in
                64|63) printf 'mac'; return ;;
            esac
            printf 'unix-ssh'; return ;;
    esac

    # Deep mode: confirm any remaining ambiguity with nmap -O if available.
    if [ "${NOEMAP_DEEP:-0}" = "1" ] && [ -n "${_FP_OS_OUT:-}" ] && [ -s "${_FP_OS_OUT:-/nonexistent}" ]; then
        _os_line="$(awk -v host="$_ip" '
            /Nmap scan report for / { found = ($NF == host) }
            found && (/OS details:/ || /Running:/ || /OS guess/) { print; exit }
        ' "$_FP_OS_OUT" 2>/dev/null)"
        case "$_os_line" in
            *[Dd]arwin*|*[Aa]pple*|*macOS*) printf 'mac';      return ;;
            *[Ww]indows*)                   printf 'windows';  return ;;
            *[Ll]inux*)                     printf 'linux-ssh'; return ;;
        esac
    fi

    # Empty/unreadable banner: do NOT assume macOS — could be filtered,
    # refused, or a non-SSH host. Classify as unknown.
    case "$_banner" in
        "") printf 'unknown'; return ;;
    esac
    printf 'linux-ssh'
}

# ---------------------------------------------------------------------------
# fingerprint_hosts — main entry point
# ---------------------------------------------------------------------------
fingerprint_hosts() {
    _host_count=0
    if [ -n "${HOST_LIST:-}" ]; then
        _host_count="$(printf '%s\n' "$HOST_LIST" | wc -l | tr -d ' ')"
    fi
    log INFO "fingerprinting ${_host_count} host(s)"

    _hosts_partial="$(session_tmp hosts_partial)"
    : > "$_hosts_partial"
    DEB_IP=""

    [ -n "${HOST_LIST:-}" ] || {
        log INFO "no hosts to fingerprint"
        return 0
    }

    # Batch SSH port scan across all discovered hosts
    _fp_nmap_out="$(session_tmp fp_nmap_out)"
    if has_cmd nmap; then
        _fp_host_file="$(session_tmp fp_hosts)"
        printf '%s\n' "$HOST_LIST" > "$_fp_host_file"
        nmap -Pn -n --host-timeout 4s -p "$_FP_SSH_PORTS" \
            -iL "$_fp_host_file" 2>/dev/null > "$_fp_nmap_out" || true
    fi

    # Deep OS fingerprint (one batch, root only). Termux/no-sudo skip silently
    # and fall back to passive banner+TTL classification in _detect_type.
    _FP_OS_OUT=""
    if [ "${NOEMAP_DEEP:-0}" = "1" ] && has_cmd nmap; then
        _os_out="$(session_tmp fp_os_out)"
        if [ "$(id -u)" = "0" ]; then
            nmap -Pn -n -O --osscan-guess --host-timeout 20s \
                -iL "$_fp_host_file" 2>/dev/null > "$_os_out" & 
            _spin_wait "$!" "OS fingerprint" || true
            _FP_OS_OUT="$_os_out"
        elif has_cmd sudo && [ -z "${PREFIX:-}" ]; then
            if sudo -v 2>/dev/null; then
                sudo nmap -Pn -n -O --osscan-guess --host-timeout 20s \
                    -iL "$_fp_host_file" 2>/dev/null > "$_os_out" & 
                _spin_wait "$!" "OS fingerprint" || true
                _FP_OS_OUT="$_os_out"
            fi
        fi
    fi

    # Per-host: TTL + SSH port → classify + record
    _deb_marker="$(session_tmp deb_ip)"

    printf '%s\n' "$HOST_LIST" > "$(session_tmp fp_host_list)"
    while IFS= read -r _ip; do
        [ -n "$_ip" ]          || continue
        [ "$_ip" = "$MY_IP" ] && continue   # skip self (double-check)

        # TTL via ping
        _ttl=""
        _ttl_raw="$(ping -c 1 -W 1 "$_ip" 2>/dev/null || true)"
        case "$_ttl_raw" in
            *[Tt][Tt][Ll]=*)
                _ttl="$(printf '%s\n' "$_ttl_raw" \
                    | sed -n 's/.*[Tt][Tt][Ll]=\([0-9]*\).*/\1/p' | head -1)" ;;
        esac

        _ssh_port="$(_detect_ssh_port "$_ip" "$_fp_nmap_out")"

        # Registry port override: if the IP already maps to a known alias in
        # devices.db (or ts-devices.db), consult the registry row for that
        # alias and use its port. Termux/Android always answer on 8022; a
        # probe that sees 22 elsewhere must not demote an established node.
        _existing_alias=""
        _existing_blk="$(blockdb_get "$DEVICES_DB" ip "$_ip" 2>/dev/null || true)"
        [ -n "$_existing_blk" ] && _existing_alias="$(blockdb_field "$_existing_blk" alias)"
        if [ -z "$_existing_alias" ] && [ -f "$BASE/state/ts-devices.db" ]; then
            _existing_blk="$(blockdb_get "$BASE/state/ts-devices.db" ip "$_ip" 2>/dev/null || true)"
            [ -n "$_existing_blk" ] && _existing_alias="$(blockdb_field "$_existing_blk" alias)"
        fi
        if [ -z "$_existing_alias" ]; then
            _hk_pre="$(_get_host_key_fingerprint "$_ip" "${_ssh_port:-22}" 2>/dev/null)"
            if [ -n "$_hk_pre" ] && command -v registry_row_by_hostkey >/dev/null 2>&1; then
                _reg_by_hk="$(registry_row_by_hostkey "$_hk_pre" 2>/dev/null || true)"
                [ -n "$_reg_by_hk" ] && _existing_alias="$(blockdb_field "$_reg_by_hk" alias)"
            fi
        fi
        if [ -n "$_existing_alias" ] && command -v registry_row_by_alias >/dev/null 2>&1; then
            _reg_blk="$(registry_row_by_alias "$_existing_alias" 2>/dev/null || true)"
            if [ -n "$_reg_blk" ]; then
                _reg_port="$(blockdb_field "$_reg_blk" port)"
                [ -n "$_reg_port" ] && _ssh_port="$_reg_port"
            fi
        fi

        # Tailscale IP substitution: if this alias has a 100.* row in
        # ts-devices.db, always report the tailscale IP for display/storage
        # instead of the WLAN IP. Tailscale-first is the network policy.
        _display_ip="$_ip"
        if [ -n "$_existing_alias" ] && [ -f "$BASE/state/ts-devices.db" ]; then
            _ts_blk="$(blockdb_get "$BASE/state/ts-devices.db" alias "$_existing_alias" 2>/dev/null || true)"
            if [ -n "$_ts_blk" ]; then
                _ts_ip="$(blockdb_field "$_ts_blk" ip)"
                case "$_ts_ip" in 100.*) _display_ip="$_ts_ip" ;; esac
            fi
        fi

        # All open ports (for display in --ports mode)
        _all_ports=""
        if [ -s "$_fp_nmap_out" ]; then
            _all_ports="$(awk -v host="$_ip" '
                /Nmap scan report for / { in_host = ($NF == host) }
                in_host && /\/tcp.*open/ {
                    split($1, a, "/"); printf "%s,", a[1]
                }
            ' "$_fp_nmap_out" | sed 's/,$//')"
        fi

        # Prefer the authoritative platform from the registry / local tables
        # over the heuristic type guess. A host already known to be android
        # (from ts-devices.db or devices.db) must never be reclassified as
        # 'unknown' just because a fresh port scan did not carry a banner.
        _authoritative_plat=""
        # 1. Registry by hostkey (most precise: identifies the machine
        #    regardless of its current IP).
        if command -v registry_row_by_hostkey >/dev/null 2>&1; then
            _auth_hk="$(_get_host_key_fingerprint "$_ip" "${_ssh_port:-22}" 2>/dev/null)"
            if [ -n "$_auth_hk" ]; then
                _auth_blk="$(registry_row_by_hostkey "$_auth_hk")"
                [ -n "$_auth_blk" ] && _authoritative_plat="$(blockdb_field "$_auth_blk" platform)"
            fi
        fi
        # 2. Registry by IP (covers hosts whose hostkey we cannot yet fetch
        #    but whose IP is already recorded in the cloud registry row).
        if [ -z "$_authoritative_plat" ] && [ -f "$REGISTRY_DB" ] && command -v blockdb_get >/dev/null 2>&1; then
            _auth_nid=""
            _auth_aliases="$(awk '
                BEGIN { RS=""; FS="\n" }
                {
                    ip=""; alias=""
                    for (i=1;i<=NF;i++) {
                        if ($i ~ /^ip: /) { sub(/^ip: /,"",$i); ip=$i }
                        if ($i ~ /^alias: /) { sub(/^alias: /,"",$i); alias=$i }
                    }
                    if (ip=="'"$_ip"'") print alias
                }
            ' "$REGISTRY_DB" 2>/dev/null)"
            # Registry rows do not carry ip today (IP is local-only), so this
            # path is a no-op unless a registry row happens to include one.
            # Kept for forward-compatibility without affecting current data.
            if [ -n "$_auth_aliases" ]; then
                for _auth_a in $_auth_aliases; do
                    _auth_blk="$(blockdb_get "$REGISTRY_DB" alias "$_auth_a" 2>/dev/null || true)"
                    [ -n "$_auth_blk" ] || continue
                    _authoritative_plat="$(blockdb_field "$_auth_blk" platform)"
                    [ -n "$_authoritative_plat" ] && break
                done
            fi
        fi
        # 3. Fallback: devices.db (WLAN) by IP.
        if [ -z "$_authoritative_plat" ]; then
            _auth_blk="$(blockdb_get "$DEVICES_DB" ip "$_ip" 2>/dev/null || true)"
            [ -n "$_auth_blk" ] && _authoritative_plat="$(blockdb_field "$_auth_blk" platform)"
        fi
        # 4. Last fallback: ts-devices.db by IP.
        if [ -z "$_authoritative_plat" ] && [ -f "$BASE/state/ts-devices.db" ]; then
            _auth_blk="$(blockdb_get "$BASE/state/ts-devices.db" ip "$_ip" 2>/dev/null || true)"
            [ -n "$_auth_blk" ] && _authoritative_plat="$(blockdb_field "$_auth_blk" platform)"
        fi

        if [ -n "$_authoritative_plat" ] && [ "$_authoritative_plat" != "unknown" ]; then
            _type="$_authoritative_plat"
            _type_src="authoritative"
        else
            _type="$(_detect_type "${_ttl:-}" "$_ssh_port" "$_ip")"
            _type_src="heuristic"
        fi

        log INFO "host $_ip  ttl=${_ttl:-?}  ssh=${_ssh_port:-none}  ports=${_all_ports:-none}  type=$_type (${_type_src})"

        # Format: IP|TYPE|TTL|SSH_PORT|ALL_PORTS
        printf '%s|%s|%s|%s|%s\n' \
            "$_display_ip" "$_type" "${_ttl:-0}" "${_ssh_port:-22}" "${_all_ports:-}" \
            >> "$_hosts_partial"

        if [ "$_type" = "linux-ssh" ] && [ ! -f "$_deb_marker" ]; then
            printf '%s\n' "$_ip" > "$_deb_marker"
        fi
    done < "$(session_tmp fp_host_list)"

    # Promote hosts.db atomically
    if [ -s "$_hosts_partial" ]; then
        if _validate_db "$_hosts_partial"; then
            atomic_write "$HOSTS_DB" < "$_hosts_partial"
        else
            log WARN "fingerprint validation failed — hosts.db left intact"
        fi
    fi

    # Recover DEB_IP from marker (subshell barrier)
    [ -f "$_deb_marker" ] && DEB_IP="$(cat "$_deb_marker")"

    [ -f "$DEVICES_DB" ] || touch "$DEVICES_DB"
    [ -s "$_hosts_partial" ] && _update_registered_hosts "$_hosts_partial"

    # Prune stale known_hosts
    known_hosts_prune "$DEVICES_DB"
}

# ---------------------------------------------------------------------------
# _update_registered_hosts — update SSH port for already-registered IPs
# if it changed. New hosts go to prompt_new_hosts in output.sh.
# ---------------------------------------------------------------------------
_update_registered_hosts() {
    _partial="$1"

    while IFS='|' read -r _ip _type _ttl _ssh_port _all_ports; do
        [ -n "$_ip" ] || continue

        # tailscale-first: an IP already recorded in ts-devices.db is
        # registered by definition -- skip WLAN re-registration to avoid
        # treating a known tailscale peer as a new host.
        if [ -f "$BASE/state/ts-devices.db" ] && [ -s "$BASE/state/ts-devices.db" ]; then
            _ts_pre_blk="$(blockdb_get "$BASE/state/ts-devices.db" ip "$_ip" 2>/dev/null || true)"
            if [ -n "$_ts_pre_blk" ]; then
                _ts_pre_alias="$(blockdb_field "$_ts_pre_blk" alias)"
                log INFO "host $_ip already registered as '$_ts_pre_alias' (tailscale)"
                continue
            fi
        fi

        _existing_blk="$(blockdb_get "$DEVICES_DB" ip "$_ip")"
        if [ -z "$_existing_blk" ]; then
            _pre_hk="$(_get_host_key_fingerprint "$_ip" "${_ssh_port:-22}" 2>/dev/null)"
            [ -n "$_pre_hk" ] && _existing_blk="$(blockdb_get "$DEVICES_DB" hostkey "$_pre_hk")"
        fi
        _existing="$([ -n "$_existing_blk" ] && blockdb_field "$_existing_blk" alias || printf '')"

        if [ -z "$_existing" ]; then
            _hk_new="$(_get_host_key_fingerprint "$_ip" "${_ssh_port:-22}")"
            if [ -n "$_hk_new" ] && [ -n "${_STALE_ALIAS_CANDIDATES:-}" ]; then
                for _cand_alias in $_STALE_ALIAS_CANDIDATES; do
                    [ "$_cand_alias" = "$(node_alias 2>/dev/null)" ] && continue
                    _cand_blk="$(blockdb_get "$DEVICES_DB" alias "$_cand_alias")"
                    [ -n "$_cand_blk" ] || continue
                    _cand_hk="$(blockdb_field "$_cand_blk" hostkey)"
                    [ -n "$_cand_hk" ] || continue
                    if [ "$_cand_hk" = "$_hk_new" ]; then
                        _cand_user="$(blockdb_field "$_cand_blk" user)"
                        _cand_nid="$(blockdb_field "$_cand_blk" node_id)"
                        _new_blk="$(printf 'alias: %s\nip: %s\nuser: %s\nport: %s\nhostkey: %s\nnode_id: %s\n' \
                            "$_cand_alias" "$_ip" "$_cand_user" "${_ssh_port:-22}" "$_cand_hk" "${_cand_nid:-}")"
                        blockdb_upsert "$DEVICES_DB" alias "$_cand_alias" "$_new_blk"
                        log OK "alias '$_cand_alias' moved to new IP $_ip (matched via SSH host key, old IP unreachable)"
                        _existing="$_cand_alias"
                        break
                    fi
                done
            fi
        fi

        [ -n "$_existing" ] || continue   # genuinely new host — handled by prompt_new_hosts

        _existing_blk="$(blockdb_get "$DEVICES_DB" alias "$_existing")"
        _cur_port="$(blockdb_field "$_existing_blk" port)"
        _cur_port="${_cur_port:-22}"
        _cur_user="$(blockdb_field "$_existing_blk" user)"
        _cur_hk="$(blockdb_field "$_existing_blk" hostkey)"

        # Consult registry.db (cloud source of truth) before overwriting port
        _registry_port="$_ssh_port"
        if command -v registry_row_by_alias >/dev/null 2>&1; then
            _reg_blk="$(registry_row_by_alias "$_existing" 2>/dev/null)"
            if [ -n "$_reg_blk" ]; then
                _reg_port="$(blockdb_field "$_reg_blk" port)"
                [ -n "$_reg_port" ] && _registry_port="$_reg_port"
            fi
        fi

        # Port policy (final): the registry (cloud) value wins when present.
        # Never overwrite a registered port with a value observed by a scan:
        # Termux/Android nodes always answer on 8022, and a one-off probe that
        # sees 22 elsewhere must not silently rewrite their row. The local
        # devices.db row already has the authoritative port when it was set
        # from the registry at registration time, so no port update here.
        if [ "$_registry_port" != "$_cur_port" ] && [ -n "$_registry_port" ]; then
            _existing_nid="$(blockdb_field "$_existing_blk" node_id)"
            _new_blk="$(printf 'alias: %s\nip: %s\nuser: %s\nport: %s\nhostkey: %s\nnode_id: %s\n' \
                "$_existing" "$_ip" "$_cur_user" "$_registry_port" "${_cur_hk:-}" "${_existing_nid:-}")"
            blockdb_upsert "$DEVICES_DB" alias "$_existing" "$_new_blk"
            log INFO "aligned SSH port for '$_existing' to registry value: $_registry_port (was $_cur_port)"
        else
            log INFO "host $_ip already registered as '$_existing'"
        fi

        # Backfill: capture hostkey for this alias if it doesn't have one yet
        # (miko-task#294 -- progressive curation so future IP-change detection
        # has something to compare against). No-op once the field is filled.
        if [ -z "$_cur_hk" ]; then
            _new_hk="$(_get_host_key_fingerprint "$_ip" "${_ssh_port:-22}")"
            if [ -n "$_new_hk" ]; then
                _refresh_blk="$(blockdb_get "$DEVICES_DB" alias "$_existing")"
                _refresh_port="$(blockdb_field "$_refresh_blk" port)"
                _refresh_user="$(blockdb_field "$_refresh_blk" user)"
                _existing_nid="$(blockdb_field "$_refresh_blk" node_id)"
                _new_blk="$(printf 'alias: %s\nip: %s\nuser: %s\nport: %s\nhostkey: %s\nnode_id: %s\n' \
                    "$_existing" "$_ip" "$_refresh_user" "${_refresh_port:-22}" "$_new_hk" "${_existing_nid:-}")"
                blockdb_upsert "$DEVICES_DB" alias "$_existing" "$_new_blk"
                log INFO "backfilled SSH host key fingerprint for '$_existing'"
            fi
        fi
    done < "$_partial"
}

# ---------------------------------------------------------------------------
# new_hosts_list — prints IPs from hosts.db not yet in devices.db.
# Used by prompt_new_hosts in output.sh.
# ---------------------------------------------------------------------------
new_hosts_list() {
    _hdb="$HOSTS_DB"

    [ -f "$_hdb" ] && [ -s "$_hdb" ] || return 0

    while IFS='|' read -r _ip _type _ttl _ssh_port _all_ports; do
        [ -n "$_ip" ] || continue
        _found_blk="$(blockdb_get "$DEVICES_DB" ip "$_ip")"
        if [ -z "$_found_blk" ]; then
            _nhl_hk="$(_get_host_key_fingerprint "$_ip" "${_ssh_port:-22}" 2>/dev/null)"
            [ -n "$_nhl_hk" ] && _found_blk="$(blockdb_get "$DEVICES_DB" hostkey "$_nhl_hk")"
        fi
        if [ -z "$_found_blk" ] && [ -f "$BASE/state/ts-devices.db" ] && [ -s "$BASE/state/ts-devices.db" ]; then
            _nhl_ts_blk="$(blockdb_get "$BASE/state/ts-devices.db" ip "$_ip" 2>/dev/null || true)"
            [ -n "$_nhl_ts_blk" ] && _found_blk="$_nhl_ts_blk"
        fi
        [ -z "$_found_blk" ] && printf '%s|%s|%s\n' "$_ip" "$_type" "${_ssh_port:-22}"
    done < "$_hdb"
}
