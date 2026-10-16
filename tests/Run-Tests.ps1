# Tests for EpicUpdateRescue.ps1. They build a fake Epic Games Launcher setup in a temp folder
# (records, file lists, a game folder) and never touch the real launcher or its files.
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1   (or pwsh)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\EpicUpdateRescue.ps1')   # loads the functions; Main doesn't run
Set-StrictMode -Off

# never look at, or close, a real launcher
$script:FakeLauncherRunning = $false
function Test-LauncherRunning { return $script:FakeLauncherRunning }
function Stop-Launcher { $script:FakeLauncherRunning = $false; return $true }
function Write-Host { }   # keep the output to the test results

$script:Passed = 0; $script:Failed = 0
function Check([bool]$Condition, [string]$What) {
    if ($Condition) { $script:Passed++; [Console]::WriteLine("  ok    $What") }
    else { $script:Failed++; [Console]::WriteLine("  FAIL  $What") }
}

function New-Record([string]$Path, [hashtable]$Fields, [bool]$Bom = $false, [bool]$Crlf = $true) {
    # Written by hand like the launcher does: tabs, CRLF, key order kept.
    $nl = if ($Crlf) { "`r`n" } else { "`n" }
    $lines = @()
    foreach ($k in $Fields.Keys) {
        $v = $Fields[$k]
        $json = if ($v -is [bool]) { $v.ToString().ToLower() } elseif ($v -is [int] -or $v -is [long]) { "$v" } else { '"' + ($v -replace '\\', '\\') + '"' }
        $lines += "`t`"$k`": $json"
    }
    $text = '{' + $nl + ($lines -join (',' + $nl)) + $nl + '}'
    $enc = New-Object System.Text.UTF8Encoding($Bom)
    [IO.File]::WriteAllText($Path, $text, $enc)
}

function New-FakeSetup {
    # A Fortnite stuck like on 16/10/2026: 3 parts, all in Pending\, one part (LEGO) never installed before;
    # plus a healthy game that must never be touched.
    $root = Join-Path ([IO.Path]::GetTempPath()) ('eur-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $m = Join-Path $root 'Manifests'; $game = Join-Path $root 'Games\Fortnite'; $eg = Join-Path $game '.egstore'
    foreach ($d in @("$m\Pending", "$eg\Pending", "$root\Games\Other\.egstore", "$root\backups")) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [IO.File]::WriteAllText("$game\FortniteGame.pak", 'game data')
    $parts = @(
        @{ Id = 'AAA1'; Name = 'Fortnite'; App = 'Fortnite'; Main = ''; Installed = $true },
        @{ Id = 'BBB2'; Name = 'Fortnite Save the World Content'; App = 'stw0001'; Main = 'Fortnite'; Installed = $true },
        @{ Id = 'CCC3'; Name = 'LEGO Fortnite Content'; App = 'lego0001'; Main = 'Fortnite'; Installed = $false }
    )
    foreach ($p in $parts) {
        $fields = [ordered]@{
            FormatVersion = 0; bIsIncompleteInstall = $true; ManifestLocation = $eg
            CompleteManifestPath = "$eg\$($p.Id).manifest"; PendingManifestPath = "$eg\Pending\$($p.Id).manifest"
            DisplayName = $p.Name; InstallLocation = $game; InstallSize = 1000000; AppName = $p.App
            AppVersionString = '++Fortnite+Release-42.40-CL-59086525-Windows'; MainGameAppName = $p.Main
        }
        New-Record "$m\Pending\$($p.Id).item" $fields ($p.Id -eq 'BBB2')   # one record with a BOM
        [IO.File]::WriteAllBytes("$eg\Pending\$($p.Id).manifest", [byte[]](1..50 | ForEach-Object { [byte]($_ + 100) }))
        if ($p.Installed) { [IO.File]::WriteAllBytes("$eg\$($p.Id).manifest", [byte[]](1..40)) }
    }
    New-Record "$m\DDD4.item" ([ordered]@{ bIsIncompleteInstall = $false; DisplayName = 'Other Game'; AppName = 'Other'; InstallLocation = "$root\Games\Other"; CompleteManifestPath = "$root\Games\Other\.egstore\DDD4.manifest"; PendingManifestPath = ''; AppVersionString = '1.0'; MainGameAppName = '' })
    [IO.File]::WriteAllBytes("$root\Games\Other\.egstore\DDD4.manifest", [byte[]](1..10))
    return @{ Root = $root; Manifests = $m; Egstore = $eg; Backups = "$root\backups" }
}

function Get-Snapshot([string]$Root) {
    # relative path -> hash, for everything except the backups folder
    $snap = @{}
    Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.FullName -notlike "$Root\backups\*" } | ForEach-Object {
        $snap[$_.FullName.Substring($Root.Length)] = (Get-FileHash -LiteralPath $_.FullName).Hash
    }
    return $snap
}
function Same-Snapshot($A, $B) {
    if ($A.Count -ne $B.Count) { return $false }
    foreach ($k in $A.Keys) { if (-not $B.ContainsKey($k) -or $B[$k] -ne $A[$k]) { return $false } }
    return $true
}

function Run-Main([hashtable]$S, [hashtable]$Opts) {
    # Main reads these like the script's parameters
    $script:ManifestsDir = $S.Manifests; $script:BackupRoot = $S.Backups
    $script:Game = $Opts.Game; $script:List = [switch][bool]$Opts.List; $script:Undo = $Opts.Undo
    $script:CloseLauncher = [switch][bool]$Opts.CloseLauncher; $script:Interactive = [switch]$false
    $script:WhatIfPreference = [bool]$Opts.WhatIf
    $global:WhatIfPreference = [bool]$Opts.WhatIf
    try { return (Main | Select-Object -Last 1) } finally { $global:WhatIfPreference = $false }
}

[Console]::WriteLine('Finding stuck games')
$s = New-FakeSetup
$records = Get-EpicRecords $s.Manifests
Check ($records.Count -eq 4) 'reads all 4 records (3 pending + 1 installed)'
$games = Get-StuckGames $records
Check ($games.Count -eq 1 -and $games[0].Name -eq 'Fortnite') 'one stuck game: Fortnite'
Check ($games[0].Parts.Count -eq 3 -and -not $games[0].Parts[0].IsPart) 'its 3 parts, the game itself first'
Check ((Find-Game $games 'fortnite').Count -eq 1) 'finds it by name, any case'
Check ((Find-Game $games 'Fortnite').Count -eq 1) 'finds it by app name'
Check ((Find-Game $games 'Other Game').Count -eq 0) 'a healthy game is not offered'
Check ((Get-PartProblems $games[0].Parts[2]).Count -eq 0) 'a part never installed before (LEGO) can still be fixed'

[Console]::WriteLine('WhatIf changes nothing')
$before = Get-Snapshot $s.Root
$code = Run-Main $s @{ Game = 'Fortnite'; WhatIf = $true }
Check ($code -eq 0) 'returns 0'
Check (Same-Snapshot $before (Get-Snapshot $s.Root)) 'every file is unchanged'
Check (@(Get-ChildItem $s.Backups).Count -eq 0) 'no backup made'

[Console]::WriteLine('The launcher must be closed')
$script:FakeLauncherRunning = $true
$code = Run-Main $s @{ Game = 'Fortnite' }
Check ($code -eq 2) 'refuses (exit 2) while the launcher runs'
Check (Same-Snapshot $before (Get-Snapshot $s.Root)) 'and changes nothing'
$code = Run-Main $s @{ Game = 'Fortnite'; WhatIf = $true; CloseLauncher = $true }
Check ($script:FakeLauncherRunning) '-WhatIf never closes the launcher'
$script:FakeLauncherRunning = $false

[Console]::WriteLine('The fix')
$pendingText = @{}; foreach ($id in 'AAA1', 'BBB2', 'CCC3') { $pendingText[$id] = [IO.File]::ReadAllBytes("$($s.Manifests)\Pending\$id.item") }
$newLists = @{}; foreach ($id in 'AAA1', 'BBB2', 'CCC3') { $newLists[$id] = (Get-FileHash "$($s.Egstore)\Pending\$id.manifest").Hash }
$otherBefore = (Get-FileHash "$($s.Manifests)\DDD4.item").Hash
$code = Run-Main $s @{ Game = 'Fortnite' }
Check ($code -eq 0) 'returns 0'
foreach ($id in 'AAA1', 'BBB2', 'CCC3') {
    $moved = "$($s.Manifests)\$id.item"
    Check ((Test-Path $moved) -and -not (Test-Path "$($s.Manifests)\Pending\$id.item")) "$id record moved out of Pending"
    $json = Get-Content $moved -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($json.bIsIncompleteInstall -eq $false) "$id marked complete"
    $was = [Text.Encoding]::UTF8.GetString($pendingText[$id]); $now = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($moved))
    Check ($now -eq $was.Replace('"bIsIncompleteInstall": true', '"bIsIncompleteInstall": false')) "$id record otherwise identical (encoding, BOM, CRLF, tabs)"
    Check ((Get-FileHash "$($s.Egstore)\$id.manifest").Hash -eq $newLists[$id]) "${id}: the new file list is now the installed one"
    Check (-not (Test-Path "$($s.Egstore)\Pending\$id.manifest")) "${id}: the pending file list is gone"
}
Check ((Get-FileHash "$($s.Manifests)\DDD4.item").Hash -eq $otherBefore) 'the healthy game is untouched'
Check (Test-Path "$($s.Root)\Games\Fortnite\FortniteGame.pak") 'game files are never touched'
$backup = @(Get-ChildItem $s.Backups -Directory)
Check ($backup.Count -eq 1 -and (Test-Path "$($backup[0].FullName)\restore.json")) 'one backup folder with restore.json'
Check (@(Get-ChildItem $backup[0].FullName -File).Count -eq 9) 'it holds 3 records + 3 new + 2 old file lists (+ restore.json)'
$stuckAfter = Get-StuckGames (Get-EpicRecords $s.Manifests)
Check ($stuckAfter.Count -eq 0) 'nothing is stuck any more'

[Console]::WriteLine('Undo puts everything back')
$code = Run-Main $s @{ Undo = $backup[0].FullName }
Check ($code -eq 0) 'returns 0'
Check (Same-Snapshot $before (Get-Snapshot $s.Root)) 'every file is exactly as before the fix (LEGO''s new installed file list removed too)'

[Console]::WriteLine('An older record of the same part in Manifests\ is replaced, and comes back on undo')
$s2 = New-FakeSetup
Copy-Item "$($s2.Manifests)\Pending\AAA1.item" "$($s2.Manifests)\AAA1.item"
(Get-Content "$($s2.Manifests)\AAA1.item" -Raw).Replace('true', 'false').Replace('42.40', '42.30') | Set-Content "$($s2.Manifests)\AAA1.item" -NoNewline
$before2 = Get-Snapshot $s2.Root
$code = Run-Main $s2 @{ Game = 'Fortnite' }
Check ($code -eq 0) 'fix returns 0'
Check ((Get-Content "$($s2.Manifests)\AAA1.item" -Raw) -match '42\.40') 'the record now says the new version'
$b2 = @(Get-ChildItem $s2.Backups -Directory)[0].FullName
Check (@(Get-ChildItem $b2 -Filter '*record-replaced*').Count -eq 1) 'the replaced record is in the backup'
$null = Run-Main $s2 @{ Undo = $b2 }
Check (Same-Snapshot $before2 (Get-Snapshot $s2.Root)) 'undo restores both records exactly'

[Console]::WriteLine('Refuses when it is not safe')
$s3 = New-FakeSetup
Remove-Item "$($s3.Egstore)\Pending\BBB2.manifest"
$before3 = Get-Snapshot $s3.Root
$code = Run-Main $s3 @{ Game = 'Fortnite' }
Check ($code -eq 1) 'a missing new file list: refuses (exit 1)'
Check (Same-Snapshot $before3 (Get-Snapshot $s3.Root)) 'and changes nothing'
Check ((Run-Main $s3 @{ Game = 'Zelda' }) -eq 1) 'an unknown game: exit 1'

[Console]::WriteLine('A failure half-way puts everything back')
$s4 = New-FakeSetup
$t = Get-Content "$($s4.Manifests)\Pending\CCC3.item" -Raw   # the last part: the first two are already changed when it fails
[IO.File]::WriteAllText("$($s4.Manifests)\Pending\CCC3.item", $t.Replace('"FormatVersion": 0', '"FormatVersion": 0, "bIsIncompleteInstall": true'))
$before4 = Get-Snapshot $s4.Root
$code = Run-Main $s4 @{ Game = 'Fortnite' }
Check ($code -eq 1) 'returns 1'
Check (Same-Snapshot $before4 (Get-Snapshot $s4.Root)) 'every file is back as it was'

[Console]::WriteLine('List')
Check ((Run-Main (New-FakeSetup) @{ List = $true }) -eq 0) '-List returns 0'
$empty = Join-Path ([IO.Path]::GetTempPath()) ('eur-none-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
Check ((Run-Main @{ Manifests = $empty; Backups = $empty } @{ Game = 'Fortnite' }) -eq 1) 'no launcher folder: exit 1'

Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'eur-test-*' | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
[Console]::WriteLine('')
[Console]::WriteLine("$script:Passed passed, $script:Failed failed")
if ($script:Failed) { exit 1 }
