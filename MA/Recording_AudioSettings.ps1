. (Join-Path $PSScriptRoot 'Recording_AudioProfiles.ps1')
# Recording settings with independent local-device and RTSP preferences (v281).
function Set-RecordingAudioSourceControls {
    param($Dialog)
    $s=$Dialog.Tag
    if($s.CameraOnly){foreach($field in @($s.Source,$s.Audio,$s.Detect,$s.AudioGrid,$s.RemoveAudio,$s.Channel,$s.Gain,$s.LocalGain)){$field.Enabled=$false};return}
    $local=$s.Source.SelectedIndex -eq 0
    $s.LocalGain.Enabled=$local;$s.Audio.Enabled=$local;$s.Detect.Enabled=$local;$s.AudioGrid.Enabled=-not $local;$s.RemoveAudio.Enabled=-not $local

    if($local -and -not $s.Devices.Count){Update-RecordingAudioDevices $Dialog}
}
function Save-RecordingSettingsDialog {
    param($Dialog)
    $s=$Dialog.Tag
    $values=@{AudioSourceType=$(if($s.Source.SelectedIndex -eq 1){'RTSP'}else{'Local'})}
    if($s.CameraOnly){$values=@{}}
    elseif($values.AudioSourceType -eq 'Local'){
        if($s.Audio.SelectedIndex -lt 0 -or $s.Audio.SelectedIndex -ge $s.Devices.Count){throw (Get-QualityText 'Select a local audio device.' 'Selecione um dispositivo de áudio local.')}
        $dev=$s.Devices[$s.Audio.SelectedIndex]
        $values.AudioDevice=if($dev.AlternativeName){$dev.AlternativeName}else{$dev.Name}
        $values.AudioDeviceName=$dev.Name
    }
    $profiles=@(Read-RecordingAudioGrid $s.AudioGrid)
    $active=@($profiles | Where-Object {$_.Enabled})
    if($active.Count -gt 1 -or ($values.AudioSourceType -eq 'RTSP' -and $active.Count -ne 1)){throw (Get-QualityText 'Select one RTSP audio source.' 'Selecione uma fonte de áudio RTSP.')}
    $values.AudioRtspProfiles=@($profiles | ForEach-Object {[pscustomobject]@{Name=$_.Name;AudioRtspUrl=$_.Url;AudioRtspUsername=$_.Username;AudioRtspPasswordProtected=$_.PasswordProtected;GainDb=$_.GainDb}})
    if($active.Count){$values.AudioRtspGainDb=$active[0].GainDb;$values.AudioRtspUrl=$active[0].Url;$values.AudioRtspUsername=$active[0].Username;$values.AudioRtspPasswordProtected=$active[0].PasswordProtected}
    elseif(-not $s.CameraOnly){$values.AudioRtspUrl='';$values.AudioRtspUsername='';$values.AudioRtspPasswordProtected=''}
    if(-not $s.CameraOnly){$values.LocalAudioGainDb=Get-RecordingGainDb $s.LocalGain.Value}
    $minutes=Read-SplitNumber $s.SegmentMinutes.Text
    if($null -eq $minutes -or $minutes -le 0 -or $minutes -gt 1440){
        throw (Get-QualityText 'Block size must be greater than 0 and at most 1440 minutes.' 'O tamanho dos blocos deve ser maior que 0 e no máximo 1440 minutos.')
    }
    $cameras=@(Read-RecordingCameraGrid $s.Camera)
    $selected=@($cameras | Where-Object {$_.Enabled})
    $values.CameraUrl=if($selected.Count){$selected[0].Url}else{''}
    $values.Cameras=@($cameras);$values.SegmentMinutes=[double]$minutes
    $values.VideoCrf=[int]$s.VideoCrf.Value
    $values.VideoPreset=@('ultrafast','superfast','veryfast','faster','fast','medium')[$s.VideoPreset.SelectedIndex]
    # Save-ConfigValues merges: using RTSP does not erase the local-device choice.
    Save-ConfigValues $script:UiConfigPath $values
    Save-SpectrumChannel $script:UiConfigPath (@('L','R')[$s.Channel.SelectedIndex])
    Save-WaveformGain $script:UiConfigPath ([int]$s.Gain.Value)
}
function New-RecordingSettingsDialog {
    $d=New-Object Windows.Forms.Form
    $d.Text=Get-QualityText 'Recording settings' 'Configuração de gravação'
    $d.ClientSize=New-Object Drawing.Size(900,800);$d.StartPosition='CenterParent';$d.MinimumSize=$d.Size
    $config=Read-RecordingConfig $script:UiConfigPath
    $source=New-Object Windows.Forms.ComboBox;$source.DropDownStyle='DropDownList'
    $source.Items.AddRange(@((Get-QualityText 'Local sound card' 'Placa de som local'),(Get-QualityText 'RTSP audio (AudioRTSP)' 'Áudio RTSP (AudioRTSP)')))
    $source.SetBounds(240,20,640,25);$source.Anchor='Top,Left,Right'
    $source.SelectedIndex=if((Get-RecordingAudioSourceType $config) -eq 'RTSP'){1}else{0}
    $audio=New-Object Windows.Forms.ComboBox;$audio.DropDownStyle='DropDownList';$audio.SetBounds(240,60,425,25);$audio.Anchor='Top,Left,Right'
    # Display the stored local preference without probing hardware in RTSP mode.
    # Switching to Local still enumerates devices before this choice can be saved.
    $savedDevice=Get-ConfigText $config 'AudioDeviceName'
    if([string]::IsNullOrWhiteSpace($savedDevice)){$savedDevice=Get-ConfigText $config 'AudioDevice'}
    if(-not [string]::IsNullOrWhiteSpace($savedDevice)){[void]$audio.Items.Add($savedDevice);$audio.SelectedIndex=0}
    $detect=New-Object Windows.Forms.Button;Register-ButtonActionTooltip $detect;$detect.SetBounds(675,60,205,25);$detect.Anchor='Top,Right'
    $detect.Text=Get-QualityText 'Refresh device list' 'Atualizar lista de dispositivos'
    $channel=New-Object Windows.Forms.ComboBox;$channel.DropDownStyle='DropDownList'
    $channel.Items.AddRange(@((Get-QualityText 'L - Ambient sound' 'L - Som ambiente'),(Get-QualityText 'R - Spindle vibration' 'R - Vibração no fuso')))
    $channel.SetBounds(240,315,640,25);$channel.Anchor='Top,Left,Right';$channel.SelectedIndex=if((Get-DefaultSpectrumChannel $script:UiConfigPath) -eq 'R'){1}else{0}
    $gain=New-Object Windows.Forms.NumericUpDown;$gain.Minimum=1;$gain.Maximum=20;$gain.Value=Get-DefaultWaveformGain $script:UiConfigPath;$gain.SetBounds(240,355,100,25)
    $localGain=New-Object Windows.Forms.NumericUpDown;$localGain.Minimum=-20;$localGain.Maximum=40;$localGain.DecimalPlaces=1;$localGain.Value=Get-RecordingGainDb $config.LocalAudioGainDb;$localGain.SetBounds(640,355,80,25)
    $localGainLabel=New-Object Windows.Forms.Label;$localGainLabel.Text=Get-QualityText 'Local sound card gain (dB)' 'Ganho da placa local (dB)';$localGainLabel.SetBounds(360,359,275,25)
    $d.Controls.AddRange(@($localGain,$localGainLabel))
    $camera=New-RecordingCameraGrid $config;$camera.Top=420
    $remove=New-Object Windows.Forms.Button;Register-ButtonActionTooltip $remove;$remove.Text=Get-QualityText 'Remove camera' 'Remover câmara';$remove.SetBounds(12,586,180,28)
    $remove.Add_Click({Remove-RecordingCameraRow $this.FindForm().Tag.Camera})
    $up=New-Object Windows.Forms.Button;Register-ButtonActionTooltip $up;$up.Text=Get-QualityText 'Move up' 'Mover para cima';$up.SetBounds(202,586,180,28)
    $up.Add_Click({Move-RecordingCameraRow $this.FindForm().Tag.Camera -1})
    $down=New-Object Windows.Forms.Button;Register-ButtonActionTooltip $down;$down.Text=Get-QualityText 'Move down' 'Mover para baixo';$down.SetBounds(392,586,180,28)
    $down.Add_Click({Move-RecordingCameraRow $this.FindForm().Tag.Camera 1})
    $minutes=New-Object Windows.Forms.TextBox;$minutes.SetBounds(240,630,100,25)
    $minutes.Text=if($null -eq $config.SegmentMinutes){'10'}else{[string]$config.SegmentMinutes}
    $encoding=Get-RecordingVideoEncodingSettings $config
    $videoCrf=New-Object Windows.Forms.NumericUpDown;$videoCrf.Minimum=0;$videoCrf.Maximum=51;$videoCrf.Value=$encoding.Crf;$videoCrf.SetBounds(240,670,100,25)
    $crfLabel=New-Object Windows.Forms.Label;$crfLabel.Text=Get-QualityText 'Video quality (CRF)' 'Qualidade do vídeo (CRF)';$crfLabel.SetBounds(12,674,220,25)
    $videoPreset=New-Object Windows.Forms.ComboBox;$videoPreset.DropDownStyle='DropDownList';$videoPreset.SetBounds(640,670,240,25);$videoPreset.Anchor='Top,Right'
    $videoPreset.Items.AddRange(@((Get-QualityText 'Minimal (ultrafast)' 'Mínima (ultrafast)'),(Get-QualityText 'Low (superfast)' 'Baixa (superfast)'),(Get-QualityText 'Balanced (veryfast)' 'Equilibrada (veryfast)'),(Get-QualityText 'Higher (faster)' 'Maior (faster)'),(Get-QualityText 'High (fast)' 'Elevada (fast)'),(Get-QualityText 'Maximum (medium)' 'Máxima (medium)')))
    $videoPreset.SelectedIndex=[Array]::IndexOf(@('ultrafast','superfast','veryfast','faster','fast','medium'),$encoding.Preset)
    $presetLabel=New-Object Windows.Forms.Label;$presetLabel.Text=Get-QualityText 'Video compression' 'Compressão do vídeo';$presetLabel.SetBounds(410,674,220,25)
    $encodingHint=New-Object Windows.Forms.Label;$encodingHint.Text=Get-QualityText 'Higher CRF: smaller files, lower quality. More compression: more CPU. Suggested: 22 / Balanced.' 'CRF maior: ficheiros menores, menor qualidade. Mais compressão: mais CPU. Sugestão: 22 / Equilibrada.';$encodingHint.SetBounds(12,707,868,35);$encodingHint.Anchor='Top,Left,Right'
    $d.Controls.AddRange(@($videoCrf,$crfLabel,$videoPreset,$presetLabel,$encodingHint))
    $labels=@((Get-QualityText 'Local audio device' 'Dispositivo de áudio local'),(Get-UiText 'Spectrogram channel'),(Get-QualityText 'Spectrum gain (1 to 20x)' 'Ganho do espectro (1 a 20x)'),(Get-QualityText 'Cameras: check to record; add in the empty row; Delete removes' 'Câmaras: marque para gravar; adicione na linha vazia; Delete remove'),(Get-QualityText 'Recording block duration (minutes)' 'Duração dos blocos de gravação (minutos)'))
    $positions=@(60,315,355,388,630);$fieldLabels=@()
    for($i=0;$i -lt 5;$i++){
        $l=New-Object Windows.Forms.Label;$l.Text=$labels[$i];$l.SetBounds(12,$positions[$i],220,25);$l.TextAlign='TopLeft';$d.Controls.Add($l);$fieldLabels+=$l
    }
    $sourceLabel=New-Object Windows.Forms.Label;$sourceLabel.Text=Get-QualityText 'External audio source' 'Origem do áudio externo';$sourceLabel.SetBounds(12,24,220,25)
    $ok=New-Object Windows.Forms.Button;Register-ButtonActionTooltip $ok;$ok.Text=Get-QualityText 'Save' 'Guardar';$ok.SetBounds(760,700,120,30);$ok.Anchor='Bottom,Right'
    $d.Controls.AddRange(@($source,$sourceLabel,$audio,$detect,$channel,$gain,$camera,$remove,$up,$down,$minutes,$ok))
    $d.Tag=@{LocalGain=$localGain;CameraOnly=($script:RecordingUi.Mode -and $script:RecordingUi.Mode.SelectedIndex -eq 2);Source=$source;Audio=$audio;Devices=@();Detect=$detect;Config=$config;Channel=$channel;Gain=$gain;Camera=$camera;SegmentMinutes=$minutes;FieldLabels=$fieldLabels;Fields=@($audio,$channel,$gain,$camera,$minutes);Save=$ok}
    $d.Tag.VideoCrf=$videoCrf;$d.Tag.VideoPreset=$videoPreset
    $ok.Top=750
    Initialize-RecordingAudioProfiles $d
    $source.Add_SelectedIndexChanged({Set-RecordingAudioSourceControls $this.FindForm()})
    $detect.Add_Click({Update-RecordingAudioDevices $this.FindForm()})
    Set-RecordingAudioSourceControls $d
    $d.Add_Shown({Set-RecordingSettingsTextLayout $this})
    $ok.Add_Click({
        $d=$this.FindForm()
        try {Save-RecordingSettingsDialog $d;$d.DialogResult='OK';$d.Close()}
        catch {Show-QualityError $_.Exception.Message}
    })
    return $d
}
function Show-RecordingSettings {
    $d=New-RecordingSettingsDialog
    try {[void]$d.ShowDialog($script:RecordingUi.Form)}finally{$d.Dispose()}
}
