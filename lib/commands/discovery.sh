#!/bin/sh
# discovery.sh -- tailscale-only orchestration for nina subcommands.

_do_self_register() {
    _self_register
}

_do_seed() {
    _seed_from_registry
}

_do_bootstrap_keys() {
    ssh_key_bootstrap "$BASE/state/ts-devices.db"
}

_do_push() {
    sync_devices_to_nodes
}

_do_all() {
    _self_register
    _seed_from_registry
    ssh_key_bootstrap "$BASE/state/ts-devices.db"
    sync_devices_to_nodes
}
