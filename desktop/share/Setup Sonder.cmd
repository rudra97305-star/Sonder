@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0desktop\setup-share.ps1"
if errorlevel 1 (
    echo.
    echo Setup did not finish. See the message above.
) else (
    echo.
    echo Setup complete. Kim Vocal 2 is already installed. Open Sonder.exe.
)
pause
