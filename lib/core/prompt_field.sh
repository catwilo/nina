#!/bin/sh
# prompt_field.sh -- shared prompt helper.

_prompt_field() {
    _label="$1"; _current="$2"
    printf '  %s [%s]: ' "$_label" "$_current" >&2
    read -r _val </dev/tty || _val=""
    _val="$(printf '%s' "$_val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$_val" ] && printf '%s\n' "$_current" || printf '%s\n' "$_val"
}
