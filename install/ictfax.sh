#!/usr/bin/env bash
#
# ICTFax-Proxmox – Proxmox VE Einzeiler-Installer (Community-Scripts-Stil)
#
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/ICTFax-Proxmox/main/install/ictfax.sh)"
#
# Läuft AUF DEM PROXMOX-HOST (root). Erstellt einen LXC (Default) oder eine VM
# (--type vm), installiert ICTFax (Docker) + das React/Vite-Portal und
# verifiziert Service + Web-UI.
#
# WICHTIG: Das Skript muss auch per `bash -c "$(wget -qLO - ...)"` laufen,
# bei dem BASH_SOURCE[0] undefiniert ist. Alles vor `set -u` (z. B. das
# TEE-Logging) würde sonst mit "unbound variable" sterben.
set -Eeuo pipefail

APP="ictfax"
APP_DISPLAY="ICTFax"
GUEST_NAME="ictfax"
PORTAL_PORT="8080"
ICTFAX_PORT="8081"
REPO_URL="https://github.com/HatchetMan111/ICTFax-Proxmox"
REPO_REF="main"

DEFAULT_CORES="2"
DEFAULT_RAM="4096"
DEFAULT_SWAP="1024"
DEFAULT_DISK="16"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"
DEFAULT_OS="debian-12-standard"
FEATURES="nesting=1,keyctl=1"

VM_CORES="2"
VM_RAM="4096"
VM_DISK="20"
VM_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
SNIPPET_STORAGE="local"

RAW_BASE="${REPO_URL/github.com/raw.githubusercontent.com}"
INNER_URL="${RAW_BASE}/${REPO_REF}/install/${APP}-inner.sh"

CT_ID="${CT_ID:-${CTID:-}}"
CORES="${CORES:-}"
RAM="${RAM:-}"
DISK="${DISK:-}"
TYPE="${TYPE:-lxc}"
HOSTNAME_ARG="${HOSTNAME_ARG:-$GUEST_NAME}"
STORAGE_ARG=""
TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE"
BRIDGE="$DEFAULT_BRIDGE"
PASSWORD_ARG=""
SSH_KEY_ARG=""
FAX_DOMAIN="${FAX_DOMAIN:-}"
SIP_EXT_IP="${SIP_EXT_IP:-}"
SMTP_ENABLED="${SMTP_ENABLED:-1}"
DEBUG="${DEBUG:-0}"
DRY_RUN="${DRY_RUN:-0}"
REBOOT_TEST="${REBOOT_TEST:-0}"
EXISTING=0
CREATED=0
CT_IP=""

if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_BLUE=$'\e[34m'; C_GREEN=$'\e[32m'
  C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_CYAN=$'\e[36m'
else
  C_RESET=""; C_BOLD=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""
fi
msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
die()       { msg_error "$*"; msg_error "Abbruch in Zeile ${LINENO}: ${BASH_COMMAND}"; exit 1; }

LOG_DIR="/var/log"
[[ -w "$LOG_DIR" ]] || LOG_DIR="/tmp"
LOG_FILE="${LOG_DIR}/${APP}-install-$(date +%F-%H%M%S).log"
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: ${LOG_FILE}"
umask 077
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

on_error() {
  local ec=$?
  trap - ERR
  set +e
  msg_error "════ INSTALLER FEHLGESCHLAGEN ════"
  msg_error "Befehl : ${BASH_COMMAND}"
  msg_error "Zeile  : ${LINENO}"
  msg_error "Exit   : ${ec}"
  msg_error "Log-Auszug (letzte 100 Zeilen von ${LOG_FILE}):"
  tail -n 100 "$LOG_FILE" >&2 2>/dev/null || true
  if [[ -n "${CT_ID:-}" ]]; then
    if [[ "${TYPE:-lxc}" == "lxc" ]] && command -v pct >/dev/null 2>&1; then
      msg_error "Container-Status:"
      pct status "$CT_ID" 2>&1 || true
      msg_error "systemd-Status (ictfax, ictfax-portal):"
      pct exec "$CT_ID" -- systemctl status ictfax ictfax-portal --no-pager 2>&1 || true
      msg_error "journalctl (letzte 120 Zeilen):"
      pct exec "$CT_ID" -- journalctl -u ictfax -u ictfax-portal --no-pager -n 120 2>&1 || true
      msg_error "docker compose ps:"
      pct exec "$CT_ID" -- bash -lc 'cd /opt/ictfax/docker && (docker compose ps || docker-compose ps) 2>&1' || true
    elif command -v qm >/dev/null 2>&1; then
      msg_error "VM-Status:"
      qm status "$CT_ID" 2>&1 || true
      msg_error "Guest-Status (letzte 120 Zeilen):"
      qm guest exec "$CT_ID" -- bash -lc 'systemctl status ictfax ictfax-portal --no-pager; journalctl -u ictfax -u ictfax-portal --no-pager -n 120' 2>&1 || true
    fi
  fi
  msg_error "Vollständiges Log: ${LOG_FILE}"
  msg_error "Erneut mit --debug laufen lassen für bash -x (komplette Kette)."
  exit "$ec"
}
trap on_error ERR

usage() {
  cat <<EOF
${APP_DISPLAY} Proxmox Installer (Community-Scripts-Stil)

Usage:
  bash -c "\$(wget -qLO - ${RAW_BASE}/${REPO_REF}/install/${APP}.sh)"
  bash ${APP}.sh [OPTIONEN]

Optionen:
  --ctid ID            ID (Default: nächste freie ID via pvesh /cluster/nextid)
  --hostname NAME      Hostname/VM-Name (Default: ${GUEST_NAME})
  --type lxc|vm        LXC (Default) oder VM (cloud-init)
  --cores N            vCPU (Default LXC ${DEFAULT_CORES} / VM ${VM_CORES})
  --memory MB          RAM (Default LXC ${DEFAULT_RAM} / VM ${VM_RAM})
  --disk GB            Disk (Default LXC ${DEFAULT_DISK} / VM ${VM_DISK})
  --storage NAME       RootFS-/Image-Storage (Default: auto, local-lvm bevorzugt)
  --template-store N   Template-/Snippet-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufällig, Datei unter /root/)
  --ssh-key PATH       SSH-Public-Key für root
  --fax-domain NAME    ICTCORE_HOST / E-Mail→Fax-Domain (Default: Gast-IP)
  --sip-ext-ip IP      Öffentliche IP für SIP/RTP (NAT/Cloud, optional)
  --no-smtp            Port 25 (E-Mail→Fax) nicht veröffentlichen
  --dry-run            Nur Plan ausgeben, nichts verändern
  --reboot-test        Bestehenden Gast rebooten und Web-UI verifizieren
  --debug              bash -x + vollständige Fehlerkette
  -h, --help           diese Hilfe

Umgebung: CT_ID, TYPE, CORES, RAM, DISK, FAX_DOMAIN, SIP_EXT_IP, SMTP_ENABLED, DEBUG
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2;;
    --hostname) HOSTNAME_ARG="$2"; shift 2;;
    --type) TYPE="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --template-store) TEMPLATE_STORE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --password) PASSWORD_ARG="$2"; shift 2;;
    --ssh-key) SSH_KEY_ARG="$2"; shift 2;;
    --fax-domain) FAX_DOMAIN="$2"; shift 2;;
    --sip-ext-ip) SIP_EXT_IP="$2"; shift 2;;
    --no-smtp) SMTP_ENABLED="0"; shift;;
    --dry-run) DRY_RUN="1"; shift;;
    --reboot-test) REBOOT_TEST="1"; shift;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

[[ "$TYPE" == "lxc" || "$TYPE" == "vm" ]] || die "--type muss lxc oder vm sein (war: $TYPE)."
[[ "$(id -u)" == "0" ]] || die "Bitte als root auf dem Proxmox-Host ausführen."
for tool in pvesh pvesm pveam; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool nicht gefunden – kein Proxmox-Host?"
done
if [[ "$TYPE" == "lxc" ]]; then
  command -v pct >/dev/null 2>&1 || die "pct nicht gefunden."
else
  command -v qm >/dev/null 2>&1 || die "qm nicht gefunden (VM-Modus)."
fi

# Werte validieren (verhindern kaputte Cloud-Init-/Env-Strings)
[[ "$FAX_DOMAIN" =~ ^[A-Za-z0-9.-]*$ ]] || die "--fax-domain enthält ungültige Zeichen: $FAX_DOMAIN"
[[ -z "$SIP_EXT_IP" || "$SIP_EXT_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "--sip-ext-ip muss eine IPv4-Adresse sein."
[[ "$SMTP_ENABLED" == "0" || "$SMTP_ENABLED" == "1" ]] || die "SMTP_ENABLED muss 0 oder 1 sein."

if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid | tr -d '[:space:]')"
  msg_info "Nächste freie ID: ${CT_ID}"
fi
[[ "$CT_ID" =~ ^[0-9]+$ ]] || die "Ungültige ID: ${CT_ID}"

if pct config "$CT_ID" >/dev/null 2>&1; then
  EXISTING=1
  if [[ "$TYPE" != "lxc" ]]; then msg_warn "ID ${CT_ID} ist ein LXC – erzwinge TYPE=lxc."; TYPE="lxc"; fi
elif qm config "$CT_ID" >/dev/null 2>&1; then
  EXISTING=1
  if [[ "$TYPE" != "vm" ]]; then msg_warn "ID ${CT_ID} ist eine VM – erzwinge TYPE=vm."; TYPE="vm"; fi
fi

if [[ "$TYPE" == "vm" ]]; then
  CORES="${CORES:-$VM_CORES}"
  RAM="${RAM:-$VM_RAM}"
  DISK="${DISK:-$VM_DISK}"
else
  CORES="${CORES:-$DEFAULT_CORES}"
  RAM="${RAM:-$DEFAULT_RAM}"
  DISK="${DISK:-$DEFAULT_DISK}"
fi

[[ "$CORES" =~ ^[1-9][0-9]*$ ]] || die "--cores muss eine positive Ganzzahl sein."
[[ "$RAM" =~ ^[1-9][0-9]*$ ]] || die "--memory muss eine positive Ganzzahl (MB) sein."
[[ "$DISK" =~ ^[1-9][0-9]*$ ]] || die "--disk muss eine positive Ganzzahl (GB) sein."
[[ "$HOSTNAME_ARG" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die "Ungültiger Hostname: ${HOSTNAME_ARG}"

if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status --storage local-lvm >/dev/null 2>&1; then
    STORAGE_ARG="local-lvm"
  elif [[ "$TYPE" == "vm" ]]; then
    STORAGE_ARG="$(pvesm status -content images 2>/dev/null | awk 'NR==2 {print $1}' || true)"
  else
    STORAGE_ARG="$(pvesm status -content rootdir 2>/dev/null | awk 'NR==2 {print $1}' || true)"
  fi
fi
[[ -n "$STORAGE_ARG" ]] || die "Kein passender Storage gefunden (pvesm status)."
msg_info "Storage: ${STORAGE_ARG} | Template/Snippet: ${TEMPLATE_STORE} | Bridge: ${BRIDGE}"

if [[ "$DRY_RUN" == "1" ]]; then
  cat <<EOF

DRY-RUN – es wird nichts verändert:
  Typ          : ${TYPE^^}
  ID           : ${CT_ID} $([[ "$EXISTING" == "1" ]] && echo "(existiert bereits – Update-Modus)" || echo "(neu)")
  Hostname     : ${HOSTNAME_ARG}
  Ressourcen   : ${CORES} vCPU / ${RAM} MB RAM / ${DISK} GB Disk
  Storage      : ${STORAGE_ARG}
  Bridge       : ${BRIDGE}
  Portal       : 0.0.0.0:${PORTAL_PORT}
  ICTFax UI    : 0.0.0.0:${ICTFAX_PORT}
  SIP          : 5060/tcp + 5060/udp
  RTP          : 16384-16484/udp
  SMTP         : $([[ "$SMTP_ENABLED" == "1" ]] && echo "25/tcp (E-Mail→Fax)" || echo "deaktiviert")
  Fax-Domain   : ${FAX_DOMAIN:-auto (Gast-IP)}
  SIP-EXT-IP   : ${SIP_EXT_IP:-<nicht gesetzt>}
  Inner-Script : ${INNER_URL}
  Repo         : ${REPO_URL} @ ${REPO_REF}
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
# Reboot-Test: bestehenden Gast neu starten und Web-UI prüfen
# ---------------------------------------------------------------------------
guest_exec() {
  if [[ "$TYPE" == "lxc" ]]; then
    pct exec "$CT_ID" -- bash -lc "$1"
  else
    qm guest exec "$CT_ID" --synchronous -- bash -lc "$1"
  fi
}

guest_ok() {
  if [[ "$TYPE" == "lxc" ]]; then
    pct exec "$CT_ID" -- bash -lc "$1" >/dev/null 2>&1
  else
    local out
    out="$(qm guest exec "$CT_ID" --synchronous -- bash -lc "$1" 2>/dev/null || true)"
    printf '%s' "$out" | grep -q '"exitcode"[[:space:]]*:[[:space:]]*0'
  fi
}

wait_for_ip() {
  for _ in $(seq 1 60); do
    sleep 5
    if [[ "$TYPE" == "lxc" ]]; then
      CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
    else
      CT_IP="$(qm guest cmd "$CT_ID" network-get-interfaces 2>/dev/null \
        | grep -oP '"ip-address"\s*:\s*"\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
        | grep -v '^127\.' | head -n1 || true)"
    fi
    [[ -n "$CT_IP" ]] && return 0
  done
  return 1
}

verify_install() {
  msg_info "Verifiziere Installation ..."
  local ok=0
  for _ in $(seq 1 36); do
    if guest_ok 'systemctl is-active ictfax >/dev/null && systemctl is-active ictfax-portal >/dev/null'; then
      ok=1; break
    fi
    sleep 10
  done
  [[ "$ok" == "1" ]] || {
    msg_error "systemd-Services sind nicht beide active."
    guest_exec 'systemctl status ictfax ictfax-portal --no-pager' || true
    guest_exec 'journalctl -u ictfax -u ictfax-portal --no-pager -n 120' || true
    return 1
  }
  msg_ok "Services laufen (ictfax + ictfax-portal = active)."

  ok=0
  for _ in $(seq 1 36); do
    if guest_ok "curl -fsS -m 15 http://localhost:${PORTAL_PORT}/api/health >/dev/null"; then
      ok=1; break
    fi
    sleep 10
  done
  [[ "$ok" == "1" ]] || {
    msg_error "Portal-Health antwortet nicht auf localhost:${PORTAL_PORT}/api/health."
    guest_exec "curl -v -m 15 http://localhost:${PORTAL_PORT}/api/health" || true
    guest_exec 'journalctl -u ictfax-portal --no-pager -n 120' || true
    return 1
  }
  msg_ok "Portal antwortet (HTTP 200 auf :${PORTAL_PORT}/api/health)."

  ok=0
  for _ in $(seq 1 18); do
    if guest_ok "curl -fsS -m 15 -o /dev/null http://localhost:${PORTAL_PORT}/"; then
      ok=1; break
    fi
    sleep 5
  done
  [[ "$ok" == "1" ]] || { msg_error "Portal-Startseite antwortet nicht auf :${PORTAL_PORT}/."; return 1; }
  msg_ok "Portal-Startseite antwortet (HTTP 200 auf :${PORTAL_PORT}/)."

  ok=0
  for _ in $(seq 1 18); do
    if guest_ok "curl -fsS -m 15 -o /dev/null http://localhost:${ICTFAX_PORT}/"; then
      ok=1; break
    fi
    sleep 5
  done
  [[ "$ok" == "1" ]] || { msg_error "Native ICTFax-UI antwortet nicht auf :${ICTFAX_PORT}/."; return 1; }
  msg_ok "Native ICTFax-UI antwortet (HTTP 200 auf :${ICTFAX_PORT}/)."
}

print_summary() {
  local admin_user="admin"
  local admin_pass="helloAdmin"
  echo ""
  echo "${C_BOLD}════════════════ INSTALLATION ERFOLGREICH ════════════════${C_RESET}"
  echo "  App          : ${APP_DISPLAY} – Faxserver + React/Vite-Portal"
  echo "  Upstream     : https://github.com/ictinnovations/ictfax"
  echo "  Repo         : ${REPO_URL}"
  echo "  Typ          : ${TYPE^^} (ID ${CT_ID}, Name ${HOSTNAME_ARG}, onboot=1)"
  echo "  Ressourcen   : ${CORES} vCPU / ${RAM} MB RAM / ${DISK} GB Disk"
  echo "  Portal       : http://${CT_IP}:${PORTAL_PORT}   ← React-Portal (Fax senden)"
  echo "  Admin-UI     : http://${CT_IP}:${ICTFAX_PORT}   (SIP-Trunk, DID, E-Mail)"
  echo "  Health       : http://${CT_IP}:${PORTAL_PORT}/api/health"
  echo "  SIP          : 5060/tcp + 5060/udp"
  echo "  RTP          : 16384-16484/udp"
  if [[ "$SMTP_ENABLED" == "1" ]]; then
    echo "  E-Mail→Fax   : Port 25/tcp (MX auf ${FAX_DOMAIN:-$CT_IP} zeigen lassen)"
  fi
  echo "  Login        : ${admin_user} / ${admin_pass}  ← sofort ändern!"
  if [[ "$CREATED" == "1" && "$TYPE" == "lxc" && -n "$PASSWORD_ARG" ]]; then
    PASS_STORE="/root"; [[ -w "$PASS_STORE" ]] || PASS_STORE="${HOME:-$LOG_DIR}"
    PASS_FILE="${PASS_STORE}/${APP}-root-password"
    if (umask 077; printf '%s\n' "$PASSWORD_ARG" > "$PASS_FILE") 2>/dev/null; then
      echo "  Root-Passwort: ${PASS_FILE} (nur root lesbar)"
    fi
  fi
  echo "  Update       : Skript erneut laufen lassen (idempotent)"
  echo "  Reboot-Test  : bash ${APP}.sh --reboot-test --ctid ${CT_ID} --type ${TYPE}"
  if [[ "$TYPE" == "lxc" ]]; then
    echo "  Deinstall    : pct stop ${CT_ID} && pct destroy ${CT_ID}"
  else
    echo "  Deinstall    : qm stop ${CT_ID} && qm destroy ${CT_ID}"
  fi
  echo "  Log          : ${LOG_FILE}"
  echo "${C_CYAN}══════════════════════════════════════════════════════════${C_RESET}"
}

if [[ "$REBOOT_TEST" == "1" ]]; then
  [[ "$EXISTING" == "1" ]] || die "Reboot-Test: ID ${CT_ID} existiert nicht."
  msg_info "Reboote ${TYPE^^} ${CT_ID} ..."
  if [[ "$TYPE" == "lxc" ]]; then pct reboot "$CT_ID"; else qm reboot "$CT_ID"; fi
  wait_for_ip || die "Keine IP nach Reboot."
  msg_ok "Adresse nach Reboot: ${CT_IP}"
  verify_install || die "Verifikation nach Reboot fehlgeschlagen."
  print_summary
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Template / Cloud-Image
# ---------------------------------------------------------------------------
TEMPLATE=""
if [[ "$TYPE" == "lxc" && "$EXISTING" == "0" ]]; then
  msg_info "Prüfe LXC-Template ..."
  pveam update >/dev/null 2>&1 || msg_warn "pveam update fehlgeschlagen – nutze vorhandene Templates."
  AVAILABLE="$(pveam available --section system 2>/dev/null || true)"
  TEMPLATE="$(printf '%s\n' "$AVAILABLE" | grep -oP "${DEFAULT_OS}[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
  if [[ -z "$TEMPLATE" ]]; then
    TEMPLATE="$(printf '%s\n' "$AVAILABLE" | grep -oP "debian-[0-9]+-standard[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
  fi
  [[ -n "$TEMPLATE" ]] || {
    msg_error "Kein Debian-Standard-Template gefunden. Verfügbare Templates:"
    printf '%s\n' "$AVAILABLE" | head -n 20 >&2 || true
    die "Bitte 'pveam update' und Netz/DNS auf dem Host prüfen."
  }
  if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; then
    msg_info "Lade Template ${TEMPLATE} ..."
    pveam download "$TEMPLATE_STORE" "$TEMPLATE"
  fi
  msg_ok "Template bereit: ${TEMPLATE_STORE}:vztmpl/${TEMPLATE}"
fi

# ---------------------------------------------------------------------------
# 2. Gast erstellen (idempotent)
# ---------------------------------------------------------------------------
if [[ "$EXISTING" == "0" ]]; then
  if [[ "$TYPE" == "lxc" ]]; then
    if [[ -z "$PASSWORD_ARG" ]]; then
      HAD_X=0; [[ "$-" == *x* ]] && HAD_X=1
      set +x
      PASSWORD_ARG="$(openssl rand -hex 12)"
      [[ "$HAD_X" == "1" ]] && set -x
    fi
    msg_info "Erstelle LXC ${CT_ID} (${HOSTNAME_ARG}): ${CORES} vCPU / ${RAM} MB / ${DISK} GB ..."
    pct create "$CT_ID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
      --hostname "$HOSTNAME_ARG" \
      --cores "$CORES" --memory "$RAM" --swap "$DEFAULT_SWAP" \
      --rootfs "${STORAGE_ARG}:${DISK}" \
      --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
      --unprivileged 1 --features "$FEATURES" \
      --onboot 1 --start 0 --password "$PASSWORD_ARG"
    CREATED=1
    msg_ok "LXC erstellt (unprivilegiert, ${FEATURES}, onboot=1)."
  else
    IMAGE_PATH="/var/lib/vz/images/${APP}-debian-12.qcow2"
    mkdir -p "$(dirname "$IMAGE_PATH")"
    if [[ ! -f "$IMAGE_PATH" ]]; then
      msg_info "Lade Debian-12-Cloud-Image ..."
      curl -fsSL --max-time 900 -o "${IMAGE_PATH}.tmp" "$VM_IMAGE_URL" \
        || die "Cloud-Image nicht ladbar: ${VM_IMAGE_URL}"
      mv "${IMAGE_PATH}.tmp" "$IMAGE_PATH"
    fi
    msg_info "Erstelle VM ${CT_ID} (${HOSTNAME_ARG}): ${CORES} vCPU / ${RAM} MB / ${DISK} GB ..."
    qm create "$CT_ID" --name "$HOSTNAME_ARG" --cores "$CORES" --memory "$RAM" \
      --net0 "virtio,bridge=${BRIDGE}" --onboot 1 --agent enabled=1 --ostype l26
    IMPORT_OUT="$(qm importdisk "$CT_ID" "$IMAGE_PATH" "$STORAGE_ARG")"
    DISK_VOL="$(printf '%s\n' "$IMPORT_OUT" | sed -n "s/.*unused0:\([^']*\)'.*/\1/p" | tr -d '[:space:]')"
    [[ -n "$DISK_VOL" ]] || DISK_VOL="${STORAGE_ARG}:vm-${CT_ID}-disk-0"
    qm set "$CT_ID" --scsihw virtio-scsi-pci --scsi0 "$DISK_VOL"
    qm resize "$CT_ID" scsi0 "${DISK}G"
    qm set "$CT_ID" --ide2 "${STORAGE_ARG}:cloudinit"
    qm set "$CT_ID" --boot c --bootdisk scsi0
    qm set "$CT_ID" --serial0 socket --vga serial0
    qm set "$CT_ID" --ipconfig0 ip=dhcp
    if [[ -n "$SSH_KEY_ARG" ]]; then
      [[ -f "$SSH_KEY_ARG" ]] || die "SSH-Key nicht gefunden: ${SSH_KEY_ARG}"
      qm set "$CT_ID" --sshkeys "$SSH_KEY_ARG"
    fi
    SNIPPET_SUPPORT="$(pvesm status -content snippets 2>/dev/null | awk 'NR>1 {print $1}' || true)"
    if ! grep -qx "$SNIPPET_STORAGE" <<< "$SNIPPET_SUPPORT"; then
      die "Storage '${SNIPPET_STORAGE}' unterstützt keine Snippets. Aktivieren: Datacenter > Storage > ${SNIPPET_STORAGE} > Snippets."
    fi
    SNIPPET_DIR="/var/lib/vz/snippets"
    mkdir -p "$SNIPPET_DIR"
    SNIPPET_FILE="${SNIPPET_DIR}/${APP}-${CT_ID}.yml"
    cat > "$SNIPPET_FILE" <<CLOUD
#cloud-config
hostname: ${HOSTNAME_ARG}
package_update: true
packages:
  - curl
  - ca-certificates
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent || true
  - curl -fsSL --max-time 120 -o /tmp/${APP}-inner.sh '${INNER_URL}?cb=$(date +%s)'
  - REPO_URL='${REPO_URL}' REPO_REF='${REPO_REF}' PORTAL_PORT='${PORTAL_PORT}' ICTFAX_PORT='${ICTFAX_PORT}' FAX_DOMAIN='${FAX_DOMAIN}' SIP_EXT_IP='${SIP_EXT_IP}' SMTP_ENABLED='${SMTP_ENABLED}' DEBUG='${DEBUG}' bash /tmp/${APP}-inner.sh
CLOUD
    qm set "$CT_ID" --cicustom "user=${SNIPPET_STORAGE}:snippets/${APP}-${CT_ID}.yml"
    CREATED=1
    msg_ok "VM erstellt (cloud-init, onboot=1)."
  fi
fi

if [[ "$TYPE" == "lxc" ]]; then
  if ! pct status "$CT_ID" 2>/dev/null | grep -q '^status: running'; then
    msg_info "Starte LXC ${CT_ID} ..."
    pct start "$CT_ID"
  fi
  if [[ "$CREATED" == "1" && -n "$SSH_KEY_ARG" ]]; then
    [[ -f "$SSH_KEY_ARG" ]] || die "SSH-Key nicht gefunden: ${SSH_KEY_ARG}"
    pct exec "$CT_ID" -- mkdir -p /root/.ssh
    pct exec "$CT_ID" -- chmod 700 /root/.ssh
    pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys
    pct exec "$CT_ID" -- chmod 600 /root/.ssh/authorized_keys
  fi
else
  if ! qm status "$CT_ID" 2>/dev/null | grep -q '^status: running'; then
    msg_info "Starte VM ${CT_ID} ..."
    qm start "$CT_ID"
  fi
fi

msg_info "Warte auf Netzwerk-Adresse ..."
wait_for_ip || {
  msg_error "Keine IP für ID ${CT_ID} erhalten – Diagnose:"
  if [[ "$TYPE" == "lxc" ]]; then
    pct status "$CT_ID" 2>&1 || true
    pct config "$CT_ID" 2>&1 | grep -E 'net0|hostname|onboot' || true
    pct exec "$CT_ID" -- ip -br addr 2>&1 || true
  else
    qm status "$CT_ID" 2>&1 || true
    qm guest cmd "$CT_ID" network-get-interfaces 2>&1 || true
  fi
  die "IP-Erkennung fehlgeschlagen – siehe Ausgabe oben und ${LOG_FILE}."
}
msg_ok "Adresse: ${CT_IP}"

# ---------------------------------------------------------------------------
# 3. Inner-Installer im Gast ausführen
# ---------------------------------------------------------------------------
msg_info "Installiere ${APP_DISPLAY} im Gast ..."
if [[ "$TYPE" == "lxc" ]]; then
  # Einzeiler-Modus (`bash -c "$(...)"`): BASH_SOURCE[0] ist undefiniert –
  # unter `set -u` würde genau hier "unbound variable" sterben (Live-Grube #1).
  # Der Default `:-` ist Pflicht; im Klon-Modus steht der echte Pfad drin.
  # Achtung: dirname "" liefert "." (aktuelles Verzeichnis, hier /root) –
  # deshalb prüfen wir BASH_SOURCE explizit, bevor SCRIPT_DIR gesetzt wird.
  SCRIPT_DIR=""
  if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
  fi
  LOCAL_INNER="${SCRIPT_DIR:-/tmp}/${APP}-inner.sh"
  if [[ -n "$SCRIPT_DIR" && -f "$LOCAL_INNER" ]]; then
    pct push "$CT_ID" "$LOCAL_INNER" "/tmp/${APP}-inner.sh"
    msg_info "Inner-Script lokal übertragen: ${LOCAL_INNER}"
  else
    # Das nackte Debian-12-LXC-Template hat kein curl (Live-Grube #2) –
    # erst wget prüfen, sonst curl per apt nachinstallieren.
    if ! pct exec "$CT_ID" -- bash -lc "command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1"; then
      msg_info "Kein curl/wget im Gast – installiere curl ..."
      pct exec "$CT_ID" -- bash -lc \
        "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq --no-install-recommends curl ca-certificates" \
        || die "curl lässt sich im Gast nicht installieren – manueller Download: ${INNER_URL}"
    fi
    if pct exec "$CT_ID" -- bash -lc "command -v curl >/dev/null 2>&1"; then
      pct exec "$CT_ID" -- bash -lc "curl -fsSL --max-time 120 -o /tmp/${APP}-inner.sh '${INNER_URL}?cb=$(date +%s)'"
    else
      pct exec "$CT_ID" -- bash -lc "wget -q -O /tmp/${APP}-inner.sh '${INNER_URL}?cb=$(date +%s)'"
    fi
    msg_info "Inner-Script im Gast geladen."
  fi
  pct exec "$CT_ID" -- env REPO_URL="$REPO_URL" REPO_REF="$REPO_REF" \
    PORTAL_PORT="$PORTAL_PORT" ICTFAX_PORT="$ICTFAX_PORT" \
    FAX_DOMAIN="$FAX_DOMAIN" SIP_EXT_IP="$SIP_EXT_IP" SMTP_ENABLED="$SMTP_ENABLED" \
    DEBUG="$DEBUG" bash "/tmp/${APP}-inner.sh"
else
  # VM: cloud-init hat den Installer beim ersten Boot gestartet. Bei Updates
  # stoßen wir ihn über den Guest-Agent erneut an (idempotent).
  msg_info "Warte auf Guest-Agent ..."
  for _ in $(seq 1 36); do
    qm guest exec "$CT_ID" -- true >/dev/null 2>&1 && break
    sleep 5
  done
  if [[ "$CREATED" == "1" ]]; then
    msg_info "Warte auf Abschluss der Cloud-Init-Installation (max. 20 Min) ..."
    for _ in $(seq 1 80); do
      guest_ok 'test -f /var/lib/ictfax/install-complete' && break
      sleep 15
    done
    guest_ok 'test -f /var/lib/ictfax/install-complete' || die "Cloud-Init-Installation hat nicht abgeschlossen (Marker fehlt)."
  else
    msg_info "Update-Modus: starte Inner-Installer erneut ..."
    qm guest exec "$CT_ID" --synchronous --timeout 3600 -- bash -lc "curl -fsSL --max-time 120 -o /tmp/${APP}-inner.sh '${INNER_URL}?cb=$(date +%s)' && REPO_URL='${REPO_URL}' REPO_REF='${REPO_REF}' PORTAL_PORT='${PORTAL_PORT}' ICTFAX_PORT='${ICTFAX_PORT}' FAX_DOMAIN='${FAX_DOMAIN}' SIP_EXT_IP='${SIP_EXT_IP}' SMTP_ENABLED='${SMTP_ENABLED}' DEBUG='${DEBUG}' bash /tmp/${APP}-inner.sh"
  fi
fi
msg_ok "Installation im Gast abgeschlossen."

verify_install || die "Verifikation fehlgeschlagen."
print_summary
