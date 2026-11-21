#!/usr/bin/env bash
#
# ICTFax-Diagnose: Login + UI + SMTP-Status im CT prüfen.
# Auf dem Proxmox-Host als root ausführen:
#
#   bash diagnose-ictfax.sh [CT_ID]
#
set -Eeuo pipefail
CT="${1:-113}"

echo "════ ICTFax-Diagnose CT ${CT} ════"

echo ""
echo "── 1. CT-Status + IP ──"
pct status "$CT"
IP="$(pct exec "$CT" -- hostname -I 2>/dev/null | awk '{print $1}')"
echo "IP: ${IP}"

echo ""
echo "── 2. Services ──"
pct exec "$CT" -- systemctl is-active ictfax ictfax-portal 2>&1 || true

echo ""
echo "── 3. Health ──"
pct exec "$CT" -- curl -s --max-time 8 "http://127.0.0.1:8080/api/health" 2>&1 || true
echo ""

echo ""
echo "── 4. Native ICTFax-UI (8081) ──"
pct exec "$CT" -- curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 8 "http://127.0.0.1:8081/" 2>&1 || true

echo ""
echo "── 5. Login-Versuch im Portal (admin / helloAdmin) ──"
RESP="$(pct exec "$CT" -- curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"helloAdmin"}' \
  http://127.0.0.1:8080/api/session/login 2>&1 || true)"
echo "$RESP"
if grep -q '"ok":true' <<<"$RESP"; then
  echo ">>> LOGIN OK"
else
  echo ">>> LOGIN FEHLER"
fi

echo ""
echo "── 6. Login-Versuch mit admin@ictcore.org ──"
pct exec "$CT" -- curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
  -d '{"username":"admin@ictcore.org","password":"helloAdmin"}' \
  http://127.0.0.1:8080/api/session/login 2>&1 || true
echo ""

echo ""
echo "── 7. exim/MTA auf Port 25 ──"
pct exec "$CT" -- bash -lc "ss -ltn | grep ':25 ' || echo 'Port 25 frei'" 2>&1 || true

echo ""
echo "── 8. Native ICTFax-Login direkt (8081 /api/authenticate) ──"
pct exec "$CT" -- curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"helloAdmin"}' \
  http://127.0.0.1:8081/api/authenticate 2>&1 || true
echo ""

echo ""
echo "── 9. Portal-Logs (letzte 30) ──"
pct exec "$CT" -- journalctl -u ictfax-portal --no-pager -n 30 2>&1 || true

echo ""
echo "════ Diagnose fertig ════"