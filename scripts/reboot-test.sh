#!/usr/bin/env bash
#
# Reboot-Test auf dem Proxmox-Host: startet den bestehenden LXC/VM neu und
# verifiziert, dass ICTFax + Portal ohne manuelles Eingreifen wieder hochkommen.
#
#   bash scripts/reboot-test.sh --ctid 123 --type lxc
#
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/../install/ictfax.sh" --reboot-test "$@"
