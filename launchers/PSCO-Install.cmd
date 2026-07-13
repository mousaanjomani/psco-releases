@echo off
chcp 65001 >nul
title PSCO Installer
echo Starting PSCO installer... (Click "Yes" if a UAC prompt appears)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PSCO-Install.ps1"
echo.
pause
