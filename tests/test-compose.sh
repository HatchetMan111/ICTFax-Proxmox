#!/usr/bin/env bash
#
# Validiert die Compose-Dateien mit Dummy-Secrets (kein Container-Start).
#
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

cat > "$TMP" <<'EOF'
DB_HOST=db
DB_PORT=3306
DB_NAME=ictfax
DB_USER=ictfax
DB_PASS=testpass
DB_ROOT_PASS=testroot
ICTCORE_HOST=ictfax.local
SIP_EXT_IP=
FS_ESL_PASSWORD=testfs
SMTP_ENABLED=1
EOF

if ! command -v docker >/dev/null 2>&1; then
  echo "[SKIP] docker nicht installiert"
  exit 0
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  echo "[SKIP] docker compose nicht verfügbar"
  exit 0
fi

export ICTFAX_ENV_FILE="$TMP"
export DB_PASS=testpass DB_ROOT_PASS=testroot FS_ESL_PASSWORD=testfs

cd "$ROOT/docker"
"${COMPOSE[@]}" -f compose.yml config -q
echo "[OK] compose.yml"
"${COMPOSE[@]}" -f compose.yml -f compose.smtp.yml config -q
echo "[OK] compose.yml + compose.smtp.yml"
echo "Ergebnis: OK"
