@echo off
rem Double-click this file to run Epic Update Rescue. It asks before closing the launcher
rem and before changing anything. Everything it changes is backed up first.
title Epic Update Rescue
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0EpicUpdateRescue.ps1" -Interactive %*
echo.
pause
