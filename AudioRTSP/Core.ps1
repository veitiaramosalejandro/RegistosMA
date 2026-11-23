# Motor independente. Windows PowerShell 5.1 / Windows x64.
Set-StrictMode -Version 2
$script:AppRoot = $PSScriptRoot
. (Join-Path $PSScriptRoot 'Paths.ps1')
. (Join-Path $PSScriptRoot 'Access.ps1')
. (Join-Path $PSScriptRoot 'ProcessOutput.ps1')
function Get-LocalIPv4 {
    $items=@()
    foreach($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if($nic.OperationalStatus -ne 'Up' -or $nic.NetworkInterfaceType -eq 'Loopback'){continue}
        $properties=$nic.GetIPProperties()
        $gateway=@($properties.GatewayAddresses | Where-Object {$_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.IPAddressToString -ne '0.0.0.0'}).Count -gt 0
        foreach($u in $properties.UnicastAddresses){
            if($u.Address.AddressFamily -ne 'InterNetwork' -or [Net.IPAddress]::IsLoopback($u.Address)){continue}
            $ip=$u.Address.IPAddressToString
            $items+=[pscustomobject]@{Address=$ip;Adapter=$nic.Name;HasGateway=$gateway;Name="$ip - $($nic.Name)"}
        }
    }
    $items | Sort-Object @{Expression='HasGateway';Descending=$true},Adapter,Address
}
function Assert-BindAddress([string]$BindAddress){
    $parsed=$null
    if(-not [Net.IPAddress]::TryParse($BindAddress,[ref]$parsed) -or $parsed.AddressFamily -ne 'InterNetwork' -or $BindAddress -eq '0.0.0.0'){
        throw 'Selecione um endereco IPv4 do PC.'
    }
    if($BindAddress -ne '127.0.0.1' -and -not (@(Get-LocalIPv4 | Where-Object {$_.Address -eq $BindAddress}).Count)){
        throw "O IP $BindAddress nao esta disponivel neste PC. Atualize as redes e selecione outro IP."
    }
    return $parsed
}
function Save-AudioSettings($Settings){
    $path=Join-Path $script:AppRoot 'config.json'
    $temp=Join-Path $script:AppRoot 'config.json.tmp'
    $merged=@{}
    if(Test-Path -LiteralPath $path){
        try{$previous=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach($property in $previous.PSObject.Properties){$merged[$property.Name]=$property.Value}
        }catch{}
    }
    foreach($key in $Settings.Keys){$merged[$key]=$Settings[$key]}
    [IO.File]::WriteAllText($temp,($merged | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($true)))
    Move-Item -LiteralPath $temp -Destination $path -Force
}
function Get-AudioDevices {
    $ErrorActionPreference='Continue' # FFmpeg writes device enumeration to stderr on Windows PowerShell.
    $lines = & (Get-AudioExecutable 'ffmpeg.exe') -hide_banner -list_devices true -f dshow -i dummy 2>&1
    $result = @(); $current = $null
    foreach ($line in $lines) {
        $s = [string]$line
        if ($s -match '"(.*)" \(audio\)') {
            $current = [pscustomobject]@{Name=$Matches[1]; Id=$Matches[1]}
            $result += $current
        } elseif ($s -match '"(.*)" \(video\)') { $current = $null
        } elseif ($null -ne $current -and $s -match 'Alternative name "(.*)"') { $current.Id=$Matches[1] }
    }
    return $result
}
function Start-PortableProcess([string]$Exe, [string[]]$Arguments) {
    # Windows native argv quoting, including embedded quotes and trailing slashes.
    $quoted = foreach ($arg in $Arguments) {
        '"' + ([regex]::Replace([regex]::Replace($arg, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"'
    }
    $process=New-Object Diagnostics.Process
    $process.StartInfo.FileName=Get-AudioExecutable $Exe
    $process.StartInfo.Arguments=$quoted -join ' '
    $process.StartInfo.WorkingDirectory=$script:AppRoot
    $process.StartInfo.UseShellExecute=$false;$process.StartInfo.CreateNoWindow=$true
    $process.StartInfo.RedirectStandardOutput=$true;$process.StartInfo.RedirectStandardError=$true
    $process.StartInfo.RedirectStandardInput=$true
    # Redirected stdin carries raw PCM. Never let a text preamble precede it.
    $previousInputEncoding=$null
    try {
        $binaryEncoding=New-Object Text.UTF8Encoding($false)
        if($process.StartInfo.PSObject.Properties['StandardInputEncoding']){$process.StartInfo.StandardInputEncoding=$binaryEncoding}
        else{$previousInputEncoding=[Console]::InputEncoding;[Console]::InputEncoding=$binaryEncoding}
        $null=$process.Start()
    } finally {if($null -ne $previousInputEncoding){[Console]::InputEncoding=$previousInputEncoding}}
    $null=$process.Handle
    try {$drain=New-Object AudioRTSP.ProcessOutput6($process.StandardOutput,$process.StandardError);$process | Add-Member NoteProperty AudioOutput $drain}
    catch {if(-not $process.HasExited){$process.Kill();$null=$process.WaitForExit(3000)};$process.Dispose();throw}
    return $process
}
function Stop-Transmission($Session) {
    if ($null -eq $Session) { return }
    foreach ($p in @($Session.Encoder, $Session.Server)) {
        if ($null -ne $p) {
            $p.Refresh()
            if (-not $p.HasExited) { $p.Kill(); $null=$p.WaitForExit(3000) }
            $p.AudioOutput.Dispose();$p.Dispose()
        }
    }
    if($Session.ConfigPath){
        $path=[IO.Path]::GetFullPath($Session.ConfigPath)
        if((Split-Path $path -Parent) -eq $script:AppRoot -and (Split-Path $path -Leaf) -match '^\.audiortsp-runtime-[a-f0-9]{32}\.yml$'){
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }
}
function Start-Transmission {
    param([string]$Device, [int]$Port=8554, [int]$Channels=2, [int]$Bitrate=192, [string]$BindAddress='127.0.0.1', [switch]$TestTone, $Access=$null, [switch]$PcmInput, [string]$AuthHttp='', [int]$ApiPort=0)
    if($null -eq $Access){
        $stored=$null;$settingsPath=Join-Path $script:AppRoot 'config.json'
        if(Test-Path -LiteralPath $settingsPath){$stored=Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json}
        $Access=Get-AudioAccessSettings $stored
    }
    Assert-AudioAccess $Access
    $bindIP=Assert-BindAddress $BindAddress
    # When a network address is selected, listen on IPv4 interfaces as well
    # so the local MachiningMonitor service can always use 127.0.0.1.
    $listenAddress=if($BindAddress -eq '127.0.0.1'){'127.0.0.1'}else{'0.0.0.0'}
    if ($Port -lt 1024 -or $Port -gt 65535) { throw 'A porta deve estar entre 1024 e 65535.' }
    if ($Channels -notin @(1,2) -or $Bitrate -notin @(64,128,192,256,320)) { throw 'Formato de audio invalido.' }
    if (-not $TestTone -and -not $PcmInput -and [string]::IsNullOrWhiteSpace($Device)) { throw 'Selecione uma entrada de audio.' }
    foreach ($exe in @('ffmpeg.exe','mediamtx.exe')) {
        if (-not (Test-Path -LiteralPath (Get-AudioExecutable $exe))) { throw "Falta ..\bin\$exe. Coloque bin ao lado da pasta AudioRTSP." }
    }
    if(@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object {$_.Port -eq $Port}).Count){throw "A porta $Port esta ocupada neste IP. Escolha outra porta."}
    $client=New-Object Net.Sockets.TcpClient
    $occupied=$false
    try{$client.Connect($BindAddress,$Port);$occupied=$true}catch{}finally{$client.Close()}
    if($occupied){throw "A porta $Port esta ocupada. Escolha outra porta."}
    $listener = New-Object Net.Sockets.TcpListener(([Net.IPAddress]::Parse($listenAddress)),$Port)
    $listener.Server.ExclusiveAddressUse=$true
    try { $listener.Start() } catch { throw "A porta $Port esta ocupada. Escolha outra porta." } finally { $listener.Stop() }
    $config=Join-Path $script:AppRoot ('.audiortsp-runtime-'+[guid]::NewGuid().ToString('N')+'.yml')
    $readerAuth='  - user: any'
    if($Access.Enabled){
        # Hash the user as well, so reserved YAML/MediaMTX tokens never become wildcards.
        $readerAuth='  - user: '+(Get-AudioCredentialHash $Access.Username)+"`n"+'    pass: '+$Access.PasswordHash
    }
    $yaml=@"
logLevel: info
logDestinations: [stdout]
rtsp: true
rtspAddress: ${listenAddress}:$Port
rtspTransports: [tcp]
rtspAuthMethods: [basic]
rtmp: false
hls: false
webrtc: false
srt: false
moq: false
api: false
metrics: false
pprof: false
playback: false
authMethod: internal
authInternalUsers:
  - user: any
    ips: ['$BindAddress', '127.0.0.1']
    permissions:
      - action: publish
        path: audio
$readerAuth
    ips: []
    permissions:
      - action: read
        path: audio
paths:
  audio:
    source: publisher
    overridePublisher: false
"@
    if($AuthHttp){
        if($AuthHttp -notmatch '^http://127\.0\.0\.1:[0-9]+/auth-[a-f0-9]+$' -or $ApiPort -lt 1){throw 'Configuração de acesso temporário inválida.'}
        $start=$yaml.IndexOf('authMethod: internal');$finish=$yaml.IndexOf('paths:',$start)
        $yaml=$yaml.Substring(0,$start)+"authMethod: http`nauthHTTPAddress: $AuthHttp`nauthHTTPExclude: []`n"+$yaml.Substring($finish)
        $yaml=$yaml.Replace('api: false',("api: true`napiAddress: 127.0.0.1:"+$ApiPort))
    }
    [IO.File]::WriteAllText($config,$yaml,(New-Object Text.UTF8Encoding($false)))
    $session=[pscustomobject]@{Server=$null;Encoder=$null;ConfigPath=$config;Url="rtsp://${BindAddress}:$Port/audio";Started=Get-Date;Ready=$false}
    try {
        $session.Server=Start-PortableProcess 'mediamtx.exe' @($config)
        $ready=$false
        for($i=0;$i -lt 40;$i++) {
            $session.Server.Refresh()
            if($session.Server.HasExited){throw 'O servidor RTSP não arrancou. Verifique a porta e a configuração de acesso.'}
            if($session.Server.AudioOutput.Listening){$ready=$true;break}
            Start-Sleep -Milliseconds 100
        }
        if(-not $ready){throw 'O servidor RTSP demorou demasiado a arrancar.'}
        $a=@('-hide_banner','-loglevel','error','-nostdin','-y')
        if($PcmInput){$a+=@('-f','s16le','-ar','44100','-ac','2','-i','pipe:0')}
        elseif($TestTone){$a+=@('-re','-f','lavfi','-i','sine=frequency=1000:sample_rate=48000')}
        else {$a+=@('-thread_queue_size','512','-f','dshow','-audio_buffer_size','50','-i',"audio=$Device")}
        $a+=@('-vn','-c:a','aac','-b:a',"${Bitrate}k",'-ar','48000','-ac',"$Channels",'-nostats','-f','rtsp','-rtsp_transport','tcp',$session.Url)
        $session.Encoder=Start-PortableProcess 'ffmpeg.exe' $a
        return $session
    } catch { Stop-Transmission $session; throw }
}
function Get-TransmissionState($Session) {
    foreach($p in @($Session.Server,$Session.Encoder)) {
        $p.Refresh()
        if($p.HasExited){return 'Falha'}
    }
    if($Session.Ready){return 'A transmitir'}
    # Readiness means the server has accepted an audio publisher.
    if($Session.Server.AudioOutput.Publishing){$Session.Ready=$true;return 'A transmitir'}
    if(((Get-Date)-$Session.Started).TotalSeconds -gt 20){return 'Falha'}
    return 'A iniciar'
}
