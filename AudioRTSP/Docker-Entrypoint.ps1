$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot 'Core.ps1')

function Get-EnvironmentInteger([string]$Name, [int]$Default, [int]$Minimum, [int]$Maximum) {
    $raw = [Environment]::GetEnvironmentVariable($Name)
    $value = $Default
    if (-not [string]::IsNullOrWhiteSpace($raw) -and -not [int]::TryParse($raw, [ref]$value)) { throw "$Name debe ser un número entero." }
    if ($value -lt $Minimum -or $value -gt $Maximum) { throw "$Name debe estar entre $Minimum y $Maximum." }
    return $value
}
function Get-EnvironmentBoolean([string]$Name, [bool]$Default) {
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    if ($raw -match '^(?i:true|1|yes|sim)$') { return $true }
    if ($raw -match '^(?i:false|0|no|nao|não)$') { return $false }
    throw "$Name debe ser true/false."
}

$port = Get-EnvironmentInteger 'RTSP_PORT' 8554 1024 65535
$channels = Get-EnvironmentInteger 'AUDIO_CHANNELS' 2 1 2
$bitrate = Get-EnvironmentInteger 'AUDIO_BITRATE' 192 64 320
if ($bitrate -notin @(64,128,192,256,320)) { throw 'AUDIO_BITRATE no es válido.' }

$bindAddress = [Environment]::GetEnvironmentVariable('BIND_ADDRESS')
if ([string]::IsNullOrWhiteSpace($bindAddress)) {
    $firstNetwork = Get-LocalIPv4 | Select-Object -First 1
    if ($null -ne $firstNetwork) { $bindAddress = [string]$firstNetwork.Address }
}
if ([string]::IsNullOrWhiteSpace($bindAddress)) { throw 'No se pudo determinar la IPv4 del contenedor. Defina BIND_ADDRESS.' }

$testTone = Get-EnvironmentBoolean 'TEST_TONE' $true
$device = [Environment]::GetEnvironmentVariable('AUDIO_DEVICE')
if (-not $testTone -and [string]::IsNullOrWhiteSpace($device)) { throw 'AUDIO_DEVICE es obligatorio cuando TEST_TONE=false.' }

$username = [Environment]::GetEnvironmentVariable('RTSP_USERNAME')
$password = [Environment]::GetEnvironmentVariable('RTSP_PASSWORD')
$authEnabled = -not [string]::IsNullOrWhiteSpace($username)
if ($authEnabled) { Assert-AudioPassword $password }
$passwordHash = if ($authEnabled) { Get-AudioCredentialHash $password } else { '' }

Save-AudioSettings @{
    Device = if ($testTone) { '' } else { $device }
    DeviceName = if ($testTone) { 'Docker test tone' } else { $device }
    BindAddress = $bindAddress
    Port = $port
    Channels = $channels
    Bitrate = $bitrate
    Language = 'pt'
    AuthEnabled = $authEnabled
    AuthUsername = if ($authEnabled) { $username } else { '' }
    AuthPasswordHash = $passwordHash
}

$webPort = Get-EnvironmentInteger 'WEB_PORT' 8080 1024 65535
& (Join-Path $PSScriptRoot 'WebServer.ps1') -Port $webPort
