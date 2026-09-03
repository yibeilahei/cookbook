@echo off
rem First-launch helper for unsigned Windows builds.
rem Clears Mark of the Web so SmartScreen stops treating Cookbook.exe as
rem an unrecognized download. After this has run once, start Cookbook.exe
rem as usual.
setlocal
cd /d "%~dp0"
if not exist "%~dp0Cookbook.exe" (
  echo Cookbook.exe was not found next to this script.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse | Unblock-File" >nul 2>&1
start "" "%~dp0Cookbook.exe"
