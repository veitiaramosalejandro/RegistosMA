$ErrorActionPreference='Stop'
. "$PSScriptRoot\Core.ps1"
. "$PSScriptRoot\Language.ps1"
try {
    $cfg=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
    if([string]::IsNullOrWhiteSpace($cfg.BindAddress)){throw 'Escolha primeiro a rede na janela do AudioRTSP.'}
    $url="rtsp://$($cfg.BindAddress):$($cfg.Port)/audio"
    Write-Host "A ouvir $url. A transmissao deve estar iniciada."
    $access=Get-AudioAccessSettings $cfg
    if($access.Enabled){
        $secure=Read-Host (Get-AudioText 'Palavra-passe') -AsSecureString
        $password=(New-Object Net.NetworkCredential('', $secure)).Password
        $url=ConvertTo-AudioClientUrl $url $access.Username $password
        $password=$null
    }
    & (Get-AudioExecutable 'ffplay.exe') -rtsp_transport tcp $url
} catch {Write-Host $_.Exception.Message;Read-Host 'Prima Enter'}
