. (Join-Path $PSScriptRoot 'Button_Tooltips.ps1')
<#
Playback_Settings.ps1 - version 182.
Graphical playback preferences: media source, synchronization offset and chart presentation. Applying changes updates the playback state.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the current behavior.
#>
#Requires -Version 5.1
# Edit playback source, synchronization offset and graph settings in a dialog.
function Show-PlaybackSettingsDialog {
    param($State)
    if (-not $State.Clock.Ready -or $State.Seeking -or $State.Dragging -or $null -ne $State.PendingSeek) { return }
    $dialog=New-Object Windows.Forms.Form
    try {
        $dialog.Text=Get-QualityText 'Playback settings' 'Configurações de reprodução'
        $dialog.ClientSize=New-Object Drawing.Size(520,420)
        $dialog.StartPosition='CenterParent'; $dialog.FormBorderStyle='FixedDialog'
        $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false
        $s=$State.Context.PlaybackSettings
        $labels=@(
            (Get-QualityText 'Audio source' 'Tipo de áudio'),
            (Get-QualityText 'External audio offset (ms)' 'Desfasamento do áudio externo (ms)'),
            (Get-QualityText 'Spectrogram channel' 'Canal do espectrograma'),
            (Get-QualityText 'Spectrum gain (1 to 20x)' 'Ganho do espectro (1 a 20x)'),
            (Get-QualityText 'External audio gain (dB)' 'Ganho do áudio externo (dB)'),
            (Get-QualityText 'Camera audio gain (dB)' 'Ganho do áudio da câmara (dB)')
        )
        for ($i=0; $i -lt $labels.Count; $i++) {
            $label=New-Object Windows.Forms.Label; $label.Text=$labels[$i]
            $label.SetBounds(12,(16+$i*44),220,24); $dialog.Controls.Add($label)
        }
        $audio=New-Object Windows.Forms.ComboBox; $audio.DropDownStyle='DropDownList'
        $codes=@('A')
        if ($s.HasVideo) { $codes=@('C'); if ($s.HasAudio) { $codes+=@('S','T') } }
        foreach ($code in $codes) {
            $text=switch ($code) {
                'A' { Get-QualityText 'External audio' 'Áudio externo' }
                'C' { Get-QualityText 'Camera audio' 'Áudio da câmara' }
                'S' { Get-QualityText 'External audio' 'Áudio externo' }
                'T' { Get-QualityText 'Mixed audio' 'Áudio misturado' }
            }
            [void]$audio.Items.Add($text)
        }
        $audio.SelectedIndex=[Array]::IndexOf($codes,$s.Source)
        $audio.Enabled=$s.HasVideo; $audio.SetBounds(240,12,264,26); $dialog.Controls.Add($audio)
        $offset=New-Object Windows.Forms.NumericUpDown
        $offset.Minimum=-3600000; $offset.Maximum=3600000; $offset.Value=$s.OffsetMs
        $offset.Enabled=$s.HasVideo; $offset.SetBounds(240,56,264,26); $dialog.Controls.Add($offset)
        # Display descriptive channel labels while keeping persisted graph parameters as L/R codes.
        $channel=New-Object Windows.Forms.ComboBox; $channel.DropDownStyle='DropDownList'
        [void]$channel.Items.Add((Get-QualityText 'L - Ambient sound' 'L - Som ambiente'))
        [void]$channel.Items.Add((Get-QualityText 'R - Spindle vibration' 'R - Vibração no fuso'))
        $channel.SelectedIndex=0; if ($s.SpectrumChannel -eq 'R') { $channel.SelectedIndex=1 }
        $channel.Enabled=$State.Context.AdaptivePlots; $channel.SetBounds(240,100,264,26); $dialog.Controls.Add($channel)
        $gain=New-Object Windows.Forms.NumericUpDown; $gain.Minimum=1; $gain.Maximum=20; $gain.Value=$s.WaveformGain
        $gain.Enabled=$State.Context.AdaptivePlots; $gain.SetBounds(240,144,264,26); $dialog.Controls.Add($gain)
        # Audible balance only; plots retain source amplitudes for comparison.
        $cameraGain=New-Object Windows.Forms.NumericUpDown;$cameraGain.Minimum=-60;$cameraGain.Maximum=60
        $sensorGain=New-Object Windows.Forms.NumericUpDown;$sensorGain.Minimum=-60;$sensorGain.Maximum=60
        $cameraGain.Value=0;$sensorGain.Value=40
        if ($null -ne $s.MixCameraGainDb) { $cameraGain.Value=$s.MixCameraGainDb }
        if ($null -ne $s.MixSensorGainDb) { $sensorGain.Value=$s.MixSensorGainDb }
        $sensorGain.SetBounds(240,188,264,26);$cameraGain.SetBounds(240,232,264,26)
        $dialog.Controls.AddRange(@($cameraGain,$sensorGain))
        # Both controls stay editable in every mode; each gain affects only its source.
        $cameraGain.Enabled=$true;$sensorGain.Enabled=$true
        # Reserve enough height for the full audio-offset explanation in both languages.
        $note=New-Object Windows.Forms.Label; $note.SetBounds(12,272,492,100)
        $note.Text=Get-QualityText 'The offset applies only to external audio, including mixed audio. Camera audio always remains synchronized with its video and is never shifted.' 'O desfasamento aplica-se apenas ao áudio externo, incluindo no áudio misturado. O áudio da câmara mantém-se sempre sincronizado com o respetivo vídeo, sem desfasamento.'
        $dialog.Controls.Add($note)
        $apply=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $apply; $apply.Text=Get-QualityText 'Apply' 'Aplicar'
        $apply.SetBounds(300,380,96,30); $dialog.Controls.Add($apply); $dialog.AcceptButton=$apply
        $cancel=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $cancel; $cancel.Text=Get-QualityText 'Cancel' 'Cancelar'
        $cancel.SetBounds(404,380,100,30); $cancel.DialogResult='Cancel'; $dialog.Controls.Add($cancel); $dialog.CancelButton=$cancel
        $dialog.Tag=@{State=$State;Audio=$audio;Codes=$codes;Offset=$offset;Channel=$channel;Gain=$gain;CameraGain=$cameraGain;SensorGain=$sensorGain}
        $apply.Add_Click({
            param($sender,$eventArgs)
            $d=$sender.FindForm(); $data=$d.Tag; $state=$data.State; $c=$state.Context; $s=$c.PlaybackSettings
            try {
                $source=$data.Codes[$data.Audio.SelectedIndex]
                $offset=[int]$data.Offset.Value; $gain=[int]$data.Gain.Value
                $channel=@('L','R')[$data.Channel.SelectedIndex]
                $cameraGain=[int]$data.CameraGain.Value;$sensorGain=[int]$data.SensorGain.Value
                $position=Get-QualityPosition $state
                # Build and validate the complete graph before changing the active context.
                if ($c.AdaptivePlots) {
                    $parameters=@{}; foreach ($key in $c.Visualization.Keys) { $parameters[$key]=$c.Visualization[$key] }
                    $parameters.Source=$source; $parameters.OffsetMs=$offset
                    $parameters.SpectrumChannel=$channel; $parameters.WaveformGain=$gain
                    $parameters.MixCameraGainDb=$cameraGain;$parameters.MixSensorGainDb=$sensorGain
                    $parameters.CanvasWidth=$state.VideoHost.ClientSize.Width
                    $parameters.CanvasHeight=$state.VideoHost.ClientSize.Height
                    $items=@(Get-VisualizationArguments @parameters)
                } elseif ($source -eq 'A') {
                    $items=@(Get-ExternalPlaybackArguments $s.AudioList $sensorGain)
                } else {
                    $items=@(Get-PlaybackMediaArguments $source $s.VideoList $s.AudioList $offset -CameraLists $s.CameraLists -MixCameraGainDb $cameraGain -MixSensorGainDb $sensorGain)
                }
                $filtered=@(Set-VibrationArguments $items $c.Vibration)
                if ($s.HasVideo) {
                    Save-PlaybackAudioSource $s.ConfigPath $source
                    Save-PlaybackOffset $s.OffsetPath $s.ConfigPath $offset
                }
                Save-MixedAudioGains $s.OffsetPath $cameraGain $sensorGain
                if ($c.AdaptivePlots) {
                    Save-SpectrumChannel $s.ConfigPath $channel
                    Save-WaveformGain $s.ConfigPath $gain
                    $c.Visualization.Source=$source; $c.Visualization.OffsetMs=$offset
                    $c.Visualization.SpectrumChannel=$channel; $c.Visualization.WaveformGain=$gain
                    $c.Visualization.MixCameraGainDb=$cameraGain;$c.Visualization.MixSensorGainDb=$sensorGain
                }
                $c.UnfilteredItems=$items; $c.ProducerItems=$filtered; $c.SensorAvailable=$source -ne 'C'
                $s.MixCameraGainDb=$cameraGain;$s.MixSensorGainDb=$sensorGain
                $s.Source=$source; $s.OffsetMs=$offset; $s.SpectrumChannel=$channel; $s.WaveformGain=$gain
                if ($null -ne $state.Split) { $state.Split.OffsetMs=$offset }
                Request-QualitySeek $state ([Math]::Min($position,[Math]::Max(0,$state.Duration-0.101)))
                $d.DialogResult='OK'; $d.Close()
            } catch { [void][Windows.Forms.MessageBox]::Show($d,$_.Exception.Message,$d.Text) }
        })
        [void]$dialog.ShowDialog($State.VideoHost.FindForm())
    } finally { $dialog.Dispose() }
}
# Add the playback-settings action to the management window.
function Add-PlaybackSettingsControls {
    param($Panel)
    $state=$Panel.Tag
    $button=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $button
    $button.Text=Get-QualityText 'Settings' 'Configurações'
    # Follow the action row when the timeline ruler changes its vertical position.
    $button.SetBounds(($state.FilterButton.Right+4),$state.FilterButton.Top,122,30)
    $button.Tag=$state; $button.Enabled=$false
    $state.FilterButton.Parent.Controls.Add($button); $state.PlaybackSettingsButton=$button
    $button.Add_Click({ param($sender,$eventArgs) Show-PlaybackSettingsDialog $sender.Tag })
}
