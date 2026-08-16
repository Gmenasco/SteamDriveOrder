# Runs inside Windows Sandbox. Writes results to C:\SandboxOut on the guest
# (mapped to .sandbox-out on the host). Does not touch the host Steam install.

$ErrorActionPreference = 'Stop'
$outDir = 'C:\SandboxOut'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$result = Join-Path $outDir 'result.txt'
$log = Join-Path $outDir 'log.txt'

function Write-Result {
    param([string]$Text)
    $Text | Set-Content -LiteralPath $result -Encoding UTF8
}

try {
    Start-Transcript -LiteralPath $log -Force | Out-Null
    Write-Result 'STARTING'
    Write-Host 'Building fake Steam + D/E/F drives...'
    & (Join-Path $PSScriptRoot 'New-FakeSteamEnv.ps1') -IAmATestVm
    Write-Result 'FAKE_STEAM_READY'
    Write-Host 'Running isolated VDF tests...'
    & (Join-Path $PSScriptRoot 'Vdf.Tests.ps1')
    Write-Result 'PASS'
    Write-Host 'Sandbox tests passed.'
}
catch {
    Write-Result ("FAIL: " + $_.Exception.Message)
    throw
}
finally {
    Stop-Transcript | Out-Null
}
