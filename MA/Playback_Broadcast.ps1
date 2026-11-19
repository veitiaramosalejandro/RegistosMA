#Requires -Version 5.1
# One runtime per manager process, shared with child playback script scopes.
. (Join-Path $PSScriptRoot 'Playback_StreamMetadata.ps1')
function Get-ApplicationBroadcast { return $global:MachiningMonitorPlaybackBroadcast }
function Get-BroadcastText([string]$English,[string]$Portuguese){
    if($script:UiLanguage -eq 'en'){return $English};return $Portuguese
}
function New-BroadcastConfiguration {
    return [pscustomobject][ordered]@{Version=2;Enabled=$false;Address='127.0.0.1';Port=8555;Channels=2;Bitrate=192;AuthEnabled=$true;Username='audio';PasswordHash=''}
}
function Read-BroadcastConfiguration([string]$Path){
    $config=New-BroadcastConfiguration
    if(Test-Path -LiteralPath $Path){
        $saved=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        foreach($name in @('Enabled','Address','Port','Channels','Bitrate','AuthEnabled','Username','PasswordHash')){
            if($null -ne $saved.PSObject.Properties[$name]){$config.$name=$saved.$name}
        }
        if($config.Enabled -isnot [bool] -or $config.AuthEnabled -isnot [bool]){throw 'Configuração de emissão inválida: as opções devem ser true/false.'}
        if($config.Port -isnot [int] -and $config.Port -isnot [long]){throw 'Configuração de emissão inválida: porta.'}
        if($config.Port -lt 1024 -or $config.Port -gt 65535){throw 'A porta deve estar entre 1024 e 65535.'}
        if($config.Channels -notin @(1,2) -or $config.Bitrate -notin @(64,128,192,256,320)){throw 'Formato de áudio guardado inválido.'}
    }
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
            $parameters=(Get-Command Start-Transmission).Parameters
            if(-not $parameters.ContainsKey('PcmInput') -or -not $parameters.ContainsKey('MetadataInput')){throw 'Atualize também AudioRTSP/Core.ps1 com a versão incluída neste pacote.'}
            Export-ModuleMember -Function *
        }
    }
    if(-not ('MachiningMonitor.Broadcast.ProcessAudio' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'Playback_ProcessAudio.cs')}
}
function New-ApplicationTransmission($Config){
    if([Environment]::OSVersion.Version.Build -lt 20348){throw 'A emissão do áudio do leitor exige Windows build 20348 ou posterior (por exemplo Windows 11).'}
    Initialize-PlaybackBroadcast
    $runtime=Get-ApplicationBroadcast;$transmission=$null;$capture=$null
    $access=[pscustomobject]@{Enabled=$Config.AuthEnabled;Username=$Config.Username;PasswordHash=$Config.PasswordHash}
    try{
        $transmission=& $runtime.Engine {param($ip,$port,$auth,$channels,$bitrate) Start-Transmission -PcmInput -MetadataInput -BindAddress $ip -Port $port -Access $auth -Channels $channels -Bitrate $bitrate} $Config.Address $Config.Port $access $Config.Channels $Config.Bitrate
        $capture=New-Object MachiningMonitor.Broadcast.ProcessAudio($transmission.Encoder.StandardInput.BaseStream)
        if($runtime.Player -and -not $runtime.Player.HasExited){$capture.SetProcess($runtime.Player.Id)}
        return @{Transmission=$transmission;Capture=$capture;LastFrames=0L;ProgressAt=[datetime]::UtcNow;CaptureWaitAt=[datetime]::UtcNow}
    }catch{
        if($transmission){& $runtime.Engine {param($s) Stop-Transmission $s} $transmission}
        if($capture){$capture.Dispose()};throw
    }
}
function Stop-ApplicationTransmission {
    $runtime=Get-ApplicationBroadcast
    if(-not $runtime -or -not $runtime.Session){return}
    $session=$runtime.Session;$runtime.Session=$null
    if($runtime.PlaybackState){$runtime.PlaybackState.Context.Broadcast=$null;$runtime.PlaybackState.Session.BroadcastCapture=$null}
    try{& $runtime.Engine {param($s) Stop-Transmission $s} $session.Transmission}finally{$session.Capture.Dispose()}
}
function Set-ApplicationBroadcastPlayer($State,$Session){
    $runtime=Get-ApplicationBroadcast
    if(-not $runtime){return}
    $runtime.Player=$Session.Player;$runtime.PlaybackState=$State
    $State.Context.Broadcast=$runtime.Session
    if($runtime.Session){$Session.BroadcastCapture=$runtime.Session.Capture;$Session.BroadcastCapture.SetProcess($Session.Player.Id);Start-PlaybackStreamMetadata $runtime $State}
}
# Closing a recording detaches only its capture. The application keeps sending silence.
function Stop-PlaybackBroadcast($State){
    $runtime=Get-ApplicationBroadcast
    if(-not $runtime){return}
    if($runtime.PlaybackState -eq $State){
        Stop-PlaybackStreamMetadata $runtime
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
        if($runtime.Session){
            $session=$runtime.Session;$now=[datetime]::UtcNow
            if($session.Capture.Failure){throw $session.Capture.Failure}
            if($session.Capture.SentFrames -ne $session.LastFrames){$session.LastFrames=$session.Capture.SentFrames;$session.ProgressAt=$now}
            if(($now-$session.ProgressAt).TotalSeconds -gt 5){throw 'O envio de áudio RTSP ficou bloqueado.'}
            if($session.Capture.CaptureReady -or $session.Capture.TargetProcess -eq 0){$session.CaptureWaitAt=$now}
            if(($now-$session.CaptureWaitAt).TotalSeconds -gt 10){throw 'O Windows não iniciou a captura do áudio do leitor.'}
            $status=& $runtime.Engine {param($s) Get-TransmissionState $s} $session.Transmission
            if($status -eq 'Falha'){throw 'O servidor ou codificador RTSP deixou de responder.'}
            Update-PlaybackStreamMetadata $runtime
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
    $runtime.Timer=New-Object Windows.Forms.Timer;$runtime.Timer.Interval=500
    $runtime.Timer.Add_Tick({Update-ApplicationBroadcast});$runtime.Timer.Start()
}
function Stop-ApplicationBroadcast {
    $runtime=Get-ApplicationBroadcast
    if(-not $runtime){return}
    try{if($runtime.Timer){$runtime.Timer.Stop();$runtime.Timer.Dispose()};Stop-ApplicationTransmission}
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
    $access=[pscustomobject]@{Enabled=$Config.AuthEnabled;Username=$Config.Username;PasswordHash=$Config.PasswordHash}
    if($Config.Enabled -or $Config.PasswordHash){& $runtime.Engine {param($a) Assert-AudioAccess $a} $access}
    $previous=$runtime.Config;$wasRunning=$null -ne $runtime.Session
    $changed=($Config|ConvertTo-Json -Compress) -ne ($previous|ConvertTo-Json -Compress)
    $replace=$Config.Enabled -and ($changed -or -not $wasRunning)
    $temp=$runtime.ConfigPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        if($replace){
            Stop-ApplicationTransmission
            $runtime.Session=New-ApplicationTransmission $Config
        }
        [IO.File]::WriteAllText($temp,($Config|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($true)))
        if(Test-Path -LiteralPath $runtime.ConfigPath){[IO.File]::Replace($temp,$runtime.ConfigPath,[NullString]::Value)}else{[IO.File]::Move($temp,$runtime.ConfigPath)}
        $runtime.Config=$Config;$runtime.LastError=$null
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
    if($Ui.Password.Text.Length){$hash=& $runtime.Engine {param($p) Assert-AudioPassword $p;Get-AudioCredentialHash $p} $Ui.Password.Text}
    $next=New-BroadcastConfiguration
    if($AccessOnly){
        foreach($property in $runtime.Config.PSObject.Properties){$next.($property.Name)=$property.Value}
    }else{
        $next.Enabled=$Ui.Enabled.Checked;$next.Address=$Ui.Network.SelectedItem.Address;$next.Port=[int]$Ui.Port.Value
        $next.Channels=[int]$Ui.Channels.SelectedItem.Value;$next.Bitrate=[int]$Ui.Bitrate.SelectedItem
    }
    $next.AuthEnabled=$Ui.Auth.Checked;$next.Username=$Ui.User.Text;$next.PasswordHash=$hash
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
    $dialog.ClientSize=New-Object Drawing.Size(720,430);$dialog.StartPosition='CenterParent';$dialog.FormBorderStyle='FixedDialog';$dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false
    $enabled=New-Object Windows.Forms.CheckBox;$enabled.Text=Get-BroadcastText 'Enable audio broadcast when playing recordings' 'Ativar emissão de áudio ao reproduzir gravações';$enabled.SetBounds(12,10,696,28);$enabled.Checked=$config.Enabled
    $network=New-Object Windows.Forms.ComboBox;$network.DropDownStyle='DropDownList';$network.DisplayMember='Name';$network.SetBounds(12,70,510,26)
    $refresh=New-Object Windows.Forms.Button;$refresh.Text=Get-BroadcastText 'Refresh networks' 'Atualizar redes';$refresh.SetBounds(538,68,162,30)
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
    $saveAccess=New-Object Windows.Forms.Button;$saveAccess.Text=Get-BroadcastText 'Save access' 'Guardar acesso';$saveAccess.SetBounds(538,260,162,30)
    $urlLabel=New-Object Windows.Forms.Label;$urlLabel.Text=Get-BroadcastText 'RTSP URL to access the audio broadcast' 'URL RTSP para acesso à transmissão de áudio';$urlLabel.SetBounds(12,308,688,24)
    $url=New-Object Windows.Forms.TextBox;$url.ReadOnly=$true;$url.SetBounds(12,336,510,26)
    $copy=New-Object Windows.Forms.Button;$copy.Text=Get-BroadcastText 'Copy address' 'Copiar endereço';$copy.SetBounds(538,334,162,30)
    $save=New-Object Windows.Forms.Button;$save.Text=Get-BroadcastText 'Save' 'Guardar';$save.SetBounds(478,388,105,30)
    $close=New-Object Windows.Forms.Button;$close.Text=Get-BroadcastText 'Cancel' 'Cancelar';$close.SetBounds(595,388,105,30);$close.DialogResult='Cancel'
    $dialog.Controls.AddRange(@($enabled,$network,$refresh,$port,$channels,$bitrate,$unit,$auth,$user,$password,$hint,$saveAccess,$urlLabel,$url,$copy,$save,$close));$dialog.CancelButton=$close;$dialog.AcceptButton=$save
    $ui=@{Dialog=$dialog;Enabled=$enabled;Network=$network;Port=$port;Channels=$channels;Bitrate=$bitrate;Auth=$auth;User=$user;Password=$password;Url=$url;Refresh=$refresh;SaveAccess=$saveAccess;Copy=$copy}
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
