#!/usr/bin/env bash
#
# ICTFax-Proxmox – Gast-Installer (läuft IM LXC/VM als root)
#
# Wird vom Host-Installer (ictfax.sh) aufgerufen. Installiert:
#   - Docker CE + Compose
#   - ICTFax (Docker, MariaDB extern)
#   - Node.js 22 + React/Vite-Portal (Express-BFF)
#   - systemd-Units, Firewall-Regeln, Selbstverifikation
#
set -Eeuo pipefail

APP="ictfax"
APP_DIR="/opt/ictfax"
DATA_DIR="/var/lib/ictfax"
ETC_DIR="/etc/ictfax"
PORTAL_ETC="/etc/ictfax-portal"
PORTAL_USER="ictfax-portal"
PORTAL_PORT="${PORTAL_PORT:-8080}"
ICTFAX_PORT="${ICTFAX_PORT:-8081}"
REPO_URL="${REPO_URL:-https://github.com/HatchetMan111/ICTFax-Proxmox}"
REPO_REF="${REPO_REF:-main}"
ICTFAX_SRC="${ICTFAX_SRC:-}"
FAX_DOMAIN="${FAX_DOMAIN:-}"
SIP_EXT_IP="${SIP_EXT_IP:-}"
SMTP_ENABLED="${SMTP_ENABLED:-1}"
DEBUG="${DEBUG:-0}"

LOG_DIR="/var/log"
[[ -w "$LOG_DIR" ]] || LOG_DIR="/tmp"
LOG_FILE="${LOG_DIR}/${APP}-inner-$(date +%F-%H%M%S).log"
umask 077
exec > >(tee -i "$LOG_FILE") 2>&1

if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BLUE=$'\e[34m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
else
  C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi
msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
die()       { msg_error "$*"; exit 1; }
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

on_error() {
  local ec=$?
  trap - ERR
  set +e
  msg_error "════ GAST-INSTALLATION FEHLGESCHLAGEN ════"
  msg_error "Befehl : ${BASH_COMMAND}"
  msg_error "Zeile  : ${LINENO}"
  msg_error "Exit   : ${ec}"
  msg_error "Log    : ${LOG_FILE}"
  msg_error "--- docker compose ps ---"
  (cd "$APP_DIR/docker" 2>/dev/null && /usr/local/bin/ictfax-compose ps) 2>&1 || true
  msg_error "--- docker logs ictfax (letzte 80) ---"
  docker logs --tail 80 ictfax 2>&1 || true
  msg_error "--- journalctl ictfax-portal (letzte 80) ---"
  journalctl -u ictfax-portal --no-pager -n 80 2>&1 || true
  msg_error "--- journalctl ictfax (letzte 80) ---"
  journalctl -u ictfax --no-pager -n 80 2>&1 || true
  exit "$ec"
}
trap on_error ERR

[[ "$(id -u)" == "0" ]] || die "Gast-Installer muss als root laufen."
msg_info "Logdatei: ${LOG_FILE}"

# ---------------------------------------------------------------------------
# 1. DNS / apt robust machen (LXC hat oft kein systemd-resolved)
#    Bekannte Grube: apt läuft als Sandbox-Benutzer _apt – der bekommt die
#    Nameserver nicht aufgelöst, wenn /etc/resolv.conf nur 0644/root:104
#    Rechte hat. Darum: Resolver-Dateien 0644 setzen UND Sandbox hart
#    abschalten (root) – sonst scheitert apt trotz funktionierendem DNS.
# ---------------------------------------------------------------------------
fix_dns() {
  local resolved=1
  getent hosts deb.debian.org >/dev/null 2>&1 || resolved=0
  if [[ "$resolved" == "0" ]]; then
    msg_warn "DNS-Auflösung fehlgeschlagen – setze 1.1.1.1 / 9.9.9.9."
    # resolv.conf darf von keinem restriktiven umask(077)-Lauf 0600 erben.
    cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 9.9.9.9
EOF
    chmod 0644 /etc/resolv.conf
  fi
  # /etc/hosts + nsswitch für den _apt-Sandbox-Benutzer lesbar halten.
  chmod 0644 /etc/hosts /etc/nsswitch.conf 2>/dev/null || true
  # apt-Sandbox abschalten: _apt scheitert sonst an nicht auflösbaren
  # Nameservern, obwohl root längst kann (klassische Proxmox-LXC-Grube).
  if ! grep -q 'APT::Sandbox::User' /etc/apt/apt.conf.d/99ictfax 2>/dev/null; then
    printf 'APT::Sandbox::User "root";\n' >> /etc/apt/apt.conf.d/99ictfax
  fi
}

# Basis-apt-Config (ohne Sandbox – die setzt fix_dns nach).
cat > /etc/apt/apt.conf.d/99ictfax <<'EOF'
Acquire::ForceIPv4 "true";
Acquire::Retries "3";
Acquire::http::Timeout "30";
EOF
fix_dns

# Locale-Warnungen (perl/apt-listchanges) im Debian-12-Template stillen:
# das Gast-Image bringt kein en_US.UTF-8 mit.
export LC_ALL=C LANG=C LANGUAGE=
# wackeln – 3 Anläufe mit kurzer Pause fangen das zuverlässig ab).
apt_retry() {
  local n=1
  until apt-get "$@"; do
    if [[ $n -ge 3 ]]; then
      msg_error "apt $* nach 3 Versuchen fehlgeschlagen."
      return 1
    fi
    msg_warn "apt $* Versuch $n fehlgeschlagen – retry in 5s ..."
    n=$((n + 1))
    sleep 5
  done
}

export DEBIAN_FRONTEND=noninteractive
msg_info "Aktualisiere Paketlisten ..."
apt_retry update -qq

msg_info "Installiere Basispakete ..."
apt_retry install -y -qq --no-install-recommends \
  ca-certificates curl gnupg git jq openssl rsync xz-utils \
  iproute2 procps logrotate >/dev/null

# ---------------------------------------------------------------------------
# 2. Docker CE (offizielles Repo, Fallback auf Debian docker.io)
# ---------------------------------------------------------------------------
install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    msg_ok "Docker + Compose bereits vorhanden."
    return 0
  fi
  msg_info "Installiere Docker CE ..."
  install -m 0755 -d /etc/apt/keyrings
  if curl -fsSL --max-time 60 https://download.docker.com/linux/debian/gpg \
      -o /etc/apt/keyrings/docker.asc; then
    chmod a+r /etc/apt/keyrings/docker.asc
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt_retry update -qq || true
    if apt_retry install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1; then
      msg_ok "Docker CE installiert."
      return 0
    fi
    msg_warn "Docker-CE-Installation fehlgeschlagen – Fallback auf Debian-Pakete."
  else
    msg_warn "Docker-GPG-Key nicht ladbar – Fallback auf Debian-Pakete."
  fi
  apt_retry install -y -qq docker.io docker-compose >/dev/null
  msg_ok "Docker (Debian) installiert."
}
install_docker

# Docker-Daemon: Log-Rotation, bei LXC ggf. vfs als Storage-Treiber
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
systemctl enable --now docker >/dev/null 2>&1 || true
if ! systemctl is-active --quiet docker; then
  msg_warn "Docker startet nicht mit overlay2 – versuche vfs (LXC)."
  cat > /etc/docker/daemon.json <<'EOF'
{
  "storage-driver": "vfs",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  systemctl restart docker || die "Docker-Daemon startet nicht (siehe journalctl -u docker)."
fi
systemctl is-active --quiet docker || die "Docker ist nicht active."
msg_ok "Docker läuft."

# ---------------------------------------------------------------------------
# 3. Repo holen/aktualisieren
# ---------------------------------------------------------------------------
msg_info "Hole ICTFax-Proxmox nach ${APP_DIR} ..."
if [[ -n "$ICTFAX_SRC" && -d "$ICTFAX_SRC" ]]; then
  mkdir -p "$APP_DIR"
  rsync -a --delete \
    --exclude '.git' --exclude 'node_modules' --exclude 'portal/dist' \
    --exclude '.env' --exclude '*.log' \
    "$ICTFAX_SRC"/ "$APP_DIR"/
  msg_ok "Lokale Quelle synchronisiert: ${ICTFAX_SRC}"
elif [[ -d "$APP_DIR/.git" ]]; then
  git -C "$APP_DIR" fetch --all --prune --quiet
  git -C "$APP_DIR" reset --hard "origin/${REPO_REF}" --quiet
  msg_ok "Repo aktualisiert (${REPO_REF})."
else
  rm -rf "$APP_DIR"
  git clone --branch "$REPO_REF" --depth 1 "$REPO_URL" "$APP_DIR" --quiet
  msg_ok "Repo geklont (${REPO_REF})."
fi
[[ -f "$APP_DIR/docker/compose.yml" ]] || die "compose.yml fehlt in ${APP_DIR}/docker."
[[ -f "$APP_DIR/portal/package.json" ]] || die "portal/package.json fehlt."

# ---------------------------------------------------------------------------
# 4. Hostname für ICTCore bestimmen
# ---------------------------------------------------------------------------
ICTCORE_HOST="${ICTCORE_HOST:-$FAX_DOMAIN}"
if [[ -z "$ICTCORE_HOST" || "$ICTCORE_HOST" == "ictfax.local" ]]; then
  DETECTED_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -n "$DETECTED_IP" ]]; then
    ICTCORE_HOST="$DETECTED_IP"
    msg_info "ICTCORE_HOST nicht gesetzt – verwende Gast-IP ${ICTCORE_HOST}."
  else
    ICTCORE_HOST="ictfax.local"
  fi
fi

# ---------------------------------------------------------------------------
# 5. Secrets / Env-Dateien (idempotent, 0600)
# ---------------------------------------------------------------------------
mkdir -p "$ETC_DIR" "$PORTAL_ETC" "$DATA_DIR"
chmod 700 "$ETC_DIR" "$PORTAL_ETC"
chmod 755 "$DATA_DIR"

if [[ ! -f "$ETC_DIR/ictfax.env" ]]; then
  msg_info "Erzeuge ICTFax-Secrets ..."
  DB_PASS="$(openssl rand -hex 16)"
  DB_ROOT_PASS="$(openssl rand -hex 16)"
  FS_PASS="$(openssl rand -hex 16)"
  cat > "$ETC_DIR/ictfax.env" <<EOF
DB_HOST=db
DB_PORT=3306
DB_NAME=ictfax
DB_USER=ictfax
DB_PASS=${DB_PASS}
DB_ROOT_PASS=${DB_ROOT_PASS}
ICTCORE_HOST=${ICTCORE_HOST}
SIP_EXT_IP=${SIP_EXT_IP}
FS_ESL_PASSWORD=${FS_PASS}
SMTP_ENABLED=${SMTP_ENABLED}
EOF
  chmod 600 "$ETC_DIR/ictfax.env"
  msg_ok "Secrets erzeugt: ${ETC_DIR}/ictfax.env"
else
  msg_ok "Vorhandene Secrets bleiben erhalten: ${ETC_DIR}/ictfax.env"
  sed -i "s|^ICTCORE_HOST=.*|ICTCORE_HOST=${ICTCORE_HOST}|" "$ETC_DIR/ictfax.env"
  sed -i "s|^SIP_EXT_IP=.*|SIP_EXT_IP=${SIP_EXT_IP}|" "$ETC_DIR/ictfax.env"
  sed -i "s|^SMTP_ENABLED=.*|SMTP_ENABLED=${SMTP_ENABLED}|" "$ETC_DIR/ictfax.env"
fi
set -a
# shellcheck disable=SC1091
. "$ETC_DIR/ictfax.env"
set +a
SMTP_ENABLED="${SMTP_ENABLED:-1}"

if [[ ! -f "$PORTAL_ETC/config.env" ]]; then
  SESSION_SECRET="$(openssl rand -hex 32)"
  cat > "$PORTAL_ETC/config.env" <<EOF
NODE_ENV=production
PORT=${PORTAL_PORT}
ICTFAX_API_URL=http://127.0.0.1:${ICTFAX_PORT}/api
ICTFAX_PUBLIC_URL=http://${ICTCORE_HOST}:${ICTFAX_PORT}
SESSION_SECRET=${SESSION_SECRET}
COOKIE_SECURE=0
EOF
  chmod 600 "$PORTAL_ETC/config.env"
  msg_ok "Portal-Konfiguration erzeugt: ${PORTAL_ETC}/config.env"
else
  msg_ok "Vorhandene Portal-Konfiguration bleibt erhalten."
  sed -i "s|^ICTFAX_PUBLIC_URL=.*|ICTFAX_PUBLIC_URL=http://${ICTCORE_HOST}:${ICTFAX_PORT}|" "$PORTAL_ETC/config.env"
fi

# ---------------------------------------------------------------------------
# 6. Compose-Wrapper
# ---------------------------------------------------------------------------
cat > /usr/local/bin/ictfax-compose <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
ENV_FILE=/etc/ictfax/ictfax.env
[[ -r "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
cd /opt/ictfax/docker
if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  echo "docker compose not available" >&2
  exit 1
fi
# mode=default|up|pull|ps|logs|down|restart|<compose args>
MODE="${1:-up}"; shift || true
# SMTP-Override nur, wenn der Gast-Port 25 frei ist (Debian-Standard-MTA
# wie exim belegt ihn sonst → "failed to bind host port 0.0.0.0:25").
if [[ "${SMTP_ENABLED:-1}" == "1" ]] \
   && ! (ss -ltn 2>/dev/null | grep -q ':25 ' || true); then
  FILES=(-f compose.yml -f compose.smtp.yml)
else
  FILES=(-f compose.yml)
  [[ "${SMTP_ENABLED:-1}" == "1" ]] && echo "WARN: Port 25 im Gast belegt – E-Mail→Fax (25/tcp) deaktiviert; MTA zuerst anpassen."
fi
case "$MODE" in
  up)
    # --wait: blockiert bis alle Container healthy/running sind. Das ist der
    # Unterschied zwischen "compose up" (forked, sofort weg) und einem
    # systemd-Dienst, der Vordergrund-Prozesse festhält (Live-Grube #3).
    exec "${COMPOSE[@]}" "${FILES[@]}" up -d --remove-orphans --wait --wait-timeout 300
    ;;
  pull)
    exec "${COMPOSE[@]}" "${FILES[@]}" pull --quiet
    ;;
  ps)
    exec "${COMPOSE[@]}" "${FILES[@]}" ps
    ;;
  logs)
    exec "${COMPOSE[@]}" "${FILES[@]}" logs --tail "${1:-100}" "${2:-}"
    ;;
  down)
    exec "${COMPOSE[@]}" "${FILES[@]}" down --remove-orphans
    ;;
  restart)
    exec "${COMPOSE[@]}" "${FILES[@]}" restart
    ;;
  *)
    # alles andere 1:1 an compose durchreichen (z. B. "ictfax-compose exec db bash")
    exec "${COMPOSE[@]}" "${FILES[@]}" "$MODE" "$@"
    ;;
esac
WRAPPER
chmod 0755 /usr/local/bin/ictfax-compose
msg_ok "Compose-Wrapper: /usr/local/bin/ictfax-compose"

# ---------------------------------------------------------------------------
# 6b. SMTP-Port-25 vorab prüfen (compose.smtp.yml scheitert sonst hart)
# ---------------------------------------------------------------------------
if [[ "$SMTP_ENABLED" == "1" ]] && ss -ltn 2>/dev/null | grep -q ':25 '; then
  msg_warn "Port 25/tcp im Gast bereits belegt (MTA?) – E-Mail→Fax wird deaktiviert."
  msg_warn "Für E-Mail→Fax: MTA im Gast stoppen/entfernen und Re-Run mit SMTP_ENABLED=1."
  SMTP_ENABLED=0
  # Für den Wrapper sichtbar machen (ictfax.env wird vorab überschrieben,
  # damit der --wait-Start das Override nicht lädt).
  sed -i "s|^SMTP_ENABLED=.*|SMTP_ENABLED=0|" "$ETC_DIR/ictfax.env"
fi

# ---------------------------------------------------------------------------
# 7. ICTFax starten und auf API warten
# ---------------------------------------------------------------------------
msg_info "Starte ICTFax-Stack (Docker) ..."
/usr/local/bin/ictfax-compose pull || msg_warn "Image-Pull fehlgeschlagen – nutze lokale Images."
/usr/local/bin/ictfax-compose up

msg_info "Warte auf ICTFax-API (Image-Init + DB-Schema, bis 12 Min) ..."
API_OK=0
for _ in $(seq 1 72); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${ICTFAX_PORT}/api/statistics" || true)"
  if [[ "$CODE" == "200" || "$CODE" == "401" ]]; then
    API_OK=1; break
  fi
  sleep 10
done
if [[ "$API_OK" != "1" ]]; then
  msg_error "ICTFax-API antwortet nicht. Letzte Container-Logs:"
  docker logs --tail 120 ictfax 2>&1 || true
  die "ICTFax-API-Start fehlgeschlagen."
fi
msg_ok "ICTFax-API erreichbar (HTTP ${CODE})."

# ---------------------------------------------------------------------------
# 8. Node.js 22
# ---------------------------------------------------------------------------
install_node() {
  local major="0"
  if command -v node >/dev/null 2>&1; then
    major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  fi
  if [[ "$major" -ge 20 ]]; then
    msg_ok "Node.js $(node -v) vorhanden."
    return 0
  fi
  msg_info "Installiere Node.js 22 ..."
  if curl -fsSL --max-time 60 https://deb.nodesource.com/setup_22.x -o /tmp/nodesource.sh; then
    if bash /tmp/nodesource.sh >/dev/null 2>&1 && apt_retry install -y -qq nodejs >/dev/null 2>&1; then
      msg_ok "Node.js $(node -v) installiert."
      return 0
    fi
    msg_warn "NodeSource fehlgeschlagen – Fallback auf Debian nodejs/npm."
  fi
  apt_retry install -y -qq nodejs npm >/dev/null
  major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  [[ "$major" -ge 18 ]] || die "Node.js >= 18 erforderlich (gefunden: $(node -v 2>/dev/null || echo none))."
  msg_ok "Node.js $(node -v) (Debian) installiert."
}
install_node

# ---------------------------------------------------------------------------
# 9. Portal bauen
# ---------------------------------------------------------------------------
msg_info "Baue React/Vite-Portal ..."
cd "$APP_DIR/portal"
if [[ -f package-lock.json ]]; then
  npm ci --no-audit --no-fund >/dev/null 2>&1 || npm install --no-audit --no-fund
else
  npm install --no-audit --no-fund
fi
npm run build >/dev/null
[[ -f dist/index.html ]] || die "Portal-Build fehlgeschlagen (dist/index.html fehlt)."
msg_ok "Portal gebaut: ${APP_DIR}/portal/dist"

# ---------------------------------------------------------------------------
# 10. Portal-Benutzer + systemd
# ---------------------------------------------------------------------------
if ! getent group "$PORTAL_USER" >/dev/null 2>&1; then
  groupadd --system "$PORTAL_USER"
fi
if ! id "$PORTAL_USER" >/dev/null 2>&1; then
  useradd --system --gid "$PORTAL_USER" --home-dir "${DATA_DIR}/portal" --shell /usr/sbin/nologin "$PORTAL_USER"
fi
mkdir -p "${DATA_DIR}/portal"
chown -R "${PORTAL_USER}:${PORTAL_USER}" "${DATA_DIR}/portal"
chmod 755 "$APP_DIR"
chown -R root:"$PORTAL_USER" "$APP_DIR/portal"
# Verzeichnisse 0755, Dateien 0644, symlinks bleiben – portal läuft als
# User portal (systemd), braucht also o+rX; die Wurzel portal/ bekommt
# u=rwX,g=rX,o=rX **rekursiv** – das macht sie 0755 (X hebt für Verz. auf
# 0755, für Dateien bleibt 0644). Wichtig: Die Wurzel darf NICHT auf 0555
# gesetzt werden (Live-Grube: /opt/ictfax/portal war danach nicht mehr
# traversierbar → node starb an /etc/ssl/openssl.cnf Permission denied).
chmod -R u=rwX,g=rX,o=rX "$APP_DIR/portal"
# /opt/ictfax selbst muss für portal traversierbar sein (x):
chmod 0755 "$APP_DIR"
# dist + server-Verzeichnisse explizit 0755, Dateien 0644 (falls die
# npm-Installation restriktivere Rechte vererbt hat).
chmod 0755 "$APP_DIR/portal" "$APP_DIR/portal/dist" "$APP_DIR/portal/server" 2>/dev/null || true

for unit in ictfax.service ictfax-portal.service; do
  if [[ -f "$APP_DIR/systemd/$unit" ]]; then
    install -m 0644 "$APP_DIR/systemd/$unit" "/etc/systemd/system/$unit"
  else
    die "systemd-Unit fehlt: ${APP_DIR}/systemd/$unit"
  fi
done

systemctl daemon-reload
systemctl enable ictfax.service ictfax-portal.service >/dev/null 2>&1 || true
# Reihenfolge: portal NACH ictfax (After=ictfax.service in der Unit). Der
# Restart von ictfax am Ende würde den gerade gestarteten Stack wieder
# runterfahren – darum nur einmal starten, nicht zweimal.
systemctl restart ictfax.service
sleep 5
systemctl restart ictfax-portal.service
msg_ok "systemd-Units installiert und gestartet."

# ---------------------------------------------------------------------------
# 11. Firewall (nur wenn aktiv – niemals bestehende Regeln löschen)
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  msg_info "Öffne Ports in ufw ..."
  ufw allow "${PORTAL_PORT}/tcp" >/dev/null 2>&1 || true
  ufw allow "${ICTFAX_PORT}/tcp" >/dev/null 2>&1 || true
  ufw allow 5060/tcp >/dev/null 2>&1 || true
  ufw allow 5060/udp >/dev/null 2>&1 || true
  ufw allow 16384:16484/udp >/dev/null 2>&1 || true
  [[ "$SMTP_ENABLED" == "1" ]] && ufw allow 25/tcp >/dev/null 2>&1 || true
  msg_ok "ufw-Regeln gesetzt."
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  msg_info "Öffne Ports in firewalld ..."
  firewall-cmd --permanent --add-port="${PORTAL_PORT}/tcp" >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port="${ICTFAX_PORT}/tcp" >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port=5060/tcp >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port=5060/udp >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port=16384-16484/udp >/dev/null 2>&1 || true
  [[ "$SMTP_ENABLED" == "1" ]] && firewall-cmd --permanent --add-port=25/tcp >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
  msg_ok "firewalld-Regeln gesetzt."
else
  msg_info "Keine aktive ufw/firewalld-Instanz – keine lokalen Regeln nötig."
fi

# ---------------------------------------------------------------------------
# 12. Verifikation
# ---------------------------------------------------------------------------
msg_info "Verifiziere Dienste ..."
for _ in $(seq 1 36); do
  if systemctl is-active --quiet ictfax && systemctl is-active --quiet ictfax-portal; then
    break
  fi
  sleep 5
done
systemctl is-active --quiet ictfax || { systemctl status ictfax --no-pager || true; die "ictfax.service ist nicht active."; }
systemctl is-active --quiet ictfax-portal || { systemctl status ictfax-portal --no-pager || true; die "ictfax-portal.service ist nicht active."; }
msg_ok "Services active: ictfax, ictfax-portal."

PORTAL_OK=0
for _ in $(seq 1 36); do
  if curl -fsS --max-time 10 "http://127.0.0.1:${PORTAL_PORT}/api/health" >/dev/null 2>&1; then
    PORTAL_OK=1; break
  fi
  sleep 5
done
[[ "$PORTAL_OK" == "1" ]] || { journalctl -u ictfax-portal --no-pager -n 80 || true; die "Portal-Healthcheck fehlgeschlagen."; }
msg_ok "Portal-Healthcheck OK (:${PORTAL_PORT}/api/health)."

curl -fsS --max-time 10 -o /dev/null "http://127.0.0.1:${PORTAL_PORT}/" || die "Portal-Startseite antwortet nicht."
msg_ok "Portal-Startseite OK."
curl -fsS --max-time 10 -o /dev/null "http://127.0.0.1:${ICTFAX_PORT}/" || die "Native ICTFax-UI antwortet nicht."
msg_ok "Native ICTFax-UI OK (:${ICTFAX_PORT})."

touch "${DATA_DIR}/install-complete"
msg_ok "Installationsmarker: ${DATA_DIR}/install-complete"

echo ""
echo "════════════════ GAST-INSTALLATION FERTIG ════════════════"
echo "  Portal        : http://${ICTCORE_HOST}:${PORTAL_PORT}"
echo "  ICTFax-UI     : http://${ICTCORE_HOST}:${ICTFAX_PORT}"
echo "  Health        : http://${ICTCORE_HOST}:${PORTAL_PORT}/api/health"
echo "  SIP           : 5060/tcp + 5060/udp"
echo "  RTP           : 16384-16484/udp"
[[ "$SMTP_ENABLED" == "1" ]] && echo "  E-Mail→Fax    : Port 25/tcp (MX auf ${ICTCORE_HOST} zeigen lassen)"
echo "  Login         : admin / helloAdmin  ← sofort ändern"
echo "  Log           : ${LOG_FILE}"
echo "══════════════════════════════════════════════════════════"
