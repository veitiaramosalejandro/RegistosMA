# Listening owns only its playback process; capture and visualisation never depend on it.
function Stop-RecordingAudioListening {
 $u=$script:RecordingUi
 if($u.ListenProcess){Stop-PlaybackProcess $u.ListenProcess;$u.ListenProcess.Dispose();$u.ListenProcess=$null}
 $u.ListenKey=$null
}
function Update-RecordingAudioListening {
 $u=$script:RecordingUi
 if(-not $u -or $u.Form.IsDisposed){return}
 $c=Read-RecordingConfig $script:UiConfigPath
 $enabled=(Get-RecordingAudioSourceType $c) -eq 'RTSP' -and $u.Mode.SelectedIndex -ne 2
 $u.ListenAudio.Enabled=$enabled
 if(-not $enabled -or -not $u.ListenAudio.Checked){Stop-RecordingAudioListening;return}
 try{
   $source=Get-RecordingRtspSource $c
   $gain=Get-RecordingAudioGainText $c
   $delay=Get-RecordingAudioDelayFilter
   $key=$source.InputName+'|'+$gain+$delay
   if($u.ListenProcess -and ($u.ListenKey -cne $key -or $u.ListenProcess.HasExited)){Stop-RecordingAudioListening}
   if(-not $u.ListenProcess -and [DateTime]::UtcNow -ge $u.ListenRetry){
     $u.ListenRetry=[DateTime]::UtcNow.AddSeconds(3)
     $u.ListenProcess=Start-PlaybackProcess (Find-PlaybackExecutable 'ffplay.exe') @('-hide_banner','-loglevel','quiet','-nodisp','-autoexit','-vn','-fflags','nobuffer','-analyzeduration','1','-probesize','32768','-fpsprobesize','0','-af',('volume='+$gain+$delay),'-rtsp_transport','tcp','-timeout','10000000','-i',$source.InputName)
     $u.ListenKey=$key
   }
 }catch{
   Stop-RecordingAudioListening;$u.ListenAudio.Checked=$false
   Show-QualityError (Get-QualityText 'Unable to listen to RTSP audio. Check the audio settings.' 'Não foi possível ouvir o áudio RTSP. Verifique a configuração do áudio.')
 }
}
function Initialize-RecordingAudioListening {
 param($Bar)
 $u=$script:RecordingUi
 $check=New-Object Windows.Forms.CheckBox;$check.AutoSize=$true;$check.Location=New-Object Drawing.Point(($u.ShowCharts.Right+16),5)
 $check.Text=Get-QualityText 'Listen to external audio' 'Ouvir áudio externo';$Bar.Controls.Add($check)
 $u.ListenAudio=$check;$u.ListenProcess=$null;$u.ListenKey=$null;$u.ListenRetry=[DateTime]::MinValue
 $timer=New-Object Windows.Forms.Timer;$timer.Interval=500;$timer.Add_Tick({Update-RecordingAudioListening});$u.ListenTimer=$timer
 $check.Add_CheckedChanged({Update-RecordingAudioListening})
 $timer.Start()
}
