#Requires -Version 5.1
# One runtime per manager process, shared with child playback script scopes.
. (Join-Path $PSScriptRoot 'Playback_Analyzer.ps1')
function Get-ApplicationBroadcast { return $global:MachiningMonitorPlaybackBroadcast }
function Get-BroadcastText([string]$English,[string]$Portuguese){
    if($script:UiLanguage -eq 'en'){return $English};return $Portuguese
}
function New-BroadcastConfiguration {
    return [pscustomobject][ordered]@{Version=5;MachineId='';ServiceApiKey='';ServiceApiKeyProtected='';ServiceCertificateSha256='';Enabled=$false;Address='127.0.0.1';Port=8555;Channels=2;Bitrate=192;AuthEnabled=$true;Username='audio';PasswordHash='';Password='';AnalyzerEnabled=$false;AnalyzerHost='127.0.0.1';AnalyzerPort=5001}
}
function Read-BroadcastConfiguration([string]$Path){
    $config=New-BroadcastConfiguration
    if(Test-Path -LiteralPath $Path){
        $saved=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        # Migrate configuration keys from the previous spelling without losing endpoints.
        foreach($entry in @(@('AnalyserEnabled','AnalyzerEnabled'),@('AnalyserHost','AnalyzerHost'),@('AnalyserPort','AnalyzerPort'))){
            if(-not $saved.PSObject.Properties[$entry[1]] -and $saved.PSObject.Properties[$entry[0]]){$saved|Add-Member NoteProperty $entry[1] $saved.($entry[0])}
        }
        foreach($name in @('Enabled','Address','Port','Channels','Bitrate','AuthEnabled','Username','PasswordHash','Password','AnalyzerEnabled','AnalyzerHost','AnalyzerPort','MachineId','ServiceApiKeyProtected','ServiceCertificateSha256')){
            if($null -ne $saved.PSObject.Properties[$name]){$config.$name=$saved.$name}
        }
        if($config.Enabled -isnot [bool] -or $config.AuthEnabled -isnot [bool]){throw 'Configuração de emissão inválida: as opções devem ser true/false.'}
        if($config.Port -isnot [int] -and $config.Port -isnot [long]){throw 'Configuração de emissão inválida: porta.'}
        if($config.Port -lt 1024 -or $config.Port -gt 65535){throw 'A porta deve estar entre 1024 e 65535.'}
        if($config.Channels -notin @(1,2) -or $config.Bitrate -notin @(64,128,192,256,320)){throw 'Formato de áudio guardado inválido.'}
        if($saved.Version -lt 5){$config.AnalyzerEnabled=$false;$config.AnalyzerPort=5001}
        if($config.AnalyzerEnabled -isnot [bool] -or $config.AnalyzerPort -lt 1 -or $config.AnalyzerPort -gt 65535){throw 'Configuração do analisador inválida.'}
    }
    if($config.ServiceApiKeyProtected){
        Add-Type -AssemblyName System.Security
        $config.ServiceApiKey=[Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($config.ServiceApiKeyProtected),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser))
    }
    # Remove the legacy plaintext secret immediately, retaining the existing reader hash.
    if(Test-Path -LiteralPath $Path){
        $clean=$config|Select-Object * -ExcludeProperty Password,ServiceApiKey
        [IO.File]::WriteAllText($Path,($clean|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
    }
    $config.Password=''
    return $config
}
function Initialize-PlaybackBroadcast {
    $runtime=Get-ApplicationBroadcast
    if($null -eq $runtime){throw 'O gestor de emissão ainda não foi inicializado.'}
    if(-not $runtime.Engine){
        $core=Join-Path (Split-Path $PSScriptRoot -Parent) 'AudioRTSP/Core.ps1'
        if(-not (Test-Path -LiteralPath $core -PathType Leaf)){throw 'Não foi encontrado AudioRTSP/Core.ps1 ao lado da pasta MA.'}
        $runtime.Engine=New-Module -Name PlaybackAudioRTSP -ArgumentList $core -ScriptBlock {
            param($CorePath)
            . $CorePath
            if(-not (Get-Command Start-Transmission).Parameters.ContainsKey('PcmInput')){throw 'Atualize também AudioRTSP/Core.ps1 com a versão incluída neste pacote.'}
            Export-ModuleMember -Function *
        }
    }
    if(-not ('MachiningMonitor.Broadcast.AudioTokenAccess' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'Playback_AudioAccess.cs') -ReferencedAssemblies System.Web.Extensions}
    if(-not ('MachiningMonitor.Broadcast.ProcessAudio' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'Playback_ProcessAudio.cs')}
}
function New-ApplicationTransmission($Config){
    if([Environment]::OSVersion.Version.Build -lt 20348){throw 'A emissão do áudio do leitor exige Windows build 20348 ou posterior (por exemplo Windows 11).'}
    Initialize-PlaybackBroadcast
    $runtime=Get-ApplicationBroadcast;$transmission=$null;$capture=$null
    $access=[pscustomobject]@{Enabled=$Config.AuthEnabled;Username=$Config.Username;PasswordHash=$Config.PasswordHash}
    $token='';$tokenUser='';$expires=[datetime]::UtcNow.AddMinutes(30);$auth=$null
    if($Config.AnalyzerEnabled){
        $auth=New-Object MachiningMonitor.Broadcast.AudioTokenAccess($Config.Address)
        # No reader is authorized while idle. Each analysis obtains a new token.
        $access=[pscustomobject]@{Enabled=$false;Username='';PasswordHash=''}
    }
    try{
        $transmission=& $runtime.Engine {param($ip,$port,$access,$channels,$bitrate,$url,$api) Start-Transmission -PcmInput -BindAddress $ip -Port $port -Access $access -Channels $channels -Bitrate $bitrate -AuthHttp $url -ApiPort $api} $Config.Address $Config.Port $access $Config.Channels $Config.Bitrate $(if($auth){$auth.AuthUrl}else{''}) $(if($auth){$auth.ApiPort}else{0})
        $capture=New-Object MachiningMonitor.Broadcast.ProcessAudio($transmission.Encoder.StandardInput.BaseStream)
        if($runtime.Player -and -not $runtime.Player.HasExited){$capture.SetProcess($runtime.Player.Id)}
        if($auth){
            # The server belongs to the manager, not to one analysis/token.
            $watch=New-Object Diagnostics.ProcessStartInfo
            $watch.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
            $watch.UseShellExecute=$false;$watch.CreateNoWindow=$true
            $watch.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'Playback_TokenLease.ps1')+'" -ServerId '+$transmission.Server.Id+' -ServerTicks '+$transmission.Server.StartTime.ToUniversalTime().Ticks+' -EncoderId '+$transmission.Encoder.Id+' -EncoderTicks '+$transmission.Encoder.StartTime.ToUniversalTime().Ticks+' -ManagerId '+$PID+' -ManagerTicks '+([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks)+' -ExpiresTicks '+[long]::MaxValue
            $guard=[Diagnostics.Process]::Start($watch);$guard.Dispose()
        }
        return @{Transmission=$transmission;Capture=$capture;LastFrames=0L;ProgressAt=[datetime]::UtcNow;CaptureWaitAt=[datetime]::UtcNow;Token=$token;TokenUser=$tokenUser;TokenExpires=$expires;Auth=$auth}
    }catch{
        if($transmission){& $runtime.Engine {param($s) Stop-Transmission $s} $transmission}
        if($capture){$capture.Dispose()};if($auth){$auth.Dispose()};throw
    }
}
function Stop-ApplicationTransmission {
    $runtime=Get-ApplicationBroadcast
    if(-not $runtime -or -not $runtime.Session){return}
    Stop-AnalyzerPlayback
    $session=$runtime.Session;$runtime.Session=$null
    if($runtime.PlaybackState){$runtime.PlaybackState.Context.Broadcast=$null;$runtime.PlaybackState.Session.BroadcastCapture=$null}
    try{& $runtime.Engine {param($s) Stop-Transmission $s} $session.Transmission}finally{$session.Capture.Dispose();if($session.Auth){$session.Auth.Dispose()}}
}
function Set-ApplicationBroadcastPlayer($State,$Session){
    $runtime=Get-ApplicationBroadcast
    if(-not $runtime){return}
    $runtime.Player=$Session.Player;$runtime.PlaybackState=$State
    $State.Context.Broadcast=$runtime.Session
    if($runtime.Session){$Session.BroadcastCapture=$runtime.Session.Capture;$Session.BroadcastCapture.SetProcess($Session.Player.Id)}
}
# Closing a recording detaches only its capture. The application keeps sending silence.
function Stop-PlaybackBroadcast($State){
    $runtime=Get-ApplicationBroadcast
    if(-not $runtime){return}
    if($runtime.PlaybackState -eq $State){
        Stop-AnalyzerPlayback
        if($runtime.Session){$runtime.Session.Capture.SetProcess(0)}
        $runtime.Player=$null;$runtime.PlaybackState=$null
    }
    if($State -and $State.Context){$State.Context.Broadcast=$null}
    if($State -and $State.Session){$State.Session.BroadcastCapture=$null}
}
function Update-ApplicationBroadcast {
    $runtime=Get-ApplicationBroadcast
    if(-not $runtime -or $runtime.Updating){return}
    $runtime.Updating=$true
    try{
        Prepare-PlaybackAnalyzer
        $revokeReady=$runtime.RevokeAudio -and (-not $runtime.AnalyzerClient -or $runtime.AnalyzerClient.HasStopped($runtime.RevokeAfterStop) -or [datetime]::UtcNow -ge $runtime.RevokeDeadline)
        if($runtime.Session -and $runtime.Session.Auth -and $revokeReady){
            $runtime.Session.Auth.RevokeToken();$runtime.Session.Token='';$runtime.RevokeAudio=$false
        }
        if($runtime.Session -and $runtime.Session.Token -and [datetime]::UtcNow -ge $runtime.Session.TokenExpires){Stop-AnalyzerPlayback}
        if($runtime.Session){
            $session=$runtime.Session;$now=[datetime]::UtcNow
            if($session.Capture.Failure){throw $session.Capture.Failure}
            if($session.Capture.SentFrames -ne $session.LastFrames){$session.LastFrames=$session.Capture.SentFrames;$session.ProgressAt=$now}
            if(($now-$session.ProgressAt).TotalSeconds -gt 5){throw 'O envio de áudio RTSP ficou bloqueado.'}
            if($session.Capture.CaptureReady -or $session.Capture.TargetProcess -eq 0){$session.CaptureWaitAt=$now}
            if(($now-$session.CaptureWaitAt).TotalSeconds -gt 10){throw 'O Windows não iniciou a captura do áudio do leitor.'}
            $status=& $runtime.Engine {param($s) Get-TransmissionState $s} $session.Transmission
            if($status -eq 'Falha'){throw 'O servidor ou codificador RTSP deixou de responder.'}
        }
    }catch{
        $runtime.LastError=$_.Exception.Message
        Stop-ApplicationTransmission
    }finally{
        if($runtime.Button -and -not $runtime.Button.IsDisposed){
            $runtime.Button.Text=Get-BroadcastText 'Configure audio broadcast' 'Configurar emissão de áudio'
        }
        $runtime.Updating=$false
    }
}
function Start-ApplicationBroadcast([string]$ConfigurationPath){
    if(Get-ApplicationBroadcast){return}
    Add-Type -AssemblyName System.Windows.Forms
    if(-not $ConfigurationPath){$ConfigurationPath=Join-Path $PSScriptRoot 'playback_broadcast.json'}
    $runtime=@{ConfigPath=$ConfigurationPath;Config=(New-BroadcastConfiguration);Engine=$null;Session=$null;Player=$null;PlaybackState=$null;Timer=$null;Button=$null;LastError=$null;Updating=$false}
    $global:MachiningMonitorPlaybackBroadcast=$runtime
    try{
        $runtime.Config=Read-BroadcastConfiguration $ConfigurationPath
        if($runtime.Config.Enabled){$runtime.Session=New-ApplicationTransmission $runtime.Config}
    }catch{$runtime.LastError=$_.Exception.Message}
    Prepare-PlaybackAnalyzer
    $runtime.Timer=New-Object Windows.Forms.Timer;$runtime.Timer.Interval=100
    $runtime.Timer.Add_Tick({Update-ApplicationBroadcast});$runtime.Timer.Start()
}
function Stop-ApplicationBroadcast {
    $runtime=Get-ApplicationBroadcast
    if(-not $runtime){return}
    try{if($runtime.Timer){$runtime.Timer.Stop();$runtime.Timer.Dispose()};Close-PlaybackAnalyzer;Stop-ApplicationTransmission}
    finally{$global:MachiningMonitorPlaybackBroadcast=$null}
}
function Save-ApplicationBroadcast($Config){
    $runtime=Get-ApplicationBroadcast
    Initialize-PlaybackBroadcast
    if($Config.Enabled -isnot [bool] -or $Config.AuthEnabled -isnot [bool]){throw 'Opções de emissão inválidas.'}
    $parsed=$null
    if(-not [Net.IPAddress]::TryParse($Config.Address,[ref]$parsed) -or $parsed.AddressFamily -ne 'InterNetwork' -or $Config.Address -eq '0.0.0.0'){throw 'Selecione um endereço IPv4 válido.'}
    if($Config.Port -lt 1024 -or $Config.Port -gt 65535){throw 'A porta deve estar entre 1024 e 65535.'}
    if($Config.Channels -notin @(1,2) -or $Config.Bitrate -notin @(64,128,192,256,320)){throw 'Selecione Mono/Estéreo e uma qualidade AAC válida.'}
    if($Config.AnalyzerEnabled -isnot [bool]){throw 'Opção de ligação ao analisador inválida.'}
    if($Config.AnalyzerEnabled){
        if([string]::IsNullOrWhiteSpace($Config.AnalyzerHost) -or $Config.AnalyzerPort -lt 1 -or $Config.AnalyzerPort -gt 65535){throw 'Defina o computador e a porta HTTPS do serviço MachiningMonitor.'}
        if(-not $Config.ServiceApiKey -or -not $Config.MachineId -or [guid]$Config.MachineId -eq [guid]::Empty){throw 'Configure a chave de acesso e o GUID da máquina no serviço.'}
        if($Config.Address -eq '127.0.0.1' -and $Config.AnalyzerHost -notin @('127.0.0.1','localhost')){throw 'Para um analisador noutro PC, escolha o IP de rede da emissão em vez de 127.0.0.1.'}
    }
    $access=[pscustomobject]@{Enabled=$Config.AuthEnabled;Username=$Config.Username;PasswordHash=$Config.PasswordHash}
    if(($Config.Enabled -and -not $Config.AnalyzerEnabled) -or $Config.PasswordHash){& $runtime.Engine {param($a) Assert-AudioAccess $a} $access}
    $previous=$runtime.Config;$wasRunning=$null -ne $runtime.Session
    $audioFields=@('Enabled','Address','Port','Channels','Bitrate','AnalyzerEnabled')
    if(-not $Config.AnalyzerEnabled){$audioFields+=@('AuthEnabled','Username','PasswordHash')}
    $changed=($Config|Select-Object $audioFields|ConvertTo-Json -Compress) -ne ($previous|Select-Object $audioFields|ConvertTo-Json -Compress)
    $replace=$Config.Enabled -and ($changed -or -not $wasRunning)
    $temp=$runtime.ConfigPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        if($replace){
            Stop-ApplicationTransmission
            $runtime.Session=New-ApplicationTransmission $Config
        }
        Add-Type -AssemblyName System.Security
        $Config.ServiceApiKeyProtected=''
        if($Config.ServiceApiKey){$Config.ServiceApiKeyProtected=[Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Config.ServiceApiKey),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser))}
        $public=$Config|Select-Object * -ExcludeProperty Password,ServiceApiKey
        [IO.File]::WriteAllText($temp,($public|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
        if(Test-Path -LiteralPath $runtime.ConfigPath){[IO.File]::Replace($temp,$runtime.ConfigPath,[NullString]::Value)}else{[IO.File]::Move($temp,$runtime.ConfigPath)}
        $runtime.Config=$Config;$runtime.LastError=$null
        if(-not $Config.AnalyzerEnabled -or -not $Config.Enabled){Close-PlaybackAnalyzer}
        Prepare-PlaybackAnalyzer
        if(-not $Config.Enabled){Stop-ApplicationTransmission}
        if($runtime.PlaybackState -and $runtime.Session){
            $runtime.PlaybackState.Context.Broadcast=$runtime.Session
            $runtime.PlaybackState.Session.BroadcastCapture=$runtime.Session.Capture
        }
    }catch{
        $problem=$_
        if($replace){
            Stop-ApplicationTransmission
            if($wasRunning){
                try{
                    $runtime.Session=New-ApplicationTransmission $previous
                    if($runtime.PlaybackState){$runtime.PlaybackState.Context.Broadcast=$runtime.Session;$runtime.PlaybackState.Session.BroadcastCapture=$runtime.Session.Capture}
                }catch{$runtime.LastError=$_.Exception.Message}
            }
        }
        throw $problem
    }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
    Update-ApplicationBroadcast
    if($runtime.PlaybackState){Update-AnalyzerPlayback $runtime.PlaybackState}
}
function Update-BroadcastNetworkList($Ui){
    $runtime=Get-ApplicationBroadcast
    $selected=$runtime.Config.Address
    if($Ui.Network.SelectedItem){$selected=$Ui.Network.SelectedItem.Address}
    $items=@(& $runtime.Engine {Get-LocalIPv4})
    $items+=,[pscustomobject]@{Address='127.0.0.1';Name=(Get-BroadcastText '127.0.0.1 - This computer only' '127.0.0.1 - Apenas este computador')}
    if($selected -notin @($items|ForEach-Object {$_.Address})){
        $items+=,[pscustomobject]@{Address=$selected;Name=($selected+' - '+(Get-BroadcastText 'Unavailable' 'Indisponível'))}
    }
    $Ui.Network.BeginUpdate()
    try{
        $Ui.Network.Items.Clear()
        foreach($item in $items){[void]$Ui.Network.Items.Add($item);if($item.Address -eq $selected){$Ui.Network.SelectedItem=$item}}
    }finally{$Ui.Network.EndUpdate()}
    Update-BroadcastDialogUrl $Ui
}
function Update-BroadcastDialogUrl($Ui){
    if($Ui.Network.SelectedItem){$Ui.Url.Text='rtsp://'+$Ui.Network.SelectedItem.Address+':'+[int]$Ui.Port.Value+'/audio'}else{$Ui.Url.Clear()}
}
function Save-BroadcastDialogSettings($Ui,[switch]$AccessOnly){
    $runtime=Get-ApplicationBroadcast
    $hash=$runtime.Config.PasswordHash
    $plainPassword=$runtime.Config.Password
    if($Ui.Password.Text.Length){$hash=& $runtime.Engine {param($p) Assert-AudioPassword $p;Get-AudioCredentialHash $p} $Ui.Password.Text}
    if($Ui.Password.Text.Length){$plainPassword=$Ui.Password.Text}
    $next=New-BroadcastConfiguration
    if($AccessOnly){
        foreach($property in $runtime.Config.PSObject.Properties){$next.($property.Name)=$property.Value}
    }else{
        $next.Enabled=$Ui.Enabled.Checked;$next.Address=$Ui.Network.SelectedItem.Address;$next.Port=[int]$Ui.Port.Value
        $next.Channels=[int]$Ui.Channels.SelectedItem.Value;$next.Bitrate=[int]$Ui.Bitrate.SelectedItem
        $next.AnalyzerEnabled=$Ui.AnalyzerEnabled.Checked;$next.AnalyzerHost=$Ui.AnalyzerHost.Text.Trim();$next.AnalyzerPort=[int]$Ui.AnalyzerPort.Value
        $next.ServiceCertificateSha256=$Ui.ServicePin.Text.Trim();$next.MachineId=$Ui.MachineId.Text.Trim();$next.ServiceApiKey=$runtime.Config.ServiceApiKey
        if($Ui.ServiceKey.Text){$next.ServiceApiKey=$Ui.ServiceKey.Text}
    }
    $next.AuthEnabled=$Ui.Auth.Checked;$next.Username=$Ui.User.Text;$next.PasswordHash=$hash
    $next.Password=''
    Save-ApplicationBroadcast $next
    $Ui.Password.Clear()
}
function Show-BroadcastDialogError($Ui,[string]$Message){
    [void][Windows.Forms.MessageBox]::Show($Ui.Dialog,$Message,$Ui.Dialog.Text,[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning)
}
function Show-ApplicationBroadcastDialog($Owner){
    $runtime=Get-ApplicationBroadcast
    Initialize-PlaybackBroadcast
    $config=$runtime.Config
    $dialog=New-Object Windows.Forms.Form;$dialog.Name='ApplicationBroadcastSettings'
    $dialog.Text=Get-BroadcastText 'Application audio broadcast' 'Emissão de áudio da aplicação'
    if($Owner){$dialog.Font=$Owner.Font}else{$dialog.Font=New-Object Drawing.Font('Segoe UI',10)}
    $dialog.ClientSize=New-Object Drawing.Size(800,790);$dialog.StartPosition='CenterParent';$dialog.FormBorderStyle='FixedDialog';$dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false
    $enabled=New-Object Windows.Forms.CheckBox;$enabled.Text=Get-BroadcastText 'Enable audio broadcast when playing recordings' 'Ativar emissão de áudio ao reproduzir gravações';$enabled.SetBounds(12,10,696,28);$enabled.Checked=$config.Enabled
    $network=New-Object Windows.Forms.ComboBox;$network.DropDownStyle='DropDownList';$network.DisplayMember='Name';$network.SetBounds(12,70,560,28)
    $refresh=New-Object Windows.Forms.Button;$refresh.Text=Get-BroadcastText 'Refresh networks' 'Atualizar redes';$refresh.SetBounds(588,68,200,32)
    $port=New-Object Windows.Forms.NumericUpDown;$port.Minimum=1024;$port.Maximum=65535;$port.Value=$config.Port;$port.SetBounds(12,144,140,26)
    $channels=New-Object Windows.Forms.ComboBox;$channels.DropDownStyle='DropDownList';$channels.DisplayMember='Name';$channels.SetBounds(182,144,180,26)
    foreach($item in @([pscustomobject]@{Name=(Get-BroadcastText 'Mono (1)' 'Mono (1)');Value=1},[pscustomobject]@{Name=(Get-BroadcastText 'Stereo (2)' 'Estéreo (2)');Value=2})){
        [void]$channels.Items.Add($item);if($item.Value -eq $config.Channels){$channels.SelectedItem=$item}
    }
    $bitrate=New-Object Windows.Forms.ComboBox;$bitrate.DropDownStyle='DropDownList';$bitrate.SetBounds(392,144,158,26)
    foreach($value in @(64,128,192,256,320)){[void]$bitrate.Items.Add($value)};$bitrate.SelectedItem=[int]$config.Bitrate
    $unit=New-Object Windows.Forms.Label;$unit.Text='kbit/s';$unit.SetBounds(560,147,65,24)
    $auth=New-Object Windows.Forms.CheckBox;$auth.Text=Get-BroadcastText 'Require username and password' 'Exigir utilizador e palavra-passe';$auth.SetBounds(12,184,696,26);$auth.Checked=$config.AuthEnabled
    $user=New-Object Windows.Forms.TextBox;$user.Text=$config.Username;$user.SetBounds(132,223,198,26)
    $password=New-Object Windows.Forms.TextBox;$password.UseSystemPasswordChar=$true;$password.SetBounds(482,223,218,26)
    foreach($row in @(@('Network / broadcast IP address','Rede / endereço IP de transmissão',12,46,696),@('RTSP port','Porta RTSP',12,120,150),@('Channels','Canais',182,120,180),@('AAC quality','Qualidade AAC',392,120,180),@('Username','Utilizador',12,226,115),@('Password','Palavra-passe',352,226,120))){
        $label=New-Object Windows.Forms.Label;$label.Text=Get-BroadcastText $row[0] $row[1];$label.SetBounds($row[2],$row[3],$row[4],24);$dialog.Controls.Add($label)
    }
    $hint=New-Object Windows.Forms.Label;$hint.SetBounds(12,268,510,26);$hint.Text=Get-BroadcastText 'Blank: keeps the saved password.' 'Em branco: mantém a palavra-passe guardada.'
    $saveAccess=New-Object Windows.Forms.Button;$saveAccess.Text=Get-BroadcastText 'Save access' 'Guardar acesso';$saveAccess.SetBounds(588,260,200,32)
    $urlLabel=New-Object Windows.Forms.Label;$urlLabel.Text=Get-BroadcastText 'RTSP URL to access the audio broadcast' 'URL RTSP para acesso à transmissão de áudio';$urlLabel.SetBounds(12,308,688,24)
    $url=New-Object Windows.Forms.TextBox;$url.ReadOnly=$true;$url.SetBounds(12,336,560,28)
    $copy=New-Object Windows.Forms.Button;$copy.Text=Get-BroadcastText 'Copy address' 'Copiar endereço';$copy.SetBounds(588,334,200,32)
    $analyzerEnabled=New-Object Windows.Forms.CheckBox;$analyzerEnabled.Text=Get-BroadcastText 'Analyze through MachiningMonitor service' 'Analisar através do serviço MachiningMonitor';$analyzerEnabled.SetBounds(12,385,776,28);$analyzerEnabled.Checked=$config.AnalyzerEnabled
    $hostLabel=New-Object Windows.Forms.Label;$hostLabel.Text=Get-BroadcastText 'Computer / IP' 'Computador / IP';$hostLabel.SetBounds(12,426,130,25)
    $analyzerHost=New-Object Windows.Forms.TextBox;$analyzerHost.Text=$config.AnalyzerHost;$analyzerHost.SetBounds(150,423,350,28)
    $portLabel=New-Object Windows.Forms.Label;$portLabel.Text=Get-BroadcastText 'HTTPS port' 'Porta HTTPS';$portLabel.SetBounds(525,426,105,25)
    $analyzerPort=New-Object Windows.Forms.NumericUpDown;$analyzerPort.Minimum=1;$analyzerPort.Maximum=65535;$analyzerPort.Value=$config.AnalyzerPort;$analyzerPort.SetBounds(638,423,150,28)
    $credentialHint=New-Object Windows.Forms.Label;$credentialHint.SetBounds(12,466,776,44)
    $credentialHint.Text=Get-BroadcastText 'Temporary audio access; configure its URL on the service.' 'Acesso temporário ao áudio; configure este URL no serviço.'
    $credentialHint.Width=560
    $testConnection=New-Object Windows.Forms.Button;$testConnection.Text='Testar ligação';$testConnection.SetBounds(588,466,200,32)
    $connectionStatus=New-Object Windows.Forms.Label;$connectionStatus.SetBounds(12,516,776,64);$connectionStatus.Text=Get-AnalyzerConnectionStatus
    $diagnosticPath=New-Object Windows.Forms.TextBox;$diagnosticPath.ReadOnly=$true;$diagnosticPath.SetBounds(12,585,776,26);$diagnosticPath.Text=$runtime.AnalyzerDiagnosticPath
    $diagnosticPath.Visible=-not [string]::IsNullOrEmpty($diagnosticPath.Text)
    $save=New-Object Windows.Forms.Button;$save.Text=Get-BroadcastText 'Save' 'Guardar';$save.SetBounds(566,748,105,30)
    $close=New-Object Windows.Forms.Button;$close.Text=Get-BroadcastText 'Cancel' 'Cancelar';$close.SetBounds(683,748,105,30);$close.DialogResult='Cancel'
    $machineLabel=New-Object Windows.Forms.Label;$machineLabel.Text='MachineId (GUID no serviço)';$machineLabel.SetBounds(12,622,360,24);$dialog.Controls.Add($machineLabel)
    $machineId=New-Object Windows.Forms.TextBox;$machineId.SetBounds(12,650,370,26);$machineId.Text=$config.MachineId;$dialog.Controls.Add($machineId)
    $keyLabel=New-Object Windows.Forms.Label;$keyLabel.Text='Chave de acesso ao serviço (em branco: manter)';$keyLabel.SetBounds(402,622,386,24);$dialog.Controls.Add($keyLabel)
    $serviceKey=New-Object Windows.Forms.TextBox;$serviceKey.UseSystemPasswordChar=$true;$serviceKey.SetBounds(402,650,386,26);$dialog.Controls.Add($serviceKey)
    $pinLabel=New-Object Windows.Forms.Label;$pinLabel.Text='SHA-256 do certificado HTTPS do serviço (opcional)';$pinLabel.SetBounds(12,686,776,24);$dialog.Controls.Add($pinLabel)
    $servicePin=New-Object Windows.Forms.TextBox;$servicePin.SetBounds(12,711,776,26);$servicePin.Text=$config.ServiceCertificateSha256;$dialog.Controls.Add($servicePin)
    $dialog.Controls.AddRange(@($enabled,$network,$refresh,$port,$channels,$bitrate,$unit,$auth,$user,$password,$hint,$saveAccess,$urlLabel,$url,$copy,$analyzerEnabled,$hostLabel,$analyzerHost,$portLabel,$analyzerPort,$credentialHint,$testConnection,$connectionStatus,$diagnosticPath,$save,$close));$dialog.CancelButton=$close;$dialog.AcceptButton=$save
    $ui=@{ServicePin=$servicePin;MachineId=$machineId;ServiceKey=$serviceKey;Dialog=$dialog;Enabled=$enabled;Network=$network;Port=$port;Channels=$channels;Bitrate=$bitrate;Auth=$auth;User=$user;Password=$password;Url=$url;Refresh=$refresh;SaveAccess=$saveAccess;Copy=$copy;AnalyzerEnabled=$analyzerEnabled;AnalyzerHost=$analyzerHost;AnalyzerPort=$analyzerPort;ConnectionStatus=$connectionStatus;TestConnection=$testConnection}
    $testConnection.Tag=$ui
    foreach($control in @($analyzerHost,$analyzerPort)){$control.Tag=$ui}
    $analyzerHost.Add_TextChanged({param($sender,$args) $sender.Tag.ConnectionStatus.Text='Endereço alterado. Teste a ligação e guarde a configuração.';$sender.Tag.ConnectionStatus.ForeColor=[Drawing.SystemColors]::ControlText})
    $analyzerPort.Add_ValueChanged({param($sender,$args) $sender.Tag.ConnectionStatus.Text='Porta alterada. Teste a ligação e guarde a configuração.';$sender.Tag.ConnectionStatus.ForeColor=[Drawing.SystemColors]::ControlText})
    $testConnection.Add_Click({
        param($sender,$args)
        $ui=$sender.Tag;$socket=New-Object Net.Sockets.TcpClient;$sender.Enabled=$false
        try{
            $connect=$socket.ConnectAsync($ui.AnalyzerHost.Text.Trim(),[int]$ui.AnalyzerPort.Value)
            if(-not $connect.Wait(1500)){throw 'Tempo de ligação excedido.'};$connect.GetAwaiter().GetResult()
            $ui.ConnectionStatus.ForeColor=[Drawing.Color]::DarkGreen
            $ui.ConnectionStatus.Text='Porta acessível em '+$ui.AnalyzerHost.Text+':'+$ui.AnalyzerPort.Value+'. A validação HTTPS e da chave será feita ao iniciar a análise.'
        }catch{$ui.ConnectionStatus.ForeColor=[Drawing.Color]::Firebrick;$ui.ConnectionStatus.Text='Não foi possível ligar a '+$ui.AnalyzerHost.Text+':'+$ui.AnalyzerPort.Value+'. '+$_.Exception.GetBaseException().Message}
        finally{$socket.Dispose();$sender.Enabled=$true}
    })
    foreach($control in @($save,$refresh,$port,$network,$saveAccess,$copy)){$control.Tag=$ui}
    $refresh.Add_Click({param($sender,$args) try{Update-BroadcastNetworkList $sender.Tag}catch{Show-BroadcastDialogError $sender.Tag $_.Exception.Message}})
    $network.Add_SelectedIndexChanged({param($sender,$args) Update-BroadcastDialogUrl $sender.Tag})
    $port.Add_ValueChanged({param($sender,$args) Update-BroadcastDialogUrl $sender.Tag})
    $copy.Add_Click({param($sender,$args) try{if($sender.Tag.Url.Text){[Windows.Forms.Clipboard]::SetText($sender.Tag.Url.Text)}}catch{Show-BroadcastDialogError $sender.Tag $_.Exception.Message}})
    $saveAccess.Add_Click({param($sender,$args) try{Save-BroadcastDialogSettings $sender.Tag -AccessOnly}catch{Show-BroadcastDialogError $sender.Tag $_.Exception.Message}})
    Update-BroadcastNetworkList $ui
    if($runtime.LastError){$dialog.Add_Shown({param($sender,$args) Show-BroadcastDialogError $sender.Tag (Get-ApplicationBroadcast).LastError})}
    $dialog.Tag=$ui
    $save.Add_Click({
        param($sender,$args)
        $ui=$sender.Tag;$runtime=Get-ApplicationBroadcast
        try{
            Save-BroadcastDialogSettings $ui
            $ui.Dialog.DialogResult='OK';$ui.Dialog.Close()
        }catch{Show-BroadcastDialogError $ui $_.Exception.Message}
    })
    try{if($Owner){[void]$dialog.ShowDialog($Owner)}else{[void]$dialog.ShowDialog()}}finally{$dialog.Dispose()}
}
function Add-ApplicationBroadcastControls($Form){
    $Form.MinimumSize=New-Object Drawing.Size(([Math]::Max(1040,$Form.MinimumSize.Width)),$Form.MinimumSize.Height)
    $button=New-Object Windows.Forms.Button;Register-ButtonActionTooltip $button
    $button.Text=Get-BroadcastText 'Configure audio broadcast' 'Configurar emissão de áudio';$button.SetBounds(12,584,228,28);$button.Anchor='Bottom,Left'
    $button.Add_Click({param($sender,$args) Show-ApplicationBroadcastDialog $sender.FindForm()})
    $Form.Controls.Add($button);$Form.Tag.BroadcastSettings=$button
    $runtime=Get-ApplicationBroadcast;if($runtime){$runtime.Button=$button;Update-ApplicationBroadcast}
}
