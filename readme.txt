
  nina — network discovery and SSH device mapper
  ─────────────────────────────────────────────────────────────────────

  DISCOVERY

    nina                   Fast scan: find SSH hosts on ports 22/8022/2222.
                           Validates registered hosts first via ping.
                           Displays results, then prompts to register new hosts.

    nina --ports           Show all probed ports per host in the results table.



  ─────────────────────────────────────────────────────────────────────

  CONNECT

    nssh <alias>                    Open interactive SSH session.
    nssh <alias> <cmd> [args...]    Run command remotely, print output.

      nssh deb                      # interactive shell
      nssh deb uname -a             # single command -> stdout
      nssh deb 'df -h | head -5'   # piped command (quote it)

  ─────────────────────────────────────────────────────────────────────

  TRANSFER

    nscp <alias>:/remote/path ./local/    Copy from remote to local.
    nscp ./local/file <alias>:/remote/    Copy from local to remote.

    nina clip get <alias>:/remote/path            Copy remote file content to clipboard
                                          (requires clipso / xclip / pbcopy).

  ─────────────────────────────────────────────────────────────────────

  CLIP (clipboard forwarding, tmux-backed)

    nina clip tunnel start                    Start local listener (Unix socket,
                                          tmux session "nina-clip-tunnel").
    nina clip tunnel stop                     Stop listener, remove socket.
    nina clip tunnel restart                  stop + start.
    nina clip tunnel status                   Show running state and socket path.
    nina clip serve start                   Start TCP listener (tmux session
                                          "nina-clip-serve", requires ncat).
    nina clip serve stop                    Stop TCP listener.
    nina clip serve restart                 stop + start.
    nina clip serve status                  Show TCP listener state.

    nina clip set <src> <dst>                 Define clipboard direction (src sends,
                                          dst receives). Starts nina clip serve
                                          start on dst, then runs a
                                          smoke-test send+read to confirm.
    nina clip status                      Show current direction config.
    nina clip clear                       Stop listener on dst, remove config.

                                          Direction is explicit, not inferred
                                          from ssh initiator. Not persisted
                                          across reboots -- re-run per session.

  ─────────────────────────────────────────────────────────────────────

  DEVICE MANAGEMENT  (nina devices)

    nina devices list                  List all registered devices.
    nina devices edit <alias>               Edit alias / IP / user / port.
    nina devices rename <old> <new>         Rename alias.
    nina devices remove <alias> [alias...]  Remove one or more devices.
    nina devices update-ip <alias> <ip>     Update IP, auto-clean known_hosts.
    nina devices resetall                   Wipe devices.db + known_hosts + hosts.db + cache.

  ─────────────────────────────────────────────────────────────────────

  NOTES

    • Aliases are short names you assign during registration (deb, cel, pi ...).
    • All tools resolve aliases from  $NINA_BASE/state/devices.db
    • SSH config lives at            $NINA_BASE/config/ssh_config
    • known_hosts lives at           ~/.local/share/nina/known_hosts
    • Logs at                        $NINA_BASE/logs/nina.log

    • On each run: registered hosts are pinged first. Non-responding hosts
      are removed automatically. Responding hosts skip the full scan.

    • Type detection = port only (8022->android, 22/2222->linux).
      No nmap -sV, no banner grab. Safe and quick on Termux.

