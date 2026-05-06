#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Site-aware Tailscale route conflict resolver for Windows.
.DESCRIPTION
    Reads sites.conf to determine which site the machine is currently at (via
    DNS suffix search list or local IP prefix), removes conflicting Tailscale
    routes, and restores local routing for that site's subnets. Cleans up stale
    routes from previously-visited sites.

    Mirrors the behavior of ts-route-fix.sh on Mac/Linux.
.PARAMETER Config
    Path to sites.conf.
    Default: $env:ProgramData\ts-route-fix\sites.conf
    Can also be set via $env:TS_ROUTE_FIX_CONF.
.PARAMETER DryRun
    Show what would be done without making any changes.
.PARAMETER Quiet
    Suppress error output from route operations (useful for unattended runs).
.EXAMPLE
    .\ts-route-fix.ps1 -DryRun -Verbose
.EXAMPLE
    .\ts-route-fix.ps1 -Config C:\custom\sites.conf
#>
[CmdletBinding()]
param(
    [string]$Config = $(
        if ($env:TS_ROUTE_FIX_CONF) { $env:TS_ROUTE_FIX_CONF }
        else { Join-Path $env:ProgramData 'ts-route-fix\sites.conf' }
    ),
    [switch]$DryRun,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── Logging ───────────────────────────────────────────────────────────────────────

function Write-Log([string]$Message) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "ts-route-fix: [$ts] $Message"
}

function Write-Dbg([string]$Message) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Verbose "ts-route-fix: [$ts] $Message"
}

function Stop-WithError([string]$Message) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    [Console]::Error.WriteLine("ts-route-fix: [$ts] ERROR: $Message")
    exit 1
}

# ── Tailscale CGNAT Range Check ───────────────────────────────────────────────────

function Test-IsTailscaleIP([string]$IP) {
    # Tailscale uses 100.64.0.0/10 (100.64.x.x through 100.127.x.x)
    $parts = $IP -split '\.'
    if ($parts.Count -lt 2 -or $parts[0] -ne '100') { return $false }
    $octet2 = [int]$parts[1]
    return ($octet2 -ge 64 -and $octet2 -le 127)
}

# ── Interface & Gateway Detection ─────────────────────────────────────────────────

function Get-TailscaleAdapter {
    $addr = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { Test-IsTailscaleIP $_.IPAddress } |
        Select-Object -First 1
    if (-not $addr) { return $null }
    return Get-NetAdapter -InterfaceIndex $addr.InterfaceIndex -ErrorAction SilentlyContinue
}

function Get-DefaultRoute([int]$ExcludeIfIndex = -1) {
    # Find the lowest-metric default route that isn't the Tailscale interface,
    # so we target the physical uplink even when Tailscale is an exit node.
    Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne '0.0.0.0' -and $_.InterfaceIndex -ne $ExcludeIfIndex } |
        Sort-Object RouteMetric |
        Select-Object -First 1
}

function Get-LocalIPs {
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $ip = $_.IPAddress
            $ip -notlike '127.*' -and
            $ip -notlike '169.254.*' -and
            -not (Test-IsTailscaleIP $ip)
        } |
        Select-Object -ExpandProperty IPAddress
}

function Get-SearchDomains {
    try { (Get-DnsClientGlobalSetting).SuffixSearchList }
    catch { @() }
}
# TODO: Windows fallback — if SuffixSearchList is empty or unreliable, also check
# the host's primary DNS suffix, which DHCP-assigned domains populate as part of
# the machine's FQDN. Candidate:
#   [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName
# This would let site detection work even when the global suffix list isn't set.

# ── Site Matching ─────────────────────────────────────────────────────────────────

function Test-DomainsMatch([string[]]$SearchDomains, [string[]]$Needles) {
    $haystack = $SearchDomains -join ' '
    foreach ($needle in $Needles) {
        if ($needle -and $haystack -like "*$needle*") { return $true }
    }
    return $false
}

function Test-IPPrefixMatch([string[]]$IPs, [string[]]$Prefixes) {
    foreach ($ip in $IPs) {
        foreach ($prefix in $Prefixes) {
            if ($prefix -and $ip.StartsWith($prefix)) { return $true }
        }
    }
    return $false
}

# ── Route Operations ──────────────────────────────────────────────────────────────

function Invoke-TsRouteDel([string]$CIDR, [int]$IfIndex, [string]$IfName) {
    Write-Log "  Removing $CIDR from $IfName"
    if ($DryRun) {
        Write-Log "  [DRY-RUN] Remove-NetRoute -DestinationPrefix $CIDR -InterfaceIndex $IfIndex"
        return
    }
    Write-Dbg "  + Remove-NetRoute -DestinationPrefix $CIDR -InterfaceIndex $IfIndex"
    try {
        Remove-NetRoute -DestinationPrefix $CIDR -InterfaceIndex $IfIndex `
            -Confirm:$false -ErrorAction Stop
    } catch {
        if (-not $Quiet) { Write-Log "    (remove: $($_.Exception.Message))" }
    }
}

function Invoke-GwRouteAdd([string]$CIDR, [int]$IfIndex, [string]$NextHop) {
    Write-Log "  Adding $CIDR via $NextHop"
    if ($DryRun) {
        Write-Log "  [DRY-RUN] New-NetRoute -DestinationPrefix $CIDR -InterfaceIndex $IfIndex -NextHop $NextHop"
        return
    }
    Write-Dbg "  + New-NetRoute -DestinationPrefix $CIDR -InterfaceIndex $IfIndex -NextHop $NextHop"
    try {
        New-NetRoute -DestinationPrefix $CIDR -InterfaceIndex $IfIndex `
            -NextHop $NextHop -ErrorAction Stop
    } catch {
        if (-not $Quiet) { Write-Log "    (add: $($_.Exception.Message))" }
    }
}

function Invoke-RouteDelAny([string]$CIDR, [int]$IfIndex) {
    Write-Dbg "  Cleaning up stale route $CIDR"
    if ($DryRun) {
        Write-Dbg "  [DRY-RUN] Remove-NetRoute -DestinationPrefix $CIDR -InterfaceIndex $IfIndex"
        return
    }
    try {
        Remove-NetRoute -DestinationPrefix $CIDR -InterfaceIndex $IfIndex `
            -Confirm:$false -ErrorAction Stop
    } catch {
        # Route didn't exist — expected during cleanup, not an error
    }
}

# ── Config Parsing ────────────────────────────────────────────────────────────────

function Read-SitesConf([string]$Path) {
    $sites = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($line in Get-Content $Path) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $fields = $line -split '\|', 5
        if ($fields.Count -lt 4) { continue }
        $sites.Add(@{
            Name     = $fields[0]
            Domains  = if ($fields[1]) { @($fields[1] -split ',' | Where-Object { $_ }) } else { @() }
            IPPrefix = if ($fields[2]) { @($fields[2] -split ',' | Where-Object { $_ }) } else { @() }
            TsRemove = if ($fields[3]) { @($fields[3] -split ',' | Where-Object { $_ }) } else { @() }
            GwAdd    = if ($fields.Count -ge 5 -and $fields[4]) {
                           @($fields[4] -split ',' | Where-Object { $_ })
                       } else { @() }
        })
    }
    return $sites
}

# ── Main ──────────────────────────────────────────────────────────────────────────

if (-not (Test-Path $Config)) {
    Stop-WithError "Config not found: $Config  (set `$env:TS_ROUTE_FIX_CONF or use -Config)"
}

$tsAdapter = Get-TailscaleAdapter
if (-not $tsAdapter) {
    # TODO: sh version exits silently (verbose-only) when Tailscale is not running,
    # so daemon polling produces no log noise. Stop-WithError is appropriate for
    # interactive use but kills the Task Scheduler run with a non-zero exit on every
    # poll when TS happens to be down. Consider: if (-not $DryRun) { exit 0 } else
    # { Stop-WithError ... } — or check $env:SESSIONNAME to distinguish interactive
    # vs scheduled runs.
    Stop-WithError "Tailscale interface not found — is Tailscale running?"
}
$tsIfIndex = $tsAdapter.InterfaceIndex
$tsIfName  = $tsAdapter.Name

$defaultRoute = Get-DefaultRoute -ExcludeIfIndex $tsIfIndex
if (-not $defaultRoute) {
    Stop-WithError "No default gateway found"
}
$physIfIndex = $defaultRoute.InterfaceIndex
$defaultGW   = $defaultRoute.NextHop

$searchDomains = @(Get-SearchDomains)
$localIPs      = @(Get-LocalIPs)

Write-Log "Tailscale interface : $tsIfName (index $tsIfIndex)"
Write-Log "Default gateway     : $defaultGW (interface index $physIfIndex)"
Write-Dbg "Search domains      : $($searchDomains -join ', ')"
Write-Dbg "Local IPs           : $($localIPs -join ', ')"

$sites = Read-SitesConf $Config

# ── Pass 1: Find the current site ────────────────────────────────────────────────

$matchedSite = $null
foreach ($site in $sites) {
    $matched = $false
    if ($site.Domains.Count -gt 0 -and $searchDomains.Count -gt 0) {
        $matched = Test-DomainsMatch $searchDomains $site.Domains
    }
    if (-not $matched -and $site.IPPrefix.Count -gt 0 -and $localIPs.Count -gt 0) {
        $matched = Test-IPPrefixMatch $localIPs $site.IPPrefix
    }
    if ($matched) { $matchedSite = $site; break }
}

# ── Pass 2: Apply or report ───────────────────────────────────────────────────────
#
# TODO (parity with ts-route-fix.sh): Two differences to resolve when testing on Windows:
#
# 1. Route pre-check — the sh version reads the route table once and exits silently
#    if the configured routes are already correct (the common polling case). This
#    prevents log noise and avoids unnecessary route commands. The equivalent here
#    would be Get-NetRoute filtered to the TS interface index and checked against
#    $matchedSite.TsRemove before proceeding. See _needs_fix() in ts-route-fix.sh
#    for the reference logic.
#
# 2. Silent exit when no site matches — the sh version calls Write-Dbg (verbose-only)
#    and exits 0 when no site matched. Write-Log below produces output on every Task
#    Scheduler run when away from all configured sites, which pollutes any log
#    capturing task output. Change Write-Log to Write-Dbg here once Windows testing
#    confirms the rest of the flow is working correctly.

if (-not $matchedSite) {
    # TODO: change to Write-Dbg for parity with sh silent-when-unmatched behavior
    Write-Log "Location: EXTERNAL (no configured site matched)"
} else {
    Write-Log "Location: $($matchedSite.Name) — fixing routes"
    foreach ($cidr in $matchedSite.TsRemove) {
        Invoke-TsRouteDel $cidr $tsIfIndex $tsIfName
    }
    foreach ($cidr in $matchedSite.GwAdd) {
        Invoke-GwRouteAdd $cidr $physIfIndex $defaultGW
    }
}

# ── Pass 3: Clean up stale GW routes from non-matched sites ──────────────────────

foreach ($site in $sites) {
    if ($matchedSite -and $site.Name -eq $matchedSite.Name) { continue }
    foreach ($cidr in $site.GwAdd) {
        Invoke-RouteDelAny $cidr $physIfIndex
    }
}

Write-Log "Done."
