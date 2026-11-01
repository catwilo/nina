#!/bin/sh
# discovery.sh -- tailscale-only orchestration for nina subcommands.

_do_self_register() {
    _self_register
}

_do_bootstrap_keys() {
    ssh_key_bootstrap
}

_do_all() {
    _self_register
    ssh_key_bootstrap
}
