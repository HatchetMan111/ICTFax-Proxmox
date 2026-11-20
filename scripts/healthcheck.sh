#!/usr/bin/env bash
#
# Healthcheck für ICTFax + Portal. Im Gast (LXC/VM) als root ausführen.
#
set -Eeuo pipefail

PORTAL_PORT="${PORTAL_PORT:-8080}"
ICTFAX_PORT="${ICTFAX_PORT:-8081}"
FAIL=0

check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "[OK]   ${label}"
  else
    echo "[FAIL] ${label}"
    FAIL=1
  fi
}

check "ictfax.service active" systemctl is-active --quiet ictfax
check "ictfax-portal.service active" systemctl is-active --quiet ictfax-portal
check "Portal /api/health" curl -fsS --max-time 10 "http://127.0.0.1:${PORTAL_PORT}/api/health"
check "Portal Startseite" curl -fsS --max-time 10 -o /dev/null "http://127.0.0.1:${PORTAL_PORT}/"
check "ICTFax UI" curl -fsS --max-time 10 -o /dev/null "http://127.0.0.1:${ICTFAX_PORT}/"
check "ICTFax API erreichbar" bash -c "code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:${ICTFAX_PORT}/api/statistics); [[ \"\$code\" == 200 || \"\$code\" == 401 ]]"

echo ""
echo "--- docker compose ps ---"
/usr/local/bin/ictfax-compose ps 2>&1 || true

if [[ "$FAIL" == "0" ]]; then
  echo ""
  echo "Ergebnis: OK"
else
  echo ""
  echo "Ergebnis: FEHLER (siehe oben)"
  echo "Logs: journalctl -u ictfax -u ictfax-portal --no-pager -n 100"
  echo "      docker logs --tail 100 ictfax"
fi
exit "$FAIL"
