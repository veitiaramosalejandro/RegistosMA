param([Parameter(Mandatory=$true)][string]$StopEvent)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Core.ps1"
$signal=[Threading.EventWaitHandle]::OpenExisting($StopEvent)
$session=$null
try {
    while(-not $signal.WaitOne(0)){
        try {
            $cfg=Get-Content -LiteralPath "$PSScriptRoot\config.json" -Raw | ConvertFrom-Json
            $session=Start-Transmission -Device $cfg.Device -BindAddress $cfg.BindAddress -Port $cfg.Port -Channels $cfg.Channels -Bitrate $cfg.Bitrate -Access (Get-AudioAccessSettings $cfg)
            while(-not $signal.WaitOne(1000)){
                if((Get-TransmissionState $session) -eq 'Falha'){throw 'Transmission failed.'}
            }
        } catch {
            # Retry after device/network outages, including during Windows startup.
        } finally {Stop-Transmission $session;$session=$null}
        if($signal.WaitOne(5000)){break}
    }
} finally {Stop-Transmission $session;$signal.Dispose()}
