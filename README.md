# Stationeers on Proxmox

A self-contained installer for a Stationeers dedicated server on Proxmox VE, in the
style of the community helper scripts. It installs:

- **Stationeers Server UI (SSUI) v6** – the official community web UI, SteamCMD
  updates, backups, Discord and mod support, on **https://server:8443**
- **Stationeers Control Deck** – a small companion panel made for this setup, on
  **https://server:8080**, for importing/activating saves and starting/stopping the
  server from any machine
- A **Debian 13 LXC** (when run on a Proxmox host) with the right glibc for the
  current Stationeers Linux server, a dedicated `stationeers` user and systemd
  services

Everything the panel needs is standard-library Python. The installer downloads SSUI
from its official GitHub releases; SSUI is not redistributed here.

## Quick install from GitHub

On a Proxmox VE host:

```bash
curl -fsSL https://raw.githubusercontent.com/RoseOO/stationprox/main/stationeers.sh -o stationeers.sh
bash stationeers.sh
```

One-liner (keeps stdin attached for the prompts):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/RoseOO/stationprox/main/stationeers.sh)"
```

Inside an existing Debian 13 container or VM:

```bash
curl -fsSL https://raw.githubusercontent.com/RoseOO/stationprox/main/stationeers.sh -o /root/stationeers.sh
bash /root/stationeers.sh --inside
```

## Requirements

- Proxmox VE 8/9 host, or an existing **Debian 13 (Trixie)** container/VM
- 8 CPU cores and 16 GB RAM recommended (the server will run with less, but
  atmospheric calculations are hungry)
- ~50 GB disk for the OS, game files and saves
- The current server requires **glibc 2.40+**. Debian 12 will not work.

## Install on a Proxmox host

Copy `stationeers.sh` to the Proxmox host, then:

```bash
bash stationeers.sh
```

It asks for the container ID, resources, bridge and an optional static IP, creates
the LXC, and runs the installer inside it. Defaults:

| Setting | Default |
| --- | --- |
| Cores | 8 |
| RAM | 16384 MB |
| Disk | 50 GB |
| Network | DHCP on `vmbr0` |

Unattended with defaults:

```bash
UNATTENDED=1 bash stationeers.sh
```

Overrides: `CTID`, `HN`, `CORES`, `RAM`, `DISK`, `BRIDGE`, `CT_IP`, `CT_GW`,
`CT_DNS`.

At the end it prints the container IP, root password and how to read the credentials.

## Install without Proxmox

On a Debian 13 container/VM, copy the script and run:

```bash
sudo bash stationeers.sh --inside
```

It installs into `/home/stationeers/ssui` and `/opt/stationeers-panel`.

## Credentials

All generated credentials are written to a file and kept there:

```bash
cat /root/stationeers-credentials.txt
# or, as root
stationeers-creds
```

The file contains the Control Deck login, the SSUI owner login, URLs, game port and
service commands. It is mode `600` and is updated if you reset the panel password.
The SSUI owner password is also stored in `/etc/stationeers-panel/config.json`
(mode `600`, owned by `stationeers`) so the panel can mint its API token.

## First start

SSUI downloads and installs SteamCMD and the ~10 GB Stationeers server on its first
run. The SSUI website only appears after that finishes. The Control Deck starts
immediately and shows progress; it connects automatically as soon as SSUI is ready.

Open the Control Deck from another machine:

```
https://<server-ip>:8080
```

Sign in with the panel credentials. Both web UIs use self-signed certificates, so the
browser warning is expected.

## Load your own saves

Current Stationeers saves are **`.save` files**. A station on disk looks like:

```
saves/
  MyBase/
    MyBase.save          <- the head save
    autosave/
    quicksave/
    manualsave/
```

The folder name (`MyBase`) is the **Save Name** the server launches with, and it
must match exactly (capitals and spaces count). Copy the whole station folder, not
just the inner file.

You can:

1. Drop the `.save` file directly on the Control Deck (it creates
   `saves/<SaveName>/<SaveName>.save` for you), or
2. Zip the whole station folder (including its autosave folders) and upload that.

Then press **Load & launch**. The panel now accepts `.save` files and both save
layouts.

Older saves that only contain `world.xml` are from before the 2025 save-system
change. The current server cannot load them directly; convert them with the
Stationeers Save Transformer or load/re-save them in a current client first.

You can also copy a save folder directly into the server:

```bash
scp -r MyBase root@server:/home/stationeers/ssui/saves/
```

Then press **Set active** (or **Load & launch**) in the panel. The folder name must
match the active Save Name exactly.

### New worlds

Use the **New World** card: pick a save name, a world from the catalog read from your
game install, and start it. The server creates the world on first launch.

## Ports

| Port | Protocol | Purpose |
| --- | --- | --- |
| 27016 | UDP | Stationeers players |
| 8443 | TCP | SSUI web UI |
| 8080 | TCP | Control Deck |

Forward only `27016/udp` to the internet. Keep `8443` and `8080` on your LAN or VPN.
If the Proxmox firewall is enabled, allow these ports for the container.

## Management

```bash
systemctl status ssui              # SSUI + game server manager
systemctl status stationeers-panel # Control Deck
journalctl -u ssui -f              # follow server/SSUI logs
```

Update SSUI, the Stationeers server and the panel (stops SSUI first, runs SteamCMD
with `validate`, then restarts):

```bash
sudo stationeers-update
```

Update only the Control Deck, without touching SSUI or the game:

```bash
sudo stationeers-update --panel
```

Skip SteamCMD validation for a faster update:

```bash
sudo SKIP_VALIDATE=1 stationeers-update
```

SSUI also has its own updater and update button; either path is fine.

Reset the Control Deck password:

```bash
sudo stationeers-install --reset-panel-password
```

## Files

| Path | Contents |
| --- | --- |
| `/home/stationeers/ssui` | SSUI binary, SteamCMD, game files, saves |
| `/home/stationeers/ssui/saves` | Save folders (`<SaveName>/world.xml`) |
| `/etc/stationeers-panel/config.json` | Panel config + SSUI owner credentials/token |
| `/etc/stationeers-panel/tls` | Self-signed panel certificate |
| `/opt/stationeers-panel` | Control Deck code |
| `/root/stationeers-credentials.txt` | Human-readable credentials |

## Troubleshooting

**`WARN: Systemd 257 detected. You may need to enable nesting.`** — this is a
Proxmox LXC start warning on Debian 13. New containers made by this script set
`nesting=1`. For an older one:

```bash
pct set <CTID> --features nesting=1
pct reboot <CTID>
```

**Console shows a login prompt** — the Proxmox console auto-logs in as root using
`container-getty@.service` and `console-getty.service` overrides (the same approach
community-scripts uses), and removes the container root password. Apply it to an
existing container with:

```bash
sudo stationeers-update --panel
```

Then close and reopen the Proxmox console.

**`glibc ... is too old`** — use Debian 13. The installer intentionally refuses
Debian 12 because the game server will not start.

**SSUI page does not open yet** — first run downloads SteamCMD and the game. Watch:

```bash
journalctl -u ssui -f
```

**Panel says it cannot connect to SSUI** — SSUI may still be installing, or the owner
account differs from the one in the panel config. Use **SSUI login** in the panel
banner and enter the SSUI credentials (the ones in the credentials file). If you
completed SSUI's own wizard with a different account, this fixes the link.

**A save does not appear** — the folder must exist under
`/home/stationeers/ssui/saves` and contain `world.xml` (or `world_meta.xml` for an
in-progress world). Check ownership with `ls -la`.

**Server stops when I stop SSUI** — that is expected; SSUI manages the game process.
Use the Control Deck Start/Stop buttons instead of stopping the web UI.

**Player cannot connect** — forward `27016/udp`; verify the address shown in the
panel. Do not forward the web ports.

## Security notes

- Both UIs use self-signed TLS. The credentials travel encrypted, but the certificate
  is not trusted by browsers until you install your own certificate.
- Keep `8080` and `8443` on a trusted LAN/VPN. SSUI is the full administration
  interface; the panel can start/stop the server and manage saves.
- The panel runs as the unprivileged `stationeers` user. Only the installer and the
  password reset need root.
- `config.json` and the credentials file contain plaintext secrets; both are `600`.

## Repository layout

- `stationeers.sh` — the single-file installer you copy to the server
- `src/install.sh`, `src/panel.py`, `src/panel.html` — sources
- `build.py` — embeds the panel into the installer (`py -3 build.py`)
- `tests/mock_e2e.py` — panel smoke test against a fake SSUI API
