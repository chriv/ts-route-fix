<#
.SYNOPSIS
    Installer for ts-route-fix on Windows.
.DESCRIPTION
    Copies ts-route-fix.ps1 and ts-route-fix.bat to C:\Program Files\ts-route-fix\,
    creates the config directory, seeds an example sites.conf if none exists,
    adds the install directory to the system PATH, and registers a Task Scheduler
    task so ts-route-fix runs automatically when a network profile connects.

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

# ── Task Scheduler ───────────────────────────────────────────────────────────────
#
# Register a task that fires on Event 10000 (network profile connected) with a
# 5-second delay to let Tailscale finish establishing its routes before we run.
# Runs as SYSTEM so no interactive session is required.

Write-Setup 'Registering Task Scheduler task...'

$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[EventID=10000]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
      <Delay>PT5S</Delay>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <LogonType>ServiceAccount</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT2M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions>
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File "$installDir\ts-route-fix.ps1" -Quiet</Arguments>
      <WorkingDirectory>$installDir</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

try {
    Register-ScheduledTask -TaskName 'ts-route-fix' -Xml $taskXml -Force | Out-Null
    Write-Setup '  Task registered — ts-route-fix will run when a network profile connects.'
    Write-Setup '  (5-second delay after connect to let Tailscale routes settle)'
} catch {
    Write-SetupWarn "Could not register Task Scheduler task: $_"
    Write-SetupWarn 'Register manually via Task Scheduler:'
    Write-SetupWarn '  Trigger: Event, Log=Microsoft-Windows-NetworkProfile/Operational, ID=10000'
    Write-SetupWarn "  Action:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$installDir\ts-route-fix.ps1`" -Quiet"
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
