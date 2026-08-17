# Builds the shippable WinForms executable with ps2exe (no extra runtime).
# Output: SteamDriveOrder.exe in the repo root.

[CmdletBinding()]
param(
    [string]$Version = '1.0.0'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$resources = Split-Path -Parent $PSScriptRoot
$root = Split-Path -Parent $resources
$icon = Join-Path $resources 'assets\app.ico'
$source = Join-Path $resources 'SteamDriveOrder.ps1'
$output = Join-Path $root 'SteamDriveOrder.exe'

if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {
    Import-Module ps2exe -ErrorAction Stop
}

function New-AppIcon {
    param([string]$Path)
    Add-Type -AssemblyName System.Drawing
    $sizes = @(16, 32, 48, 256)
    $pngs = New-Object System.Collections.Generic.List[byte[]]
    foreach ($size in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap $size, $size
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::FromArgb(27, 32, 40))
        $accent = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(26, 159, 255))
        $card = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(45, 50, 58))
        $barH = [Math]::Max(2, [int]($size * 0.07))
        $g.FillRectangle($accent, 0, 0, $size, $barH)
        $pad = [Math]::Max(2, [int]($size * 0.16))
        $gap = [Math]::Max(1, [int]($size * 0.08))
        $slotH = [int](($size - $pad - $barH - (2 * $gap) - $pad) / 3)
        if ($slotH -lt 2) { $slotH = 2 }
        $y = $barH + $pad
        for ($i = 0; $i -lt 3; $i++) {
            $w = $size - ($pad * 2) - ($i * [Math]::Max(1, [int]($size * 0.08)))
            $g.FillRectangle($card, $pad, $y, $w, $slotH)
            $g.FillRectangle($accent, $pad, $y, [Math]::Max(1, [int]($size * 0.08)), $slotH)
            $y += $slotH + $gap
        }
        $g.Dispose()
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngs.Add($ms.ToArray())
        $bmp.Dispose()
        $ms.Dispose()
        $accent.Dispose()
        $card.Dispose()
    }

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $fs = [System.IO.File]::Create($Path)
    $bw = New-Object System.IO.BinaryWriter $fs
    $bw.Write([uint16]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]$pngs.Count)
    $offset = 6 + (16 * $pngs.Count)
    for ($i = 0; $i -lt $pngs.Count; $i++) {
        $dim = $sizes[$i]
        $bw.Write([byte]$(if ($dim -ge 256) { 0 } else { $dim }))
        $bw.Write([byte]$(if ($dim -ge 256) { 0 } else { $dim }))
        $bw.Write([byte]0)
        $bw.Write([byte]0)
        $bw.Write([uint16]1)
        $bw.Write([uint16]32)
        $bw.Write([uint32]$pngs[$i].Length)
        $bw.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($png in $pngs) { $bw.Write($png) }
    $bw.Flush()
    $fs.Dispose()
}

if (-not (Test-Path -LiteralPath $icon)) {
    New-AppIcon -Path $icon
}

Write-Host 'Building SteamDriveOrder.exe...'
Invoke-ps2exe -inputFile $source -outputFile $output `
    -iconFile $icon `
    -noConsole `
    -STA `
    -DPIAware `
    -supportOS `
    -UNICODEEncoding `
    -noOutput `
    -title 'SteamDriveOrder' `
    -description 'Reorder Steam Install To / Storage drives' `
    -company "Garrett's Project" `
    -product 'SteamDriveOrder' `
    -copyright 'MIT' `
    -version $Version

Get-Item $output | ForEach-Object {
    Write-Host ("{0}  {1:N1} KB" -f $_.Name, ($_.Length / 1KB))
}
Write-Host 'Done.'
