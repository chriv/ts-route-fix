@echo off
:: ts-route-fix launcher
:: Runs ts-route-fix.ps1 from the same directory.
:: Must be run as Administrator (right-click -> Run as administrator).
::
:: All arguments are passed through to the PowerShell script, e.g.:
::   ts-route-fix.bat -DryRun -Verbose
::   ts-route-fix.bat -Config C:\custom\sites.conf
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ts-route-fix.ps1" %*
