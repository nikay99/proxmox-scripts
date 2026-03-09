#!/bin/bash
set -e

# ─────────────────────────────────────────────
# PAPERCLIP UBUNTU 24.04 VM - PROXMOX INSTALL
# Läuft auf dem Proxmox HOST (nicht in der VM)
# ─────────────────────────────────────────────

VMID="${VMID:-9001}"
VMNAME="${VMNAME:-paperclip}"
STORAGE="${STORAGE:-local-lvm}"
CISTORAGE="${CISTORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
CORES="${CORES:-4}"
MEMORY="${MEMORY:-8192}"
DISK_SIZE="${DISK_SIZE:-40G}"
CI_USER="${CI_USER:-paper}"
CI_PASSWORD="${CI_PASSWORD:-Test1234}"
IPCONFIG0="${IPCONFIG0:-dhcp}"
PUBLIC_HOST="${PUBLIC_HOST:-}"
PORT="${PORT:-3100}"

IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMAGE_PATH="/tmp/ubuntu-2404-cloud.img"
BETTER_AUTH_SECRET=$(openssl rand -hex 32)

echo "======================================"
echo " PAPERCLIP VM INSTALLER"
echo " VMID:    $VMID"
echo " Name:    $VMNAME"
echo " Storage: $STORAGE"
echo " IP:      $IPCONFIG0"
echo "======================================"

# Cloud Image downloaden
if [ ! -f "$IMAGE_PATH" ]; then
  echo "[1/7] Downloading Ubuntu 24.04 cloud image..."
  wget -q --show-progress "$IMAGE_URL" -O "$IMAGE_PATH"
else
  echo "[1/7] Cloud image already exists, skipping download."
fi

# VM erstellen
echo "[2/7] Creating VM $VMID..."
qm create "$VMID" \
  --name "$VMNAME" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --net0 "virtio,bridge=$BRIDGE" \
  --serial0 socket \
  --vga serial0 \
  --agent enabled=1 \
  --ostype l26

# Disk importieren
echo "[3/7] Importing disk..."
qm importdisk "$VMID" "$IMAGE_PATH" "$STORAGE"
qm set "$VMID" --scsihw virtio-scsi-pci --scsi0 "$STORAGE:vm-$VMID-disk-0"
qm resize "$VMID" scsi0 "$DISK_SIZE"
qm set "$VMID" --boot order=scsi0

# Cloud-init
echo "[4/7] Configuring cloud-init..."
qm set "$VMID" --ide2 "$CISTORAGE:cloudinit"
qm set "$VMID" --ipconfig0 "$IPCONFIG0"
qm set "$VMID" --ciuser "$CI_USER"
qm set "$VMID" --cipassword "$CI_PASSWORD"
qm set "$VMID" --ciupgrade 0

# Cloud-init user-data Script
echo "[5/7] Writing cloud-init user-data..."

ALLOWED_HOSTNAMES="\"127.0.0.1\""
if [ -n "$PUBLIC_HOST" ]; then
  ALLOWED_HOSTNAMES="\"127.0.0.1\", \"$PUBLIC_HOST\""
fi

cat > /tmp/paperclip-userdata.yml << USERDATA
#cloud-config
package_update: false
package_upgrade: false

write_files:
  - path: /root/paperclip-setup.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -e
      LOG=/root/paperclip-install-result.txt
      exec > >(tee -a \$LOG) 2>&1

      echo "==== PAPERCLIP INSTALL START ===="
      echo "Date: \$(date)"

      # Node.js 22
      curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
      apt-get install -y nodejs git curl

      # pnpm
      corepack enable
      corepack prepare pnpm@latest --activate

      # paper user
      id paper 2>/dev/null || useradd -m -s /bin/bash paper
      echo "paper:${CI_PASSWORD}" | chpasswd

      # Paperclip clonen
      sudo -u paper git clone https://github.com/paperclipai/paperclip /home/paper/paperclip-src
      cd /home/paper/paperclip-src
      sudo -u paper pnpm install --frozen-lockfile

      # Verzeichnisse anlegen
      sudo -u paper mkdir -p /home/paper/.paperclip/instances/default/{db,data/backups,data/storage,logs,secrets}
      sudo -u paper mkdir -p /home/paper/workdir

      # .env mit Secrets
      cat > /home/paper/.paperclip/instances/default/.env << ENV
BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
NODE_ENV=production
PAPERCLIP_HOME=/home/paper/.paperclip
ENV
      chown paper:paper /home/paper/.paperclip/instances/default/.env
      chmod 600 /home/paper/.paperclip/instances/default/.env

      # config.json
      cat > /home/paper/.paperclip/instances/default/config.json << CONFIG
{
  "\$meta": { "version": 1, "updatedAt": "\$(date -u +%Y-%m-%dT%H:%M:%S.000Z)", "source": "install" },
  "database": {
    "mode": "embedded-postgres",
    "embeddedPostgresDataDir": "/home/paper/.paperclip/instances/default/db",
    "embeddedPostgresPort": 54329,
    "backup": {
      "enabled": true,
      "intervalMinutes": 60,
      "retentionDays": 30,
      "dir": "/home/paper/.paperclip/instances/default/data/backups"
    }
  },
  "logging": {
    "mode": "file",
    "logDir": "/home/paper/.paperclip/instances/default/logs"
  },
  "server": {
    "deploymentMode": "authenticated",
    "exposure": "private",
    "host": "0.0.0.0",
    "port": ${PORT},
    "allowedHostnames": [${ALLOWED_HOSTNAMES}],
    "serveUi": true
  },
  "auth": {
    "baseUrlMode": "auto",
    "disableSignUp": false
  },
  "storage": {
    "provider": "local_disk",
    "localDisk": {
      "baseDir": "/home/paper/.paperclip/instances/default/data/storage"
    }
  },
  "secrets": {
    "provider": "local_encrypted",
    "strictMode": false,
    "localEncrypted": {
      "keyFilePath": "/home/paper/.paperclip/instances/default/secrets/master.key"
    }
  }
}
CONFIG
      chown paper:paper /home/paper/.paperclip/instances/default/config.json

      # systemd service
      cat > /etc/systemd/system/paperclip.service << SERVICE
[Unit]
Description=Paperclip
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=paper
Group=paper
WorkingDirectory=/home/paper/paperclip-src
EnvironmentFile=/home/paper/.paperclip/instances/default/.env
Environment=NODE_ENV=production
Environment=PAPERCLIP_HOME=/home/paper/.paperclip
Environment=PATH=/home/paper/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/pnpm paperclipai run
Restart=always
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
SERVICE

      systemctl daemon-reload
      systemctl enable paperclip
      systemctl start paperclip

      echo ""
      echo "==== PAPERCLIP INSTALL COMPLETE ===="
      echo "User:   paper"
      echo "Pass:   ${CI_PASSWORD}"
      echo "Port:   ${PORT}"
      echo "URL:    http://\$(hostname -I | awk '{print \$1}'):${PORT}"

runcmd:
  - bash /root/paperclip-setup.sh
USERDATA

qm set "$VMID" --cicustom "user=local:snippets/paperclip-userdata-$VMID.yml"
mkdir -p /var/lib/vz/snippets/
cp /tmp/paperclip-userdata.yml "/var/lib/vz/snippets/paperclip-userdata-$VMID.yml"

# VM starten
echo "[6/7] Starting VM..."
qm start "$VMID"

echo "[7/7] Done!"
echo ""
echo "========================================"
echo " VM $VMID ($VMNAME) gestartet"
echo " Cloud-init läuft im Hintergrund (~3-5 Min)"
echo ""
echo " Status prüfen:"
echo "   qm guest exec $VMID -- cat /root/paperclip-install-result.txt"
echo ""
echo " Console öffnen:"
echo "   qm terminal $VMID"
echo "========================================"

 
