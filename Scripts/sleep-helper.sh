#!/bin/bash
set -euo pipefail
rule=/private/etc/sudoers.d/sidepulse-swift-disablesleep
[[ "$(id -u)" == 0 ]] || { echo 'Run this script with sudo.' >&2; exit 1; }
case "${1:-}" in
  install)
    account=${SUDO_USER:-}
    [[ "$account" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ && "$account" != root ]] || { echo 'Run with sudo from your normal account.' >&2; exit 1; }
    mkdir -p /private/etc/sudoers.d
    temp=$(mktemp /private/etc/sudoers.d/.sidepulse-swift.XXXXXXXX)
    trap 'rm -f "$temp"' EXIT
    printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n' "$account" > "$temp"
    chmod 0440 "$temp"
    /usr/sbin/visudo -cf "$temp"
    mv -f "$temp" "$rule"
    ;;
  uninstall)
    rm -f "$rule"
    ;;
  *) echo 'Use install or uninstall.' >&2; exit 2 ;;
esac
