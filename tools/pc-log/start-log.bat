@echo off
title USB/IP PC-side log recorder
cd /d "%~dp0"
echo.
echo   Starting the recorder. Reproduce the problem (attach / disconnect / reattach),
echo   then press Ctrl+C here or run stop-log.bat to stop and merge.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0usbip-monitor.ps1" %*
echo.
echo   Recorder finished. Look for merged.log under logs\^<timestamp^>\
echo.
pause
