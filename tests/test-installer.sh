#!/usr/bin/env bash
#
# Statische Tests für den Installer (ohne Proxmox). Auf jedem Linux ausführbar.
#
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

say() { printf '%s\n' "$*"; }
ok()  { say "[OK]   $*"; }
bad() { say "[FAIL] $*"; FAIL=1; }

say "== bash -n =="
while IFS= read -r -d '' f; do
  if bash -n "$f" 2>/dev/null; then
    ok "Syntax: ${f#"$ROOT"/}"
  else
    bad "Syntax: ${f#"$ROOT"/}"
  fi
done < <(find "$ROOT" -type f -name '*.sh' -print0)

say ""
say "== ShellCheck (optional) =="
if command -v shellcheck >/dev/null 2>&1; then
  while IFS= read -r -d '' f; do
    if shellcheck -S warning "$f"; then
      ok "ShellCheck: ${f#"$ROOT"/}"
    else
      bad "ShellCheck: ${f#"$ROOT"/}"
    fi
  done < <(find "$ROOT" -type f -name '*.sh' -print0)
else
  say "[SKIP] shellcheck nicht installiert"
fi

say ""
say "== Pflichtdateien =="
for rel in \
  install/ictfax.sh install/ictfax-inner.sh \
  docker/compose.yml docker/compose.smtp.yml \
  systemd/ictfax.service systemd/ictfax-portal.service \
  portal/package.json portal/server/index.js portal/index.html \
  README.md; do
  if [[ -s "$ROOT/$rel" ]]; then
    ok "$rel"
  else
    bad "$rel fehlt oder ist leer"
  fi
done

say ""
say "== Einzeiler-URL =="
if grep -q 'raw.githubusercontent.com/HatchetMan111/ICTFax-Proxmox/main/install/ictfax.sh' "$ROOT/README.md"; then
  ok "README enthält den Einzeiler"
else
  bad "README-Einzeiler fehlt"
fi

say ""
if [[ "$FAIL" == "0" ]]; then
  say "Ergebnis: OK"
else
  say "Ergebnis: FEHLER"
fi
exit "$FAIL"
