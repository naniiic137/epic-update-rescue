<#
.SYNOPSIS
    Stops the Epic Games Launcher from re-downloading a whole game after you paused or
    cancelled an update.

.DESCRIPTION
    When an update is paused, cancelled or interrupted (launcher closed, PC shut down),
    the Epic Games Launcher can mark the game as an "incomplete install". From then on it
    offers to download the full game again (for example 44 GB for Fortnite) and greys out
    Verify.

    This script makes the launcher treat the game as already updated, so Verify becomes
    available. Verify then checks the files you already have and downloads only what really
    changed. Everything it touches is backed up first, and -Undo puts it all back.

    Works for any game with this problem, and for games made of several parts
    (Fortnite: the game + Save the World + LEGO Fortnite content).

.PARAMETER List
    Show every game the launcher knows, and which ones are stuck as incomplete.

.PARAMETER Game
    The game to fix: its name (e.g. "Fortnite") or its app name. Without it, the script
    lists the stuck games and asks.

.PARAMETER CloseLauncher
    Close the Epic Games Launcher if it is running (it must be closed, or it overwrites the fix).

.PARAMETER Undo
    Put everything back from a backup folder made by an earlier run.

.PARAMETER Interactive
    Ask before closing the launcher and before changing anything (used by the double-click launcher).

.PARAMETER WhatIf
    Show what would change, change nothing.

.PARAMETER BackupRoot
    Where backups go. Default: Documents\EpicUpdateRescue\backups.

.PARAMETER ManifestsDir
    The launcher's records folder. Default: %ProgramData%\Epic\EpicGamesLauncher\Data\Manifests.

.EXAMPLE
    .\EpicUpdateRescue.ps1 -List
.EXAMPLE
    .\EpicUpdateRescue.ps1 -Game Fortnite -WhatIf
.EXAMPLE
    .\EpicUpdateRescue.ps1 -Game Fortnite -CloseLauncher
.EXAMPLE
    .\EpicUpdateRescue.ps1 -Undo "$env:USERPROFILE\Documents\EpicUpdateRescue\backups\Fortnite-20261016-140000"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$List,
    [string]$Game,
    [switch]$CloseLauncher,
    [string]$Undo,
    [switch]$Interactive,
    [string]$BackupRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'EpicUpdateRescue\backups'),
    [string]$ManifestsDir = (Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Version = '1.0.0'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:LauncherProcesses = @('EpicGamesLauncher', 'EpicWebHelper')

# ---------------------------------------------------------------- reading the launcher's records

function Read-TextKeepEncoding([string]$Path) {
    # Returns the text and whether the file started with a UTF-8 BOM, so it can be written back the same way.
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $start = if ($bom) { 3 } else { 0 }
    return @{ Text = [Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start); Bom = $bom }
}

function Write-TextKeepEncoding([string]$Path, [string]$Text, [bool]$Bom) {
    $enc = if ($Bom) { New-Object System.Text.UTF8Encoding($true) } else { $script:Utf8NoBom }
    [IO.File]::WriteAllText($Path, $Text, $enc)
}

function Get-Prop($Object, [string]$Name) {
    # Strict-mode-safe property read (records from older launchers may miss some fields).
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value } else { return $null }
}

function Get-EpicRecords([string]$Dir) {
    # Every .item record in Manifests\ (installed) and Manifests\Pending\ (pending / incomplete).
    $records = @()
    foreach ($folder in @(@{ Path = $Dir; Pending = $false }, @{ Path = (Join-Path $Dir 'Pending'); Pending = $true })) {
        if (-not (Test-Path -LiteralPath $folder.Path)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $folder.Path -Filter '*.item' -File) {
            try { $json = (Read-TextKeepEncoding $file.FullName).Text | ConvertFrom-Json }
            catch { Write-Warning "Skipping $($file.Name): not readable JSON ($($_.Exception.Message))"; continue }
            $main = [string](Get-Prop $json 'MainGameAppName')
            $app = [string](Get-Prop $json 'AppName')
            $records += [pscustomobject]@{
                File                 = $file.FullName
                Name                 = $file.Name
                InPendingFolder      = $folder.Pending
                DisplayName          = [string](Get-Prop $json 'DisplayName')
                AppName              = $app
                GameKey              = if ($main) { $main } else { $app }   # parts of a game share their main game's key
                IsPart               = [bool]$main
                Version              = [string](Get-Prop $json 'AppVersionString')
                Incomplete           = [bool](Get-Prop $json 'bIsIncompleteInstall')
                InstallLocation      = [string](Get-Prop $json 'InstallLocation')
                CompleteManifestPath = [string](Get-Prop $json 'CompleteManifestPath')
                PendingManifestPath  = [string](Get-Prop $json 'PendingManifestPath')
                InstallSize          = [double](Get-Prop $json 'InstallSize')
            }
        }
    }
    return , $records
}

function Get-GameName($Records, [string]$Key) {
    $main = @($Records | Where-Object { $_.GameKey -eq $Key -and -not $_.IsPart } | Select-Object -First 1)
    if ($main.Count) { return $main[0].DisplayName }
    return $Key
}

function Get-StuckGames($Records) {
    # Games with at least one incomplete record, each with all of its incomplete parts.
    $stuck = @($Records | Where-Object { $_.Incomplete })
    $games = @()
    foreach ($key in @($stuck | ForEach-Object { $_.GameKey } | Select-Object -Unique)) {
        $parts = @($stuck | Where-Object { $_.GameKey -eq $key } | Sort-Object IsPart, DisplayName)
        $games += [pscustomobject]@{ Key = $key; Name = (Get-GameName $Records $key); Parts = $parts; Version = $parts[0].Version }
    }
    return , $games
}

function Find-Game($Games, [string]$Query) {
    $q = $Query.Trim()
    $exact = @($Games | Where-Object { $_.Key -eq $q -or $_.Name -eq $q })
    if ($exact.Count) { return , $exact }
    return , @($Games | Where-Object { $_.Key -like "*$q*" -or $_.Name -like "*$q*" })
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

# ---------------------------------------------------------------- checking before changing anything

function Test-LauncherRunning {
    return [bool](Get-Process -Name $script:LauncherProcesses -ErrorAction SilentlyContinue)
}

function Stop-Launcher {
    Get-Process -Name $script:LauncherProcesses -ErrorAction SilentlyContinue | Stop-Process -Force
    for ($i = 0; $i -lt 20 -and (Test-LauncherRunning); $i++) { Start-Sleep -Milliseconds 250 }
    return -not (Test-LauncherRunning)
}

function Get-PartProblems($Part) {
    # Why this part can't be fixed (empty list = it can).
    $problems = @()
    if (-not $Part.InstallLocation -or -not (Test-Path -LiteralPath $Part.InstallLocation)) {
        $problems += "the game folder is missing ($($Part.InstallLocation))"
    }
    if (-not $Part.CompleteManifestPath) { $problems += 'the record has no CompleteManifestPath' }
    if (-not $Part.PendingManifestPath -or -not (Test-Path -LiteralPath $Part.PendingManifestPath)) {
        $problems += "the new version's file list isn't on disk ($($Part.PendingManifestPath)); the launcher hasn't fetched the update yet"
    }
    return , $problems
}

# ---------------------------------------------------------------- the fix

function New-FixPlan($GameInfo, [string]$Dir) {
    # One step list per part: what gets backed up, copied, edited, moved. Nothing is changed here.
    $steps = @()
    foreach ($p in $GameInfo.Parts) {
        $target = Join-Path $Dir $p.Name
        $steps += [pscustomobject]@{
            Part              = $p
            NewManifest       = $p.PendingManifestPath
            InstalledManifest = $p.CompleteManifestPath
            HadInstalled      = [bool]($p.CompleteManifestPath -and (Test-Path -LiteralPath $p.CompleteManifestPath))
            RecordFrom        = $p.File
            RecordTo          = $target
            ReplacesRecord    = ($p.File -ne $target) -and (Test-Path -LiteralPath $target)
        }
    }
    return , $steps
}

function Save-Backup($Plan, [string]$Root, [string]$GameName) {
    $safe = ($GameName -replace '[^\w\-]+', '_').Trim('_')
    if (-not $safe) { $safe = 'game' }
    $folder = Join-Path $Root ('{0}-{1}' -f $safe, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $toSave = @()
    foreach ($s in $Plan) {
        $toSave += , @($s.RecordFrom, 'record')
        if ($s.ReplacesRecord) { $toSave += , @($s.RecordTo, 'record-replaced') }
        $toSave += , @($s.NewManifest, 'new-filelist')
        if ($s.HadInstalled) { $toSave += , @($s.InstalledManifest, 'old-filelist') }
    }
    $entries = @()
    for ($i = 0; $i -lt $toSave.Count; $i++) {
        $original = $toSave[$i][0]
        $copy = '{0:D2}-{1}-{2}' -f ($i + 1), $toSave[$i][1], (Split-Path $original -Leaf)
        $dest = Join-Path $folder $copy
        Copy-Item -LiteralPath $original -Destination $dest
        if ((Get-FileHash -LiteralPath $original).Hash -ne (Get-FileHash -LiteralPath $dest).Hash) { throw "The backup copy of $original doesn't match the original" }
        $entries += [pscustomobject]@{ Original = $original; Backup = $copy; Kind = $toSave[$i][1] }
    }
    # what the fix creates, so Undo can remove it
    $created = @()
    foreach ($s in $Plan) {
        if ($s.RecordTo -ne $s.RecordFrom -and -not $s.ReplacesRecord) { $created += $s.RecordTo }
        if (-not $s.HadInstalled) { $created += $s.InstalledManifest }
    }
    $info = [pscustomobject]@{ Tool = 'EpicUpdateRescue'; ToolVersion = $script:Version; Game = $GameName; Made = (Get-Date).ToString('s'); Files = $entries; Created = $created }
    Write-TextKeepEncoding (Join-Path $folder 'restore.json') ($info | ConvertTo-Json -Depth 5) $false
    return $folder
}

function Set-RecordComplete([string]$Path) {
    # Change only "bIsIncompleteInstall": true -> false, keeping the rest of the file byte for byte.
    $file = Read-TextKeepEncoding $Path
    $rx = New-Object System.Text.RegularExpressions.Regex('("bIsIncompleteInstall"\s*:\s*)true')
    if ($rx.Matches($file.Text).Count -ne 1) { throw "$(Split-Path $Path -Leaf): expected exactly one `"bIsIncompleteInstall`": true" }
    $text = $rx.Replace($file.Text, '${1}false', 1)
    $null = $text | ConvertFrom-Json   # still valid JSON
    Write-TextKeepEncoding $Path $text $file.Bom
}

function Invoke-Fix($Plan) {
    foreach ($s in $Plan) {
        # 1. the new version's file list becomes the installed one
        $dir = Split-Path $s.InstalledManifest -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Copy-Item -LiteralPath $s.NewManifest -Destination $s.InstalledManifest -Force
        Remove-Item -LiteralPath $s.NewManifest -Force
        # 2. the record says: complete
        Set-RecordComplete $s.RecordFrom
        # 3. and leaves the Pending folder
        if ($s.RecordFrom -ne $s.RecordTo) { Move-Item -LiteralPath $s.RecordFrom -Destination $s.RecordTo -Force }
    }
}

function Invoke-Undo([string]$Folder) {
    $infoPath = Join-Path $Folder 'restore.json'
    if (-not (Test-Path -LiteralPath $infoPath)) { throw "No restore.json in ${Folder}: not a backup made by this tool" }
    $info = (Read-TextKeepEncoding $infoPath).Text | ConvertFrom-Json
    foreach ($c in @($info.Created)) { if ($c -and (Test-Path -LiteralPath $c)) { Remove-Item -LiteralPath $c -Force } }
    foreach ($f in @($info.Files)) {
        $dir = Split-Path $f.Original -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Copy-Item -LiteralPath (Join-Path $Folder $f.Backup) -Destination $f.Original -Force
    }
    return $info
}

# ---------------------------------------------------------------- talking to the person

function Write-Title([string]$Text) { Write-Host ''; Write-Host $Text -ForegroundColor Cyan }

function Show-List($Records) {
    if (-not $Records.Count) { Write-Host "No Epic Games Launcher records found in $ManifestsDir."; return }
    Write-Title 'Games the Epic Games Launcher knows'
    foreach ($key in @($Records | ForEach-Object { $_.GameKey } | Select-Object -Unique)) {
        $parts = @($Records | Where-Object { $_.GameKey -eq $key })
        $bad = @($parts | Where-Object { $_.Incomplete })
        $state = if ($bad.Count) { "STUCK ($($bad.Count) of $($parts.Count) parts marked incomplete)" } else { 'ok' }
        $color = if ($bad.Count) { 'Yellow' } else { 'Gray' }
        Write-Host ('  {0,-34} {1}' -f (Get-GameName $Records $key), $state) -ForegroundColor $color
    }
}

function Confirm-Yes([string]$Question) {
    $answer = Read-Host "$Question (y/n)"
    return $answer -match '^(y|yes|o|oui)$'
}

function Select-Game($Games) {
    Write-Title 'Games stuck as an incomplete install'
    for ($i = 0; $i -lt $Games.Count; $i++) {
        Write-Host ('  {0}. {1}  ({2} part(s), {3})' -f ($i + 1), $Games[$i].Name, $Games[$i].Parts.Count, $Games[$i].Version)
    }
    $answer = Read-Host "Which one? (1-$($Games.Count), Enter to cancel)"
    $n = 0
    if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $Games.Count) { return $Games[$n - 1] }
    return $null
}

function Main {
    Write-Host "Epic Update Rescue $script:Version" -ForegroundColor Cyan

    if ($Undo) {
        if (Test-LauncherRunning) {
            if (-not $CloseLauncher) { Write-Host 'Close the Epic Games Launcher first (tray icon > Exit), or add -CloseLauncher.' -ForegroundColor Yellow; return 2 }
            if (-not (Stop-Launcher)) { Write-Host 'Could not close the launcher.' -ForegroundColor Red; return 2 }
        }
        if ($WhatIfPreference) { Write-Host "WhatIf: would restore the backup in $Undo. Nothing changed."; return 0 }
        $info = Invoke-Undo $Undo
        Write-Host "Restored $($info.Game) as it was on $($info.Made)." -ForegroundColor Green
        return 0
    }

    if (-not (Test-Path -LiteralPath $ManifestsDir)) {
        Write-Host "The Epic Games Launcher's records folder wasn't found: $ManifestsDir" -ForegroundColor Red
        Write-Host 'Is the launcher installed? (Or point -ManifestsDir at it.)'
        return 1
    }
    $records = Get-EpicRecords $ManifestsDir
    if ($List) { Show-List $records; return 0 }

    $games = Get-StuckGames $records
    if (-not $games.Count) {
        Write-Host 'No game is stuck as an incomplete install: nothing to fix.' -ForegroundColor Green
        Write-Host '(If the launcher still wants a full download, run with -List and check the game is there.)'
        return 0
    }
    if ($Game) {
        $found = Find-Game $games $Game
        if ($found.Count -ne 1) {
            $why = if ($found.Count) { 'matches more than one game, be more precise' } else { "isn't stuck (or isn't known)" }
            Write-Host "`"$Game`" $why." -ForegroundColor Yellow
            Show-List $records
            return 1
        }
        $pick = $found[0]
    } else {
        $pick = if ($games.Count -eq 1) { $games[0] } else { Select-Game $games }
        if (-not $pick) { Write-Host 'Cancelled.'; return 0 }
    }

    Write-Title "$($pick.Name): $($pick.Parts.Count) part(s) marked as an incomplete install"
    $blocked = $false
    foreach ($p in $pick.Parts) {
        $problems = Get-PartProblems $p
        $mark = if ($problems.Count) { 'X' } else { 'ok' }
        Write-Host ('  [{0}] {1}  {2}  ({3})' -f $mark, $p.DisplayName, $p.Version, (Format-Size $p.InstallSize))
        foreach ($pr in $problems) { Write-Host "       $pr" -ForegroundColor Red; $blocked = $true }
    }
    if ($blocked) {
        Write-Host ''
        Write-Host "Can't fix this one safely, nothing was changed." -ForegroundColor Red
        return 1
    }

    if (Test-LauncherRunning) {
        if ($WhatIfPreference) { Write-Host 'Note: the launcher is running; it must be closed for the real run (-CloseLauncher does it).' -ForegroundColor Yellow }
        elseif (-not $CloseLauncher -and -not ($Interactive -and (Confirm-Yes 'The Epic Games Launcher is running and would undo the fix. Close it now?'))) {
            Write-Host ''
            Write-Host 'The Epic Games Launcher is running, and it would undo the fix.' -ForegroundColor Yellow
            Write-Host 'Exit it (tray icon > Exit) and run this again, or add -CloseLauncher.'
            return 2
        } elseif (-not (Stop-Launcher)) { Write-Host 'Could not close the launcher.' -ForegroundColor Red; return 2 }
        else { Write-Host 'Closed the Epic Games Launcher.' }
    }

    $plan = New-FixPlan $pick $ManifestsDir
    Write-Title 'What will change'
    foreach ($s in $plan) {
        Write-Host "  $($s.Part.DisplayName):"
        Write-Host "    - the new version's file list becomes the installed one"
        Write-Host '    - the record is marked complete and moves out of Pending'
        if ($s.ReplacesRecord) { Write-Host '    - it replaces an older record of the same part (kept in the backup)' }
    }
    if ($WhatIfPreference) { Write-Host ''; Write-Host 'WhatIf: nothing was changed.' -ForegroundColor Green; return 0 }
    if ($Interactive -and -not (Confirm-Yes 'Go ahead?')) { Write-Host 'Cancelled, nothing changed.'; return 0 }

    $backup = Save-Backup $plan $BackupRoot $pick.Name
    Write-Host "Backup: $backup" -ForegroundColor Gray
    try { Invoke-Fix $plan }
    catch {
        Write-Host "Something failed ($($_.Exception.Message)); putting everything back..." -ForegroundColor Red
        if ($_.Exception -is [UnauthorizedAccessException]) { Write-Host 'Windows refused access: run it again as administrator (right-click > Run as administrator).' -ForegroundColor Yellow }
        $null = Invoke-Undo $backup
        Write-Host 'Restored. Nothing changed.' -ForegroundColor Yellow
        return 1
    }

    Write-Title 'Done. Now, in the Epic Games Launcher:'
    Write-Host "  1. Open it. $($pick.Name) should show as installed, with no update."
    Write-Host "  2. Library > $($pick.Name) > ... > Manage > Verify."
    Write-Host "  3. Let it finish: don't pause it and don't close the launcher. It checks your files first"
    Write-Host '     (slow on a hard drive), then downloads only what changed.'
    Write-Host ''
    Write-Host 'To put everything back:' -ForegroundColor Gray
    Write-Host "  .\EpicUpdateRescue.ps1 -Undo `"$backup`"" -ForegroundColor Gray
    return 0
}

# Run only when started as a script, not when dot-sourced by the tests.
if ($MyInvocation.InvocationName -ne '.') {
    try { $code = Main | Select-Object -Last 1 } catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red; $code = 1 }
    exit $code
}
