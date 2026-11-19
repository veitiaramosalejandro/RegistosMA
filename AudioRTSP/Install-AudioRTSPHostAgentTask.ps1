param(
    [string]$TaskName = 'AudioRTSP Host Agent'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = $PSScriptRoot
$envFile = Join-Path $projectRoot '.env'
$port = 8091
if (Test-Path -LiteralPath $envFile) {
    $lines = Get-Content -LiteralPath $envFile
    $portLine = $lines | Where-Object { $_ -match '^\s*AUDIO_AGENT_PORT\s*=\s*(\d+)\s*$' } | Select-Object -First 1
    if ($portLine -and $portLine -match '(\d+)\s*$') { $port = [int]$Matches[1] }
    else {
        $urlLine = $lines | Where-Object { $_ -match '^\s*AUDIO_AGENT_URL\s*=\s*' } | Select-Object -First 1
        if ($urlLine -and $urlLine -match ':(\d+)(?:/|\s*$)') { $port = [int]$Matches[1] }
    }
}
if ($port -lt 1024 -or $port -gt 65535) { throw "Puerto inválido: $port" }

$ffmpeg = (Get-Command ffmpeg.exe -ErrorAction Stop).Source
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$startScript = Join-Path $projectRoot 'Start-AudioRTSPHostAgent.ps1'
$arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$startScript`" -Port $port -FfmpegBin `"$ffmpeg`""
$action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory $projectRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User ([Environment]::UserName)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description 'Inicia el agente Windows de AudioRTSP para exponer entradas DirectShow a Docker.' -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Host "Tarea instalada e iniciada: $TaskName"
Write-Host "Puerto del agente: $port"
Write-Host "Prueba: http://127.0.0.1:$port/health"
