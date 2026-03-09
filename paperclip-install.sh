#!/bin/bash
# ─────────────────────────────────────────────────────────────
# paperclip-install.sh
# Deploys a Paperclip AI Ubuntu 24.04 VM on a Proxmox host
# Run this on the Proxmox HOST, not inside the VM
# ─────────────────────────────────────────────────────────────
set -euo pipefail

# ── Configuration (override via env vars) ────────────────────
VMID="${VMID:-9001}"
VMNAME="${VMNAME:-paperclip}"
STORAGE="${STORAGE:-local-lvm}"
CISTORAGE="${CISTORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
CORES="${CORES:-4}"
MEMORY="${MEMORY:-8192}"
DISK_SIZE="${DISK_SIZE:-40G}"
CI_USER="${CI_USER:-paper}"
CI_PASSWORD="${CI_PASSWORD:-$(openssl rand -base64 16)}"
IPCONFIG0="${IPCONFIG0:-dhcp}"
PUBLIC_HOST="${PUBLIC_HOST:-}"
PORT="${PORT:-3100}"
OPENCODE_VERSION="${OPENCODE_VERSION:-1.2.22}"

IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMAGE_PATH="/tmp/ubuntu-2404-cloud.img"
BETTER_AUTH_SECRET="$(openssl rand -hex 32)"

# ── Preflight checks ─────────────────────────────────────────
if ! command -v qm &>/dev/null; then
  echo "ERROR: This script must be run on a Proxmox host." >&2
  exit 1
fi

if qm status "$VMID" &>/dev/null; then
  echo "ERROR: VM $VMID already exists. Choose a different VMID." >&2
  exit 1
fi

if ! pvesm status | grep -q "^$STORAGE "; then
  echo "ERROR: Storage '$STORAGE' not found. Available:" >&2
  pvesm status | awk 'NR>1 {print "  " $1}' >&2
  exit 1
fi

# ── Summary ──────────────────────────────────────────────────
echo "════════════════════════════════════════"
echo "  PAPERCLIP VM INSTALLER"
echo "════════════════════════════════════════"
echo "  VMID       : $VMID"
echo "  Name       : $VMNAME"
echo "  Storage    : $STORAGE"
echo "  Cores      : $CORES"
echo "  Memory     : ${MEMORY}MB"
echo "  Disk       : $DISK_SIZE"
echo "  IP         : $IPCONFIG0"
echo "  Port       : $PORT"
echo "  User       : $CI_USER"
echo "  Public host: ${PUBLIC_HOST:-none}"
echo "════════════════════════════════════════"
read -rp "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Download cloud image ──────────────────────────────────────
if [ ! -f "$IMAGE_PATH" ]; then
  echo "[1/7] Downloading Ubuntu 24.04 cloud image..."
  wget -q --show-progress "$IMAGE_URL" -O "$IMAGE_PATH"
else
  echo "[1/7] Cloud image already cached at $IMAGE_PATH"
fi

# ── Create VM ────────────────────────────────────────────────
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

# ── Import disk ───────────────────────────────────────────────
echo "[3/7] Importing disk..."
qm importdisk "$VMID" "$IMAGE_PATH" "$STORAGE" -format qcow2
qm set "$VMID" --scsihw virtio-scsi-pci --scsi0 "$STORAGE:vm-$VMID-disk-0"
qm resize "$VMID" scsi0 "$DISK_SIZE"
qm set "$VMID" --boot order=scsi0

# ── Cloud-init base config ────────────────────────────────────
echo "[4/7] Configuring cloud-init..."
qm set "$VMID" \
  --ide2 "$CISTORAGE:cloudinit" \
  --ipconfig0 "$IPCONFIG0" \
  --ciuser "$CI_USER" \
  --cipassword "$CI_PASSWORD" \
  --ciupgrade 0

# ── Build allowed hostnames list ──────────────────────────────
ALLOWED_HOSTNAMES='"127.0.0.1"'
if [ -n "$PUBLIC_HOST" ]; then
  ALLOWED_HOSTNAMES='"127.0.0.1", "'"$PUBLIC_HOST"'"'
fi

# ── Write setup script ────────────────────────────────────────
echo "[5/7] Writing cloud-init user-data..."
mkdir -p /var/lib/vz/snippets/

cat > /tmp/paperclip-setup-"$VMID".sh << SETUP
#!/bin/bash
set -euo pipefail
LOG=/root/paperclip-install-result.txt
exec > >(tee -a "\$LOG") 2>&1

echo "==== PAPERCLIP INSTALL START ===="
echo "Date: \$(date -u)"

# ── User ──────────────────────────────────────────────────────
id ${CI_USER} 2>/dev/null || useradd -m -s /bin/bash ${CI_USER}
echo "${CI_USER}:${CI_PASSWORD}" | chpasswd

# sudo NOPASSWD for paper (agents need full control)
echo "${CI_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${CI_USER}
chmod 440 /etc/sudoers.d/${CI_USER}

# ── Dependencies ──────────────────────────────────────────────
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs git curl ca-certificates

corepack enable
corepack prepare pnpm@latest --activate

# ── opencode ${OPENCODE_VERSION} ──────────────────────────────
npm install -g opencode-ai@${OPENCODE_VERSION}

# opencode config: ask before rm/sudo, allow everything else
mkdir -p /home/${CI_USER}/.config/opencode
cat > /home/${CI_USER}/.config/opencode/opencode.json << 'OPENCODE_CFG'
{
  "\$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "permission": {
    "bash": {
      "*": "allow",
      "rm -rf *": "ask",
      "rm -r *": "ask",
      "sudo rm *": "ask",
      "sudo shutdown *": "ask",
      "sudo reboot *": "ask",
      "sudo passwd *": "ask",
      "sudo deluser *": "ask",
      "sudo userdel *": "ask"
    },
    "edit": "allow",
    "read": "allow",
    "write": "allow",
    "webfetch": "allow"
  }
}
OPENCODE_CFG
chown -R ${CI_USER}:${CI_USER} /home/${CI_USER}/.config

# ── Paperclip ────────────────────────────────────────────────
sudo -u ${CI_USER} git clone https://github.com/paperclipai/paperclip /home/${CI_USER}/paperclip-src
cd /home/${CI_USER}/paperclip-src
sudo -u ${CI_USER} pnpm install --frozen-lockfile

# ── Directories ───────────────────────────────────────────────
sudo -u ${CI_USER} mkdir -p \
  /home/${CI_USER}/.paperclip/instances/default/{db,data/backups,data/storage,logs,secrets} \
  /home/${CI_USER}/million/{agents,projects}

# ── .env ─────────────────────────────────────────────────────
cat > /home/${CI_USER}/.paperclip/instances/default/.env << ENV
BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
NODE_ENV=production
PAPERCLIP_HOME=/home/${CI_USER}/.paperclip
ENV
chown ${CI_USER}:${CI_USER} /home/${CI_USER}/.paperclip/instances/default/.env
chmod 600 /home/${CI_USER}/.paperclip/instances/default/.env

# ── Paperclip config.json ────────────────────────────────────
cat > /home/${CI_USER}/.paperclip/instances/default/config.json << CONFIG
{
  "\$meta": { "version": 1, "updatedAt": "\$(date -u +%Y-%m-%dT%H:%M:%S.000Z)", "source": "install" },
  "database": {
    "mode": "embedded-postgres",
    "embeddedPostgresDataDir": "/home/${CI_USER}/.paperclip/instances/default/db",
    "embeddedPostgresPort": 54329,
    "backup": {
      "enabled": true,
      "intervalMinutes": 60,
      "retentionDays": 30,
      "dir": "/home/${CI_USER}/.paperclip/instances/default/data/backups"
    }
  },
  "logging": {
    "mode": "file",
    "logDir": "/home/${CI_USER}/.paperclip/instances/default/logs"
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
      "baseDir": "/home/${CI_USER}/.paperclip/instances/default/data/storage"
    }
  },
  "secrets": {
    "provider": "local_encrypted",
    "strictMode": false,
    "localEncrypted": {
      "keyFilePath": "/home/${CI_USER}/.paperclip/instances/default/secrets/master.key"
    }
  }
}
CONFIG
chown ${CI_USER}:${CI_USER} /home/${CI_USER}/.paperclip/instances/default/config.json

# ── systemd service ───────────────────────────────────────────
cat > /etc/systemd/system/paperclip.service << SERVICE
[Unit]
Description=Paperclip AI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${CI_USER}
Group=${CI_USER}
WorkingDirectory=/home/${CI_USER}/paperclip-src
EnvironmentFile=/home/${CI_USER}/.paperclip/instances/default/.env
Environment=NODE_ENV=production
Environment=PAPERCLIP_HOME=/home/${CI_USER}/.paperclip
Environment=PATH=/home/${CI_USER}/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/pnpm paperclipai run
Restart=always
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
SERVICE

# ── Permissions & start ───────────────────────────────────────
chown -R ${CI_USER}:${CI_USER} /home/${CI_USER}/
chmod -R 755 /home/${CI_USER}/million

systemctl daemon-reload
systemctl enable paperclip
systemctl start paperclip

VM_IP=\$(hostname -I | awk '{print \$1}')

echo ""
echo "==== PAPERCLIP INSTALL COMPLETE ===="
echo "User     : ${CI_USER}"
echo "Password : ${CI_PASSWORD}"
echo "URL      : http://\${VM_IP}:${PORT}"
echo "Sudo     : NOPASSWD (full control)"
echo "opencode : ${OPENCODE_VERSION}"
echo "====================================="
SETUP

# ── Encode setup script into cloud-init userdata ──────────────
SETUP_B64=$(base64 -w0 /tmp/paperclip-setup-"$VMID".sh)

cat > "/var/lib/vz/snippets/paperclip-userdata-$VMID.yml" << USERDATA
#cloud-config
package_update: false
package_upgrade: false

write_files:
  - path: /root/paperclip-setup.sh
    permissions: '0755'
    encoding: b64
    content: ${SETUP_B64}

runcmd:
  - bash /root/paperclip-setup.sh
USERDATA

qm set "$VMID" --cicustom "user=local:snippets/paperclip-userdata-$VMID.yml"

# ── Start VM ──────────────────────────────────────────────────
echo "[6/7] Starting VM $VMID..."
qm start "$VMID"

# ── Save credentials locally ──────────────────────────────────
CREDS_FILE="/root/paperclip-vm-$VMID-credentials.txt"
cat > "$CREDS_FILE" << CREDS
PAPERCLIP VM $VMID - $(date -u)
================================
VMID     : $VMID
Name     : $VMNAME
User     : $CI_USER
Password : $CI_PASSWORD
Port     : $PORT
IP       : $IPCONFIG0
Auth     : BETTER_AUTH_SECRET saved in VM at /home/$CI_USER/.paperclip/instances/default/.env
CREDS
chmod 600 "$CREDS_FILE"

echo "[7/7] Done!"
echo ""
echo "════════════════════════════════════════"
echo "  VM $VMID ($VMNAME) is starting"
echo "  Cloud-init takes ~8-10 minutes"
echo ""
echo "  Check install log (after ~10 min):"
echo "    qm guest exec $VMID -- cat /root/paperclip-install-result.txt"
echo ""
echo "  Open console:"
echo "    qm terminal $VMID"
echo ""
echo "  Credentials saved to:"
echo "    $CREDS_FILE"
echo "════════════════════════════════════════"
