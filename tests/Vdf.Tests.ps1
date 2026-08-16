$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'SteamDriveOrder.ps1') -SkipMain

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ($Expected -ne $Actual) {
        throw "FAIL ${Name}: expected '$Expected', got '$Actual'"
    }
    Write-Host "PASS $Name"
}

$samplePath = Join-Path $PSScriptRoot 'libraryfolders.sample.vdf'
$text = [System.IO.File]::ReadAllText($samplePath)
$parsed = ConvertFrom-SteamVdf -Text $text
$entries = Get-LibraryEntries -Root $parsed
$paths = @($entries.Libraries | ForEach-Object { $_.Path })

Assert-Equal 'C:\Program Files (x86)\Steam' $paths[0] 'sample index 0 is C'
Assert-Equal 'E:\SteamLibrary' $paths[1] 'sample index 1 is E'
Assert-Equal 'D:\SteamLibrary' $paths[2] 'sample index 2 is D'
Assert-Equal 'F:\SteamLibrary' $paths[3] 'sample index 3 is F'

$sorted = Sort-LibrariesByDrive -Libraries $entries.Libraries
$sortedPaths = @($sorted | ForEach-Object { $_.Path })
Assert-Equal 'C:\Program Files (x86)\Steam' $sortedPaths[0] 'sorted 0 is C'
Assert-Equal 'D:\SteamLibrary' $sortedPaths[1] 'sorted 1 is D'
Assert-Equal 'E:\SteamLibrary' $sortedPaths[2] 'sorted 2 is E'
Assert-Equal 'F:\SteamLibrary' $sortedPaths[3] 'sorted 3 is F'

$kept = Sort-LibrariesByDrive -Libraries $entries.Libraries -KeepFirstPath 'C:\Program Files (x86)\Steam'
Assert-Equal 'C:\Program Files (x86)\Steam' $kept[0].Path 'keep-first leaves C first'
Assert-Equal 'D:\SteamLibrary' $kept[1].Path 'keep-first sorts remaining to D'

$rebuilt = New-LibraryRoot -Meta $entries.Meta -Libraries $sorted
$written = ConvertTo-SteamVdf -Root $rebuilt
$roundTrip = Get-LibraryEntries -Root (ConvertFrom-SteamVdf -Text $written)
$rtPaths = @($roundTrip.Libraries | ForEach-Object { $_.Path })
Assert-Equal 'D:\SteamLibrary' $rtPaths[1] 'round-trip keeps D second'
Assert-Equal '333' $roundTrip.Libraries[1].Block['contentid'] 'contentid stays with D'
Assert-Equal '200' $roundTrip.Libraries[1].Block['apps']['223850'] 'apps stay with D'
Assert-Equal '222' $roundTrip.Libraries[2].Block['contentid'] 'contentid stays with E'

Assert-Equal 'C' (Get-PathDriveLetter 'C:\Program Files (x86)\Steam') 'drive letter C'
Assert-Equal 'D' (Get-PathDriveLetter 'D:\SteamLibrary') 'drive letter D'

Assert-Equal '512 GB' (Format-Gib (512GB)) 'format 512 GB'
Assert-Equal '1.00 TB' (Format-Gib (1024GB)) 'format 1024 GB as TB'
Assert-Equal '1.50 TB' (Format-Gib (1536GB)) 'format 1.50 TB'

$script:Libraries = New-Object System.Collections.Generic.List[object]
foreach ($lib in $entries.Libraries) { $script:Libraries.Add($lib) }
Move-LibraryInList -From 1 -To 2
Assert-Equal 'D:\SteamLibrary' $script:Libraries[1].Path 'move E past D'
Assert-Equal 'E:\SteamLibrary' $script:Libraries[2].Path 'E lands in slot 3'
Assert-Equal '333' $script:Libraries[1].Block['contentid'] 'moved block keeps D contentid'

$fakeRoot = Join-Path $env:TEMP ("SteamDriveOrder-tests-" + [guid]::NewGuid().ToString('N'))
$fakeSteam = Join-Path $fakeRoot 'Steam'
New-Item -ItemType Directory -Path (Join-Path $fakeSteam 'config') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fakeSteam 'steamapps') -Force | Out-Null
Copy-Item -LiteralPath $samplePath -Destination (Join-Path $fakeSteam 'config\libraryfolders.vdf')
Copy-Item -LiteralPath $samplePath -Destination (Join-Path $fakeSteam 'steamapps\libraryfolders.vdf')
Set-Content -LiteralPath (Join-Path $fakeSteam 'steam.exe') -Value 'fake-steam' -Encoding ASCII

$vdfPaths = Get-LibraryVdfPaths -SteamPath $fakeSteam
$hashBefore = (Get-FileHash -LiteralPath $vdfPaths.Config).Hash + '|' + (Get-FileHash -LiteralPath $vdfPaths.SteamApps).Hash
$script:DummyMode = $true
$dummyResult = Save-LibraryOrder -SteamPath $fakeSteam -Meta $entries.Meta -Libraries $sorted
$hashAfterDummy = (Get-FileHash -LiteralPath $vdfPaths.Config).Hash + '|' + (Get-FileHash -LiteralPath $vdfPaths.SteamApps).Hash
Assert-Equal $true ($dummyResult -like '*dummy*') 'dummy apply reports dummy'
Assert-Equal $hashBefore $hashAfterDummy 'dummy apply does not change fake VDF files'

$script:DummyMode = $false
$backup = Save-LibraryOrder -SteamPath $fakeSteam -Meta $entries.Meta -Libraries $sorted
$writtenDisk = Get-LibraryEntries -Root (ConvertFrom-SteamVdf -Text ([System.IO.File]::ReadAllText($vdfPaths.Config)))
$appsDisk = Get-LibraryEntries -Root (ConvertFrom-SteamVdf -Text ([System.IO.File]::ReadAllText($vdfPaths.SteamApps)))
Assert-Equal 'D:\SteamLibrary' $writtenDisk.Libraries[1].Path 'live write puts D second in config'
Assert-Equal 'D:\SteamLibrary' $appsDisk.Libraries[1].Path 'live write puts D second in steamapps'
Assert-Equal $true (Test-Path -LiteralPath $backup) 'backup folder created'
Assert-Equal $true (Test-Path -LiteralPath (Join-Path $backup 'config-libraryfolders.vdf')) 'config backup saved'

$script:SteamPath = $fakeSteam
$script:Meta = $entries.Meta
$script:Libraries = New-Object System.Collections.Generic.List[object]
foreach ($lib in $entries.Libraries) { $script:Libraries.Add($lib) }
$sortFromClosure = { Invoke-SortLibrariesAz }.GetNewClosure()
& $sortFromClosure
Assert-Equal 'D:\SteamLibrary' $script:Libraries[1].Path 'Sort A-Z from UI closure puts D second'
Assert-Equal 'Alphabetical' $script:UiMode 'Sort A-Z from UI closure sets mode'

Copy-Item -LiteralPath $samplePath -Destination $vdfPaths.Config -Force
Copy-Item -LiteralPath $samplePath -Destination $vdfPaths.SteamApps -Force
$script:DummyMode = $true
$applyFromClosure = { Invoke-UiApplyOrder }.GetNewClosure()
$closureDummy = & $applyFromClosure
Assert-Equal $true ($closureDummy -like '*dummy*') 'Test Apply from UI closure stays dummy'

$script:DummyMode = $false
$closureBackup = & $applyFromClosure
$closureWritten = Get-LibraryEntries -Root (ConvertFrom-SteamVdf -Text ([System.IO.File]::ReadAllText($vdfPaths.Config)))
Assert-Equal 'D:\SteamLibrary' $closureWritten.Libraries[1].Path 'Test Apply from UI closure writes sorted order'
Assert-Equal $true (Test-Path -LiteralPath $closureBackup) 'Test Apply from UI closure still backups'

Remove-Item -LiteralPath $fakeRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host 'All tests passed.'
