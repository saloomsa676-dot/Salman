@echo off
title Laptop Fix
if not exist "%~dp0LaptopFix.ps1" (
  echo.
  echo   ERROR: LaptopFix.ps1 was not found next to this file.
  echo   Right-click the ZIP file, choose "Extract All", then run this file
  echo   from the extracted folder.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0LaptopFix.ps1"
echo.
echo   You can close this window now.
pause
