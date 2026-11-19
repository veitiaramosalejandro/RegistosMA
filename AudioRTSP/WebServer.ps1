param([int]$Port = 8080)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot 'Core.ps1')

function Read-RequestJson($Context) {
    $reader = New-Object IO.StreamReader($Context.Request.InputStream, $Context.Request.ContentEncoding)
    try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ([string]::IsNullOrWhiteSpace($raw)) { return [pscustomobject]@{} }
    return ($raw | ConvertFrom-Json)
}
function Write-Json($Context, $Value, [int]$Status = 200) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 10 -Compress))
    $Context.Response.StatusCode = $Status; $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length); $Context.Response.Close()
}
function Write-Text($Context, [string]$Text, [string]$ContentType) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $Context.Response.StatusCode = 200; $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length); $Context.Response.Close()
}
function Error-Json($Context, [int]$Status, [string]$Message) { Write-Json $Context @{ error = $Message } $Status }
function Get-WebConfig {
    $path = Get-AudioConfigPath
    if (Test-Path -LiteralPath $path) { try { return (Get-Content $path -Raw | ConvertFrom-Json) } catch {} }
    return [pscustomobject]@{ Device=''; DeviceName=''; BindAddress=''; Port=8554; Channels=2; Bitrate=192; Language='pt'; AuthEnabled=$false; AuthUsername=''; AuthPasswordHash='' }
}
function Get-PublicConfig($Config) {
    $address = [string]$Config.BindAddress
    if ($address -match '^System\.' -or $address -eq '0') { $address = '' }
    [pscustomobject]@{ Device=[string]$Config.Device; DeviceName=[string]$Config.DeviceName; BindAddress=$address; Port=[int]$Config.Port; Channels=[int]$Config.Channels; Bitrate=[int]$Config.Bitrate; Language=[string]$Config.Language; AuthEnabled=[bool]$Config.AuthEnabled; AuthUsername=[string]$Config.AuthUsername; PasswordStored=(-not [string]::IsNullOrWhiteSpace([string]$Config.AuthPasswordHash)) }
}
function Get-PublicRtspUrl([int]$Port) {
    $hostName = [Environment]::GetEnvironmentVariable('PUBLIC_HOST')
    if ([string]::IsNullOrWhiteSpace($hostName)) { $hostName = 'localhost' }
    return "rtsp://${hostName}:$Port/audio"
}
function Get-State {
    $cfg = Get-WebConfig
    $state = if ($null -eq $script:session) { 'Parado' } else { Get-TransmissionState $script:session }
    $addresses = @(Get-LocalIPv4 | ForEach-Object { [pscustomobject]@{ Address=$_.Address; Name=$_.Name; Adapter=$_.Adapter } })
    $devices = @()
    try { $devices = @(Get-AudioDevices | ForEach-Object { [pscustomobject]@{ Id=$_.Id; Name=$_.Name } }) } catch {}
    [pscustomobject]@{ state=$state; url=if($null -ne $script:session){Get-PublicRtspUrl ([int]$cfg.Port)}else{''}; config=(Get-PublicConfig $cfg); networks=$addresses; devices=$devices; testTone=([Environment]::GetEnvironmentVariable('TEST_TONE') -match '^(?i:true|1|yes|sim)$') }
}
function Apply-WebConfig($Body) {
    $cfg = Get-WebConfig
    $address = [string]$Body.BindAddress
    if ([string]::IsNullOrWhiteSpace($address)) { throw 'Selecione a rede / endereço IP de transmissão.' }
    $access = Get-AudioAccessSettings $cfg
    $enabled = [bool]$Body.AuthEnabled
    $user = [string]$Body.AuthUsername
    $hash = [string]$cfg.AuthPasswordHash
    if ($enabled -and -not [string]::IsNullOrWhiteSpace([string]$Body.Password)) { Assert-AudioPassword ([string]$Body.Password); $hash = Get-AudioCredentialHash ([string]$Body.Password) }
    $candidate = @{ Device=[string]$Body.Device; DeviceName=[string]$Body.DeviceName; BindAddress=$address; Port=[int]$Body.Port; Channels=[int]$Body.Channels; Bitrate=[int]$Body.Bitrate; Language=if([string]$Body.Language -eq 'en'){'en'}else{'pt'}; AuthEnabled=$enabled; AuthUsername=$user; AuthPasswordHash=$hash }
    $access = Get-AudioAccessSettings ([pscustomobject]$candidate); Assert-AudioAccess $access
    Save-AudioSettings $candidate
    return (Get-PublicConfig ([pscustomobject]$candidate))
}

$script:session = $null
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://+:$Port/")
try {
    $listener.Start()
    Write-Host "AudioRTSP Web: http://0.0.0.0:$Port/"
} catch [Net.HttpListenerException] {
    $listener.Close()
    $listener = New-Object Net.HttpListener
    $listener.Prefixes.Add("http://127.0.0.1:$Port/")
    $listener.Start()
    Write-Host "AudioRTSP Web: http://127.0.0.1:$Port/ (fallback local; reserve the URL for LAN access)"
}
try {
    while ($listener.IsListening) {
        $context = $listener.GetContext(); $path = $context.Request.Url.AbsolutePath; $method = $context.Request.HttpMethod
        try {
            if ($method -eq 'GET' -and $path -eq '/api/state') { Write-Json $context (Get-State); continue }
            if ($method -eq 'GET' -and $path -eq '/health') { Write-Json $context @{ status='ok'; rtsp=($null -ne $script:session) }; continue }
            if ($method -eq 'POST' -and $path -eq '/api/refresh') { Write-Json $context (Get-State); continue }
            if ($method -eq 'POST' -and $path -eq '/api/config') { if($null -ne $script:session){throw 'Pare a transmissão antes de alterar a configuração.'}; Write-Json $context @{ config=(Apply-WebConfig (Read-RequestJson $context)); state='Pronto' }; continue }
            if ($method -eq 'POST' -and $path -eq '/api/start') {
                if($null -ne $script:session){throw 'A transmissão já está em execução.'}
                $cfg=Get-WebConfig; $access=Get-AudioAccessSettings $cfg
                $tone=([Environment]::GetEnvironmentVariable('TEST_TONE') -match '^(?i:true|1|yes|sim)$')
                if(-not $tone -and [string]::IsNullOrWhiteSpace([string]$cfg.Device)){throw 'Selecione uma entrada de áudio.'}
                $params=@{Device=[string]$cfg.Device; Port=[int]$cfg.Port; Channels=[int]$cfg.Channels; Bitrate=[int]$cfg.Bitrate; BindAddress=[string]$cfg.BindAddress; Access=$access}; if($tone){$params.TestTone=$true}
                $script:session=Start-Transmission @params; Write-Json $context @{ state=(Get-TransmissionState $script:session); url=(Get-PublicRtspUrl ([int]$cfg.Port)) }; continue
            }
            if ($method -eq 'POST' -and $path -eq '/api/stop') { Stop-Transmission $script:session; $script:session=$null; Write-Json $context @{ state='Parado' }; continue }
            if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) { Write-Text $context (Get-Content (Join-Path $PSScriptRoot 'web\index.html') -Raw) 'text/html; charset=utf-8'; continue }
            if ($method -eq 'GET' -and $path -eq '/app.js') { Write-Text $context (Get-Content (Join-Path $PSScriptRoot 'web\app.js') -Raw) 'application/javascript; charset=utf-8'; continue }
            if ($method -eq 'GET' -and $path -eq '/styles.css') { Write-Text $context (Get-Content (Join-Path $PSScriptRoot 'web\styles.css') -Raw) 'text/css; charset=utf-8'; continue }
            Error-Json $context 404 'Recurso no encontrado.'
        } catch { try { Error-Json $context 400 $_.Exception.Message } catch {} }
    }
} finally { Stop-Transmission $script:session; $listener.Stop(); $listener.Close() }
