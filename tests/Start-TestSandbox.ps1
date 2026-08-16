# Starts Windows Sandbox with the project mapped in and isolated tests auto-run.
# Safe on the host: the guest cannot write to the project, only to .sandbox-out.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$wsb = Join-Path $PSScriptRoot 'SteamDriveOrder.Sandbox.wsb'
$outDir = Join-Path $root '.sandbox-out'
$sandbox = Join-Path $env:WINDIR 'System32\WindowsSandbox.exe'

if (-not (Test-Path -LiteralPath $sandbox)) {
    throw 'Windows Sandbox is not installed. Enable it in Turn Windows features on or off, then reboot.'
}

New-Item -ItemType Directory -Path $outDir -Force | Out-Null
'WAITING' | Set-Content -LiteralPath (Join-Path $outDir 'result.txt') -Encoding UTF8
Start-Process -FilePath $sandbox -ArgumentList ("`"{0}`"" -f $wsb)
Write-Host "Windows Sandbox starting. Results will land in $outDir\result.txt"
