# nina — ARCHITECTURE

Living reference of how nina is built. Update on every session that touches
the subsystem described here. Active bugs live in miko, not in a parallel
file.

## Scope

Tailscale-only. Every peer is reachable via its `100.x` IP. There is no
LAN discovery, no nmap, no ping, no ARP — all of that was removed by design
because the tailscale network is persistent and its peers/IPs never change.

Single source of truth for identity: `~/.nina-registry/registry.db` (git,
cloud). Single source for peers and their IPs: local `ts-devices.db`.

## Module map

    bin/nina                 entry point (dispatch + ssh-setup + client-setup)
    bin/nssh  bin/nscp  bin/nsafe   standalone wrappers
    bin/_bootstrap           shared self/data resolution + _source_mods

    lib/core/util.sh         log, has_cmd, session, atomic_write, dirs
    lib/core/network.sh      reachable_ssh, reachable_cloud, hostkey, known_hosts
    lib/core/blockdb.sh      blockdb file format
    lib/core/lock.sh         session lock
    lib/core/dispatch.sh     top-level subcommand router
    lib/core/prompt_field.sh interactive field prompt

    lib/identity/identity.sh        node_id, machine_seed, tailscale detection
    lib/identity/registry.sh        _registry_write, node_alias_set, lookups
    lib/identity/self_register.sh   _self_register + _registry_pull_latest
    lib/identity/seed.sh            _seed_from_registry
    lib/identity/prompt.sh          _prompt_self_identity

    lib/commands/devices.sh         nina devices
    lib/commands/clip.sh            nina clip
    lib/commands/discovery.sh       nina {all, self-register, seed, push}

    lib/connection/devices.sh       resolve_device, resolve_scp_target
    lib/connection/sync.sh          sync_devices_to_nodes
    lib/connection/ssh_bootstrap.sh ssh_key_bootstrap

    lib/output/output.sh            render_registered_devices, render_connect

## Identity rules

- `node_id` = first 16 hex of SHA-256 over `machine-seed` (persisted at
  `$BASE/state/machine-seed`).
- `_registry_write` is the ONLY writer of `registry.db`. It:
  1. Prepares branch `chore/registry-<node-id>` off a fresh `origin/main`.
  2. If the target alias exists and belongs to another node_id, reclaims it
     when (a) the existing row has empty hostkey, or (b) the local sshd
     hostkey matches. A genuine collision (different node_id + different
     hostkey) aborts with a visible error and leaves no branch.
  3. Writes the row, commits, pushes the branch, ff-merges to main, deletes
     the branch, and calls `_distribute_registry`.
- `_self_register` reads its own row from registry (or local cache), prompts
  for a name only if both are absent, then writes to `ts-devices.db` with the
  tailscale IP from `detect_tailscale_ip`, and populates hostkey via
  `_get_host_key_fingerprint 127.0.0.1 <port>`.

## Clip

Two independent mechanisms:
- `clip tunnel` — Unix socket via SSH RemoteForward, started/stopped around
  interactive `nssh` sessions.
- `clip serve`  — TCP listener (`ncat`, port 9988), independent of SSH.

## Deploy

Source of truth is the repo. Symlink-installed. Deploy order per change:
`ut ship` → `ut distribute --install <repo>` → `miko sync <repo>`.
