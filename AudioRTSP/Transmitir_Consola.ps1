param([Parameter(Mandatory=$true)][string]$Device,[Parameter(Mandatory=$true)][string]$BindAddress,[int]$Port=8554,[int]$Channels=2,[int]$Bitrate=192)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Core.ps1"
$mutex=New-Object Threading.Mutex($false,'Local\MA_RTSP_Transmissor_v1')
$owned=$false; $session=$null
try {
    $owned=$mutex.WaitOne(0)
    if(-not $owned){throw 'Ja existe um transmissor aberto neste PC.'}
    $null=Assert-BindAddress $BindAddress
    Save-AudioSettings @{Device=$Device;DeviceName=$Device;BindAddress=$BindAddress;Port=$Port;Channels=$Channels;Bitrate=$Bitrate}
    $session=Start-Transmission -Device $Device -Port $Port -Channels $Channels -Bitrate $Bitrate -BindAddress $BindAddress
    Write-Host "AudioRTSP: $($session.Url) - Ctrl+C para terminar."
    while($true){
        if((Get-TransmissionState $session) -eq 'Falha'){throw 'A transmissao terminou. Verifique a placa de som e a rede.'}
        Start-Sleep -Seconds 1
    }
} finally {Stop-Transmission $session; if($owned){$mutex.ReleaseMutex()}; $mutex.Dispose()}
