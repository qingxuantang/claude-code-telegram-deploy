@echo off
REM Click this when Telegram from phone doesn't reach Claude.
REM Runs %USERPROFILE%\fix-daemon.ps1 (idempotent -- safe even if daemon is already healthy).
REM Log written to %USERPROFILE%\fix-daemon.log
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\fix-daemon.ps1"
echo.
echo Done. Check %USERPROFILE%\fix-daemon.log for details.
echo.
pause
