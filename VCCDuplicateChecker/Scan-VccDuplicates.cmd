@echo off
rem Wrapper to bypass PowerShell ExecutionPolicy without changing system settings.
rem Calls Restore-BlueprintId.ps1 with -NoProfile -ExecutionPolicy Bypass.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scan-VccDuplicates.ps1" %*
exit /b %ERRORLEVEL%
