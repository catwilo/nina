# nina

Network discovery and SSH device mapper for LAN environments. Scans for
SSH-reachable hosts, registers them under short aliases, and provides
alias-aware wrappers around ssh, scp, rsync, and clipboard copy.

Targets: Debian 13 and Termux (non-root). Shell: POSIX sh for tools.

## Install

    nina install

Idempotent. Symlinks `bin/*` into `~/.local/bin` (or `$PREFIX/bin` on
Termux) and writes a delimited block to `~/.zshrc` (PATH fallback).
Re-running overwrites the previous block cleanly.

## Commands

All commands accept `-h` for usage.

- `nina` — fast scan for SSH hosts, then prompt to register new ones.
  - `--ports` shows open ports.
  - `-i <iface>` forces the network interface (otherwise derived from the
    default route).
- `nina devices` — manage the device database (list, add, edit, rename,
  remove, update-ip, rollback, push-vpn, resetall, node-set, node-add,
  registry-set, hostkey-refresh).
- `nssh <alias> [cmd...]` -- SSH to an alias; forwards an optional command.
- `nscp [-r] <src> <dst>` — scp using aliases; `alias:/path` for remote.
- `nina clip get <alias:/path>` — copy a remote file to the clipboard via
  clipso.
- `nina clip send [--ssh] <alias>` — send stdin to a remote clipboard.
- `nina clip set <src> <dst>` — define clipboard direction and smoke-test.
- `nina clip tunnel <start|stop|restart|status>` — manage the SSH RemoteForward
  listener.
- `nina clip serve <start|stop|restart|status>` — manage the TCP/ncat listener.

## Interface selection

On multi-homed hosts, the scan interface is derived from the default
route, not the first interface the kernel lists. Override with
`nina -i <iface>`.

## Layout

    bin/     command-line tools
    lib/     shared helpers (devices, iface, scan, ...)
    config/  ssh_config used by the wrappers
    state/   devices.db and cache.env
