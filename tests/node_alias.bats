#!/usr/bin/env bats
# node_alias.bats -- alias resolution with registry and offline cache fallback.

load helpers

setup() { setup_env; }

_seed_self() {
    _nid="$(node_id)"
    {
        [ -s "$NODES_DB" ] && printf '\n'
        printf 'node_id: %s\nalias: %s\nuser: u\nport: 8022\nos: android\nkind: phone\nroot: no\nhostkey: \nip: %s\nstate: active\n' \
            "$_nid" "$1" "$2"
    } >> "$NODES_DB"
}

@test "node_alias: registry row present returns registry alias" {
    _seed_self tx2 10.0.0.2
    [ "$(node_alias)" = "tx2" ]
}

@test "node_alias: registry empty falls back to node-config cache" {
    : > "$NODES_DB"
    printf 'tx2|u|8022|android|phone|no\n' > "$NODE_CONFIG"
    [ "$(node_alias)" = "tx2" ]
}

@test "node_alias: no registry row and no cache returns empty" {
    : > "$NODES_DB"
    rm -f "$NODE_CONFIG"
    [ -z "$(node_alias)" ]
}

@test "node_alias: registry row wins over cache on conflict" {
    _seed_self tx2 10.0.0.2
    printf 'WRONG|u|8022|android|phone|no\n' > "$NODE_CONFIG"
    [ "$(node_alias)" = "tx2" ]
}
