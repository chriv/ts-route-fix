# ts-route-fix

Fixes Tailscale route conflicts when a local network's subnets overlap with routes Tailscale advertises. Detects which site you're at and removes the conflicting Tailscale routes, restoring local routing for those subnets. When you move to a different site, stale local routes are cleaned up automatically.

## The problem

Tailscale lets exit nodes and subnet routers advertise routes to the whole tailnet. If you're physically on one of those networks, Tailscale's route for that subnet shadows your local routing — traffic that should stay on the LAN goes through the tunnel instead.

## How it works

A `sites.conf` file defines each known location: which DNS search domains (or local IP prefixes) identify it, which Tailscale-advertised routes to remove, and which of those routes to explicitly re-add via the local gateway. On each run:

1. **Detect site** — match `/etc/resolv.conf` search domains, fall back to local IP prefix
2. **Fix routes** — delete matched routes from the Tailscale interface; re-add via local gateway where needed
3. **Clean up** — remove any locally-added routes from other sites (handles moving between locations)

If no configured site matches, the script reports `EXTERNAL` and still cleans up stale routes.

## Requirements

- Tailscale running with subnet routes advertised
- macOS or Linux: `root` / `sudo` for route modifications
- Windows: Administrator privileges; PowerShell 5.1+ (ships with Windows 10/11)

## Configuration

Copy the example and edit:

```sh
sudo mkdir -p /etc/ts-route-fix
sudo cp config/sites.conf.example /etc/ts-route-fix/sites.conf
sudo $EDITOR /etc/ts-route-fix/sites.conf
```

Each line in `sites.conf` defines one site (pipe-delimited, five fields):

```
SITE_NAME | SEARCH_DOMAINS | LOCAL_IP_PREFIX | TS_REMOVE_ROUTES | GW_ADD_ROUTES
```

| Field | Description |
|---|---|
| `SITE_NAME` | Label shown in log output |
| `SEARCH_DOMAINS` | Comma-separated strings matched against `/etc/resolv.conf` search line |
| `LOCAL_IP_PREFIX` | Comma-separated IP prefixes for fallback detection (e.g. `192.168.1.`) |
| `TS_REMOVE_ROUTES` | Comma-separated CIDRs to delete from the Tailscale interface |
| `GW_ADD_ROUTES` | Comma-separated CIDRs to re-add via local gateway (omit if directly-connected routing suffices) |

The routes in `TS_REMOVE_ROUTES` come from whatever your subnet routers are configured to advertise in your tailnet — this tool doesn't assume anything about that. You may have one site or many; any number of sites can be defined.

Example with three sites:

```
# Removed from Tailscale and re-added via local gateway:
site1|site1.example.com|192.168.1.|192.168.1.0/24,192.168.2.0/24|192.168.1.0/24,192.168.2.0/24

# Removed from Tailscale only (directly-connected routing handles the rest):
site2|site2.example.com|10.1.0.|10.1.0.0/24,10.1.1.0/24|

# Many subnets, multiple detection domains:
site3|site3.example.com,site3.example.internal|172.16.0.|172.16.0.0/24,172.16.1.0/24,172.16.2.0/24|172.16.0.0/24,172.16.1.0/24,172.16.2.0/24
```

Lines starting with `#` and blank lines are ignored. The config file is gitignored by design — see `config/sites.conf.example` for the full format reference.

## Usage

### macOS / Linux

```
sudo ts-route-fix [-c config_file] [-n] [-q] [-v]
```

| Flag | Description |
|---|---|
| `-c path` | Path to `sites.conf` (default: `/etc/ts-route-fix/sites.conf`) |
| `-n` | Dry-run: print what would be done without executing |
| `-q` | Quiet: suppress output from route commands (useful for unattended/hook runs) |
| `-v` | Verbose: show interface/IP details and each command run |

Config path can also be set via `$TS_ROUTE_FIX_CONF`.

Quick test before first real run:

```sh
sudo ts-route-fix -n -v
```

### Windows

Run PowerShell or `ts-route-fix.bat` as Administrator.

```powershell
.\ts-route-fix.ps1 [-Config path] [-DryRun] [-Quiet] [-Verbose]
```

| Parameter | Description |
|---|---|
| `-Config path` | Path to `sites.conf` (default: `%ProgramData%\ts-route-fix\sites.conf`) |
| `-DryRun` | Print what would be done without executing |
| `-Quiet` | Suppress error output from route operations |
| `-Verbose` | Show interface/IP details and each command run |

Config path can also be set via `$env:TS_ROUTE_FIX_CONF`.

Quick test before first real run:

```powershell
.\ts-route-fix.ps1 -DryRun -Verbose
```

The `.bat` launcher is provided for contexts that can't invoke `.ps1` directly (Task Scheduler, some automation tools):

```
ts-route-fix.bat -DryRun -Verbose
```

## Installation

### macOS / Linux

```sh
sudo ./setup.sh
```

`setup.sh` installs the script to `/usr/local/bin/ts-route-fix`, creates `/etc/ts-route-fix/`, seeds an example `sites.conf` if none exists, and installs a sudoers drop-in so you can run it without a password prompt. Run it from the repo directory as shown above.

### Windows

Run `setup.ps1` from the repo directory in an Administrator PowerShell session (or double-click — it will re-launch elevated automatically):

```powershell
.\setup.ps1
```

`setup.ps1` copies the scripts to `C:\Program Files\ts-route-fix\`, creates `%ProgramData%\ts-route-fix\`, seeds an example `sites.conf` if none exists, and adds the install directory to the system PATH.

### After installation

Edit your site definitions, then do a dry-run before the first real run:

```sh
# macOS / Linux
${EDITOR:-vi} /etc/ts-route-fix/sites.conf
sudo ts-route-fix -n -v
```

```powershell
# Windows (as Administrator)
notepad "$env:ProgramData\ts-route-fix\sites.conf"
ts-route-fix.bat -DryRun -Verbose
```

## Project status

| Phase | Status | Description |
|---|---|---|
| 1 | ✅ Done | Config-driven Mac + Linux shell script |
| 2 | ✅ Done | Windows PowerShell (`ts-route-fix.ps1` + `ts-route-fix.bat`) |
| 3 | ✅ Done | Installer scripts (`setup.sh` / `setup.ps1`) |
| 4 | Planned | Auto-run on Tailscale up (LaunchDaemon / networkd-dispatcher / Task Scheduler) |
| 5 | Planned | Uninstall, test matrix, hardening |

## Security notes

`sites.conf` is gitignored. Only `config/sites.conf.example` (with fictional networks) is committed. Never put real subnet or domain data in any committed file.
