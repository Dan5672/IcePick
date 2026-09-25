@echo off
rem Runs the freeze heartbeat monitor in this window. Leave it open until the next freeze.
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0IcePick.ps1" -Monitor -IntervalSec 10
