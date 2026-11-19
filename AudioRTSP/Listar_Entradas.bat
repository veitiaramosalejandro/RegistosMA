@echo off
setlocal
cd /d "%~dp0"
"%~dp0..\bin\ffmpeg.exe" -hide_banner -list_devices true -f dshow -i dummy
echo.
echo O aviso final sobre dummy e normal neste comando de listagem.
pause
