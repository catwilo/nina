
  nina — tailscale-only SSH device mapper
  ─────────────────────────────────────────────────────────────────────

  TOP-LEVEL

    nina                   Run the full pipeline: self-register + seed
                           + bootstrap-keys + push.
    nina self-register     Register this node identity in ts-devices.db
                           and registry.db.
    nina seed              Pull other nodes rows from the cloud registry.
    nina bootstrap-keys    Distribute SSH keys to registered peers.
    nina push              Sync ts-devices.db to all registered peers.
    nina status            List devices; marks the local node.
    nina -h | --help       Show this help.

  ─────────────────────────────────────────────────────────────────────

  CONNECT

    nssh <alias>                    Open interactive SSH session.
    nssh <alias> <cmd> [args...]    Run command remotely, print output.

      nssh tx1                      # interactive shell
      nssh tx1 uname -a             # single command -> stdout

  ─────────────────────────────────────────────────────────────────────

  TRANSFER

    nscp <alias>:/remote/path ./local/    Copy from remote to local.
    nscp ./local/file <alias>:/remote/    Copy from local to remote.

  ─────────────────────────────────────────────────────────────────────

  DEVICE MANAGEMENT  (nina devices)

    nina devices list                            List all devices.
    nina devices add <alias> <ip> <user> [port]  Register manually.
    nina devices edit <alias>                    Edit device details.
    nina devices rename <old> <new>              Rename alias.
    nina devices remove <alias> [alias...]       Remove devices.
    nina devices update-ip <alias> <ip>          Set device IP.
    nina devices refresh-ips                     Refresh local IP from tun0;
                                                 peers from tailscale CLI (jq)
                                                 if present.
    nina devices push-vpn                        Sync ts-devices.db to peers.
    nina devices rollback <alias>                Restore from snapshot.
    nina devices resetall                        Wipe ts-devices.db + known_hosts.
    nina devices node-set <alias> [user] [port] [platform]
                                                 Set THIS node identity.
    nina devices node-add <node-id> <alias> <user> <port> <platform>
                                                 Register another node.
    nina devices registry-set <node-id> <alias> [user] [port] [platform]
                                                 Edit any node in registry.
    nina devices hostkey-refresh                 Refresh SSH host keys.

  ─────────────────────────────────────────────────────────────────────

  CLIP (clipboard forwarding, tmux-backed)

    nina clip get <alias>:/remote/path   Copy remote file to local clipboard.
    nina clip send [--ssh] <alias>       Send stdin to remote clipboard.
    nina clip set <src> <dst>            Define direction + smoke-test.
    nina clip clear                      Clear direction config.
    nina clip status                     Show direction config.
    nina clip tunnel <start|stop|restart|status>
                                         Unix socket listener (SSH RemoteForward).
    nina clip serve  <start|stop|restart|status>
                                         TCP listener (ncat, port 9988).

  ─────────────────────────────────────────────────────────────────────

  NOTES

    • Aliases are short names you assign manually during registration
      (tx1, tx2, ...). No automatic suggestion.
    • All tools resolve aliases from  $NINA_BASE/state/ts-devices.db
    • registry.db (cloud source of identity) lives at
      ~/.nina-registry/registry.db
    • SSH config lives at             $NINA_BASE/config/ssh_config
    • known_hosts lives at            ~/.local/share/nina/known_hosts
    • Logs at                         $NINA_BASE/logs/nina.log

    • Tailscale-only: peers are reached via their 100.x IP.
      Without the tailscale CLI installed, peer IPs must be populated
      once with: nina devices update-ip <alias> <ip>

    • Identity is stable across reinstall: registry.sh reclaims the
      alias when the local SSH hostkey matches an existing row.

