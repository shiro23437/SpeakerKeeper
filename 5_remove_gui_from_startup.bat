@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\gui-startup.ps1" -Mode remove
pause
