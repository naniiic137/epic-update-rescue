# Epic Update Rescue

**Paused a game update in the Epic Games Launcher, and now it wants to download the whole game again?** This fixes it, so you download only what the update really changed.

Works for any Epic game, including games made of several parts (Fortnite: the game + Save the World + LEGO Fortnite content). One PowerShell script, nothing to install, everything backed up, one command to undo.

![tests](https://github.com/naniiic137/epic-update-rescue/actions/workflows/tests.yml/badge.svg)

## The problem

You start an update, then pause it, close the launcher or shut the PC down. Next time, the launcher shows the **full game size** (for example **44.78 GB** for a Fortnite update) and **Verify** is greyed out.

What happened: the launcher moved the game's record to its `Pending` folder and marked it `"bIsIncompleteInstall": true`. From then on it treats the game as a fresh **install**, not an **update**, even though all your files are still there.

## What this does

It makes the launcher see the new version as already installed. Then **Verify** works again: it checks the files you already have and downloads only what's different.

Real case (the reason this exists): Fortnite 42.40 wanted 44.78 GB after a paused update. After the fix, Verify finished in about 35 minutes on a hard drive, downloading only the changes.

## How to use it

1. **Download** this repo: green **Code** button → **Download ZIP**, then unzip it.
2. **Double-click `Fix-Epic-Update.bat`.**
3. It shows the stuck game(s), asks before closing the launcher and before changing anything.
4. **Open the Epic Games Launcher** → Library → your game → **⋯ → Manage → Verify**.
5. **Let Verify finish**: don't pause it and don't close the launcher. It reads your files first (slow on a hard drive), then downloads only what changed.

If Windows says it protected your PC, click **More info → Run anyway** (the script isn't signed). You can read all of it first: it's one file, [`EpicUpdateRescue.ps1`](EpicUpdateRescue.ps1).

### From PowerShell

```powershell
.\EpicUpdateRescue.ps1 -List                        # which games are stuck
.\EpicUpdateRescue.ps1 -Game Fortnite -WhatIf       # show what would change, change nothing
.\EpicUpdateRescue.ps1 -Game Fortnite -CloseLauncher
.\EpicUpdateRescue.ps1 -Undo "<the backup folder it printed>"
```

If PowerShell refuses to run scripts: `powershell -ExecutionPolicy Bypass -File .\EpicUpdateRescue.ps1 -List`.

## What it changes

Only the launcher's bookkeeping files for that game, never the game files:

| File | Where | Change |
|---|---|---|
| The game's record (`<id>.item`, one per part) | `C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests\Pending\` | `bIsIncompleteInstall` → `false` (nothing else, same encoding), then moved up into `Manifests\` |
| The new version's file list (`<id>.manifest`) | `<game folder>\.egstore\Pending\` | moved to `<game folder>\.egstore\`, replacing the old version's list |

## Safety

- **Backup first**: every file it touches is copied (and checked byte for byte) to `Documents\EpicUpdateRescue\backups\<game>-<date>` with a `restore.json`.
- **Undo**: `-Undo <backup folder>` puts every file back exactly as it was.
- **Refuses rather than guesses**: if the launcher is running (it would overwrite the fix), if a part's new file list isn't on disk yet, or if the game folder is missing. If anything fails half-way, it restores the backup by itself.
- **`-WhatIf`** shows the plan and changes nothing.

## FAQ

**Does it work for games other than Fortnite?** Yes: any Epic Games Launcher game stuck as an incomplete install. `-List` shows what the launcher knows.

**Verify still downloads a lot.** Then the update really is big (some updates change half of a game's files). It's still only what changed, never the whole game.

**"Access denied".** Run it as administrator (right-click the `.bat` → Run as administrator); it restores everything if a write fails.

**How do I avoid this next time?** Don't pause or close the launcher during an update. To keep the PC usable, use the launcher's **Settings → Throttle downloads** instead.

## Tests

`tests\Run-Tests.ps1` builds a fake launcher setup in a temp folder and checks the whole flow: finding stuck games, `-WhatIf`, refusing while the launcher runs, the fix byte for byte, undo restoring everything exactly, unsafe cases, and rolling back a failure half-way. It never touches a real launcher.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
```

They run on every push (Windows PowerShell 5.1 and PowerShell 7).

## Not affiliated with Epic Games

This is an independent tool. It only edits the launcher's own local files on your PC, the way you could by hand. Use it at your own risk; the backup and `-Undo` are there for that.

## Licence

[MIT](LICENSE) © 2026 Hamza Ben Ismail
