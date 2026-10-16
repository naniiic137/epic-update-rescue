# Epic Update Rescue: one-line start.
#
#   PowerShell:  irm https://raw.githubusercontent.com/naniiic137/epic-update-rescue/main/get.ps1 | iex
#   cmd:         powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/naniiic137/epic-update-rescue/main/get.ps1 | iex"
#
# It downloads EpicUpdateRescue.ps1 from this repo into %TEMP%\EpicUpdateRescue and runs it in its
# own PowerShell (so its exit never closes your window, and the script policy doesn't block it).
# It asks before closing the launcher and before changing anything. Options can be passed too:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/naniiic137/epic-update-rescue/main/get.ps1))) -List

$ErrorActionPreference = 'Stop'
$source = 'https://raw.githubusercontent.com/naniiic137/epic-update-rescue/main/EpicUpdateRescue.ps1'
$folder = Join-Path $env:TEMP 'EpicUpdateRescue'
$script = Join-Path $folder 'EpicUpdateRescue.ps1'

# older Windows PowerShell may not offer TLS 1.2 by default, and GitHub requires it
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

Write-Host 'Downloading Epic Update Rescue...' -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $folder | Out-Null
Invoke-WebRequest -Uri $source -OutFile $script -UseBasicParsing

$options = @('-Interactive') + @($args)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script @options
