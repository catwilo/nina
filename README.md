# nina

Tailscale-only SSH device mapper. Manages node identity in a cloud-backed
registry, syncs a local device table (`ts-devices.db`) across peers, and
provides alias-aware wrappers around ssh and scp.

Targets: Debian 13 and Termux (non-root). Shell: POSIX sh.

## Install

    sh install.sh

Idempotent. Symlinks `bin/*` into `$PREFIX/bin` (Termux) or `~/.local/bin`,
and `lib/` into `~/.local/share/nina/lib`. State files stay user-owned.

## Commands

All commands accept `-h`.

### Top-level

- `nina` — run the full pipeline: self-register + seed + bootstrap-keys + push.
- `nina self-register` — register this node identity.
- `nina seed` — pull peer rows from the cloud registry.
- `nina bootstrap-keys` — distribute SSH keys to registered peers.
- `nina push` — sync `ts-devices.db` to all peers.
- `nina status` — list devices; marks the local node.

### Devices

- `nina devices list`
- `nina devices add <alias> <ip> <user> [port]`
- `nina devices edit|rename|remove|update-ip|refresh-ips|rollback`
- `nina devices push-vpn`
- `nina devices resetall`
- `nina devices node-set <alias> [user] [port] [platform]`
- `nina devices node-add <node-id> <alias> <user> <port> <platform>`
- `nina devices registry-set <node-id> <alias> [user] [port] [platform]`
- `nina devices hostkey-refresh`

### Clip

- `nina clip get <alias>:/path`
- `nina clip send [--ssh] <alias>`
- `nina clip set|clear|status`
- `nina clip tunnel <start|stop|restart|status>`
- `nina clip serve  <start|stop|restart|status>`

### Standalone wrappers

- `nssh <alias> [cmd...]`
- `nscp [-r] <src> <dst>`
- `nsafe run -- <cmd...>`

## Identity

Registry (`~/.nina-registry/registry.db`, git-backed) is the cloud source of
truth for node identity. Aliases are **assigned manually** — no automatic
suggestion. `_registry_write` reclaims an alias when the local SSH hostkey
matches an existing row; genuine collisions abort with a visible error.

## Layout

    bin/     command-line tools and _bootstrap
    lib/core/       util, network, blockdb, lock, dispatch, prompt_field
    lib/identity/   identity, registry, seed, self_register, prompt
    lib/commands/   devices, clip, discovery
    lib/connection/ devices, sync, ssh_bootstrap
    lib/output/     output (render only)
    config/  ssh_config used by the wrappers
    state/   ts-devices.db (real), cache.env (real)
