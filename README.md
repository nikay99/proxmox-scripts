# paperclip-proxmox

Automated installer for [Paperclip AI](https://github.com/paperclipai/paperclip) on Proxmox VE using Ubuntu 24.04 cloud images and cloud-init.

Deploys a fully configured Paperclip instance in ~10 minutes — including opencode, PostgreSQL, systemd service, and correct permissions for AI agents.

---

## Requirements

- Proxmox VE host with internet access
- A storage target (e.g. `local-lvm`)
- A bridge network (e.g. `vmbr0`)
- `openssl` and `wget` available on the Proxmox host

---

## Quickstart

```bash
# Clone or download the script to your Proxmox host
wget -O paperclip-install.sh https://raw.githubusercontent.com/YOUR_USERNAME/paperclip-proxmox/main/paperclip-install.sh
chmod +x paperclip-install.sh

# Run with defaults (DHCP, VMID 9001, local-lvm)
bash paperclip-install.sh
```

---

## Configuration

All options are set via environment variables. The script will prompt for confirmation before doing anything.

| Variable | Default | Description |
|---|---|---|
| `VMID` | `9001` | Proxmox VM ID |
| `VMNAME` | `paperclip` | VM display name |
| `STORAGE` | `local-lvm` | Disk storage target |
| `CISTORAGE` | `local-lvm` | Cloud-init storage target |
| `BRIDGE` | `vmbr0` | Network bridge |
| `CORES` | `4` | CPU cores |
| `MEMORY` | `8192` | RAM in MB |
| `DISK_SIZE` | `40G` | Disk size |
| `CI_USER` | `paper` | VM user |
| `CI_PASSWORD` | *(random)* | VM user password |
| `IPCONFIG0` | `dhcp` | IP config (see examples below) |
| `PORT` | `3100` | Paperclip web port |
| `PUBLIC_HOST` | *(empty)* | Public hostname to allow (e.g. `agents.example.com`) |
| `OPENCODE_VERSION` | `1.2.22` | opencode version to install |

---

## Examples

### DHCP with public hostname

```bash
PUBLIC_HOST=agents.example.com bash paperclip-install.sh
```

### Static IP

```bash
VMID=9002 \
VMNAME=paperclip-prod \
STORAGE=local-lvm \
BRIDGE=vmbr0 \
IPCONFIG0='ip=192.168.1.50/24,gw=192.168.1.1' \
PUBLIC_HOST=agents.example.com \
bash paperclip-install.sh
```

### Custom resources

```bash
VMID=9003 \
CORES=8 \
MEMORY=16384 \
DISK_SIZE=80G \
bash paperclip-install.sh
```

---

## What the script does

1. Downloads the Ubuntu 24.04 cloud image (cached on re-runs)
2. Creates the VM on Proxmox with the specified resources
3. Attaches a cloud-init drive with user credentials and IP config
4. Writes a setup script that runs inside the VM via cloud-init:
   - Creates user `paper` with `sudo NOPASSWD` (AI agents need full control)
   - Installs Node.js 22, pnpm, git
   - Installs `opencode-ai` at the specified version
   - Writes a safe `opencode.json` config (ask before `rm -rf` and `sudo` destructive commands)
   - Clones Paperclip from source and runs `pnpm install`
   - Writes `~/.paperclip/instances/default/config.json` and `.env`
   - Installs and starts a `paperclip.service` systemd unit
5. Starts the VM
6. Saves credentials to `/root/paperclip-vm-<VMID>-credentials.txt` on the Proxmox host

---

## After install

Cloud-init takes ~8-10 minutes. Check the install log:

```bash
qm guest exec 9001 -- cat /root/paperclip-install-result.txt
```

Open a console:

```bash
qm terminal 9001
```

Check service status inside the VM:

```bash
systemctl status paperclip --no-pager
journalctl -u paperclip -n 50 --no-pager
```

Health check:

```bash
curl http://127.0.0.1:3100/api/health
```

---

## opencode permissions

The installed `opencode.json` allows all file and shell operations, but **prompts for approval** before running:

- `rm -rf` / `rm -r`
- `sudo rm`
- `sudo shutdown` / `sudo reboot`
- `sudo passwd` / `sudo deluser` / `sudo userdel`

Everything else (bash, edit, read, write, webfetch) runs without confirmation so agents can work uninterrupted.

See [`examples/opencode.example.json`](examples/opencode.example.json) to customize.

---

## File structure

```
paperclip-proxmox/
├── paperclip-install.sh          # Main installer (run on Proxmox host)
└── examples/
    ├── .env.example              # Paperclip .env template
    ├── paperclip-config.example.json   # Paperclip config.json template
    └── opencode.example.json     # opencode permission config template
```

---

## VM file structure (after install)

```
/home/paper/
├── paperclip-src/                # Paperclip source (cloned from GitHub)
├── million/                      # Default company workspace
│   ├── agents/                   # Agent instruction files (AGENTS.md etc.)
│   └── projects/                 # Project working directories
└── .paperclip/
    └── instances/default/
        ├── .env                  # Secrets (BETTER_AUTH_SECRET)
        ├── config.json           # Paperclip configuration
        ├── db/                   # Embedded PostgreSQL data
        ├── logs/                 # Service logs
        ├── secrets/              # Encrypted secrets store
        └── data/
            ├── storage/          # File storage
            └── backups/          # Database backups
```

---

## Troubleshooting

### Service keeps crashing

```bash
journalctl -u paperclip -n 100 --no-pager
```

Most common cause: `BETTER_AUTH_SECRET` not set. Check:

```bash
cat /home/paper/.paperclip/instances/default/.env
```

### opencode models command fails

Config is invalid. Check:

```bash
cat /home/paper/.config/opencode/opencode.json
```

Must be valid JSON with `$schema` set. Remove any trailing commas.

### Agents can't write to project directory

```bash
sudo chown -R paper:paper /home/paper/million
sudo chmod -R 755 /home/paper/million
```

### Port 3100 already in use

Another process is running. Check and stop:

```bash
lsof -i :3100
sudo systemctl stop paperclip
```

---

## Security notes

- The `paper` user has `sudo NOPASSWD:ALL` — this is intentional so AI agents have full control of the VM. **Do not expose this VM directly to the internet** without a reverse proxy and authentication in front.
- `BETTER_AUTH_SECRET` is stored in `/home/paper/.paperclip/instances/default/.env` with `chmod 600`.
- VM credentials are saved to `/root/paperclip-vm-<VMID>-credentials.txt` on the Proxmox host with `chmod 600`.
- Change the default password after setup: `passwd paper`
- For production: add SSH key auth and disable password login.

---

## License

MIT
