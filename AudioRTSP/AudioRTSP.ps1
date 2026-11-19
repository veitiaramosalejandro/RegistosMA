param([switch]$SmokeTest,[string]$ScreenshotPath,[string]$SmokeSelectAddress,[ValidateSet('','pt','en')][string]$SmokeLanguage='',[string]$SmokeCredentialFile='')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. "$PSScriptRoot\Core.ps1"
. "$PSScriptRoot\Language.ps1"
. "$PSScriptRoot\Service.ps1"
$script:session=$null
$script:smokeFailure=$null
$mutexName=if($SmokeTest){'Local\MA_RTSP_Transmissor_SmokeTest'}else{'Local\MA_RTSP_Transmissor_v1'}
$mutex=New-Object Threading.Mutex($false,$mutexName)
$owned=$false
try {
    $owned=$mutex.WaitOne(0)
    if(-not $owned){throw 'Ja existe um transmissor aberto neste PC.'}
    $form=New-Object Windows.Forms.Form
    $form.Text='AudioRTSP'
    $form.ClientSize=New-Object Drawing.Size(730,810)
    $form.MinimumSize=$form.Size
    $form.FormBorderStyle='FixedSingle'; $form.MaximizeBox=$false
    $form.StartPosition='CenterScreen'
    $form.Font=New-Object Drawing.Font('Segoe UI',10)
    function Label([string]$Text,[int]$X,[int]$Y,[int]$Width=650){
        $c=New-Object Windows.Forms.Label; $c.Text=$Text;$c.Tag=$Text; $c.SetBounds($X,$Y,$Width,25);$form.Controls.Add($c);return $c
    }
    function Button([string]$Text,[int]$X,[int]$Y,[int]$Width=150){
        $c=New-Object Windows.Forms.Button;$c.Text=$Text;$c.Tag=$Text;$c.SetBounds($X,$Y,$Width,34);$form.Controls.Add($c);return $c
    }
    $null=Label 'Escolha a entrada da placa de som que pretende transmitir.' 20 16
    $null=Label 'Entrada de áudio' 20 54
    $devices=New-Object Windows.Forms.ComboBox
    $devices.DropDownStyle='DropDownList';$devices.DisplayMember='Name';$devices.SetBounds(20,82,510,30);$form.Controls.Add($devices)
    $refresh=Button 'Atualizar entradas' 545 79 165
    $null=Label 'Rede / endereço IP de transmissão' 20 130
    $network=New-Object Windows.Forms.ComboBox
    $network.DropDownStyle='DropDownList';$network.DisplayMember='Name';$network.DropDownWidth=680
    $network.SetBounds(20,158,510,30);$form.Controls.Add($network)
    $refreshNetwork=Button 'Atualizar redes' 545 155 165
    $null=Label 'Porta RTSP' 20 220 140
    $port=New-Object Windows.Forms.NumericUpDown;$port.Minimum=1024;$port.Maximum=65535;$port.Value=8554;$port.SetBounds(20,248,140,30);$form.Controls.Add($port)
    $null=Label 'Canais' 190 220 150
    $channels=New-Object Windows.Forms.ComboBox;$channels.DropDownStyle='DropDownList';$null=$channels.Items.AddRange(@('Mono (1)','Estéreo (2)'));$channels.SelectedIndex=1;$channels.SetBounds(190,248,180,30);$form.Controls.Add($channels)
    $null=Label 'Qualidade AAC' 400 220 180
    $bitrate=New-Object Windows.Forms.ComboBox;$bitrate.DropDownStyle='DropDownList';$null=$bitrate.Items.AddRange(@('64','128','192','256','320'));$bitrate.SelectedItem='192';$bitrate.SetBounds(400,248,160,30);$form.Controls.Add($bitrate)
    $null=Label 'kbit/s' 570 250 100
    $start=Button 'Iniciar transmissão' 20 300 190
    $stop=Button 'Parar' 225 300 120;$stop.Enabled=$false
    $status=Label 'Parado' 20 352
    $status.Font=New-Object Drawing.Font('Segoe UI',12,[Drawing.FontStyle]::Bold)
    $null=Label 'URL RTSP para acesso à transmissão de áudio' 20 392
    $url=New-Object Windows.Forms.TextBox;$url.ReadOnly=$true;$url.SetBounds(20,423,510,30);$form.Controls.Add($url)
    $copy=Button 'Copiar endereço' 545 420 165
    $footer=Label 'Na primeira utilização, permita o acesso pela rede privada na Firewall do Windows.' 20 502 700
    foreach($control in $form.Controls){$control.Top+=40}
    $footer.Top-=30
    $null=Label 'Idioma / Language' 20 16 140
    $language=New-Object Windows.Forms.ComboBox;$language.DropDownStyle='DropDownList'
    $language.Items.AddRange(@('Português','English'));$language.SetBounds(170,12,170,30)
    $language.SelectedIndex=if($script:AudioLanguage -eq 'en'){1}else{0};$form.Controls.Add($language)
    $apply=Button 'Aplicar' 355 10 120
    foreach($control in $form.Controls){if($control.Top -ge 330){$control.Top+=120}}
    $authEnabled=New-Object Windows.Forms.CheckBox;$authEnabled.Text='Exigir utilizador e palavra-passe';$authEnabled.Tag=$authEnabled.Text
    $authEnabled.SetBounds(20,330,690,25);$form.Controls.Add($authEnabled)
    $null=Label 'Utilizador' 20 366 110
    $authUser=New-Object Windows.Forms.TextBox;$authUser.SetBounds(140,362,200,30);$form.Controls.Add($authUser)
    $null=Label 'Palavra-passe' 360 366 125
    $authPassword=New-Object Windows.Forms.TextBox;$authPassword.UseSystemPasswordChar=$true;$authPassword.SetBounds(490,362,220,30);$form.Controls.Add($authPassword)
    $null=Label 'Em branco: mantém a palavra-passe guardada.' 20 406 515
    $saveAccess=Button 'Guardar acesso' 545 400 165
    $serviceStatus=Label 'Serviço não instalado' 20 677 690
    $serviceInstall=Button 'Instalar serviço' 20 709 190
    $serviceToggle=Button 'Iniciar serviço' 225 709 190
    $serviceAuto=New-Object Windows.Forms.CheckBox
    $serviceAuto.Text='Arrancar automaticamente com o Windows';$serviceAuto.Tag=$serviceAuto.Text
    $serviceAuto.SetBounds(20,755,690,28);$form.Controls.Add($serviceAuto)
    $script:updatingService=$false
    function Refresh-ServiceControls {
        $script:updatingService=$true
        try {
            $svc=Get-AudioService
            $installed=$null -ne $svc
            $active=$installed -and $svc.Status -ne 'Stopped'
            $serviceStatus.Text=Get-AudioText $(if(-not $installed){'Serviço não instalado'}elseif($svc.Status -eq 'Running'){'Serviço em execução'}elseif($svc.Status -eq 'Stopped'){'Serviço parado'}else{'Serviço a mudar de estado...'})
            $serviceInstall.Text=Get-AudioText $(if($installed){'Desinstalar serviço'}else{'Instalar serviço'})
            $serviceToggle.Text=Get-AudioText $(if($active){'Parar serviço'}else{'Iniciar serviço'})
            $local=$null -ne $script:session
            $serviceInstall.Enabled=-not $local
            $serviceToggle.Enabled=$installed -and -not $local -and $svc.Status -in @('Running','Stopped')
            $serviceAuto.Enabled=$installed -and -not $local
            $serviceAuto.Checked=$installed -and $svc.StartType -eq 'Automatic'
            if(-not $local){Set-Running $active;$stop.Enabled=$false}
        } finally {$script:updatingService=$false}
    }
    function Invoke-ServiceUI([string]$Operation){
        try {
            if($Operation -in @('Install','Start')){
                if($null -eq $devices.SelectedItem){throw 'Selecione uma entrada de audio.'}
                if($null -eq $network.SelectedItem){throw 'Selecione a rede / endereço IP de transmissão.'}
                $settings=Get-Settings
                Assert-AudioAccess (Get-AudioAccessSettings ([pscustomobject]$settings))
                Save-AudioSettings $settings;$script:savedAuthHash=$settings.AuthPasswordHash
            }
            Invoke-AudioServiceAction $Operation
        } catch {$null=[Windows.Forms.MessageBox]::Show((Get-AudioText $_.Exception.Message),'AudioRTSP','OK','Error')}
        Refresh-ServiceControls
    }
    $serviceInstall.Add_Click({if(Get-AudioService){Invoke-ServiceUI 'Uninstall'}else{Invoke-ServiceUI 'Install'}})
    $serviceToggle.Add_Click({$svc=Get-AudioService;if($svc -and $svc.Status -ne 'Stopped'){Invoke-ServiceUI 'Stop'}else{Invoke-ServiceUI 'Start'}})
    $serviceAuto.Add_CheckedChanged({if(-not $script:updatingService){Invoke-ServiceUI $(if($serviceAuto.Checked){'Automatic'}else{'Manual'})}})
    $script:savedAuthHash=''
    function Update-AccessControls {
        $svc=Get-AudioService
        $editable=$null -eq $script:session -and ($null -eq $svc -or $svc.Status -eq 'Stopped')
        $authEnabled.Enabled=$editable;$saveAccess.Enabled=$editable
        $authUser.Enabled=$editable -and $authEnabled.Checked;$authPassword.Enabled=$authUser.Enabled
    }
    $script:statusKey='Parado'
    function Set-Status([string]$Text){$script:statusKey=$Text;$status.Text=Get-AudioText $Text}
    function Update-AudioLanguage {
        foreach($control in $form.Controls){if($control.Tag -is [string] -and $control -ne $status){$control.Text=Get-AudioText $control.Tag}}
        $index=$channels.SelectedIndex;$channels.Items.Clear();$channels.Items.AddRange(@('Mono (1)',(Get-AudioText 'Estéreo (2)')));$channels.SelectedIndex=$index
        $apply.Text=if($language.SelectedIndex -eq 1){'Apply'}else{'Aplicar'}
        Set-Status $script:statusKey
    }
    $profile=Join-Path $PSScriptRoot 'config.json'
    $script:savedId=''
    $script:savedAddress=''
    $script:loadingNetworks=$false
    if(Test-Path -LiteralPath $profile){
        try {
            $cfg=Get-Content -LiteralPath $profile -Raw | ConvertFrom-Json
            $port.Value=[Math]::Max(1024,[Math]::Min(65535,[int]$cfg.Port))
            $channels.SelectedIndex=([int]$cfg.Channels)-1
            if($bitrate.Items.Contains([string]$cfg.Bitrate)){$bitrate.SelectedItem=[string]$cfg.Bitrate}
            $script:savedId=[string]$cfg.Device
            if($cfg.PSObject.Properties['BindAddress']){$script:savedAddress=[string]$cfg.BindAddress}
            $access=Get-AudioAccessSettings $cfg
            $authEnabled.Checked=$access.Enabled;$authUser.Text=$access.Username;$script:savedAuthHash=$access.PasswordHash
        } catch {Set-Status 'Configuracao invalida; escolha novamente as opcoes.'}
    }
    function Update-Url {
        if($null -eq $network.SelectedItem){$url.Text='';$copy.Enabled=$false;return}
        $hostAddress=$network.SelectedItem.Address
        $url.Text="rtsp://${hostAddress}:$($port.Value)/audio";$copy.Enabled=$true
    }
    function Get-Settings {
        $deviceId=$script:savedId;$deviceName=''
        if($null -ne $devices.SelectedItem){$deviceId=$devices.SelectedItem.Id;$deviceName=$devices.SelectedItem.Name}
        $address=$script:savedAddress
        if($null -ne $network.SelectedItem){$address=$network.SelectedItem.Address}
        $hash=$script:savedAuthHash
        if($authEnabled.Checked -and $authPassword.Text.Length){Assert-AudioPassword $authPassword.Text;$hash=Get-AudioCredentialHash $authPassword.Text}
        return @{Device=$deviceId;DeviceName=$deviceName;BindAddress=$address;Port=[int]$port.Value;Channels=$channels.SelectedIndex+1;Bitrate=[int]$bitrate.SelectedItem;Language=$script:AudioLanguage;AuthEnabled=$authEnabled.Checked;AuthUsername=$authUser.Text.Trim();AuthPasswordHash=$hash}
    }
    function Save-CurrentSettings {
        try {Save-AudioSettings (Get-Settings)} catch {
            Set-Status 'Não foi possível guardar o config.json.'
            if($SmokeTest){throw}
            $null=[Windows.Forms.MessageBox]::Show((Get-AudioText $_.Exception.Message),'AudioRTSP','OK','Error')
        }
    }
    function Refresh-Networks {
        $script:loadingNetworks=$true
        try {
            $network.Items.Clear()
            foreach($item in @(Get-LocalIPv4)){$null=$network.Items.Add($item)}
            $network.SelectedIndex=-1
            for($i=0;$i -lt $network.Items.Count;$i++){
                if($network.Items[$i].Address -eq $script:savedAddress){$network.SelectedIndex=$i;break}
            }
            if(-not $script:savedAddress -and $network.Items.Count){$network.SelectedIndex=0}
            if($network.SelectedIndex -lt 0){Set-Status 'O IP guardado não está disponível. Selecione uma rede ativa.'}
        } finally {$script:loadingNetworks=$false}
        Update-Url
        if($null -ne $network.SelectedItem){$script:savedAddress=$network.SelectedItem.Address;Save-CurrentSettings}
    }
    function Set-Running([bool]$Value){
        foreach($c in @($devices,$refresh,$network,$refreshNetwork,$port,$channels,$bitrate,$start)){$c.Enabled=-not $Value}
        $stop.Enabled=$Value
        $authEnabled.Enabled=-not $Value;$saveAccess.Enabled=-not $Value
        $authUser.Enabled=-not $Value -and $authEnabled.Checked;$authPassword.Enabled=$authUser.Enabled
    }
    function Refresh-Devices {
        $form.UseWaitCursor=$true
        try {
            if($null -ne $devices.SelectedItem){$script:savedId=$devices.SelectedItem.Id}
            $devices.Items.Clear()
            foreach($d in @(Get-AudioDevices)){$null=$devices.Items.Add($d)}
            if($devices.Items.Count){
                $devices.SelectedIndex=if($script:savedId){-1}else{0}
                for($i=0;$i -lt $devices.Items.Count;$i++){if($devices.Items[$i].Id -eq $script:savedId){$devices.SelectedIndex=$i;break}}
                Set-Status 'Pronto. Selecione a entrada e inicie a transmissão.'
                if($devices.SelectedIndex -lt 0){Set-Status 'A entrada guardada não está disponível. Selecione outra entrada.'}
            } else {Set-Status 'Nenhuma entrada encontrada. Ligue a placa e atualize as entradas.'}
        } catch {Set-Status $_.Exception.Message} finally {$form.UseWaitCursor=$false}
    }
    $refresh.Add_Click({Refresh-Devices})
    $authEnabled.Add_CheckedChanged({Update-AccessControls})
    $saveAccess.Add_Click({
        try {$settings=Get-Settings;Assert-AudioAccess (Get-AudioAccessSettings ([pscustomobject]$settings));Save-AudioSettings $settings;$script:savedAuthHash=$settings.AuthPasswordHash;Set-Status 'Configuração de acesso guardada.'}
        catch {if($SmokeTest){throw};$null=[Windows.Forms.MessageBox]::Show((Get-AudioText $_.Exception.Message),'AudioRTSP','OK','Error')}
    })
    $language.Add_SelectedIndexChanged({$apply.Text=if($this.SelectedIndex -eq 1){'Apply'}else{'Aplicar'}})
    $apply.Add_Click({$script:AudioLanguage=if($language.SelectedIndex -eq 1){'en'}else{'pt'};Update-AudioLanguage;Save-CurrentSettings})
    $refreshNetwork.Add_Click({Refresh-Networks})
    $network.Add_SelectedIndexChanged({
        if(-not $script:loadingNetworks -and $null -ne $network.SelectedItem){
            $script:savedAddress=$network.SelectedItem.Address;Update-Url;Save-CurrentSettings
            if($null -ne $devices.SelectedItem){Set-Status 'Pronto. Selecione a entrada e inicie a transmissão.'}
        }
    })
    $port.Add_ValueChanged({Update-Url})
    $copy.Add_Click({[Windows.Forms.Clipboard]::SetText($url.Text)})
    $start.Add_Click({
        try {
            if($null -eq $devices.SelectedItem){throw 'Selecione uma entrada de audio.'}
            if($null -eq $network.SelectedItem){throw 'Selecione a rede / endereço IP de transmissão.'}
            $svc=Get-AudioService;if($svc -and $svc.Status -ne 'Stopped'){throw 'Pare o serviço antes de iniciar a transmissão na aplicação.'}
            Set-Running $true;Set-Status 'A iniciar...';$form.Refresh()
            $settings=Get-Settings
            $access=Get-AudioAccessSettings ([pscustomobject]$settings)
            Assert-AudioAccess $access
            Save-AudioSettings $settings
            $script:savedAuthHash=$settings.AuthPasswordHash
            $script:session=Start-Transmission -Device $settings.Device -Port $settings.Port -Channels $settings.Channels -Bitrate $settings.Bitrate -BindAddress $settings.BindAddress -Access $access
            Update-Url
        } catch {
            Stop-Transmission $script:session;$script:session=$null;Set-Running $false;Set-Status 'Nao foi possivel iniciar.'
            $null=[Windows.Forms.MessageBox]::Show((Get-AudioText $_.Exception.Message),'AudioRTSP','OK','Error')
        }
    })
    $stop.Add_Click({Stop-Transmission $script:session;$script:session=$null;Set-Running $false;Set-Status 'Parado'})
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=1000
    $timer.Add_Tick({
        Refresh-ServiceControls
        if($null -eq $script:session){return}
        $state=Get-TransmissionState $script:session
        if($state -eq 'Falha'){
            Stop-Transmission $script:session;$script:session=$null;Set-Running $false
            Set-Status 'Transmissão interrompida. Verifique a placa de som e a rede e volte a iniciar.'
            $notice=Get-AudioText 'Verifique a placa de som, as permissões do microfone e a ligação de rede.'
            $null=[Windows.Forms.MessageBox]::Show($notice,(Get-AudioText 'Transmissao interrompida'),'OK','Warning')
        } else {Set-Status $state}
    })
    $form.Add_FormClosing({$timer.Stop();Stop-Transmission $script:session;$script:session=$null})
    Update-Url
    Update-AudioLanguage
    Update-AccessControls
    Refresh-ServiceControls
    if($SmokeTest){
        $form.Add_Shown({
            try {
            Refresh-Devices
            Refresh-Networks
            if($SmokeLanguage){$language.SelectedIndex=if($SmokeLanguage -eq 'en'){1}else{0};$apply.PerformClick()}
            if($SmokeSelectAddress){
                for($i=0;$i -lt $network.Items.Count;$i++){if($network.Items[$i].Address -eq $SmokeSelectAddress){$network.SelectedIndex=$i;break}}
                if($null -eq $network.SelectedItem -or $network.SelectedItem.Address -ne $SmokeSelectAddress){throw 'IP de teste indisponível'}
            }
            if($SmokeCredentialFile){
                $testAccess=Get-Content -LiteralPath $SmokeCredentialFile -Raw | ConvertFrom-Json
                $authEnabled.Checked=[bool]$testAccess.Enabled;$authUser.Text=[string]$testAccess.Username;$authPassword.Text=[string]$testAccess.Password
                $saveAccess.PerformClick()
            }
            if($ScreenshotPath){[IO.File]::WriteAllText(($ScreenshotPath+'.json'),(@{SelectedAddress=$script:savedAddress;Url=$url.Text;Language=$script:AudioLanguage;AuthEnabled=$authEnabled.Checked;PasswordStored=($script:savedAuthHash.Length -gt 0);ControlTexts=@($form.Controls | Where-Object {$_ -ne $authPassword} | ForEach-Object {$_.Text})} | ConvertTo-Json))}
            if($ScreenshotPath){
                $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
                $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
                $bitmap.Save($ScreenshotPath);$bitmap.Dispose()
            }
            } catch {$script:smokeFailure=$_.Exception} finally {$form.Close()}
        })
    } else {$form.Add_Shown({Refresh-Devices;Refresh-Networks;$timer.Start()})}
    $null=$form.ShowDialog()
    if($script:smokeFailure){throw $script:smokeFailure}
    $timer.Dispose();$form.Dispose()
} catch {
    if($SmokeTest){throw}
    $null=[Windows.Forms.MessageBox]::Show((Get-AudioText $_.Exception.Message),'AudioRTSP','OK','Error')
} finally {
    Stop-Transmission $script:session
    if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()
}


