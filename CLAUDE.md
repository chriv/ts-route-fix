# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

`ts-route-fix` solves a Tailscale route conflict problem: when a machine is on a local network whose subnets overlap with Tailscale's advertised routes, the Tailscale routes shadow the local routes. This script detects which "site" the machine is at (home, work, external, etc.) by examining DNS search domains and local IP addresses, then removes conflicting Tailscale routes and restores local routing for those subnets.

The existing working prototype is at `/usr/local/bin/ts-route-fix` (Mac/zsh only, hardcoded routes).

## Target Architecture

The goal is a cross-platform, config-driven version. **All configuration files are gitignored** — only example configs are committed.

```
ts-route-fix/
├── .gitignore
├── CLAUDE.md
├── ts-route-fix.sh          # Main script: Mac + Linux
├── ts-route-fix.ps1         # Main script: Windows PowerShell
├── setup.sh                 # Installer: Mac + Linux
├── setup.ps1                # Installer: Windows
├── config/
│   ├── sites.conf.example   # Committed template (no real networks)
│   └── sites.conf           # Gitignored — user's actual site definitions
└── sudoers.d/
    └── ts-route-fix.example # Example sudoers snippet
```

## Configuration Format

Each line in `sites.conf` defines one site:

```
# FORMAT: SITE_NAME|SEARCH_DOMAINS|LOCAL_IP_PREFIX|ROUTES_TO_RESTORE
# Fields are pipe-delimited. Multiple values within a field are comma-delimited.
# SEARCH_DOMAINS: partial strings matched against /etc/resolv.conf search line
# LOCAL_IP_PREFIX: prefix matched against local IPs (e.g. "10.10." or "192.168.1.")
# ROUTES_TO_RESTORE: CIDR blocks that Tailscale advertises but should use local routing
#
# Example:
# home|example.local,home.lan|10.0.1.|10.0.0.0/24,10.0.1.0/24
# office|corp.example.com|172.16.0.|172.16.0.0/16
```

## Platform-Specific Behavior

| Concern | Mac | Linux | Windows |
|---|---|---|---|
| Tailscale interface | `utun*` (detect via `ifconfig`) | `tailscale0` (usually) | Tailscale TAP adapter |
| Route commands | `route -n delete/add -net` | `ip route del/add` | `route delete/add` or `Remove-NetRoute` |
| Search domain detection | `/etc/resolv.conf` | `/etc/resolv.conf` | `Get-DnsClientGlobalSetting` |
| Tailscale up hook | LaunchDaemon plist or `networksetup` | `/etc/networkd-dispatcher/` or `if-up.d/` | Task Scheduler on network connect |
| sudoers.d | `/etc/sudoers.d/` | `/etc/sudoers.d/` | N/A (Run As) |
| Config location | `/etc/ts-route-fix/` | `/etc/ts-route-fix/` | `%ProgramData%\ts-route-fix\` |
| Install location | `/usr/local/bin/` | `/usr/local/bin/` | `C:\Program Files\ts-route-fix\` |

## Implementation Phases

Work through these in order. Each phase should be fully functional before starting the next.

### Phase 1 — Config-driven Mac/Linux shell script
**Goal:** Replace the hardcoded prototype with a config-file-driven `ts-route-fix.sh` that works on both Mac and Linux.

Key tasks:
- Parse `sites.conf` at runtime (default path: `/etc/ts-route-fix/sites.conf`; override via `$TS_ROUTE_FIX_CONF` env var or `-c` flag)
- Use `uname` to branch Mac vs Linux for interface detection and route commands
- Mac interface detection: `ifconfig | awk` pattern from prototype
- Linux interface detection: `ip -4 addr show tailscale0` or look for the `100.x.x.x` address via `ip addr`
- Mac route ops: `route -n delete/add -net CIDR -interface IF` / `route -n add -net CIDR GW`
- Linux route ops: Tailscale on Linux installs its routes in **routing table 52** (not the main table). Deletions must target that table: `ip route del CIDR table 52`. Additions go into the main table as normal: `ip route add CIDR via GW`. Verify with `ip route show table 52` on a Linux+Tailscale host before implementing.
- Parse search domains from `/etc/resolv.conf` on both platforms
- Fall back to local IP prefix matching when no search domain matches
- Log actions clearly; support `-v` verbose flag and `-n` dry-run flag
- Exit codes: 0 success, 1 no Tailscale interface, 2 no matching site (applies no changes)
- Must be POSIX-compatible `#!/bin/sh` except where platform branching requires bash-isms

### Phase 2 — Windows PowerShell script ✅ Done
**Goal:** `ts-route-fix.ps1` that reads the same `sites.conf` format and performs equivalent route management on Windows.

Key tasks:
- Config location: `%ProgramData%\ts-route-fix\sites.conf` (override via env var)
- Tailscale interface: find adapter whose IP is in `100.64.0.0/10` via `Get-NetIPAddress`
- Default gateway: `Get-NetRoute -DestinationPrefix "0.0.0.0/0"`
- Search domain detection: `(Get-DnsClientGlobalSetting).SuffixSearchList`
- **TODO (Windows fallback):** If the suffix list is empty, also check the machine's primary DNS suffix — Windows populates this from the DHCP-assigned domain name as part of the host FQDN. Candidate API: `[System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName`
- Local IP: `Get-NetIPAddress` filtered for private ranges
- Route ops: `Remove-NetRoute` / `New-NetRoute` (requires elevation)
- Provide a `.bat` launcher shim for contexts that can't call `.ps1` directly

### Phase 3 — Installer scripts
**Goal:** `setup.sh` (Mac/Linux) and `setup.ps1` (Windows) that install everything with a single command.

`setup.sh` tasks:
- Detect OS and verify prerequisites (`tailscale` CLI in PATH)
- Copy `ts-route-fix.sh` to `/usr/local/bin/ts-route-fix` (chmod 755)
- Create `/etc/ts-route-fix/` and copy `sites.conf.example` → `sites.conf` if not present
- Install sudoers drop-in: write `/etc/sudoers.d/ts-route-fix` allowing the current user to run the script as root without password, validated with `visudo -c`
- Prompt user to edit their `sites.conf` before continuing

`setup.ps1` tasks:
- Check for Administrator elevation; re-launch elevated if needed
- Copy script to `C:\Program Files\ts-route-fix\`
- Create config directory and example config

### Phase 4 — Auto-run on Tailscale up
**Goal:** The script runs automatically whenever Tailscale brings up its interface.

Mac approach:
- Create a `LaunchDaemon` plist at `/Library/LaunchDaemons/org.example.ts-route-fix.plist`
- Watch for the Tailscale interface via `WatchPaths` on the Tailscale socket or use `launchd` `NetworkState` key — or simpler: a `LaunchAgent` that polls with a short interval checking if `tailscale status` changed
- Alternative (simpler): use Tailscale's built-in `--up-script` if available in the installed version

Linux approach:
- For `networkd-dispatcher`: install script in `/etc/networkd-dispatcher/routable.d/`
- For `NetworkManager`: install in `/etc/NetworkManager/dispatcher.d/` checking `$2 == "up"` and interface name
- For `systemd`: create a `.service` unit with `ExecStartPost=` or use a path unit watching the Tailscale socket

Windows approach:
- Task Scheduler task triggered on network adapter connect event (Event ID 10000 from `Microsoft-Windows-NetworkProfile`)
- `setup.ps1` creates the task via `Register-ScheduledTask`

### Phase 5 — Hardening, docs, and example configs
- Add a `--uninstall` flag to `setup.sh` / `setup.ps1`
- Write `README.md` with quickstart instructions (no real network info)
- Ensure `sites.conf` and any generated files with real data are in `.gitignore`
- Test matrix: Mac (zsh/bash), Ubuntu (bash), Debian (dash as /bin/sh), Windows 11 (PowerShell 5 and 7)

## Critical Constraints

- **Privacy:** `sites.conf` (and any file containing actual subnet/domain data) must be gitignored. Only `*.example` files are committed. The script itself must not hardcode any network info.
- **No Python dependency:** stick to shell (`/bin/sh` or bash where needed) and PowerShell.
- **sudoers safety:** always validate with `visudo -c` before installing any sudoers file.
- **Idempotency:** running the script multiple times should not stack duplicate routes or fail on already-deleted routes (use `|| true` / `2>/dev/null` for route delete failures).
- **Dry-run first:** when testing route changes on a live machine, always add `-n` (dry-run) support and test that before real runs.

## Key Shell Patterns

OS detection used throughout:
```sh
OS=$(uname -s)
case "$OS" in
  Darwin) ... ;;
  Linux)  ... ;;
  *)      echo "Unsupported OS: $OS"; exit 1 ;;
esac
```

Config parsing (pipe-delimited, skip comments/blanks):
```sh
while IFS='|' read -r name domains ip_prefix routes; do
  case "$name" in ''|\#*) continue ;; esac
  # process fields
done < "$CONF_FILE"
```
