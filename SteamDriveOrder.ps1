# SteamDriveOrder - reorder Steam's Install To / Storage drive list.
# Free, unofficial, not affiliated with Valve. Tips optional.
# Requires: Windows PowerShell 5.1+ or PowerShell 7+, Steam desktop client.

[CmdletBinding()]
param(
    [switch]$SortDriveLetters,
    [switch]$KeepClientFirst,
    [switch]$Apply,
    [switch]$SkipMain,
    [string]$SteamRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SteamRoot = $SteamRoot
$script:PatreonUrl = 'https://www.patreon.com/GarrettsProjects'
$script:Drag = $null
$script:DragFilter = $null
$script:DragAnim = $null
$script:CardHost = $null
$script:Ui = $null
$script:ApplyButton = $null
$script:ForceButton = $null
$script:SortButton = $null
$script:FooterPanel = $null
$script:PatreonRow = $null
$script:ApplyPhase = 'apply'
$script:ApplySpinTimer = $null
$script:ApplyWatchTimer = $null
$script:ApplyIdleTimer = $null
$script:ApplyForceAt = $null
$script:ForceWanted = $false
$script:ForceSlide = 0.0
$script:ClosingForced = $false
$script:HintLabel = $null
$script:MainForm = $null
$script:KeepClientFirst = $true
$script:Libraries = $null
$script:Meta = $null
$script:SteamPath = $null
$script:WarnBanner = $null
$script:WarnBannerHide = $null
$script:ShowingError = $false

function Get-VdfTokens {
    param([string]$Text)

    $tokens = New-Object System.Collections.Generic.List[string]
    $i = 0
    $n = $Text.Length
    while ($i -lt $n) {
        $c = $Text[$i]
        if ([char]::IsWhiteSpace($c)) {
            $i++
            continue
        }
        if ($c -eq '{' -or $c -eq '}') {
            $tokens.Add([string]$c)
            $i++
            continue
        }
        if ($c -eq '"') {
            $i++
            $sb = New-Object System.Text.StringBuilder
            while ($i -lt $n) {
                $ch = $Text[$i]
                if ($ch -eq '\' -and ($i + 1) -lt $n) {
                    [void]$sb.Append($Text[$i + 1])
                    $i += 2
                    continue
                }
                if ($ch -eq '"') {
                    $i++
                    break
                }
                [void]$sb.Append($ch)
                $i++
            }
            $tokens.Add($sb.ToString())
            continue
        }
        $start = $i
        while ($i -lt $n -and -not [char]::IsWhiteSpace($Text[$i]) -and $Text[$i] -ne '{' -and $Text[$i] -ne '}') {
            $i++
        }
        $tokens.Add($Text.Substring($start, $i - $start))
    }
    return $tokens
}

function Read-VdfObject {
    param(
        [System.Collections.Generic.List[string]]$Tokens,
        [ref]$Index
    )

    $obj = [ordered]@{}
    while ($Index.Value -lt $Tokens.Count) {
        $token = $Tokens[$Index.Value]
        if ($token -eq '}') {
            $Index.Value++
            return $obj
        }
        $key = $token
        $Index.Value++
        if ($Index.Value -ge $Tokens.Count) {
            throw "VDF ended inside an object (key '$key')."
        }
        $next = $Tokens[$Index.Value]
        if ($next -eq '{') {
            $Index.Value++
            $obj[$key] = Read-VdfObject -Tokens $Tokens -Index $Index
        }
        else {
            $obj[$key] = $next
            $Index.Value++
        }
    }
    return $obj
}

function ConvertFrom-SteamVdf {
    param([string]$Text)

    $tokens = Get-VdfTokens -Text $Text
    if ($tokens.Count -lt 2) {
        throw 'VDF file is empty or invalid.'
    }
    $index = 0
    $rootKey = $tokens[$index]
    $index++
    if ($tokens[$index] -ne '{') {
        throw 'VDF root is not an object.'
    }
    $index++
    $body = Read-VdfObject -Tokens $tokens -Index ([ref]$index)
    $root = [ordered]@{}
    $root[$rootKey] = $body
    return $root
}

function Escape-VdfString {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return (($Value -replace '\\', '\\') -replace '"', '\"')
}

function Write-VdfObjectText {
    param(
        $Object,
        [int]$Indent
    )

    $tab = "`t" * $Indent
    $sb = New-Object System.Text.StringBuilder
    foreach ($key in $Object.Keys) {
        $val = $Object[$key]
        if ($val -is [System.Collections.IDictionary]) {
            [void]$sb.Append($tab)
            [void]$sb.Append('"')
            [void]$sb.Append((Escape-VdfString ([string]$key)))
            [void]$sb.Append('"')
            [void]$sb.Append("`n")
            [void]$sb.Append($tab)
            [void]$sb.Append("{`n")
            [void]$sb.Append((Write-VdfObjectText -Object $val -Indent ($Indent + 1)))
            [void]$sb.Append($tab)
            [void]$sb.Append("}`n")
        }
        else {
            [void]$sb.Append($tab)
            [void]$sb.Append('"')
            [void]$sb.Append((Escape-VdfString ([string]$key)))
            [void]$sb.Append('"')
            [void]$sb.Append("`t`t")
            [void]$sb.Append('"')
            [void]$sb.Append((Escape-VdfString ([string]$val)))
            [void]$sb.Append('"')
            [void]$sb.Append("`n")
        }
    }
    return $sb.ToString()
}

function ConvertTo-SteamVdf {
    param($Root)

    $sb = New-Object System.Text.StringBuilder
    foreach ($key in $Root.Keys) {
        [void]$sb.Append('"')
        [void]$sb.Append((Escape-VdfString ([string]$key)))
        [void]$sb.Append("`"`n{`n")
        [void]$sb.Append((Write-VdfObjectText -Object $Root[$key] -Indent 1))
        [void]$sb.Append("}`n")
    }
    return $sb.ToString()
}

function Get-LibraryEntries {
    param($Root)

    if (-not $Root.Contains('libraryfolders')) {
        throw "Missing 'libraryfolders' root key."
    }
    $folders = $Root['libraryfolders']
    $meta = [ordered]@{}
    $libs = New-Object System.Collections.Generic.List[object]
    foreach ($key in @($folders.Keys)) {
        if ($key -match '^\d+$') {
            $block = $folders[$key]
            if (-not $block.Contains('path')) {
                throw "Library '$key' has no path."
            }
            $libs.Add([pscustomobject]@{
                    Index = [int]$key
                    Path  = [string]$block['path']
                    Block = $block
                })
        }
        else {
            $meta[$key] = $folders[$key]
        }
    }
    return [pscustomobject]@{
        Meta      = $meta
        Libraries = $libs
    }
}

function New-LibraryRoot {
    param(
        $Meta,
        $Libraries
    )

    $folders = [ordered]@{}
    if ($Meta -is [System.Collections.IDictionary]) {
        foreach ($key in $Meta.Keys) {
            $folders[$key] = $Meta[$key]
        }
    }
    $i = 0
    foreach ($lib in $Libraries) {
        $folders["$i"] = $lib.Block
        $i++
    }
    $root = [ordered]@{}
    $root['libraryfolders'] = $folders
    return $root
}

function Get-PathDriveLetter {
    param([string]$Path)
    if ($Path -match '^([A-Za-z]):') {
        return $Matches[1].ToUpperInvariant()
    }
    return $null
}

function Sort-LibrariesByDrive {
    param(
        [System.Collections.IList]$Libraries,
        [string]$KeepFirstPath
    )

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Libraries) { $items.Add($item) }

    $head = $null
    if ($KeepFirstPath) {
        $norm = $KeepFirstPath.TrimEnd('\')
        for ($i = 0; $i -lt $items.Count; $i++) {
            if ($items[$i].Path.TrimEnd('\') -ieq $norm) {
                $head = $items[$i]
                $items.RemoveAt($i)
                break
            }
        }
    }

    $sorted = @($items | Sort-Object @{
            Expression = {
                $letter = Get-PathDriveLetter $_.Path
                if ($letter) { "0$letter" } else { "1$($_.Path)" }
            }
        })

    $result = New-Object System.Collections.Generic.List[object]
    if ($head) { $result.Add($head) }
    foreach ($item in $sorted) { $result.Add($item) }
    return $result
}

function Get-SteamInstallPath {
    if (-not [string]::IsNullOrWhiteSpace($script:SteamRoot)) {
        $full = [System.IO.Path]::GetFullPath($script:SteamRoot)
        if (Test-Path -LiteralPath (Join-Path $full 'steam.exe')) {
            return $full
        }
        throw "SteamRoot not found or missing steam.exe: $script:SteamRoot"
    }

    $candidates = @()
    foreach ($key in @(
            'HKCU:\Software\Valve\Steam',
            'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
            'HKLM:\SOFTWARE\Valve\Steam'
        )) {
        if (-not (Test-Path $key)) { continue }
        $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($name in @('SteamPath', 'InstallPath')) {
            $prop = $props.PSObject.Properties[$name]
            if ($prop -and $prop.Value) { $candidates += [string]$prop.Value }
        }
    }
    $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Steam')
    $candidates += (Join-Path $env:ProgramFiles 'Steam')

    foreach ($raw in $candidates) {
        if (-not $raw) { continue }
        $full = [System.IO.Path]::GetFullPath($raw)
        if (Test-Path (Join-Path $full 'steam.exe')) {
            return $full
        }
    }
    throw 'Could not find steam.exe. Is the Steam desktop client installed?'
}

function Format-DisplayPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    try {
        $full = [System.IO.Path]::GetFullPath($Path.Trim())
    }
    catch {
        return $Path
    }
    if ($full.Length -lt 2 -or $full[1] -ne ':') { return $full }
    $current = ([char]::ToUpperInvariant($full[0])).ToString() + ':\'
    $tail = $full.Substring(2).TrimStart('\')
    if (-not $tail) { return $current }
    foreach ($part in $tail.Split([char]'\')) {
        if (-not $part) { continue }
        $resolved = $null
        if (Test-Path -LiteralPath $current) {
            $resolved = Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ieq $part } |
                Select-Object -First 1
        }
        if ($resolved) {
            $current = Join-Path $current $resolved.Name
            continue
        }
        $pretty = switch -Regex ($part) {
            '^(?i)program files \(x86\)$' { 'Program Files (x86)' }
            '^(?i)program files$' { 'Program Files' }
            '^(?i)steam$' { 'Steam' }
            '^(?i)steamlibrary$' { 'SteamLibrary' }
            default { $part }
        }
        $current = Join-Path $current $pretty
    }
    return $current
}

function Get-LibraryVdfPaths {
    param([string]$SteamPath)
    return [pscustomobject]@{
        Config    = Join-Path $SteamPath 'config\libraryfolders.vdf'
        SteamApps = Join-Path $SteamPath 'steamapps\libraryfolders.vdf'
    }
}

function Read-SteamLibraries {
    param([string]$SteamPath)

    $paths = Get-LibraryVdfPaths -SteamPath $SteamPath
    $configExists = Test-Path $paths.Config
    $appsExists = Test-Path $paths.SteamApps
    if (-not $configExists -and -not $appsExists) {
        throw "No libraryfolders.vdf found under $SteamPath"
    }

    $warning = $null
    $source = if ($configExists) { $paths.Config } else { $paths.SteamApps }
    if ($configExists -and $appsExists) {
        $hashA = (Get-FileHash $paths.Config -Algorithm SHA256).Hash
        $hashB = (Get-FileHash $paths.SteamApps -Algorithm SHA256).Hash
        if ($hashA -ne $hashB) {
            $warning = 'config and steamapps copies differ. Using the config copy as the source of truth.'
        }
    }

    $text = [System.IO.File]::ReadAllText($source)
    $root = ConvertFrom-SteamVdf -Text $text
    $parsed = Get-LibraryEntries -Root $root
    return [pscustomobject]@{
        SteamPath = $SteamPath
        Paths     = $paths
        Meta      = $parsed.Meta
        Libraries = $parsed.Libraries
        Warning   = $warning
    }
}

function Format-Gib {
    param([double]$Bytes)
    $gb = $Bytes / 1GB
    if ([Math]::Round($gb) -ge 1024) {
        return '{0:N2} TB' -f ($Bytes / 1TB)
    }
    return '{0:N0} GB' -f $gb
}

function Get-LibraryDisplayInfo {
    param($Library)

    $letter = Get-PathDriveLetter -Path $Library.Path
    $label = [string]$Library.Block['label']
    $freeText = ''
    $spaceText = ''
    $usedPercent = 0.0
    if ($letter) {
        try {
            $drive = New-Object System.IO.DriveInfo ("${letter}:")
            if ($drive.IsReady) {
                if ([string]::IsNullOrWhiteSpace($label)) {
                    $label = [string]$drive.VolumeLabel
                }
                $free = [double]$drive.AvailableFreeSpace
                $total = [double]$drive.TotalSize
                $freeText = '{0} free' -f (Format-Gib $free)
                if ($total -gt 0) {
                    $spaceText = '{0} free of {1}' -f (Format-Gib $free), (Format-Gib $total)
                    $usedPercent = [Math]::Max(0.0, [Math]::Min(1.0, ($total - $free) / $total))
                }
                else {
                    $spaceText = $freeText
                }
            }
        }
        catch {
            $freeText = ''
        }
    }
    if ([string]::IsNullOrWhiteSpace($label)) {
        $label = if ($letter) { 'Local Drive' } else { 'Library' }
    }
    return [pscustomobject]@{
        Drive       = $(if ($letter) { "${letter}:" } else { '' })
        Label       = $label
        Space       = $spaceText
        UsedPercent = $usedPercent
        Path        = $Library.Path
    }
}

function Get-SteamClientProcesses {
    return , @(Get-Process -Name steam, steamwebhelper -ErrorAction SilentlyContinue)
}

function Get-SteamCloseProcessSummary {
    $counts = @{}
    $procs = Get-SteamClientProcesses
    if ($null -eq $procs) { return '' }
    foreach ($proc in $procs) {
        if ($null -eq $proc) { continue }
        $prop = $proc.PSObject.Properties['ProcessName']
        if (-not $prop) { $prop = $proc.PSObject.Properties['Name'] }
        if (-not $prop) { continue }
        $name = [string]$prop.Value
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($name -notmatch '(?i)\.exe$') { $name = "$name.exe" }
        if ($counts.ContainsKey($name)) {
            $counts[$name] += 1
        }
        else {
            $counts[$name] = 1
        }
    }
    if ($counts.Count -eq 0) { return '' }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($counts.Keys | Sort-Object)) {
        $n = [int]$counts[$name]
        if ($n -gt 1) {
            $parts.Add("$name ($n)")
        }
        else {
            $parts.Add($name)
        }
    }
    return ($parts -join ', ')
}

function Update-SteamCloseHint {
    $list = Get-SteamCloseProcessSummary
    if ([string]::IsNullOrWhiteSpace($list)) { return }
    if ($script:ClosingForced) {
        Set-HintText "Forcing $list"
    }
    elseif ($script:ForceWanted) {
        Set-HintText "Still waiting on $list"
    }
    else {
        Set-HintText "Waiting on $list"
    }
}

function Get-SteamMainProcesses {
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($proc in @(Get-Process -Name steam -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $proc.Path } catch { }
        if ($path -and ($path -notmatch '(?i)\\steam\.exe$')) { continue }
        $found.Add($proc)
    }
    return , @($found.ToArray())
}

function Test-RealSteamExecutable {
    param([string]$SteamPath)
    $exe = Join-Path $SteamPath 'steam.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return $false }
    $stream = [System.IO.File]::OpenRead($exe)
    try {
        return ($stream.ReadByte() -eq 77 -and $stream.ReadByte() -eq 90)
    }
    finally {
        $stream.Dispose()
    }
}

function Test-SteamClientForPath {
    param([string]$SteamPath)
    if (-not (Test-RealSteamExecutable -SteamPath $SteamPath)) { return $false }
    $target = [System.IO.Path]::GetFullPath((Join-Path $SteamPath 'steam.exe'))
    foreach ($proc in @(Get-Process -Name steam -ErrorAction SilentlyContinue)) {
        try {
            if ($proc.Path -and ([System.IO.Path]::GetFullPath($proc.Path) -ieq $target)) {
                return $true
            }
        }
        catch {
        }
    }
    return $false
}

function Test-SteamGameRunning {
    try {
        $id = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).RunningAppID
        if ($null -eq $id) { return $false }
        return ([int]$id -ne 0)
    }
    catch {
        return $false
    }
}

function Stop-SteamClient {
    param([string]$SteamPath)

    $exe = Join-Path $SteamPath 'steam.exe'
    if (Get-Process -Name steam -ErrorAction SilentlyContinue) {
        Start-Process -FilePath $exe -ArgumentList '-shutdown' -WindowStyle Hidden | Out-Null
    }
    $deadline = (Get-Date).AddSeconds(45)
    do {
        Start-Sleep -Milliseconds 400
        $left = Get-SteamMainProcesses
    } while ($left.Count -gt 0 -and (Get-Date) -lt $deadline)

    if ((Get-SteamMainProcesses).Count -gt 0) {
        throw 'Steam did not exit. Close it from the system tray and try again.'
    }
}

function Start-SteamClient {
    param([string]$SteamPath)
    Start-Process -FilePath (Join-Path $SteamPath 'steam.exe') | Out-Null
}

function Set-HintText {
    param([string]$Text)
    if ($script:HintLabel) {
        $script:HintLabel.Text = $Text
    }
}

function Invoke-SortLibrariesAz {
    $keepPath = $null
    if ($script:KeepClientFirst) {
        $keepPath = $script:SteamPath
    }
    $script:Libraries = Sort-LibrariesByDrive -Libraries $script:Libraries -KeepFirstPath $keepPath
}

function Invoke-UiApplyOrder {
    return Save-LibraryOrder -SteamPath $script:SteamPath -Meta $script:Meta -Libraries $script:Libraries -RestartSteam
}

function Test-SteamStillRunning {
    $procs = Get-SteamClientProcesses
    return ($null -ne $procs -and $procs.Count -gt 0)
}

function Request-SteamShutdown {
    param([string]$SteamPath)
    $exe = Join-Path $SteamPath 'steam.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return }
    if (Get-Process -Name steam -ErrorAction SilentlyContinue) {
        Start-Process -FilePath $exe -ArgumentList '-shutdown' -WindowStyle Hidden | Out-Null
    }
}

function Stop-ApplyWaitTimers {
    if ($script:ApplySpinTimer) { $script:ApplySpinTimer.Stop() }
    if ($script:ApplyWatchTimer) { $script:ApplyWatchTimer.Stop() }
}

function Stop-ApplyUiTimers {
    Stop-ApplyWaitTimers
    if ($script:ApplyIdleTimer) { $script:ApplyIdleTimer.Stop() }
}

function Start-ApplyIdleWatch {
    if ($script:ApplyIdleTimer) { return }
    $idle = New-Object System.Windows.Forms.Timer
    $idle.Interval = 1000
    $idle.Add_Tick({
            if ($script:ApplyPhase -eq 'closing') { return }
            Update-ApplyButton
        })
    $script:ApplyIdleTimer = $idle
    $idle.Start()
}

function Update-ApplyButton {
    if (-not $script:ApplyButton) { return }
    if ($script:ApplyPhase -eq 'closing') { return }
    if (Test-SteamStillRunning) {
        $script:ApplyPhase = 'close'
        $script:ApplyButton.ShowSpinner = $false
        $script:ApplyButton.Text = 'Close Steam'
        $script:ApplyButton.Enabled = $true
    }
    else {
        $script:ApplyPhase = 'apply'
        $script:ApplyButton.ShowSpinner = $false
        $script:ApplyButton.Text = 'Apply to Steam'
        $script:ApplyButton.Enabled = $true
    }
    $script:ApplyButton.Invalidate()
}

function Update-FooterButtons {
    $footer = $script:FooterPanel
    $apply = $script:ApplyButton
    $sort = $script:SortButton
    $force = $script:ForceButton
    if (-not $footer -or -not $apply -or -not $sort) { return }
    $gutter = Get-CardListGutter
    $gap = 10
    $apply.Top = 20
    $sort.Top = 20
    $apply.Left = $footer.Width - $gutter - $apply.Width
    $slide = [double]$script:ForceSlide
    if ($slide -lt 0) { $slide = 0 }
    if ($slide -gt 1) { $slide = 1 }
    $ease = 1.0 - [Math]::Pow((1.0 - $slide), 3)
    if ($force) {
        $force.Top = 20
        $under = $apply.Left
        $out = $apply.Left - $gap - $force.Width
        $force.Left = [int][Math]::Round($under + (($out - $under) * $ease))
        $showForce = [bool]$script:ForceWanted -or ($slide -gt 0.001)
        $force.Visible = $showForce
        $apply.BringToFront()
        if ($showForce -and $slide -gt 0.001) {
            $sort.Left = $force.Left - $gap - $sort.Width
        }
        else {
            $sort.Left = $apply.Left - $gap - $sort.Width
        }
    }
    else {
        $sort.Left = $apply.Left - $gap - $sort.Width
    }
    $patreon = $script:PatreonRow
    if ($patreon) {
        $patreon.Left = $gutter
        $patreon.Top = 21
    }
}

function Hide-ForceButton {
    $script:ForceWanted = $false
    $script:ForceSlide = 0.0
    $script:ApplyForceAt = $null
    if ($script:ForceButton) {
        $script:ForceButton.Visible = $false
        $script:ForceButton.Enabled = $true
    }
    Update-FooterButtons
}

function Show-ForceButton {
    if (-not $script:ForceButton) { return }
    if ($script:ForceWanted) { return }
    $script:ForceWanted = $true
    $script:ForceButton.Visible = $true
    $script:ForceButton.Enabled = $true
    Update-SteamCloseHint
    Update-FooterButtons
}

function Update-ApplySpinner {
    if ($script:ApplyButton -and $script:ApplyButton.ShowSpinner) {
        $script:ApplyButton.SpinnerAngle = ($script:ApplyButton.SpinnerAngle + 14) % 360
        $script:ApplyButton.Invalidate()
    }
    if ($script:ForceWanted -and $script:ForceSlide -lt 1) {
        $script:ForceSlide = [Math]::Min(1.0, [double]$script:ForceSlide + 0.07)
        Update-FooterButtons
    }
    elseif ((-not $script:ForceWanted) -and $script:ForceSlide -gt 0) {
        $script:ForceSlide = [Math]::Max(0.0, [double]$script:ForceSlide - 0.12)
        Update-FooterButtons
    }
}

function Update-ApplySteamWait {
    if (-not (Test-SteamStillRunning)) {
        Complete-UiSteamClosed
        return
    }
    Update-SteamCloseHint
    if ($script:ApplyForceAt -and ((Get-Date) -ge $script:ApplyForceAt)) {
        Show-ForceButton
    }
}

function Complete-UiSteamClosed {
    Stop-ApplyWaitTimers
    $script:ClosingForced = $false
    Hide-ForceButton
    $script:ApplyPhase = 'apply'
    Update-ApplyButton
    Set-HintText 'Steam is closed. Apply when you are ready.'
    Update-FooterButtons
}

function Invoke-ForceSteamClose {
    $script:ClosingForced = $true
    Update-SteamCloseHint
    if ($script:ForceButton) { $script:ForceButton.Enabled = $false }
    Get-Process -Name steam, steamwebhelper -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Start-UiSteamClose {
    if (-not (Test-SteamStillRunning)) {
        Complete-UiSteamClosed
        return
    }
    if (Test-SteamGameRunning) {
        [void](Show-SteamPrompt -Title 'Could not close Steam' -Body 'A Steam game is running. Exit the game first, then try again.' -Kind Error -Owner $script:MainForm)
        return
    }
    $script:ApplyPhase = 'closing'
    $script:ClosingForced = $false
    $script:ForceWanted = $false
    $script:ForceSlide = 0.0
    $script:ApplyForceAt = (Get-Date).AddSeconds(10)
    if ($script:ForceButton) {
        $script:ForceButton.Visible = $false
        $script:ForceButton.Enabled = $true
    }
    $script:ApplyButton.Text = ''
    $script:ApplyButton.ShowSpinner = $true
    $script:ApplyButton.Enabled = $false
    $script:ApplyButton.Invalidate()
    Update-SteamCloseHint
    Request-SteamShutdown -SteamPath $script:SteamPath
    if (-not $script:ApplySpinTimer) {
        $spin = New-Object System.Windows.Forms.Timer
        $spin.Interval = 30
        $spin.Add_Tick({ Update-ApplySpinner })
        $script:ApplySpinTimer = $spin
    }
    if (-not $script:ApplyWatchTimer) {
        $watch = New-Object System.Windows.Forms.Timer
        $watch.Interval = 250
        $watch.Add_Tick({ Update-ApplySteamWait })
        $script:ApplyWatchTimer = $watch
    }
    $script:ApplySpinTimer.Start()
    $script:ApplyWatchTimer.Start()
}

function Invoke-UiApplyConfirm {
    $prompt = "Both libraryfolders.vdf files will be updated.`nSteam will then reopen so the new Install to order is used.`nA backup is created first."
    $answer = Show-SteamPrompt -Title 'Apply library order' -Body $prompt -Kind Question -Owner $script:MainForm
    if ($answer -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        $backup = Invoke-UiApplyOrder
        Set-HintText "Saved. Steam is restarting. Backup: $backup"
        [void](Show-SteamPrompt -Title 'SteamDriveOrder' -Body "Library order saved.`n`nSteam is restarting so the new order is used.`n`nBackup:`n$backup" -Kind Info -Owner $script:MainForm)
        if ($script:MainForm -and -not $script:MainForm.IsDisposed) {
            $script:MainForm.Close()
        }
    }
    catch {
        [void](Show-SteamPrompt -Title 'Could not apply order' -Body $_.Exception.Message -Kind Error -Owner $script:MainForm)
        Update-ApplyButton
    }
}

function Invoke-ApplyButtonClick {
    try {
        if ($script:ApplyPhase -eq 'close') {
            Start-UiSteamClose
            return
        }
        Invoke-UiApplyConfirm
    }
    catch {
        Restore-UiAfterDialog -Owner $script:MainForm
        [void](Show-SteamPrompt -Title 'Could not apply order' -Body $_.Exception.Message -Kind Error -Owner $script:MainForm)
        Update-ApplyButton
    }
}

function Save-LibraryOrder {
    param(
        [string]$SteamPath,
        $Meta,
        $Libraries,
        [switch]$RestartSteam
    )

    $root = New-LibraryRoot -Meta $Meta -Libraries $Libraries
    $text = ConvertTo-SteamVdf -Root $root
    $verify = Get-LibraryEntries -Root (ConvertFrom-SteamVdf -Text $text)
    $expected = @($Libraries | ForEach-Object { $_.Path.TrimEnd('\') })
    $actual = @($verify.Libraries | ForEach-Object { $_.Path.TrimEnd('\') })
    if ($expected.Count -ne $actual.Count) {
        throw 'Write verification failed: library count changed.'
    }
    for ($i = 0; $i -lt $expected.Count; $i++) {
        if ($expected[$i] -ine $actual[$i]) {
            throw "Write verification failed at index $i."
        }
    }

    $realClient = Test-RealSteamExecutable -SteamPath $SteamPath
    if ($realClient -and (Test-SteamGameRunning)) {
        throw 'A Steam game is running. Exit the game before changing library order.'
    }

    $paths = Get-LibraryVdfPaths -SteamPath $SteamPath
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $env:LOCALAPPDATA "SteamDriveOrder\backups\$stamp"
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    if (Test-Path $paths.Config) {
        Copy-Item -LiteralPath $paths.Config -Destination (Join-Path $backup 'config-libraryfolders.vdf')
    }
    if (Test-Path $paths.SteamApps) {
        Copy-Item -LiteralPath $paths.SteamApps -Destination (Join-Path $backup 'steamapps-libraryfolders.vdf')
    }

    if ($realClient -and (Test-SteamClientForPath -SteamPath $SteamPath)) {
        Stop-SteamClient -SteamPath $SteamPath
    }

    $utf8 = New-Object System.Text.UTF8Encoding $false
    foreach ($target in @($paths.Config, $paths.SteamApps)) {
        $dir = Split-Path -Parent $target
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($target, $text, $utf8)
    }

    $written = Get-LibraryEntries -Root (ConvertFrom-SteamVdf -Text ([System.IO.File]::ReadAllText($paths.Config)))
    $writtenPaths = @($written.Libraries | ForEach-Object { $_.Path.TrimEnd('\') })
    if ($expected.Count -ne $writtenPaths.Count) {
        throw 'Write verification failed: library count changed on disk.'
    }
    for ($i = 0; $i -lt $expected.Count; $i++) {
        if ($expected[$i] -ine $writtenPaths[$i]) {
            throw "Write verification failed at index $i on disk."
        }
    }

    if ($RestartSteam -and $realClient) {
        Start-SteamClient -SteamPath $SteamPath
    }

    return $backup
}

function Invoke-CliApply {
    $steam = Get-SteamInstallPath
    $state = Read-SteamLibraries -SteamPath $steam
    $libs = $state.Libraries
    if ($SortDriveLetters) {
        $keep = $null
        if ($KeepClientFirst) { $keep = $steam }
        $libs = Sort-LibrariesByDrive -Libraries $libs -KeepFirstPath $keep
    }
    $backup = Save-LibraryOrder -SteamPath $steam -Meta $state.Meta -Libraries $libs -RestartSteam
    Write-Host "Updated both libraryfolders.vdf files."
    Write-Host "Backup: $backup"
    Write-Host "New order:"
    $i = 1
    foreach ($lib in $libs) {
        $info = Get-LibraryDisplayInfo -Library $lib
        Write-Host ("  {0}. {1} {2}  {3}" -f $i, $info.Drive, $info.Label, $info.Path)
        $i++
    }
}

function Hide-HostConsole {
    if (-not ('SteamDriveOrderNative' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SteamDriveOrderNative {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    public static void HideConsole() {
        IntPtr hwnd = GetConsoleWindow();
        if (hwnd != IntPtr.Zero) ShowWindow(hwnd, 0);
    }
}
"@
    }
    [SteamDriveOrderNative]::HideConsole()
}

function Get-UiTheme {
    return @{
        Bg         = [System.Drawing.Color]::FromArgb(27, 32, 40)
        Surface    = [System.Drawing.Color]::FromArgb(23, 26, 33)
        Card       = [System.Drawing.Color]::FromArgb(45, 50, 58)
        CardHot    = [System.Drawing.Color]::FromArgb(61, 68, 80)
        Line       = [System.Drawing.Color]::FromArgb(45, 50, 58)
        Text       = [System.Drawing.Color]::FromArgb(220, 222, 223)
        Muted      = [System.Drawing.Color]::FromArgb(139, 148, 158)
        Accent     = [System.Drawing.Color]::FromArgb(26, 159, 255)
        AccentSoft = [System.Drawing.Color]::FromArgb(102, 192, 244)
        Accent2    = [System.Drawing.Color]::FromArgb(199, 128, 22)
        Good       = [System.Drawing.Color]::FromArgb(89, 191, 64)
        GoodText   = [System.Drawing.Color]::FromArgb(255, 255, 255)
        Button     = [System.Drawing.Color]::FromArgb(61, 68, 80)
        ButtonHot  = [System.Drawing.Color]::FromArgb(75, 84, 99)
        BarBack    = [System.Drawing.Color]::FromArgb(35, 41, 50)
        Title      = [System.Drawing.Color]::FromArgb(23, 26, 33)
        Dialog     = [System.Drawing.Color]::FromArgb(24, 27, 34)
    }
}

function Initialize-SteamDriveOrderUi {
    Hide-HostConsole
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    try {
        [void][System.Windows.Forms.Application]::SetHighDpiMode('PerMonitorV2')
    }
    catch {
        if (-not ('SteamDriveOrderDpi' -as [type])) {
            Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public static class SteamDriveOrderDpi {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
"@
        }
        [SteamDriveOrderDpi]::SetProcessDPIAware() | Out-Null
    }
    [System.Windows.Forms.Application]::EnableVisualStyles()
    Enable-UiErrorHandler

    $script:Ui = Get-UiTheme
    $script:Drag = New-CardDragState

    if (-not ('SteamChrome' -as [type])) {
        Add-Type -ReferencedAssemblies @('System.Windows.Forms.dll', 'System.Drawing.dll') -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class SteamChrome {
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    public static void UseDarkTitleBar(IntPtr hwnd) {
        int useDark = 1;
        DwmSetWindowAttribute(hwnd, 20, ref useDark, 4);
        DwmSetWindowAttribute(hwnd, 19, ref useDark, 4);
    }

    public static GraphicsPath RoundRect(Rectangle r, int radius) {
        return RoundRectF(new RectangleF(r.X, r.Y, r.Width, r.Height), radius);
    }

    public static GraphicsPath RoundRectF(RectangleF r, float radius) {
        float d = Math.Max(1.5f, radius * 2f);
        if (d > r.Width) d = r.Width;
        if (d > r.Height) d = r.Height;
        GraphicsPath path = new GraphicsPath();
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}

public class SteamForm : Form {
    bool _shown;
    public SteamForm() {
        BackColor = Color.FromArgb(27, 32, 40);
        ForeColor = Color.FromArgb(220, 222, 223);
        DoubleBuffered = true;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.Opaque | ControlStyles.ResizeRedraw, true);
        UpdateStyles();
        Opacity = 0d;
    }
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x02000000;
            return cp;
        }
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0014) {
            m.Result = (IntPtr)1;
            return;
        }
        base.WndProc(ref m);
    }
    protected override void OnPaintBackground(PaintEventArgs e) {
        using (SolidBrush br = new SolidBrush(BackColor))
            e.Graphics.FillRectangle(br, ClientRectangle);
    }
    protected override void OnPaint(PaintEventArgs e) {
        using (SolidBrush br = new SolidBrush(BackColor))
            e.Graphics.FillRectangle(br, ClientRectangle);
    }
    protected override void OnShown(EventArgs e) {
        if (!_shown) {
            _shown = true;
            Opacity = 1d;
            Update();
        }
        base.OnShown(e);
    }
}

public class SteamUsageBar : Control {
    public float UsedPercent;
    public Color BarBack = Color.FromArgb(35, 41, 50);
    public Color BarFill = Color.FromArgb(26, 159, 255);
    public SteamUsageBar() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        Height = 10;
    }
    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.SmoothingMode = SmoothingMode.None;
        using (SolidBrush back = new SolidBrush(BarBack))
            e.Graphics.FillRectangle(back, 0, 0, Width, Height);
        int w = (int)Math.Round(Width * Math.Max(0f, Math.Min(1f, UsedPercent)));
        if (w > 0) {
            using (SolidBrush fill = new SolidBrush(BarFill))
                e.Graphics.FillRectangle(fill, 0, 0, w, Height);
        }
    }
}

public class SteamButton : Button {
    public bool IsPrimary;
    public bool IsDanger;
    public bool ShowSpinner;
    public float SpinnerAngle;
    public int Arrow;
    Color _clear = Color.FromArgb(27, 32, 40);
    public Color ClearColor {
        get { return _clear; }
        set {
            _clear = value;
            BackColor = value;
            FlatAppearance.MouseOverBackColor = value;
            FlatAppearance.MouseDownBackColor = value;
            Invalidate();
        }
    }
    public SteamButton() {
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        FlatAppearance.MouseOverBackColor = _clear;
        FlatAppearance.MouseDownBackColor = _clear;
        ForeColor = Color.White;
        BackColor = _clear;
        Cursor = Cursors.Hand;
        TabStop = false;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }
    protected override bool ShowFocusCues { get { return false; } }
    protected override void OnPaintBackground(PaintEventArgs e) {
        using (SolidBrush clear = new SolidBrush(_clear))
            e.Graphics.FillRectangle(clear, ClientRectangle);
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.CompositingQuality = CompositingQuality.HighQuality;
        using (SolidBrush clear = new SolidBrush(_clear))
            g.FillRectangle(clear, ClientRectangle);
        RectangleF r = new RectangleF(1.25f, 1.25f, Math.Max(1f, Width - 2.5f), Math.Max(1f, Height - 2.5f));
        bool hot = ClientRectangle.Contains(PointToClient(Control.MousePosition));
        using (GraphicsPath path = SteamChrome.RoundRectF(r, 3f)) {
            if (IsDanger) {
                Color c = hot ? Color.FromArgb(232, 88, 88) : Color.FromArgb(196, 54, 54);
                using (SolidBrush br = new SolidBrush(c))
                    g.FillPath(br, path);
            } else if (IsPrimary) {
                Color c = hot ? Color.FromArgb(64, 176, 255) : Color.FromArgb(26, 159, 255);
                using (SolidBrush br = new SolidBrush(c))
                    g.FillPath(br, path);
            } else {
                Color c = hot ? Color.FromArgb(75, 84, 99) : Color.FromArgb(61, 68, 80);
                using (SolidBrush br = new SolidBrush(c))
                    g.FillPath(br, path);
            }
        }
        if (ShowSpinner) {
            float s = Math.Min(Width, Height) * 0.42f;
            float cx = Width / 2f;
            float cy = Height / 2f;
            RectangleF ring = new RectangleF(cx - s / 2f, cy - s / 2f, s, s);
            using (Pen dim = new Pen(Color.FromArgb(70, 255, 255, 255), 2.3f))
            using (Pen arc = new Pen(Color.White, 2.3f)) {
                dim.StartCap = LineCap.Round;
                dim.EndCap = LineCap.Round;
                arc.StartCap = LineCap.Round;
                arc.EndCap = LineCap.Round;
                g.DrawArc(dim, ring, 0f, 360f);
                g.DrawArc(arc, ring, SpinnerAngle, 78f);
            }
        } else if (Arrow != 0) {
            float cx = Width / 2f;
            float cy = Height / 2f;
            PointF[] pts = Arrow > 0
                ? new PointF[] { new PointF(cx, cy - 4.6f), new PointF(cx + 5.1f, cy + 4.1f), new PointF(cx - 5.1f, cy + 4.1f) }
                : new PointF[] { new PointF(cx, cy + 4.6f), new PointF(cx + 5.1f, cy - 4.1f), new PointF(cx - 5.1f, cy - 4.1f) };
            using (GraphicsPath tri = new GraphicsPath())
            using (SolidBrush br = new SolidBrush(Color.White))
            using (Pen pen = new Pen(Color.White, 1.1f)) {
                pen.LineJoin = LineJoin.Round;
                tri.AddPolygon(pts);
                g.FillPath(br, tri);
                g.DrawPath(pen, tri);
            }
        } else {
            TextRenderer.DrawText(g, Text, Font, ClientRectangle, Color.White,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        }
    }
}

public class SteamCard : Panel {
    public Color ClearColor = Color.FromArgb(27, 32, 40);
    public Color TopAccent = Color.Empty;
    public int CornerRadius = 3;
    public bool Placeholder;
    public SteamCard() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }
    void PaintCard(Graphics g) {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.CompositingQuality = CompositingQuality.HighQuality;
        using (SolidBrush clear = new SolidBrush(ClearColor))
            g.FillRectangle(clear, ClientRectangle);
        RectangleF r = new RectangleF(0.5f, 0.5f, Math.Max(1f, Width - 1.5f), Math.Max(1f, Height - 1.5f));
        using (GraphicsPath path = SteamChrome.RoundRectF(r, CornerRadius)) {
            if (Placeholder) {
                using (SolidBrush br = new SolidBrush(Color.FromArgb(22, 32, 44)))
                    g.FillPath(br, path);
                using (Pen pen = new Pen(Color.FromArgb(80, 102, 192, 244), 1.25f)) {
                    pen.DashStyle = DashStyle.Dash;
                    g.DrawPath(pen, path);
                }
                return;
            }
            using (SolidBrush br = new SolidBrush(BackColor))
                g.FillPath(br, path);
            if (TopAccent.A > 0) {
                g.SetClip(path);
                using (SolidBrush accent = new SolidBrush(TopAccent))
                    g.FillRectangle(accent, 0, 0, Width, 4);
                g.ResetClip();
            }
        }
    }
    protected override void OnPaintBackground(PaintEventArgs e) {
        PaintCard(e.Graphics);
    }
    protected override void OnPaint(PaintEventArgs e) {
        PaintCard(e.Graphics);
    }
}

public class SteamText : Label {
    public bool Wrap;
    public SteamText() {
        AutoSize = false;
        UseMnemonic = false;
        Padding = Padding.Empty;
        Margin = Padding.Empty;
        UseCompatibleTextRendering = false;
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
    }
    protected override void OnPaint(PaintEventArgs e) {
        using (SolidBrush b = new SolidBrush(BackColor))
            e.Graphics.FillRectangle(b, ClientRectangle);
        if (string.IsNullOrEmpty(Text)) return;
        TextFormatFlags flags = TextFormatFlags.Left | TextFormatFlags.NoPrefix | TextFormatFlags.GlyphOverhangPadding;
        if (Wrap) flags |= TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl;
        else flags |= TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis;
        TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, ForeColor, flags);
    }
}

public class SteamPatreonMark : Control {
    public Color MarkColor = Color.FromArgb(255, 66, 77);
    public Color ClearColor = Color.FromArgb(23, 26, 33);
    public SteamPatreonMark() {
        Size = new Size(22, 22);
        Cursor = Cursors.Hand;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        using (SolidBrush clear = new SolidBrush(ClearColor))
            g.FillRectangle(clear, ClientRectangle);
        float s = Math.Min(Width, Height);
        float pad = s * 0.12f;
        float x = (Width - s) / 2f + pad;
        float y = (Height - s) / 2f + pad;
        float inner = s - pad * 2f;
        using (SolidBrush br = new SolidBrush(MarkColor)) {
            g.FillEllipse(br, x, y + inner * 0.38f, inner * 0.46f, inner * 0.46f);
            using (GraphicsPath bar = SteamChrome.RoundRectF(new RectangleF(x + inner * 0.62f, y, inner * 0.28f, inner), inner * 0.14f))
                g.FillPath(br, bar);
        }
    }
}

public class SteamGhost : Form {
    public Image Frame;
    public SteamGhost() {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        Opacity = 0.58;
        BackColor = Color.FromArgb(27, 32, 40);
        ShowIcon = false;
        ControlBox = false;
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x00000080;
            cp.ExStyle |= 0x00080000;
            cp.ExStyle |= 0x00000020;
            cp.ExStyle |= 0x08000000;
            return cp;
        }
    }
    protected override void OnPaintBackground(PaintEventArgs e) { }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Color.FromArgb(27, 32, 40));
        if (Frame != null)
            g.DrawImage(Frame, 0, 0, Width, Height);
        using (GraphicsPath path = SteamChrome.RoundRectF(new RectangleF(0.5f, 0.5f, Math.Max(1f, Width - 1.5f), Math.Max(1f, Height - 1.5f)), 6f))
        using (Pen pen = new Pen(Color.FromArgb(170, 102, 192, 244), 1.6f))
            g.DrawPath(pen, path);
    }
    protected override void Dispose(bool disposing) {
        if (disposing && Frame != null) {
            Frame.Dispose();
            Frame = null;
        }
        base.Dispose(disposing);
    }
}

public class SteamDragFilter : IMessageFilter {
    public bool Active;
    public event EventHandler DragMove;
    public event EventHandler DragEnd;
    public bool PreFilterMessage(ref Message m) {
        if (!Active) return false;
        const int WM_MOUSEMOVE = 0x0200;
        const int WM_LBUTTONUP = 0x0202;
        const int WM_KEYDOWN = 0x0100;
        if (m.Msg == WM_MOUSEMOVE) {
            EventHandler h = DragMove;
            if (h != null) h(this, EventArgs.Empty);
            return false;
        }
        if (m.Msg == WM_LBUTTONUP || (m.Msg == WM_KEYDOWN && m.WParam.ToInt32() == 0x1B)) {
            EventHandler h = DragEnd;
            if (h != null) h(this, EventArgs.Empty);
            return true;
        }
        return false;
    }
}

public class SteamPromptMark : Control {
    public Color Accent = Color.FromArgb(26, 159, 255);
    public string Glyph = "!";
    public SteamPromptMark() {
        Size = new Size(36, 36);
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }
    protected override void OnPaintBackground(PaintEventArgs e) { }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        using (SolidBrush clear = new SolidBrush(BackColor))
            g.FillRectangle(clear, ClientRectangle);
        RectangleF ring = new RectangleF(2.25f, 2.25f, Width - 5.5f, Height - 5.5f);
        using (SolidBrush fill = new SolidBrush(Color.FromArgb(28, Accent)))
            g.FillEllipse(fill, ring);
        using (Pen pen = new Pen(Color.FromArgb(180, Accent), 1.4f))
            g.DrawEllipse(pen, ring);
        Font font = new Font("Segoe UI", Math.Max(10f, Width * 0.34f), FontStyle.Bold);
        TextRenderer.DrawText(g, Glyph, font, ClientRectangle, Color.FromArgb(230, 236, 242),
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
        font.Dispose();
    }
}

public class SteamScrollView : Panel, IMessageFilter {
    readonly Panel _content;
    readonly Timer _anim;
    int _offset;
    int _target;
    bool _drag;
    int _dragOff;
    const int BarPad = 12;

    public Panel Content { get { return _content; } }
    public int Offset { get { return _offset; } }

    public SteamScrollView() {
        AutoScroll = false;
        DoubleBuffered = true;
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        BackColor = Color.FromArgb(27, 32, 40);
        _content = new Panel();
        _content.BackColor = Color.FromArgb(27, 32, 40);
        _content.Location = Point.Empty;
        Controls.Add(_content);
        _anim = new Timer();
        _anim.Interval = 12;
        _anim.Tick += AnimateTick;
        Application.AddMessageFilter(this);
    }

    protected override void Dispose(bool disposing) {
        if (disposing) {
            Application.RemoveMessageFilter(this);
            _anim.Stop();
            _anim.Dispose();
        }
        base.Dispose(disposing);
    }

    public bool PreFilterMessage(ref Message m) {
        const int WM_MOUSEWHEEL = 0x020A;
        if (m.Msg != WM_MOUSEWHEEL || !IsHandleCreated || !Visible) return false;
        if (!RectangleToScreen(new Rectangle(0, 0, Width, Height)).Contains(Control.MousePosition)) return false;
        int delta = (short)((m.WParam.ToInt64() >> 16) & 0xFFFF);
        int step = Math.Max(48, ClientSize.Height / 8);
        AnimateTo(_target - (delta / 120) * step);
        return true;
    }

    int MaxOffset {
        get { return Math.Max(0, _content.Height - ClientSize.Height); }
    }

    public void SetOffsetImmediate(int value) {
        int max = MaxOffset;
        if (value < 0) value = 0;
        if (value > max) value = max;
        _offset = value;
        _target = value;
        _content.Top = -_offset;
        Invalidate();
    }

    public void AnimateTo(int value) {
        int max = MaxOffset;
        if (value < 0) value = 0;
        if (value > max) value = max;
        _target = value;
        if (!_anim.Enabled) _anim.Start();
    }

    void AnimateTick(object s, EventArgs e) {
        int diff = _target - _offset;
        if (Math.Abs(diff) <= 1) {
            _offset = _target;
            _anim.Stop();
        } else {
            _offset += (int)Math.Round(diff * 0.28);
        }
        _content.Top = -_offset;
        Invalidate();
    }

    public void RefreshLayout() {
        _content.Left = 0;
        _content.Width = Math.Max(0, ClientSize.Width - BarPad);
        SetOffsetImmediate(_offset);
    }

    protected override void OnSizeChanged(EventArgs e) {
        base.OnSizeChanged(e);
        RefreshLayout();
    }

    Rectangle ThumbRect() {
        int view = ClientSize.Height;
        int content = _content.Height;
        if (content <= view + 1) return Rectangle.Empty;
        int track = Math.Max(1, Height - 16);
        int th = Math.Max(28, (int)(track * (view / (float)content)));
        if (th > track) th = track;
        int y = 8 + (int)((track - th) * (_offset / (float)Math.Max(1, MaxOffset)));
        return new Rectangle(Width - 9, y, 6, th);
    }

    protected override void OnPaint(PaintEventArgs e) {
        using (SolidBrush gutter = new SolidBrush(BackColor))
            e.Graphics.FillRectangle(gutter, Width - BarPad, 0, BarPad, Height);
        Rectangle t = ThumbRect();
        if (t.Height <= 0) return;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (GraphicsPath path = SteamChrome.RoundRect(t, 3))
        using (SolidBrush br = new SolidBrush(Color.FromArgb(120, 132, 144)))
            e.Graphics.FillPath(br, path);
    }

    protected override void OnMouseDown(MouseEventArgs e) {
        Rectangle t = ThumbRect();
        if (t.Contains(e.Location)) {
            _drag = true;
            _dragOff = e.Y - t.Y;
            Capture = true;
            _anim.Stop();
        } else if (e.X >= Width - BarPad && MaxOffset > 0) {
            int page = Math.Max(64, ClientSize.Height * 3 / 4);
            AnimateTo(_offset + (e.Y < t.Y ? -page : page));
        }
    }

    protected override void OnMouseUp(MouseEventArgs e) {
        _drag = false;
        Capture = false;
    }

    protected override void OnMouseMove(MouseEventArgs e) {
        if (!_drag) return;
        int track = Math.Max(1, Height - 16);
        int th = Math.Max(28, ThumbRect().Height);
        int y = Math.Max(8, Math.Min(Height - 8 - th, e.Y - _dragOff));
        float pct = (y - 8) / (float)Math.Max(1, track - th);
        SetOffsetImmediate((int)(pct * MaxOffset));
    }
}
"@
    }
}

function Set-ControlBackColor {
    param($Control, $Color)
    if ($null -eq $Control -or $null -eq $Color) { return }
    if ($Color -is [System.Drawing.Color]) {
        $Control.BackColor = $Color
    }
}

function Get-UiTextWidth {
    param([string]$Text, $Font)
    if ([string]::IsNullOrEmpty($Text) -or -not $Font) { return 0 }
    $size = New-Object System.Drawing.Size
    $size.Width = 0
    $size.Height = 0
    return [System.Windows.Forms.TextRenderer]::MeasureText(
        $Text,
        $Font,
        $size,
        [System.Windows.Forms.TextFormatFlags]::NoPrefix
    ).Width
}

function Format-PromptWrappedText {
    param(
        [string]$Text,
        [int]$MaxWidth,
        $Font
    )
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($raw in ($Text -split "`n", -1)) {
        if ($raw.Length -eq 0) {
            $lines.Add('')
            continue
        }
        if ((Get-UiTextWidth -Text $raw -Font $Font) -le $MaxWidth) {
            $lines.Add($raw)
            continue
        }
        $parts = [regex]::Split($raw, '(?<=[\\/])')
        $current = ''
        foreach ($part in $parts) {
            if ($part.Length -eq 0) { continue }
            $try = $current + $part
            if ($current.Length -gt 0 -and (Get-UiTextWidth -Text $try -Font $Font) -gt $MaxWidth) {
                $lines.Add($current)
                $current = $part
            }
            else {
                $current = $try
            }
        }
        if ($current.Length -gt 0) { $lines.Add($current) }
    }
    return ($lines -join "`n")
}

function Show-SteamPrompt {
    param(
        [string]$Title,
        [string]$Body,
        [ValidateSet('Question', 'Error', 'Info')]
        [string]$Kind = 'Info',
        $Owner = $null
    )

    $ui = Get-UiTheme
    $chrome = $ui.Dialog
    $box = $ui.Card
    $headingText = if ([string]::IsNullOrWhiteSpace($Title)) { 'SteamDriveOrder' } else { $Title }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $headingText
    $form.FormBorderStyle = 'None'
    $form.StartPosition = $(if ($Owner -and -not $Owner.IsDisposed) { 'CenterParent' } else { 'CenterScreen' })
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ControlBox = $false
    $form.ShowInTaskbar = $false
    $form.ShowIcon = $false
    $form.BackColor = $chrome
    $form.ForeColor = $ui.Text
    $form.Font = New-UiFont
    $form.ClientSize = New-Object System.Drawing.Size -ArgumentList 480, 200
    Enable-DoubleBuffer -Control $form

    $card = New-Object SteamCard
    $card.BackColor = $box
    $card.ClearColor = $chrome
    $card.CornerRadius = 3

    $heading = New-UiLabel -Text $headingText -Size 12.5 -Style Bold -Fore $ui.Text -Flush
    $heading.BackColor = $box
    $heading.SetBounds(16, 14, 400, 26)

    $label = New-UiLabel -Text $Body -Size 10 -Fore $ui.Text -Flush
    $label.Wrap = $true
    $label.BackColor = $box
    $label.SetBounds(16, 44, 400, 80)
    $card.Controls.Add($label)
    $card.Controls.Add($heading)

    $minTextW = 400
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($Owner -and -not $Owner.IsDisposed) {
        $area = [System.Windows.Forms.Screen]::FromControl($Owner).WorkingArea
    }
    $maxTextW = [Math]::Max($minTextW, $area.Width - 200)
    $neededTextW = $minTextW
    foreach ($line in ($Body -split "`n", -1)) {
        if ($line.Length -eq 0) { continue }
        $lineW = Get-UiTextWidth -Text $line -Font $label.Font
        if ($lineW -gt $neededTextW) { $neededTextW = $lineW }
    }
    if ($neededTextW -gt $maxTextW) { $neededTextW = $maxTextW }
    $displayBody = Format-PromptWrappedText -Text $Body -MaxWidth $neededTextW -Font $label.Font
    $label.Text = $displayBody

    $okText = if ($Kind -eq 'Question') { 'Continue' } else { 'OK' }
    $ok = New-UiButton -Text $okText -Width 120 -Height 36 -Primary
    $ok.ClearColor = $chrome
    $ok.Add_Click({
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        }.GetNewClosure())

    $buttons = New-Object System.Collections.Generic.List[object]
    if ($Kind -eq 'Question') {
        $cancel = New-UiButton -Text 'Cancel' -Width 110 -Height 36
        $cancel.ClearColor = $chrome
        $cancel.Add_Click({
                $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
                $form.Close()
            }.GetNewClosure())
        $buttons.Add($cancel)
        $form.Controls.Add($cancel)
        $form.CancelButton = $cancel
    }
    $buttons.Add($ok)
    $form.Controls.Add($ok)
    $form.AcceptButton = $ok

    $place = {
        $pad = 20
        $card.Left = $pad
        $card.Top = $pad
        $card.Width = $form.ClientSize.Width - ($pad * 2)
        $textW = [Math]::Max(120, $card.Width - 32)
        $heading.Width = $textW
        $label.Width = $textW
        $x = $form.ClientSize.Width - $pad
        $y = $form.ClientSize.Height - $pad - 36
        for ($i = $buttons.Count - 1; $i -ge 0; $i--) {
            $b = $buttons[$i]
            $x -= $b.Width
            $b.Left = $x
            $b.Top = $y
            $x -= 8
        }
    }.GetNewClosure()

    $form.Controls.Add($card)
    $form.Add_Paint({
            param($sender, $event)
            $pen = New-Object System.Drawing.Pen $ui.CardHot, 1
            $event.Graphics.DrawRectangle($pen, 0, 0, ($sender.ClientSize.Width - 1), ($sender.ClientSize.Height - 1))
            $pen.Dispose()
        }.GetNewClosure())

    $drag = @{ Active = $false; X = 0; Y = 0 }
    $startDrag = {
        param($sender, $event)
        if ($event.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        $cursor = [System.Windows.Forms.Cursor]::Position
        $drag.Active = $true
        $drag.X = $cursor.X - $form.Left
        $drag.Y = $cursor.Y - $form.Top
    }.GetNewClosure()
    $moveDrag = {
        param($sender, $event)
        if (-not $drag.Active) { return }
        $cursor = [System.Windows.Forms.Cursor]::Position
        $form.Left = $cursor.X - $drag.X
        $form.Top = $cursor.Y - $drag.Y
    }.GetNewClosure()
    $endDrag = { $drag.Active = $false }
    foreach ($dragTarget in @($form, $card, $heading, $label)) {
        $dragTarget.Add_MouseDown($startDrag)
        $dragTarget.Add_MouseMove($moveDrag)
        $dragTarget.Add_MouseUp($endDrag)
    }

    $measureSize = New-Object System.Drawing.Size
    $measureSize.Width = $neededTextW
    $measureSize.Height = 0
    $needed = [System.Windows.Forms.TextRenderer]::MeasureText(
        $displayBody,
        $label.Font,
        $measureSize,
        [System.Windows.Forms.TextFormatFlags]::WordBreak
    ).Height
    $label.Height = [Math]::Max(40, ($needed + 8))
    $card.Height = $label.Bottom + 16
    $formSize = New-Object System.Drawing.Size
    $formSize.Width = $neededTextW + 72
    $formSize.Height = [int]($card.Bottom + 36 + 36 + 24)
    $form.ClientSize = $formSize
    & $place

    $ownerForm = $null
    if ($Owner -and -not $Owner.IsDisposed) { $ownerForm = $Owner }
    try {
        if ($ownerForm) {
            return $form.ShowDialog($ownerForm)
        }
        return $form.ShowDialog()
    }
    catch {
        return [System.Windows.Forms.DialogResult]::Cancel
    }
    finally {
        Restore-UiAfterDialog -Owner $ownerForm
        if ($form -and -not $form.IsDisposed) {
            $form.Dispose()
        }
    }
}

function Restore-UiAfterDialog {
    param($Owner = $null)
    $forms = New-Object System.Collections.Generic.List[object]
    if ($Owner) { $forms.Add($Owner) }
    if ($script:MainForm) { $forms.Add($script:MainForm) }
    foreach ($f in $forms) {
        if ($f -and -not $f.IsDisposed) {
            $f.Enabled = $true
        }
    }
}

function Show-SteamErrorDialog {
    param($ErrorObject)
    $details = ''
    if ($ErrorObject -is [System.Exception]) {
        $details = $ErrorObject.ToString()
    }
    elseif ($ErrorObject -and $ErrorObject.Exception) {
        $details = $ErrorObject.Exception.ToString()
    }
    else {
        $details = [string]$ErrorObject
    }

    $ui = Get-UiTheme
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'SteamDriveOrder error'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(860, 560)
    $form.MinimumSize = New-Object System.Drawing.Size(640, 400)
    $form.BackColor = $ui.Bg
    $form.ForeColor = $ui.Text
    $form.ShowIcon = $false

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Something went wrong'
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $ui.Text
    $title.BackColor = $ui.Bg
    $title.Dock = 'Top'
    $title.Height = 40
    $title.Padding = New-Object System.Windows.Forms.Padding(16, 10, 16, 0)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.ScrollBars = 'Both'
    $box.WordWrap = $true
    $box.Dock = 'Fill'
    $box.Font = New-Object System.Drawing.Font('Consolas', 10)
    $box.BackColor = $ui.Card
    $box.ForeColor = $ui.Text
    $box.Text = $details

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Close'
    $ok.Dock = 'Bottom'
    $ok.Height = 40
    $ok.FlatStyle = 'Flat'
    $ok.BackColor = $ui.Button
    $ok.ForeColor = $ui.Text
    $ok.FlatAppearance.BorderSize = 0
    $ok.Add_Click({ $form.Close() })

    $form.Controls.Add($box)
    $form.Controls.Add($ok)
    $form.Controls.Add($title)
    try {
        [void]$form.ShowDialog()
    }
    finally {
        Restore-UiAfterDialog -Owner $script:MainForm
        if (-not $form.IsDisposed) { $form.Dispose() }
    }
}

function Enable-UiErrorHandler {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException({
            Restore-UiAfterDialog -Owner $script:MainForm
            foreach ($open in @([System.Windows.Forms.Application]::OpenForms)) {
                if ($open -and $open -ne $script:MainForm -and -not $open.IsDisposed) {
                    try { $open.Close() } catch { }
                }
            }
            if ($script:ShowingError) { return }
            $script:ShowingError = $true
            try {
                Show-SteamErrorDialog -ErrorObject $_.Exception
            }
            finally {
                $script:ShowingError = $false
                Restore-UiAfterDialog -Owner $script:MainForm
            }
        })
    [System.AppDomain]::CurrentDomain.add_UnhandledException({
            if ($script:ShowingError) { return }
            $script:ShowingError = $true
            try {
                Show-SteamErrorDialog -ErrorObject $_.ExceptionObject
            }
            finally {
                $script:ShowingError = $false
                Restore-UiAfterDialog -Owner $script:MainForm
            }
        })
}

function Enable-DarkTitleBar {
    param([System.Windows.Forms.Form]$Form)
    $apply = {
        try { [SteamChrome]::UseDarkTitleBar($Form.Handle) } catch { }
    }.GetNewClosure()
    $Form.Add_HandleCreated({ & $apply }.GetNewClosure())
    if ($Form.IsHandleCreated) { & $apply }
}

function Enable-DoubleBuffer {
    param([System.Windows.Forms.Control]$Control)
    $prop = $Control.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
    if ($prop) { $prop.SetValue($Control, $true, $null) }
}

function New-UiFont {
    param(
        [float]$Size = 9.5,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )
    return New-Object System.Drawing.Font('Segoe UI', $Size, $Style)
}

function New-UiLabel {
    param(
        [string]$Text,
        [float]$Size = 9.5,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular,
        $Fore = $null,
        [switch]$Auto,
        [switch]$Flush
    )
    $label = if ($Flush) { New-Object SteamText } else { New-Object System.Windows.Forms.Label }
    $label.Text = $Text
    $label.Font = New-UiFont -Size $Size -Style $Style
    $label.ForeColor = $(if ($Fore) { $Fore } else { $script:Ui.Text })
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.Margin = New-Object System.Windows.Forms.Padding(0)
    $label.Padding = New-Object System.Windows.Forms.Padding(0)
    if ($Auto) { $label.AutoSize = $true }
    return $label
}

function New-UiButton {
    param(
        [string]$Text,
        [int]$Width = 140,
        [int]$Height = 36,
        [int]$Arrow = 0,
        $Clear = $null,
        [switch]$Primary,
        [switch]$Danger
    )
    $button = New-Object SteamButton
    $button.Text = $Text
    $button.Width = $Width
    $button.Height = $Height
    $button.IsPrimary = [bool]$Primary
    $button.IsDanger = [bool]$Danger
    $button.Arrow = $Arrow
    $button.Font = New-UiFont -Size 9.5 -Style Bold
    $button.ForeColor = [System.Drawing.Color]::White
    $clearColor = if ($Clear) { $Clear } else { $script:Ui.Surface }
    $button.ClearColor = $clearColor
    return $button
}

function New-PatreonLink {
    $row = New-Object System.Windows.Forms.Panel
    $row.Height = 36
    $row.Width = 118
    $row.BackColor = $script:Ui.Surface
    $row.Cursor = [System.Windows.Forms.Cursors]::Hand
    $row.Visible = -not [string]::IsNullOrWhiteSpace($script:PatreonUrl)

    $mark = New-Object SteamPatreonMark
    $mark.ClearColor = $script:Ui.Surface
    $mark.SetBounds(0, 7, 22, 22)

    $label = New-UiLabel -Text 'Patreon' -Size 9.5 -Flush
    $label.BackColor = $script:Ui.Surface
    $label.ForeColor = $script:Ui.Muted
    $label.Cursor = [System.Windows.Forms.Cursors]::Hand
    $label.SetBounds(28, 6, 86, 24)

    $url = $script:PatreonUrl
    $muted = $script:Ui.Muted
    $hot = [System.Drawing.Color]::FromArgb(255, 66, 77)
    $open = {
        if ([string]::IsNullOrWhiteSpace($url)) { return }
        Start-Process $url
    }.GetNewClosure()
    foreach ($c in @($row, $mark, $label)) {
        $c.Add_Click($open)
        $c.Add_MouseEnter({
                $label.ForeColor = $hot
            }.GetNewClosure())
        $c.Add_MouseLeave({
                $label.ForeColor = $muted
            }.GetNewClosure())
    }
    $row.Controls.Add($mark)
    $row.Controls.Add($label)
    return $row
}

function Get-CardListGutter { return 28 }

function Get-CardHostInnerWidth {
    $hostPanel = $script:CardHost
    $gutter = Get-CardListGutter
    if (-not $hostPanel) { return 480 }
    if ($hostPanel -is [SteamScrollView]) {
        # Content is view width minus the 12px scrollbar gutter. Keep a 28px
        # visual margin on both sides of the window: 28 left, 12+16 right.
        $w = $hostPanel.Content.Width - (($gutter * 2) - 12)
        if ($w -lt 360) { $w = 360 }
        return $w
    }
    $pad = $hostPanel.Padding.Left + $hostPanel.Padding.Right
    $w = $hostPanel.ClientSize.Width - $pad - ($gutter * 2)
    if ($w -lt 360) { $w = 360 }
    return $w
}

function Get-DriveCardMetrics {
    param(
        [int]$Width,
        [bool]$Custom
    )
    $pad = 20
    $indexW = 24
    $btn = 28
    $gap = 8
    $textLeft = $pad + $indexW + 4
    $textInset = 3
    $btnBlock = if ($Custom) { ($btn * 2) + $gap } else { 0 }
    $rightReserve = $pad + $btnBlock
    $textWidth = [Math]::Max(80, $Width - $textLeft - $rightReserve)
    $barLeft = $textLeft + $textInset
    $barGap = if ($Custom) { 14 } else { 0 }
    $barRight = $Width - $rightReserve - $barGap
    [pscustomobject]@{
        Pad        = $pad
        IndexX     = $pad
        TextLeft   = $textLeft
        TextWidth  = $textWidth
        BarLeft    = $barLeft
        BarWidth   = [Math]::Max(80, $barRight - $barLeft)
        Btn        = $btn
        UpX        = $Width - $pad - $btn - $gap - $btn
        DownX      = $Width - $pad - $btn
        BtnY       = 45
    }
}

function Update-DriveCardLayout {
    param(
        $Card,
        [int]$Width
    )
    $custom = $false
    foreach ($c in $Card.Controls) {
        if ($c -is [SteamButton] -and $c.Arrow -ne 0) { $custom = $true; break }
    }
    $m = Get-DriveCardMetrics -Width $Width -Custom $custom
    $Card.Width = $Width
    foreach ($inner in $Card.Controls) {
        if ($inner.Name -eq 'up') {
            $inner.SetBounds($m.UpX, $m.BtnY, $m.Btn, $m.Btn)
        }
        elseif ($inner.Name -eq 'down') {
            $inner.SetBounds($m.DownX, $m.BtnY, $m.Btn, $m.Btn)
        }
        elseif ($inner.Name -eq 'index') {
            $inner.Left = $m.IndexX
        }
        elseif ($inner.Name -eq 'bar') {
            $inner.SetBounds($m.BarLeft, $inner.Top, $m.BarWidth, $inner.Height)
        }
        elseif ($inner.Name -eq 'text') {
            $inner.Left = $m.TextLeft
            $inner.Width = $m.TextWidth
        }
    }
}

function Set-CardChromeColor {
    param($Card, $Color)
    Set-ControlBackColor $Card $Color
    foreach ($c in $Card.Controls) {
        if ($c -is [SteamButton]) {
            $c.ClearColor = $Color
        }
        elseif ($c -is [System.Windows.Forms.Label]) {
            $c.BackColor = $Color
        }
    }
}

function Move-LibraryInList {
    param([int]$From, [int]$To)
    if ($From -eq $To -or $From -lt 0 -or $To -lt 0) { return }
    if ($From -ge $script:Libraries.Count -or $To -ge $script:Libraries.Count) { return }
    $item = $script:Libraries[$From]
    $script:Libraries.RemoveAt($From)
    $script:Libraries.Insert($To, $item)
}

function Get-DriveAccent {
    param([string]$Drive)
    $letter = if ($Drive) { $Drive.Substring(0, 1).ToUpperInvariant() } else { '?' }
    switch ($letter) {
        'C' { return [System.Drawing.Color]::FromArgb(76, 168, 255) }
        'D' { return [System.Drawing.Color]::FromArgb(94, 214, 196) }
        'E' { return [System.Drawing.Color]::FromArgb(255, 184, 92) }
        'F' { return [System.Drawing.Color]::FromArgb(188, 140, 255) }
        'G' { return [System.Drawing.Color]::FromArgb(255, 128, 160) }
        default { return $script:Ui.Accent }
    }
}

function New-CardDragState {
    return @{
        Index   = -1
        Armed   = $false
        Active  = $false
        From    = -1
        Hover   = -1
        Start   = [System.Drawing.Point]::Empty
        Grab    = [System.Drawing.Point]::Empty
        Card    = $null
        Ghost   = $null
        Targets = $null
    }
}

function Get-CardListContent {
    $hostPanel = $script:CardHost
    if (-not $hostPanel) { return $null }
    if ($hostPanel -is [SteamScrollView]) { return $hostPanel.Content }
    return $hostPanel
}

function Get-CardDragSlotIndex {
    $content = Get-CardListContent
    if (-not $content -or -not $script:Libraries) { return 0 }
    $n = $script:Libraries.Count
    if ($n -lt 1) { return 0 }
    $pt = $content.PointToClient([System.Windows.Forms.Control]::MousePosition)
    $slot = [int][Math]::Floor(($pt.Y - 16) / 130)
    if ($slot -lt 0) { $slot = 0 }
    if ($slot -gt ($n - 1)) { $slot = $n - 1 }
    return $slot
}

function Set-LiveCardSlotTargets {
    $content = Get-CardListContent
    if (-not $content) { return }
    $from = [int]$script:Drag.From
    $hover = [int]$script:Drag.Hover
    $n = $script:Libraries.Count
    $others = New-Object System.Collections.Generic.List[object]
    foreach ($c in $content.Controls) {
        if ([int]$c.Tag -ne $from) { [void]$others.Add($c) }
    }
    $sorted = @($others | Sort-Object { [int]$_.Tag })
    $targets = @{}
    $oi = 0
    for ($slot = 0; $slot -lt $n; $slot++) {
        $y = 16 + ($slot * 130)
        if ($slot -eq $hover) {
            $targets["$from"] = $y
            continue
        }
        if ($oi -lt $sorted.Count) {
            $card = $sorted[$oi]
            $targets[("{0}" -f [int]$card.Tag)] = $y
            $oi++
        }
    }
    $script:Drag.Targets = $targets
}

function Initialize-CardDragSupport {
    if ($null -ne $script:DragFilter) { return }
    $filter = New-Object SteamDragFilter
    $filter.add_DragMove({ Update-CardDrag })
    $filter.add_DragEnd({ Stop-CardDrag })
    [System.Windows.Forms.Application]::AddMessageFilter($filter)
    $script:DragFilter = $filter

    $anim = New-Object System.Windows.Forms.Timer
    $anim.Interval = 12
    $anim.add_Tick({ Update-CardDragAnimation })
    $script:DragAnim = $anim
}

function Test-LibraryIsCDrive {
    param($Library)
    if (-not $Library -or -not $Library.Path) { return $false }
    return (Get-PathDriveLetter -Path $Library.Path) -eq 'C'
}

function Show-CDriveMoveWarning {
    if (-not $script:WarnBanner) { return }
    if ($null -ne $script:WarnBannerHide) { $script:WarnBannerHide.Stop() }
    $script:WarnBanner.Visible = $true
    $script:WarnBanner.BringToFront()
}

function Hide-CDriveMoveWarning {
    param([int]$DelayMs = 0)
    if (-not $script:WarnBanner) { return }
    if ($DelayMs -le 0) {
        if ($null -ne $script:WarnBannerHide) { $script:WarnBannerHide.Stop() }
        $script:WarnBanner.Visible = $false
        return
    }
    if ($null -eq $script:WarnBannerHide) {
        $timer = New-Object System.Windows.Forms.Timer
        $timer.add_Tick({
                if ($null -ne $script:WarnBannerHide) { $script:WarnBannerHide.Stop() }
                if ($null -ne $script:WarnBanner) { $script:WarnBanner.Visible = $false }
            })
        $script:WarnBannerHide = $timer
    }
    $script:WarnBannerHide.Stop()
    $script:WarnBannerHide.Interval = $DelayMs
    $script:WarnBannerHide.Start()
}

function Start-CardDrag {
    param([System.Windows.Forms.Control]$Card)
    if (-not $Card -or $script:Drag.Active) { return }
    Initialize-CardDragSupport
    $from = [int]$Card.Tag
    $script:Drag.Active = $true
    $script:Drag.Armed = $false
    $script:Drag.From = $from
    $script:Drag.Hover = $from
    $script:Drag.Index = $from
    $script:Drag.Card = $Card
    $script:Drag.Grab = $Card.PointToClient([System.Windows.Forms.Control]::MousePosition)

    $bmp = New-Object System.Drawing.Bitmap($Card.Width, $Card.Height)
    $Card.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $Card.Width, $Card.Height)))

    foreach ($child in $Card.Controls) { $child.Visible = $false }
    $Card.Placeholder = $true
    $Card.Invalidate()

    $ghost = New-Object SteamGhost
    $ghost.Frame = $bmp
    $ghost.Size = $Card.Size
    $screen = [System.Windows.Forms.Control]::MousePosition
    $ghost.Location = New-Object System.Drawing.Point(($screen.X - $script:Drag.Grab.X), ($screen.Y - $script:Drag.Grab.Y))
    [void]$ghost.Show()
    $script:Drag.Ghost = $ghost
    $Card.Capture = $true
    $script:DragFilter.Active = $true
    Set-LiveCardSlotTargets
    $script:DragAnim.Start()
    $lib = $null
    if ($script:Libraries -and $from -ge 0 -and $from -lt $script:Libraries.Count) {
        $lib = $script:Libraries[$from]
    }
    if (Test-LibraryIsCDrive -Library $lib) {
        Show-CDriveMoveWarning
    }
}

function Update-CardDrag {
    if (-not $script:Drag.Active) { return }
    $ghost = $script:Drag.Ghost
    if ($ghost -and -not $ghost.IsDisposed) {
        $screen = [System.Windows.Forms.Control]::MousePosition
        $ghost.Location = New-Object System.Drawing.Point(($screen.X - $script:Drag.Grab.X), ($screen.Y - $script:Drag.Grab.Y))
    }
    $hover = Get-CardDragSlotIndex
    if ($hover -ne [int]$script:Drag.Hover) {
        $script:Drag.Hover = $hover
        Set-LiveCardSlotTargets
    }
    $view = $script:CardHost
    if ($view -is [SteamScrollView]) {
        $vpt = $view.PointToClient([System.Windows.Forms.Control]::MousePosition)
        if ($vpt.Y -lt 40) {
            $view.AnimateTo($view.Offset - 48)
        }
        elseif ($vpt.Y -gt ($view.Height - 40)) {
            $view.AnimateTo($view.Offset + 48)
        }
    }
}

function Update-CardDragAnimation {
    if (-not $script:Drag.Active -or -not $script:Drag.Targets) { return }
    $content = Get-CardListContent
    if (-not $content) { return }
    foreach ($c in $content.Controls) {
        $key = '{0}' -f [int]$c.Tag
        if (-not $script:Drag.Targets.ContainsKey($key)) { continue }
        $ty = [int]$script:Drag.Targets[$key]
        $dy = $ty - $c.Top
        if ([Math]::Abs($dy) -le 1) { $c.Top = $ty }
        else { $c.Top += [int][Math]::Round($dy * 0.36) }
    }
}

function Stop-CardDrag {
    if (-not $script:Drag -or -not $script:Drag.Active) {
        if ($script:Drag) { $script:Drag.Armed = $false }
        return
    }
    $from = [int]$script:Drag.From
    $to = [int]$script:Drag.Hover
    $script:Drag.Active = $false
    $script:Drag.Armed = $false
    $script:Drag.Index = -1
    if ($script:DragFilter) { $script:DragFilter.Active = $false }
    if ($script:DragAnim) { $script:DragAnim.Stop() }
    if ($script:Drag.Ghost) {
        try {
            $script:Drag.Ghost.Close()
            $script:Drag.Ghost.Dispose()
        }
        catch { }
        $script:Drag.Ghost = $null
    }
    $card = $script:Drag.Card
    if ($card -and -not $card.IsDisposed) {
        $card.Capture = $false
        $card.Placeholder = $false
        foreach ($child in $card.Controls) { $child.Visible = $true }
    }
    $script:Drag.Card = $null
    $script:Drag.Targets = $null
    $lib = $null
    if ($script:Libraries -and $from -ge 0 -and $from -lt $script:Libraries.Count) {
        $lib = $script:Libraries[$from]
    }
    $drop = $from
    if ($to -ge 0) { $drop = $to }
    if (Test-LibraryIsCDrive -Library $lib) {
        if ($drop -eq $from -or $drop -eq 0) {
            Hide-CDriveMoveWarning
        }
    }
    if ($to -ge 0 -and $to -ne $from) {
        Move-LibraryInList -From $from -To $to
    }
    Rebuild-DriveCards
}

function Add-CardDragHandlers {
    param(
        [System.Windows.Forms.Control]$Control,
        [System.Windows.Forms.Control]$Card
    )
    $drag = $script:Drag
    $cardRef = $Card
    $Control.Add_MouseDown({
            param($sender, $event)
            if ($event.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
            $drag.Index = [int]$cardRef.Tag
            $drag.Start = $event.Location
            $drag.Armed = $true
        }.GetNewClosure())
    $Control.Add_MouseMove({
            param($sender, $event)
            if (-not $drag.Armed -or $drag.Active) { return }
            if ($event.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
            $dx = $event.X - $drag.Start.X
            $dy = $event.Y - $drag.Start.Y
            if ([Math]::Abs($dx) -lt 5 -and [Math]::Abs($dy) -lt 5) { return }
            $drag.Armed = $false
            Start-CardDrag -Card $cardRef
        }.GetNewClosure())
    $Control.Add_MouseUp({
            if (-not $drag.Active) { $drag.Armed = $false }
        }.GetNewClosure())
}

function New-DriveCard {
    param(
        [int]$Index,
        $Library,
        [int]$Width
    )

    $info = Get-LibraryDisplayInfo -Library $Library
    $accent = Get-DriveAccent -Drive $info.Drive
    $custom = $true
    $titleText = if ($info.Drive) { '{0} ({1})' -f $info.Label, $info.Drive } else { $info.Label }
    $m = Get-DriveCardMetrics -Width $Width -Custom $custom

    $card = New-Object SteamCard
    $card.Width = $Width
    $card.Height = 124
    $card.BackColor = $script:Ui.Card
    $card.ClearColor = $script:Ui.Bg
    $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
    $card.Tag = $Index

    $order = New-UiLabel -Text ('{0}' -f ($Index + 1)) -Size 10 -Style Bold -Fore $script:Ui.AccentSoft
    $order.Name = 'index'
    $order.AutoSize = $false
    $order.BackColor = $script:Ui.Card
    $order.SetBounds($m.IndexX, 16, 24, 24)
    $order.TextAlign = 'MiddleLeft'

    $name = New-UiLabel -Text $titleText -Size 12.5 -Style Bold
    $name.Name = 'text'
    $name.AutoSize = $false
    $name.BackColor = $script:Ui.Card
    $name.SetBounds($m.TextLeft, 14, $m.TextWidth, 28)

    $space = New-UiLabel -Text $(if ($info.Space) { $info.Space } else { $info.Path }) -Size 9 -Fore $script:Ui.Muted
    $space.Name = 'text'
    $space.AutoSize = $false
    $space.BackColor = $script:Ui.Card
    $space.SetBounds($m.TextLeft, 42, $m.TextWidth, 22)

    $bar = New-Object SteamUsageBar
    $bar.Name = 'bar'
    $bar.UsedPercent = [float]$info.UsedPercent
    $bar.BarBack = $script:Ui.BarBack
    $bar.BarFill = $accent
    $bar.SetBounds($m.BarLeft, 68, $m.BarWidth, 10)

    $path = New-UiLabel -Text $info.Path -Size 8.5 -Fore $script:Ui.Muted
    $path.Name = 'text'
    $path.AutoSize = $false
    $path.BackColor = $script:Ui.Card
    $path.SetBounds($m.TextLeft, 86, $m.TextWidth, 22)

    $card.Controls.Add($path)
    $card.Controls.Add($bar)
    $card.Controls.Add($space)
    $card.Controls.Add($name)
    $card.Controls.Add($order)

    if ($custom) {
        $up = New-UiButton -Arrow 1 -Clear $script:Ui.Card -Width $m.Btn -Height $m.Btn
        $up.Name = 'up'
        $up.SetBounds($m.UpX, $m.BtnY, $m.Btn, $m.Btn)
        $up.Tag = $Index
        $up.Add_Click({
                $i = [int]$this.Tag
                if ($i -le 0) { return }
                Move-LibraryInList -From $i -To ($i - 1)
                Rebuild-DriveCards
            })

        $down = New-UiButton -Arrow (-1) -Clear $script:Ui.Card -Width $m.Btn -Height $m.Btn
        $down.Name = 'down'
        $down.SetBounds($m.DownX, $m.BtnY, $m.Btn, $m.Btn)
        $down.Tag = $Index
        $down.Add_Click({
                $i = [int]$this.Tag
                if ($i -ge $script:Libraries.Count - 1) { return }
                Move-LibraryInList -From $i -To ($i + 1)
                Rebuild-DriveCards
            })

        $card.Controls.Add($up)
        $card.Controls.Add($down)
        $card.Cursor = [System.Windows.Forms.Cursors]::SizeAll
        Add-CardDragHandlers -Control $card -Card $card
        foreach ($child in @($order, $name, $space, $bar, $path)) {
            $child.Cursor = [System.Windows.Forms.Cursors]::SizeAll
            Add-CardDragHandlers -Control $child -Card $card
        }
    }

    $cardHot = $script:Ui.CardHot
    $cardNorm = $script:Ui.Card
    $card.Add_MouseEnter({
            Set-CardChromeColor $this $cardHot
        }.GetNewClosure())
    $card.Add_MouseLeave({
            $over = $this.RectangleToScreen($this.ClientRectangle).Contains([System.Windows.Forms.Cursor]::Position)
            if (-not $over) { Set-CardChromeColor $this $cardNorm }
        }.GetNewClosure())

    return $card
}

function Rebuild-DriveCards {
    if (-not $script:CardHost) { return }
    $hostPanel = $script:CardHost
    $content = $hostPanel
    if ($hostPanel -is [SteamScrollView]) {
        $content = $hostPanel.Content
        $hostPanel.RefreshLayout()
    }
    $content.SuspendLayout()
    $content.Controls.Clear()
    $width = Get-CardHostInnerWidth
    $gutter = Get-CardListGutter
    $y = 16
    $i = 0
    foreach ($lib in $script:Libraries) {
        $card = New-DriveCard -Index $i -Library $lib -Width $width
        $card.Location = New-Object System.Drawing.Point($gutter, $y)
        [void]$content.Controls.Add($card)
        $y += $card.Height + 12
        $i++
    }
    $content.Height = $y + 8
    $content.ResumeLayout()
    if ($hostPanel -is [SteamScrollView]) {
        $hostPanel.RefreshLayout()
    }
    if ($script:WarnBanner -and $script:WarnBanner.Visible) {
        $cAtHome = $false
        if ($script:Libraries -and $script:Libraries.Count -gt 0) {
            $cAtHome = Test-LibraryIsCDrive -Library $script:Libraries[0]
        }
        if ($cAtHome) { Hide-CDriveMoveWarning }
    }
    if ($script:HintLabel) {
        $script:HintLabel.Text = 'Drag a drive, use the arrows, or Sort A-Z. Then apply.'
    }
}

function Show-SteamDriveOrderWindow {
    $form = New-Object SteamForm
    $form.Text = 'SteamDriveOrder'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(860, 680)
    $form.MinimumSize = New-Object System.Drawing.Size(760, 560)
    $form.BackColor = $script:Ui.Bg
    $form.ForeColor = $script:Ui.Text
    $form.Font = New-UiFont
    $form.ShowIcon = $false
    Enable-DoubleBuffer -Control $form
    Enable-DarkTitleBar -Form $form

    $warnBanner = New-UiLabel -Text 'Moving the C Drive is not recommended' -Size 9.5 -Style Bold -Fore $script:Ui.Text
    $warnBanner.Dock = 'Top'
    $warnBanner.Height = 32
    $warnBanner.TextAlign = 'MiddleCenter'
    $warnBanner.BackColor = $script:Ui.Accent2
    $warnBanner.Visible = $false
    $script:WarnBanner = $warnBanner

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 136
    $header.BackColor = $script:Ui.Surface

    $accentLine = New-Object System.Windows.Forms.Panel
    $accentLine.Height = 2
    $accentLine.Dock = 'Top'
    $accentLine.BackColor = $script:Ui.Accent

    $kicker = New-UiLabel -Text 'STORAGE' -Size 8 -Style Bold -Fore $script:Ui.Accent -Flush
    $kicker.BackColor = $script:Ui.Surface

    $title = New-UiLabel -Text 'Library Order' -Size 20 -Style Bold -Flush
    $title.BackColor = $script:Ui.Surface

    $hint = New-UiLabel -Text '' -Size 9.5 -Fore $script:Ui.Muted -Flush
    $hint.BackColor = $script:Ui.Surface
    $script:HintLabel = $hint

    $pathLabel = New-UiLabel -Text ("Steam  ·  {0}" -f (Format-DisplayPath $script:SteamPath)) -Size 8.5 -Fore $script:Ui.Muted -Flush
    $pathLabel.BackColor = $script:Ui.Surface

    $placeHeaderText = {
        $left = Get-CardListGutter
        $textW = [Math]::Max(160, $header.ClientSize.Width - $left - 28)
        $kicker.SetBounds($left, 14, $textW, 18)
        $titleFlags = [System.Windows.Forms.TextFormatFlags]::NoPadding
        $titleWidth = [System.Windows.Forms.TextRenderer]::MeasureText(
            $title.Text,
            $title.Font,
            (New-Object System.Drawing.Size(400, 40)),
            $titleFlags
        ).Width
        $title.SetBounds($left, 32, [Math]::Max(80, $titleWidth + 4), 40)
        $hint.SetBounds($left, 72, $textW, 26)
        $pathLabel.SetBounds($left, 100, $textW, 22)
    }
    $header.Add_Resize({ & $placeHeaderText }.GetNewClosure())
    & $placeHeaderText

    $header.Controls.Add($accentLine)
    $header.Controls.Add($kicker)
    $header.Controls.Add($title)
    $header.Controls.Add($hint)
    $header.Controls.Add($pathLabel)

    $footer = New-Object System.Windows.Forms.Panel
    $footer.Dock = 'Bottom'
    $footer.Height = 78
    $footer.BackColor = $script:Ui.Surface

    $patreonLink = New-PatreonLink
    $patreonLink.Location = New-Object System.Drawing.Point((Get-CardListGutter), 21)
    $script:PatreonRow = $patreonLink

    $btnSort = New-UiButton -Text 'Sort A-Z' -Width 110 -Height 36
    $btnForce = New-UiButton -Text 'Force' -Width 88 -Height 36 -Danger
    $btnForce.Visible = $false
    $btnApply = New-UiButton -Text 'Apply to Steam' -Width 168 -Height 36 -Primary
    $script:SortButton = $btnSort
    $script:ForceButton = $btnForce
    $script:ApplyButton = $btnApply
    $script:FooterPanel = $footer
    $script:MainForm = $form
    Update-ApplyButton

    $btnSort.Add_Click({
            Invoke-SortLibrariesAz
            Rebuild-DriveCards
        })
    $btnForce.Add_Click({ Invoke-ForceSteamClose })
    $btnApply.Add_Click({ Invoke-ApplyButtonClick })

    $footer.Controls.Add($patreonLink)
    $footer.Controls.Add($btnSort)
    $footer.Controls.Add($btnForce)
    $footer.Controls.Add($btnApply)
    $footer.Add_Resize({ Update-FooterButtons })
    Update-FooterButtons

    $hostPanel = New-Object SteamScrollView
    $script:CardHost = $hostPanel
    $hostPanel.Dock = 'Fill'
    $hostPanel.BackColor = $script:Ui.Bg
    $hostPanel.Content.BackColor = $script:Ui.Bg
    Enable-DoubleBuffer -Control $hostPanel

    $form.Add_FormClosed({
            Stop-ApplyUiTimers
            if ($script:Drag -and $script:Drag.Active) { Stop-CardDrag }
        })

    $form.Add_Resize({
            if (-not $script:CardHost) { return }
            if ($script:Drag -and $script:Drag.Active) { return }
            if ($script:CardHost -is [SteamScrollView]) {
                $script:CardHost.RefreshLayout()
                $width = Get-CardHostInnerWidth
                $gutter = Get-CardListGutter
                $y = 16
                foreach ($child in $script:CardHost.Content.Controls) {
                    $child.Left = $gutter
                    $child.Top = $y
                    Update-DriveCardLayout -Card $child -Width $width
                    $y += $child.Height + 12
                }
                $script:CardHost.Content.Height = $y + 8
                $script:CardHost.RefreshLayout()
            }
        })
    $form.Controls.Add($hostPanel)
    $form.Controls.Add($footer)
    $form.Controls.Add($warnBanner)
    $form.Controls.Add($header)
    $form.Add_Shown({
            Update-FooterButtons
            Rebuild-DriveCards
            Update-ApplyButton
            Start-ApplyIdleWatch
        })
    [void]$form.ShowDialog()
}

function Invoke-SteamDriveOrder {
    if ($Apply) {
        Invoke-CliApply
        return
    }
    Initialize-SteamDriveOrderUi
    $steam = Get-SteamInstallPath
    $state = Read-SteamLibraries -SteamPath $steam
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($lib in $state.Libraries) { $list.Add($lib) }
    $script:Meta = $state.Meta
    $script:Libraries = $list
    $script:SteamPath = $steam
    $script:Drag = New-CardDragState
    Show-SteamDriveOrderWindow
}

if (-not $SkipMain) {
    Invoke-SteamDriveOrder
}
