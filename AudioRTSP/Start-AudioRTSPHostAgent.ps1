param(
    [int]$Port = 8091,
    [string]$FfmpegBin = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = $PSScriptRoot
$node = (Get-Command node.exe -ErrorAction Stop).Source
if ([string]::IsNullOrWhiteSpace($FfmpegBin)) {
    $FfmpegBin = (Get-Command ffmpeg.exe -ErrorAction Stop).Source
}
if (-not (Test-Path -LiteralPath $FfmpegBin -PathType Leaf)) {
    throw "No se encontró FFmpeg: $FfmpegBin"
}

$env:AUDIO_AGENT_PORT = [string]$Port
$env:FFMPEG_BIN = $FfmpegBin
Set-Location -LiteralPath $projectRoot
& $node (Join-Path $projectRoot 'host-agent\index.js')
exit $LASTEXITCODE
