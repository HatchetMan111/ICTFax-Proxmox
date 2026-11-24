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
say "== Einzeiler-Modus (bash -c, BASH_SOURCE undefiniert) =="
# Nur echte Expansionen zählen (einrückte Kommentare mit -- ignorieren).
# Ohne Default killt `set -u` den Einzeiler mit "unbound variable".
CODE="$(grep -vE '^[[:space:]]*#' "$ROOT/install/ictfax.sh")"
if grep -q 'BASH_SOURCE\[0\}[^:}]' <<<"$CODE"; then
  bad "BASH_SOURCE ohne Default expandiert – killt bash -c unter set -u"
elif grep -q 'BASH_SOURCE\[0\]:-\|BASH_SOURCE\[0\]}' <<<"$CODE"; then
  ok "BASH_SOURCE nur mit :- Default expandiert (bash-c-sicher)"
else
  bad "BASH_SOURCE gar nicht abgesichert – unerwarteter Zustand"
fi
# Regressionstest: Der Skriptkopf muss sich per bash -c ausführen lassen,
# ohne an "unbound variable" zu sterben (Live-Grube #1). -n prüft nur Syntax,
# der echte Test parst den Quelltext mitten aus dem String.
if BASH_SOURCE_TEST="$(cat "$ROOT/install/ictfax.sh")" bash -c 'bash -n <<<"$BASH_SOURCE_TEST"' 2>/dev/null; then
  ok "Syntax via bash -c-String gültig"
else
  bad "bash -c-String nicht parsbar"
fi
# Der Log-Block (exec tee) muss NACH set -u stehen – sonst unbound-variable.
awk '/^set -[a-zA-Z]*u/{found=NR} /exec >.*tee/{if(found && NR>found) ok=1} END{exit !ok}' \
  "$ROOT/install/ictfax.sh" \
  && ok "tee-Logging steht nach set -u" \
  || bad "tee-Logging steht vor/ohne set -u (Einzeiler-Grube)"
# curl-fallback im LXC-Zweig: wget oder apt-install muss vor curl stehen
if grep -q 'command -v wget' "$ROOT/install/ictfax.sh" \
   || grep -q 'apt-get install.*curl' "$ROOT/install/ictfax.sh"; then
  ok "curl-Fallback für nackte Templates vorhanden"
else
  bad "kein curl/wget-Fallback im Gast-Download"
fi

say ""
say "== systemd: ictfax.service Shape =="
# `docker compose up -d --wait` exits as soon as the containers are healthy.
# With Type=simple + Restart=always systemd restarted the unit forever and
# `systemctl is-active` stayed in "activating (auto-restart)" – the installer
# and the reboot test failed although the stack was up.
if grep -q '^Type=oneshot' "$ROOT/systemd/ictfax.service" \
   && grep -q '^RemainAfterExit=yes' "$ROOT/systemd/ictfax.service"; then
  ok "ictfax.service ist Type=oneshot + RemainAfterExit (kein Restart-Loop)"
else
  bad "ictfax.service muss Type=oneshot + RemainAfterExit sein (compose up --wait exitst)"
fi
if grep -q '^Restart=always' "$ROOT/systemd/ictfax.service"; then
  bad "Restart=always auf Type=oneshot lässt is-active dauerhaft 'activating' melden"
else
  ok "kein Restart=always auf dem oneshot-Dienst"
fi

say ""
say "== Portal: Session-Regression (token_payload) =="
# ICTCore hat KEIN /api/token_payload. Das Portal hat damit nach dem Login
# jedes Mal das Session-Cookie gelöscht → alle API-Aufrufe 401.
if grep -q "token_payload" "$ROOT/portal/server/index.js" \
   && ! grep -q "apiFetch('/token_payload'" "$ROOT/portal/server/index.js"; then
  ok "Portal fragt token_payload nicht mehr als Session-Quelle ab"
else
  bad "Portal nutzt /token_payload als Session-Prüfung – ICTCore hat den Endpunkt nicht"
fi
if grep -q "verifyToken" "$ROOT/portal/server/index.js"; then
  ok "Session wird gegen /statistics verifiziert (echter ICTFax-Endpunkt)"
else
  bad "Session-Verifikation fehlt"
fi

say ""
say "== User()/Berechtigungen (systemd startet portal als User) =="
if grep -q 'o=rX' "$ROOT/install/ictfax-inner.sh"; then
  ok "portal-Verzeichnisse haben o+rX (node-Leserecht)"
else
  bad "portal-Verzeichnisse ohne o+rX – ictfax-portal.service startet nicht"
fi
if grep -q -- '--wait' "$ROOT/install/ictfax-inner.sh"; then
  ok "compose up nutzt --wait (detached + healthy-Block)"
else
  bad "compose up ohne --wait (systemd-Dienst hält keine Container)"
fi
# Login-Doku muss beide Varianten nennen (admin + admin@ictcore.org).
# ICTCore akzeptiert beides – der Demo-User hat username='admin' und
# email='admin@ictcore.org'.
if grep -h 'admin@ictcore.org' "$ROOT/README.md" "$ROOT/install/ictfax.sh" "$ROOT/install/ictfax-inner.sh" 2>/dev/null \
   | grep -vE 'nicht|existiert' | grep -q 'admin@ictcore.org'; then
  ok "Login-Doku nennt beide Varianten (admin + admin@ictcore.org)"
else
  bad "Login-Doku fehlt admin@ictcore.org – beide Varianten müssen genannt sein"
fi

say ""
say "== Upstream-Login verifiziert (Demo-User) =="
if curl -fsS --max-time 20 -s "https://raw.githubusercontent.com/ictinnovations/ictcore/ae9ffcf00bcd923f1ade67fd3ee18b92ff779cd5/db/data/demo_users.sql" 2>/dev/null | grep -q "'admin', MD5('helloAdmin')"; then
  ok "Upstream demo_users.sql: admin / MD5(helloAdmin) bestätigt"
else
  bad "Upstream-Demo-User nicht verifizierbar (Netz/DNS?)"
fi

say ""
if [[ "$FAIL" == "0" ]]; then
  say "Ergebnis: OK"
else
  say "Ergebnis: FEHLER"
fi
exit "$FAIL"
