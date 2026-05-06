<#
.SYNOPSIS
    Installer for ts-route-fix on Windows.
.DESCRIPTION
    Copies ts-route-fix.ps1 and ts-route-fix.bat to C:\Program Files\ts-route-fix\,
    creates the config directory, seeds an example sites.conf if none exists,
    and adds the install directory to the system PATH.

    Re-launches itself elevated if not already running as Administrator.
.EXAMPLE
    .\setup.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Elevation ─────────────────────────────────────────────────────────────────────

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'setup: Not running as Administrator — relaunching elevated...'
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process powershell.exe -ArgumentList $args -Verb RunAs
    exit
}

$installDir = 'C:\Program Files\ts-route-fix'
$configDir  = Join-Path $env:ProgramData 'ts-route-fix'
$configFile = Join-Path $configDir 'sites.conf'
$scriptDir  = $PSScriptRoot

function Write-Setup {
    param([string]$Message = '')
    if ($Message) { Write-Host "setup: $Message" } else { Write-Host '' }
}

function Write-SetupWarn([string]$Message) {
    Write-Warning "setup: $Message"
}

# ── Preflight ─────────────────────────────────────────────────────────────────────

if (-not (Test-Path (Join-Path $scriptDir 'ts-route-fix.ps1'))) {
    Write-Error "setup: ts-route-fix.ps1 not found in $scriptDir — run setup.ps1 from the repo directory"
    exit 1
}

if (-not (Get-Command tailscale -ErrorAction SilentlyContinue)) {
    Write-SetupWarn "'tailscale' not found in PATH. Install Tailscale before using ts-route-fix."
}

# ── Install scripts ───────────────────────────────────────────────────────────────

Write-Setup "Installing ts-route-fix to $installDir..."
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
Copy-Item (Join-Path $scriptDir 'ts-route-fix.ps1') (Join-Path $installDir 'ts-route-fix.ps1') -Force
Copy-Item (Join-Path $scriptDir 'ts-route-fix.bat') (Join-Path $installDir 'ts-route-fix.bat') -Force
Write-Setup '  Done.'

# ── Config directory ──────────────────────────────────────────────────────────────

Write-Setup "Creating config directory $configDir..."
New-Item -ItemType Directory -Force -Path $configDir | Out-Null

if (Test-Path $configFile) {
    Write-Setup "  $configFile already exists — leaving it in place."
} else {
    Copy-Item (Join-Path $scriptDir 'config\sites.conf.example') $configFile
    Write-Setup "  Copied sites.conf.example to $configFile."
}

# ── System PATH ───────────────────────────────────────────────────────────────────

$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($machinePath -notlike "*$installDir*") {
    Write-Setup "Adding $installDir to system PATH..."
    [Environment]::SetEnvironmentVariable('Path', "$machinePath;$installDir", 'Machine')
    Write-Setup '  Done. Restart your terminal for the PATH change to take effect.'
} else {
    Write-Setup "$installDir is already in system PATH."
}

# ── Done ──────────────────────────────────────────────────────────────────────────

Write-Setup
Write-Setup 'Installation complete.'
Write-Setup
Write-Setup '  Edit your site definitions:'
Write-Setup "    notepad `"$configFile`""
Write-Setup
Write-Setup '  Then test before your first real run (as Administrator):'
Write-Setup '    ts-route-fix.bat -DryRun -Verbose'
Write-Setup
