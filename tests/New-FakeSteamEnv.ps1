# Builds a fake Steam install + D/E/F libraries inside a blank test VM or Windows Sandbox.
# Refuses to run on the host PC.

[CmdletBinding()]
param(
    [switch]$IAmATestVm,
    [string]$Root = 'C:\SteamDriveOrderFake'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-HostFingerprint {
    $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)
    foreach ($disk in $disks) {
        $letter = ([string]$disk.DeviceID).TrimEnd(':')
        $label = [string]$disk.VolumeName
        if ($letter -eq 'D' -and $label -eq 'M2 SSD') { return $true }
        if ($letter -eq 'E' -and $label -eq 'SATA SSD') { return $true }
        if ($letter -eq 'F' -and $label -eq 'HDD' -and [double]$disk.Size -gt 1TB) { return $true }
    }
    $realSteam = 'C:\Program Files (x86)\Steam\steam.exe'
    if (Test-Path -LiteralPath $realSteam) {
        $len = (Get-Item -LiteralPath $realSteam).Length
        if ($len -gt 1MB) { return $true }
    }
    return $false
}

if (-not $IAmATestVm) {
    throw 'This only builds a fake Steam world inside a test VM. Pass -IAmATestVm from Windows Sandbox or a blank Hyper-V VM.'
}
if (Test-HostFingerprint) {
    throw 'This looks like the host PC (real Steam or labeled D/E/F drives). Refusing to run here.'
}

$sample = Join-Path $PSScriptRoot 'libraryfolders.sample.vdf'
if (-not (Test-Path -LiteralPath $sample)) {
    throw "Missing $sample"
}

New-Item -ItemType Directory -Path $Root -Force | Out-Null

$needed = @('D', 'E', 'F')
$mapped = @()
foreach ($letter in $needed) {
    $existing = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
    if ($existing) { continue }
    $driveDir = Join-Path $Root "drives\$letter"
    New-Item -ItemType Directory -Path $driveDir -Force | Out-Null
    subst "${letter}:" $driveDir
    if ($LASTEXITCODE -ne 0) {
        throw "Could not map ${letter}: as a fake drive."
    }
    $mapped += $letter
}

foreach ($letter in $needed) {
    $lib = "${letter}:\SteamLibrary"
    New-Item -ItemType Directory -Path $lib -Force | Out-Null
}

$steam = 'C:\Program Files (x86)\Steam'
New-Item -ItemType Directory -Path (Join-Path $steam 'config') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $steam 'steamapps') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $steam 'steam.exe') -Value 'fake-steam' -Encoding ASCII
Copy-Item -LiteralPath $sample -Destination (Join-Path $steam 'config\libraryfolders.vdf') -Force
Copy-Item -LiteralPath $sample -Destination (Join-Path $steam 'steamapps\libraryfolders.vdf') -Force

$reg = 'HKCU:\Software\Valve\Steam'
if (-not (Test-Path $reg)) {
    New-Item -Path $reg -Force | Out-Null
}
Set-ItemProperty -Path $reg -Name SteamPath -Value $steam
Set-ItemProperty -Path $reg -Name RunningAppID -Value 0

Write-Host "Fake Steam is ready at $steam"
if ($mapped.Count -gt 0) {
    Write-Host ("Mapped fake drives: " + (($mapped | ForEach-Object { "${_}:" }) -join ', '))
}
Write-Host 'Libraries:'
Write-Host '  C:\Program Files (x86)\Steam'
Write-Host '  D:\SteamLibrary'
Write-Host '  E:\SteamLibrary'
Write-Host '  F:\SteamLibrary'
Write-Host ''
Write-Host 'Run the app against this fake install:'
Write-Host '  powershell -ExecutionPolicy Bypass -File C:\SteamDriveOrder\SteamDriveOrder.ps1 -SteamRoot "C:\Program Files (x86)\Steam"'
