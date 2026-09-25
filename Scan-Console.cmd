@echo off
rem Runs a IcePick scan in this console window (no GUI). Extra args are passed through, e.g. Scan-Console.cmd -Days 90
net session >nul 2>&1
if %errorlevel% neq 0 (
  if "%~1"=="" (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  ) else (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
  )
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0IcePick.ps1" %*
pause
