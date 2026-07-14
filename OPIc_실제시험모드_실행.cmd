@echo off
setlocal
set "APP_DIR=%~dp0"
start "OPIc Voice" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%APP_DIR%OPIc_음성서버.ps1"
timeout /t 2 /nobreak >nul
start "" "http://127.0.0.1:8765/"
endlocal
