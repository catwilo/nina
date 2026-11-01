# helpers.bash -- shared setup for nina BATS tests.
#
# Aisla HOME/XDG/TMPDIR en BATS_TEST_TMPDIR. Crea un git repo real en
# $HOME/.nina-registry (con origin bare) para poder ejercitar
# _nodes_commit_push sin tocar el repo real del usuario.
#
# Stubs:
#   nya   no se invoca nunca: los tests llaman a las funciones puras
#         (_devices_list, _devices_all, _devices_set_state) directamente,
#         no al dispatcher completo.

setup_env() {
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CACHE_HOME="$HOME/.cache"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_DATA_HOME="$HOME/.local/share"
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$TMPDIR"

    export REPO="$BATS_TEST_DIRNAME/.."
    export LIB_NINA="$REPO/lib"
    export NINA="$REPO/bin/nina"

    export REGISTRY_DIR="$HOME/.nina-registry"
    export NODES_DB="$REGISTRY_DIR/nodes.db"
    mkdir -p "$REGISTRY_DIR"
    git init -q -b main "$REGISTRY_DIR"
    git -C "$REGISTRY_DIR" config user.email "test@nina"
    git -C "$REGISTRY_DIR" config user.name "nina-test"
    git init -q --bare "$HOME/origin.git"
    git -C "$REGISTRY_DIR" remote add origin "$HOME/origin.git"
    : > "$NODES_DB"
    git -C "$REGISTRY_DIR" add nodes.db
    git -C "$REGISTRY_DIR" commit -q -m init
    git -C "$REGISTRY_DIR" push -q -u origin main

    export BASE="$HOME/.local/share/nina"
    mkdir -p "$BASE/state" "$BASE/logs"

    # Source the modules under test. Order matters: util -> blockdb ->
    # network -> identity -> devices.
    # shellcheck source=/dev/null
    . "$LIB_NINA/core/util.sh"
    # shellcheck source=/dev/null
    . "$LIB_NINA/core/blockdb.sh"
    # shellcheck source=/dev/null
    . "$LIB_NINA/core/network.sh"
    # shellcheck source=/dev/null
    . "$LIB_NINA/identity/identity.sh"
    # shellcheck source=/dev/null
    . "$LIB_NINA/identity/registry.sh"
    # shellcheck source=/dev/null
    . "$LIB_NINA/commands/devices.sh"

    # _distribute_registry calls nya; replace it with a no-op so tests
    # never attempt real SSH.
    _distribute_registry() { return 0; }
    export -f _distribute_registry 2>/dev/null || true
}

# _seed_node <alias> <ip> <state> -- append a node block to nodes.db.
_seed_node() {
    {
        [ -s "$NODES_DB" ] && printf '\n'
        printf 'node_id: nid-%s\nalias: %s\nuser: u\nport: 8022\nos: android\nkind: phone\nroot: no\nhostkey: \nip: %s\nstate: %s\n' \
            "$1" "$1" "$2" "$3"
    } >> "$NODES_DB"
}

# _state_of <alias> -- print the state field of a node block.
_state_of() {
    blockdb_field "$(blockdb_get "$NODES_DB" alias "$1")" state
}
