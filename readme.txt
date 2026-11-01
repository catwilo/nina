
  nina — tailscale-only SSH device mapper
  ─────────────────────────────────────────────────────────────────────

  TOP-LEVEL

    nina                   Run the full pipeline: self-register + bootstrap-keys.
    nina self-register     Register this node identity in nodes.db.
    nina bootstrap-keys    Distribute SSH keys to registered peers.
    nina status [--remote-only]
                           Emit "alias ip user port kind os", one node per line.
                           The FIRST line is always the local node; every
                           following line is an ACTIVE remote node.
                           Suspended nodes are omitted from this view.
                           --remote-only omits the local line and emits active
                           remotes only -- the source nya consumes.
    nina status -h         Show the status contract.
    nina -h | --help       Show this help.

  ─────────────────────────────────────────────────────────────────────

  CONNECT

    Remote execution and file transfer moved to `nya` (separate repo):

      nya <alias>                    # interactive shell
      nya <alias> uname -a           # single command -> stdout
      nya <alias>:/remote/path ./local/    # copy from remote to local
      nya ./local/file <alias>:/remote/    # copy from local to remote

  ─────────────────────────────────────────────────────────────────────

  DEVICE MANAGEMENT  (nina devices)

    nina devices list                            Emit active nodes + local (nya consumes this).
    nina devices all                             List every node with its state.
    nina devices add <alias> <ip> <user> [port]  Register manually.
    nina devices edit <alias>                    Edit device details.
    nina devices rename <old> <new>              Rename alias.
    nina devices remove <alias> [alias...]       Remove devices.
    nina devices update-ip <alias> <ip>          Set device IP.
    nina devices refresh-ips                     Refresh local IP from tun0;
                                                 peers from tailscale CLI (jq)
                                                 if present.
    nina devices suspend <alias>                 Mark suspended (excluded from status).
    nina devices resume <alias>                  Mark active again.
    nina devices node-set <alias> [user] [port] [platform]
                                                 Set THIS node identity.
    nina devices node-add <node-id> <alias> <user> <port> <platform>
                                                 Register another node.
    nina devices registry-set <node-id> <alias> [user] [port] [platform]
                                                 Edit any node.
    nina devices hostkey-refresh                 Refresh SSH host keys.

  ─────────────────────────────────────────────────────────────────────

  NOTES

    • Aliases are short names assigned manually (tx1, tx2, ...).
    • Canonical registry: ~/.nina-registry/nodes.db (blockdb, git-backed).
      Every node and its state (active|suspended) lives there.
    • Any change to nodes.db is committed and pushed, then distributed to
      every active node immediately via `nya @all`.
    • When this node is suspended, `nina status` warns and offers to resume.
    • SSH config lives at  $NINA_BASE/config/ssh_config
    • Logs at              $NINA_BASE/logs/nina.log
    • Tailscale-only: peers are reached via their 100.x IP.
