@echo off
chcp 65001 >nul
title PSCO Update
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PSCO-Update.ps1"
echo.
pause
