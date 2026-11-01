# nina — ARCHITECTURE

Living reference of how nina is built. Update on every session that touches
the subsystem described here. Active bugs live in miko, not in a parallel
file.

## Scope

Tailscale-only. Every peer is reachable via its `100.x` IP. There is no
LAN discovery, no nmap, no ping, no ARP — all of that was removed by design
because the tailscale network is persistent and its peers/IPs never change.

Single source of truth: `~/.nina-registry/nodes.db` (blockdb, git-backed,
cloud). Every node and its `state: active|suspended` lives there. `nina
status` reads it, filters to active, and is the source `nya` consumes for
targets.

## Module map

    bin/nina                 entry point (dispatch + ssh-setup)
    bin/_bootstrap           shared self/data resolution + _source_mods

    lib/core/util.sh         log, has_cmd, session, dirs
    lib/core/network.sh      reachable_ssh, hostkey, known_hosts
    lib/core/blockdb.sh      blockdb file format
    lib/core/lock.sh         session lock
    lib/core/dispatch.sh     top-level subcommand router
    lib/core/prompt_field.sh interactive field prompt

    lib/identity/identity.sh        node_id, machine_seed, tailscale detection
    lib/identity/registry.sh        _registry_write, node_alias_set, lookups
    lib/identity/self_register.sh   _self_register + _registry_pull_latest
    lib/identity/prompt.sh          _prompt_self_identity

    lib/commands/devices.sh         nina devices, nina status
    lib/commands/discovery.sh       nina {all, self-register, bootstrap-keys}

    lib/connection/ssh_bootstrap.sh ssh_key_bootstrap

## Identity rules

- `node_id` = first 16 hex of SHA-256 over `machine-seed` (persisted at
  `$BASE/state/machine-seed`).
- `_registry_write` is the ONLY writer of `nodes.db`. It:
  1. Prepares branch `chore/registry-<node-id>` off a fresh `origin/main`.
  2. If the target alias exists and belongs to another node_id, reclaims it
     when (a) the existing row has empty hostkey, or (b) the local sshd
     hostkey matches. A genuine collision aborts visibly.
  3. Writes the row (preserving its `state`), commits, pushes the branch,
     ff-merges to main, deletes the branch, and calls `_distribute_registry`.
- `_self_register` reads its own row from nodes.db (or local cache), prompts
  for a name only if both are absent, and writes to nodes.db with the
  tailscale IP from `detect_tailscale_ip` and hostkey via
  `_get_host_key_fingerprint 127.0.0.1 <port>`.

## State model

- `state: active` — default. Node is listed by `nina status`, reachable by
  `nya @all`.
- `state: suspended` — node is omitted from `nina status`; visible only via
  `nina devices all`. `nya` never targets it.
- `nina devices suspend|resume <alias>` writes the new state, commits and
  pushes `nodes.db`, then runs `nya @all "git pull --rebase"` so live peers
  converge immediately.
- When the local node is suspended, `nina status` prints a warning and (on a
  TTY) offers to resume it.
- One base, one channel (git), one field per node. No `ts-devices.db`, no
  peer-to-peer push, no snapshots.

## Deploy

Source of truth is the repo. Symlink-installed. Deploy order per change:
`ut ship` → `ut distribute --install <repo>` → `miko sync <repo>`.
