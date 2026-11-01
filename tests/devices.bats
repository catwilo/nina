#!/usr/bin/env bats
# devices.bats -- comportamiento de nina devices (nodes.db state model).

load helpers

setup() { setup_env; }

# _seed_self <alias> <ip> -- seed this node's own row using the real node_id.
_seed_self() {
    _nid="$(node_id)"
    {
        [ -s "$NODES_DB" ] && printf '\n'
        printf 'node_id: %s\nalias: %s\nuser: u\nport: 8022\nos: android\nkind: phone\nroot: no\nhostkey: \nip: %s\nstate: active\n' \
            "$_nid" "$1" "$2"
    } >> "$NODES_DB"
}

@test "devices list: local + active remotes, omits suspended" {
    _seed_self tx2 10.0.0.2
    _seed_node db1 10.0.0.3 active
    _seed_node tx1 10.0.0.4 suspended
    run _devices_list 0
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "${lines[0]}" == tx2* ]]
    [[ "${lines[1]}" == db1* ]]
}

@test "devices list --remote-only: active remotes, no local" {
    _seed_self tx2 10.0.0.2
    _seed_node db1 10.0.0.3 active
    _seed_node tx1 10.0.0.4 suspended
    run _devices_list 1
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" == db1* ]]
}

@test "devices all: every node with its state" {
    _seed_node db1 10.0.0.3 active
    _seed_node tx1 10.0.0.4 suspended
    run _devices_all
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "${lines[0]}" == *active ]]
    [[ "${lines[1]}" == *suspended ]]
}

@test "devices set_state: flips state, preserves other fields" {
    _seed_node db1 10.0.0.3 active
    _devices_set_state db1 suspended suspend
    [ "$(_state_of db1)" = "suspended" ]
    [ "$(blockdb_field "$(blockdb_get "$NODES_DB" alias db1)" ip)" = "10.0.0.3" ]
    [ "$(blockdb_field "$(blockdb_get "$NODES_DB" alias db1)" user)" = "u" ]
}


@test "devices set_state: unknown alias fails without touching nodes.db" {
    _seed_node db1 10.0.0.3 active
    _before="$(cat "$NODES_DB")"
    run _devices_set_state nosuch active resume
    [ "$status" -ne 0 ]
    [ "$(cat "$NODES_DB")" = "$_before" ]
}

@test "registry_write: preserves state when the row already exists" {
    _seed_node db1 10.0.0.3 suspended
    git -C "$REGISTRY_DIR" add nodes.db
    git -C "$REGISTRY_DIR" commit -q -m "seed"
    git -C "$REGISTRY_DIR" push -q origin main
    _registry_write "nid-db1" db1 u 8022 debian laptop no 10.0.0.99
    [ "$(_state_of db1)" = "suspended" ]
    [ "$(blockdb_field "$(blockdb_get "$NODES_DB" alias db1)" ip)" = "10.0.0.99" ]
}

@test "nodes_commit_push: no-op when nodes.db is unchanged" {
    _seed_node db1 10.0.0.3 active
    git -C "$REGISTRY_DIR" add nodes.db
    git -C "$REGISTRY_DIR" commit -q -m "seed"
    git -C "$REGISTRY_DIR" push -q origin main
    run _nodes_commit_push "should be a no-op"
    [ "$status" -eq 0 ]
    [[ "$output" == *"unchanged"* ]]
}

@test "nodes_commit_push: commits and pushes when nodes.db changed" {
    _seed_node db1 10.0.0.3 active
    run _nodes_commit_push "chore: test"
    [ "$status" -eq 0 ]
    _head_subject="$(git -C "$REGISTRY_DIR" log -1 --pretty=%s)"
    [ "$_head_subject" = "chore: test" ]
    _remote_head="$(git -C "$HOME/origin.git" rev-parse main)"
    _local_head="$(git -C "$REGISTRY_DIR" rev-parse main)"
    [ "$_remote_head" = "$_local_head" ]
}
