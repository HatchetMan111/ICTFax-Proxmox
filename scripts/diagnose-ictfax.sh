#!/usr/bin/env bash
#
# ICTFax-Diagnose (v2): Container-Port-Problem + Crash-Loop eingrenzen.
# Auf dem Proxmox-Host als root ausführen:
#
#   bash diagnose-ictfax.sh <CT_ID>
#
set -Eeuo pipefail
CT="${1:-}"
if [[ -z "$CT" ]]; then
  echo "Usage: bash diagnose-ictfax.sh <CT_ID>" >&2
  echo "  (Container bzw. VM-ID des ICTFax-Gasts, z. B. 113)" >&2
  exit 2
fi

echo "════ ICTFax-Diagnose v2 CT ${CT} ════"

echo ""
echo "── 1. CT-Status + IP ──"
pct status "$CT"
IP="$(pct exec "$CT" -- hostname -I 2>/dev/null | awk '{print $1}')"
echo "IP: ${IP}"

echo ""
echo "── 2. Services ──"
pct exec "$CT" -- systemctl is-active ictfax ictfax-portal 2>&1 || true

echo ""
echo "── 3. Health (Portal-BFF → ICTFax) ──"
pct exec "$CT" -- curl -s --max-time 8 "http://127.0.0.1:8080/api/health" 2>&1 || true
echo ""

echo ""
echo "── 4. Native ICTFax-UI (8081) ──"
pct exec "$CT" -- curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 8 "http://127.0.0.1:8081/" 2>&1 || true

echo ""
echo "── 5. Login-Versuch (admin@ictcore.org / helloAdmin) ──"
RESP="$(pct exec "$CT" -- curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
  -d '{"username":"admin@ictcore.org","password":"helloAdmin"}' \
  http://127.0.0.1:8080/api/session/login 2>&1 || true)"
echo "$RESP"
if grep -q '"ok":true' <<<"$RESP"; then
  echo ">>> LOGIN OK"
else
  echo ">>> LOGIN FEHLER"
fi

echo ""
echo "── 6. Login-Versuch (admin / helloAdmin) ──"
RESP="$(pct exec "$CT" -- curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"helloAdmin"}' \
  http://127.0.0.1:8080/api/session/login 2>&1 || true)"
echo "$RESP"
if grep -q '"ok":true' <<<"$RESP"; then
  echo ">>> LOGIN OK (Username-Form)"
else
  echo ">>> LOGIN FEHLER"
fi

echo ""
echo "── 7. exim/MTA auf Port 25 ──"
pct exec "$CT" -- bash -lc "ss -ltn | grep ':25 ' || echo 'Port 25 frei'" 2>&1 || true

echo ""
echo "── 8. Container-Status + Logs (Crash-Loop?) ──"
pct exec "$CT" -- /usr/local/bin/ictfax-compose ps 2>&1 || true
echo "--- letzte Logs (ictfax) ---"
pct exec "$CT" -- bash -lc "docker logs --tail 40 ictfax 2>&1 | tail -25" 2>&1 || true

echo ""
echo "── 9. Container-interner HTTP-Test (httpd auf :80) ──"
pct exec "$CT" -- bash -lc "docker exec ictfax curl -s -o /dev/null -w 'innen httpd: HTTP %{http_code}\n' --max-time 5 http://localhost:80/ 2>&1 || echo 'docker exec fehlgeschlagen (Container weg?)'" 2>&1 || true

echo ""
echo "── 10. iptables NAT (Docker) ──"
pct exec "$CT" -- bash -lc "iptables -t nat -L DOCKER -n 2>&1 | grep -E '8081|8080' || echo 'keine DOCKER-NAT-Regeln für 8081/8080'" 2>&1 || true

echo ""
echo "── 11. CT-Config (net0/features/keyctl) ──"
pct config "$CT" | grep -E 'net0|features|keyctl|hostname' || true

echo ""
echo "── 12. Host-Ports (lauscht 8081/8080 auf dem Host?) ──"
ss -ltnp 2>/dev/null | grep -E ':8081|:8080' || echo "Host lauscht nicht auf 8081/8080"

echo ""
echo "════ Diagnose fertig ════"