# ICTFax-Proxmox

Einzeiler-Installer im Stil der [Proxmox VE Helper-Scripts](https://community-scripts.github.io/ProxmoxVE/)
für **[ICTFax](https://github.com/ictinnovations/ictfax)** – Faxserver (GPLv3) mit
Docker-Backend und einem eigenen React/Vite-Portal.

Erstellt einen **LXC (Default)** oder eine **VM** auf Proxmox VE, installiert ICTFax
inkl. MariaDB, ein React-Portal mit Express-BFF, systemd-Units, Firewall-Regeln und
verifiziert anschließend Services und Web-UI.

## Features

- **LXC oder VM**: unprivilegierter Debian-12-LXC (`nesting=1,keyctl=1`) oder
  Debian-12-Cloud-Image-VM, per `--type vm`.
- **ICTFax-Backend** als Docker-Compose-Stack (`ictinnovations/ictfax` + MariaDB 10.11).
- **React/Vite-Portal** (`:8080`) mit Login, Dashboard, Faxversand, Postausgang,
  Posteingang und Dokument-Download.
- **Native ICTFax-Admin-UI** (`:8081`) für SIP-Trunk, DID, E-Mail→Fax und Provisioning.
- **Eigene Secrets** in `/etc/ictfax/ictfax.env` und `/etc/ictfax-portal/config.env`
  (0600, idempotent, bleiben bei Updates erhalten).
- **systemd**: `ictfax.service` (Compose) und `ictfax-portal.service` (Node-BFF),
  beide `Restart=always`, `onboot=1` für den Gast.
- **Selbstverifikation** nach der Installation und `--reboot-test` für den
  Neustart-Test.
- **Sichere Defaults**: unprivilegierter LXC, keine Default-Passwörter in Skripten,
  Firewall-Regeln nur ergänzend, keine bestehenden Regeln werden gelöscht.

## Einzeiler

Auf dem **Proxmox-Host** als root:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/ICTFax-Proxmox/main/install/ictfax.sh)"
```

Alternativ lokal:

```bash
git clone https://github.com/HatchetMan111/ICTFax-Proxmox.git
cd ICTFax-Proxmox
bash install/ictfax.sh
```

## Voraussetzungen

- Proxmox VE 8.x (getestet mit Debian 12-Templates/Cloud-Image)
- Root-Zugriff auf den Host
- Internetzugang für Template, Docker-Images und npm-Pakete
- Für **E-Mail→Fax**: MX-Record auf die Gast-IP/Domain und Port 25 erreichbar
- Für **echten Faxversand**: SIP-Trunk oder ATA-Gerät, im ICTFax-Admin einzurichten

## Usage

```text
bash ictfax.sh [OPTIONEN]

  --ctid ID            ID (Default: nächste freie ID)
  --hostname NAME      Hostname/VM-Name (Default: ictfax)
  --type lxc|vm        LXC (Default) oder VM (cloud-init)
  --cores N            vCPU (Default LXC 2 / VM 2)
  --memory MB          RAM (Default LXC 4096 / VM 4096)
  --disk GB            Disk (Default LXC 16 / VM 20)
  --storage NAME       RootFS-/Image-Storage (Default: auto, local-lvm bevorzugt)
  --template-store N   Template-/Snippet-Storage (Default: local)
  --bridge NAME        Netzwerk-Bridge (Default: vmbr0)
  --password PW        Root-Passwort (Default: zufällig, Datei unter /root/)
  --ssh-key PATH       SSH-Public-Key für root
  --fax-domain NAME    ICTCORE_HOST / E-Mail→Fax-Domain (Default: Gast-IP)
  --sip-ext-ip IP      Öffentliche IP für SIP/RTP (NAT/Cloud, optional)
  --no-smtp            Port 25 (E-Mail→Fax) nicht veröffentlichen
  --dry-run            Nur Plan ausgeben, nichts verändern
  --reboot-test        Bestehenden Gast rebooten und Web-UI verifizieren
  --debug              bash -x + vollständige Fehlerkette
  -h, --help           Hilfe
```

Beispiele:

```bash
# LXC mit 4 GB RAM und 4 vCPU
bash install/ictfax.sh --cores 4 --memory 4096

# VM statt LXC
bash install/ictfax.sh --type vm --ctid 210

# Update des bestehenden Gasts (idempotent)
bash install/ictfax.sh --ctid 210 --type lxc

# Reboot-Test
bash install/ictfax.sh --reboot-test --ctid 210 --type lxc

# Nur planen
bash install/ictfax.sh --dry-run --ctid 210
```

## Ports

| Port | Protokoll | Zweck |
|------|-----------|-------|
| 8080 | TCP | React/Vite-Portal + BFF |
| 8081 | TCP | Native ICTFax-Admin-UI + REST-API |
| 5060 | TCP/UDP | SIP |
| 16384–16484 | UDP | RTP (Fax-Medien) |
| 25 | TCP | E-Mail→Fax (optional, `--no-smtp` deaktiviert) |

## Architektur

```text
Client ──HTTP:8080──► Express-BFF ──HTTP:8081/api──► ICTFax (Docker)
   │                        │                              │
   │                        └── Cookie-Session (JWT)       ├── MariaDB 10.11
   └──HTTP:8081───────────── Native Admin-UI ─────────────┘
```

- Das Portal spricht **nie** direkt mit ICTFax; der BFF hält das JWT in einem
  `HttpOnly`-Cookie und setzt den `Authorization: Bearer`-Header.
- Das native Admin-UI läuft auf derselben ICTFax-Instanz und bleibt für
  SIP-/DID-/E-Mail-Konfiguration verfügbar.

## Erster Login

- Portal: `http://<IP>:8080`
- Native Admin-UI: `http://<IP>:8081`
- Benutzer: `admin@ictcore.org`
- Passwort: `helloAdmin`

**Bitte sofort ändern** (im nativen Admin-UI unter Benutzer/Passwort).

## Portal-API (BFF)

| Methode | Pfad | Zweck |
|---------|------|-------|
| POST | `/api/session/login` | Login, setzt HttpOnly-Cookie |
| POST | `/api/session/logout` | Cookie löschen |
| GET | `/api/session` | Session prüfen |
| GET | `/api/health` | Healthcheck (ICTFax erreichbar?) |
| GET | `/api/dashboard` | Statistik + letzte Faxe + Konten |
| GET | `/api/accounts` | Caller-ID-Konten |
| GET | `/api/transmissions?direction=outbound\|inbound` | Übertragungen |
| POST | `/api/fax/send` | Multipart: `file`, `phone`, `account_id`, `title`, `email`, `quality` |
| GET | `/api/transmissions/:id/document` | Fax-Dokument herunterladen |

## ICTFax-API-Flow (Fax senden)

Der BFF bildet den Ablauf des offiziellen Angular-Clients nach:

1. `POST /api/documents` → `document_id`
2. `POST /api/documents/{id}/media` (Rohdatei, kein Multipart)
3. `POST /api/programs/sendfax` → `program_id`
4. `POST /api/transmissions` → `transmission_id`
5. `POST /api/transmissions/{id}/send` → `spool_id`

Dokument-Download:

1. `GET /api/transmissions/{id}/results?name=document` → `document_id`
2. `GET /api/documents/{id}/media` → PDF/TIFF

## Updates

Das Skript ist idempotent. Erneut ausführen:

```bash
bash install/ictfax.sh --ctid <ID> --type lxc
```

- Repo wird auf `origin/main` zurückgesetzt (`git reset --hard`).
- Docker-Images werden gepullt, der Stack neu erstellt.
- Portal wird neu gebaut (`npm ci && npm run build`).
- Secrets in `/etc/ictfax/` und `/etc/ictfax-portal/` bleiben erhalten.

## Reboot-Test

```bash
bash scripts/reboot-test.sh --ctid <ID> --type lxc
```

Der Test rebootet den Gast, wartet auf die IP und prüft:

- `ictfax.service` und `ictfax-portal.service` = active
- `http://localhost:8080/api/health` = 200
- `http://localhost:8080/` = 200
- `http://localhost:8081/` = 200

Bei Fehlern werden `journalctl` und `docker compose ps` ausgegeben.

## Sicherheit

- **Keine Secrets im Repo.** Alle Passwörter werden zur Laufzeit erzeugt und
  liegen in `/etc/ictfax/` bzw. `/etc/ictfax-portal/` (0600).
- **HTTP ohne TLS** ist der Default (LAN). Für öffentliche Erreichbarkeit
  einen Reverse-Proxy (Caddy/Traefik/nginx) mit TLS vor das Portal setzen und
  `COOKIE_SECURE=1` in `/etc/ictfax-portal/config.env` setzen.
- **Port 25** nur öffnen, wenn E-Mail→Fax benötigt wird (`--no-smtp`).
- **SIP/RTP** nur so weit wie nötig exposen; bei NAT `--sip-ext-ip` setzen.
- **Default-Login** sofort ändern.
- Der BFF setzt `HttpOnly`, `SameSite=Lax` und (optional) `Secure`-Cookies.

## Troubleshooting

**Portal zeigt 502 / „Upstream“-Fehler**

```bash
systemctl status ictfax ictfax-portal --no-pager
journalctl -u ictfax -u ictfax-portal --no-pager -n 100
docker logs --tail 100 ictfax
```

**ICTFax-Container startet nicht**

```bash
cd /opt/ictfax/docker
/usr/local/bin/ictfax-compose ps
/usr/local/bin/ictfax-compose logs --tail 100 ictfax
```

Häufig: MariaDB noch nicht bereit (Healthcheck abwarten), falsches DB-Passwort
oder zu wenig RAM (mind. 4 GB empfohlen).

**Kein Faxversand / „kein Medienpfad“**

- SIP-Trunk/ATA im nativen Admin-UI konfigurieren.
- Port 5060/TCP+UDP und RTP 16384–16484/UDP müssen erreichbar sein.
- Bei NAT `--sip-ext-ip <öffentliche-IP>` setzen und Installation wiederholen.

**E-Mail→Fax kommt nicht an**

- MX-Record auf die Gast-Domain/IP zeigen lassen.
- Port 25/tcp muss von außen erreichbar sein (Provider-Firewall!).
- `--no-smtp` darf nicht gesetzt sein.
- Logs: `docker logs ictfax | grep -i sendmail`.

**LXC: Docker startet nicht**

Der Installer fällt automatisch auf den `vfs`-Storage-Treiber zurück. Prüfen:

```bash
systemctl status docker --no-pager
journalctl -u docker --no-pager -n 100
```

**Portal-Build fehlt**

```bash
cd /opt/ictfax/portal
npm ci && npm run build
systemctl restart ictfax-portal
```

## Deinstallation

```bash
# LXC
pct stop <ID> && pct destroy <ID>

# VM
qm stop <ID> && qm destroy <ID>
```

## Tests

```bash
bash tests/test-installer.sh     # Syntax, Pflichtdateien, Einzeiler
bash tests/test-compose.sh       # Compose-Validierung (Docker nötig)
cd portal && npm ci && npm test  # BFF-Unit-Tests
```

## Lizenz

- Installer/Portal: **MIT** (siehe `LICENSE`)
- ICTFax: **GPLv3** – siehe [ictinnovations/ictfax](https://github.com/ictinnovations/ictfax)

ICTFax ist ein eigenständiges Open-Source-Projekt von ICT Innovations. Dieses
Repository liefert nur den Proxmox-Installer und das Portal, nicht ICTFax selbst.
