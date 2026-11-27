#!/usr/bin/env bats
# pubkey.bats -- _sb_clean_pubkey: llave publica limpia desde salida de nya.

load helpers

setup() {
    setup_env
    . "$LIB_NINA/connection/ssh_bootstrap.sh"
    ssh-keygen -q -t ed25519 -N "" -C "u@db2" -f "$BATS_TEST_TMPDIR/k"
    KEY="$(cat "$BATS_TEST_TMPDIR/k.pub")"
}

@test "clean_pubkey: llave valida pasa sin cambios" {
    run _sb_clean_pubkey <<< "$KEY"
    [ "$status" -eq 0 ]
    [ "$output" = "$KEY" ]
}

@test "clean_pubkey: quita el prefijo [alias] de nya" {
    run _sb_clean_pubkey <<< "[db2] $KEY"
    [ "$status" -eq 0 ]
    [ "$output" = "$KEY" ]
}

@test "clean_pubkey: toma solo la linea de llave de una salida con ruido" {
    run _sb_clean_pubkey <<< "$(printf 'warning: algo\n[db2] %s\n' "$KEY")"
    [ "$status" -eq 0 ]
    [ "$output" = "$KEY" ]
}

@test "clean_pubkey: texto que no es llave falla sin salida" {
    run _sb_clean_pubkey <<< "[db2] permission denied"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "clean_pubkey: base64 invalido con forma de llave falla" {
    run _sb_clean_pubkey <<< "ssh-ed25519 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA u@x"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}
