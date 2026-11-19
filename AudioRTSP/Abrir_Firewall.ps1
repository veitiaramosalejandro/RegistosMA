param([ValidateRange(1024,65535)][int]$Port=8554)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Paths.ps1')
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    Write-Host 'Abra o Windows PowerShell como administrador e execute este ficheiro novamente.'
    Read-Host 'Prima Enter';exit 1
}
$name="AudioRTSP-$Port"
if(Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue){Remove-NetFirewallRule -Name $name}
New-NetFirewallRule -Name $name -DisplayName "AudioRTSP v5 - TCP $Port (rede local privada)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Program (Get-AudioExecutable 'mediamtx.exe') -Profile Private -RemoteAddress LocalSubnet | Out-Null
Write-Host "Acesso permitido na rede local privada, porta TCP $Port."
Read-Host 'Prima Enter'
