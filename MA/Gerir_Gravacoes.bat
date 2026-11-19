REM Launch recording management and playback in Windows PowerShell 5.1.
REM Hide command echo; keep environment changes local to this launcher.
@echo off
setlocal
REM START launches asynchronously; its first empty quoted argument is the window title.
REM Use the system PowerShell, STA for Windows Forms, no user profile and a hidden console.
REM ExecutionPolicy Bypass applies to this child process; %~dp0 anchors the script to this BAT folder.
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Gerir_Gravacoes.ps1"
REM Return to the caller without closing its command prompt.
exit /b
