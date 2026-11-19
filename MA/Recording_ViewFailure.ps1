# Diagnose the failed source before choosing the live-view notice (v282).
function Test-RecordingRtspAudio {
    param([string]$FFmpeg,[string]$Url)
    $p=New-Object Diagnostics.Process
    $started=$false
    $p.StartInfo.FileName=$FFmpeg
    $p.StartInfo.Arguments=Join-PlaybackArguments @('-nostdin','-hide_banner','-loglevel','error','-rtsp_transport','tcp','-timeout','3000000','-i',$Url,'-map','0:a:0','-frames:a','1','-f','null','-','-progress','pipe:1')
    $p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true
    $p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true
    try {
        $started=$p.Start()
        if(-not $started){return $false}
        $output=$p.StandardOutput.ReadToEndAsync();$errors=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(5000)){return $false}
        return $p.ExitCode -eq 0 -and $output.Result -match '(?m)^out_time_us=[1-9][0-9]*\s*$'
    } catch {return $false}
    finally {if($started -and -not $p.HasExited){$p.Kill();$null=$p.WaitForExit(1000)};$p.Dispose()}
}
function Get-RecordingViewIssues {
    param([switch]$Capturing,[switch]$AudioUnavailable,[switch]$VideoUnavailable)
    $u=$script:RecordingUi
    $source=$script:activeAudioSource;$cameras=@($script:activeCamera | Where-Object {$_})
    $wantAudio=$u.ShowCharts.Checked -and $u.Mode.SelectedIndex -ne 2
    $wantVideo=$u.ShowVideo.Checked -and $u.Mode.SelectedIndex -ne 1
    # Startup can fail before the renderer snapshot exists; inspect configured sources independently.
    if(-not $Capturing -and (($wantAudio -and (-not $source -or $source.Type -eq 'None')) -or ($wantVideo -and -not $cameras.Count))){
        try {
            $config=Read-RecordingConfig $script:configPath
            if($wantAudio -and (-not $source -or $source.Type -eq 'None')){$source=[pscustomobject]@{Type=(Get-RecordingAudioSourceType $config);InputName=(Get-ConfigText $config 'AudioRtspUrl')}}
            if($wantVideo -and -not $cameras.Count){$cameras=@(Get-RecordingCameraUrls $script:configPath)}
        }catch{}
    }
    if($Capturing){$source=$script:selectedDevice;$cameras=@($script:camera | Where-Object {$_});$wantAudio=$source.Type -ne 'None';$wantVideo=$cameras.Count -gt 0}
    $issues=@()
    if($wantAudio -and ($AudioUnavailable -or ($source -and $source.Type -eq 'RTSP' -and -not (Test-RecordingRtspAudio $u.FFmpeg $source.InputName)))){
        $message=if($source -and $source.Type -eq 'RTSP'){
            Get-QualityText 'External RTSP audio is unavailable. Check AudioRTSP and the network. Audio charts will be disabled; you can enable them again after restoring the audio.' 'O áudio externo RTSP está indisponível. Verifique o AudioRTSP e a rede. A visualização dos gráficos de áudio será desativada; pode voltar a ativá-la depois de restabelecer o áudio.'
        }else{Get-QualityText 'External audio is unavailable. Check the sound card. Audio charts will be disabled; you can enable them again after restoring the audio.' 'O áudio externo está indisponível. Verifique a placa de som. A visualização dos gráficos de áudio será desativada; pode voltar a ativá-la depois de restabelecer o áudio.'}
        if($Capturing){$message+=[Environment]::NewLine+(Get-QualityText 'Recorded blocks are preserved.' 'Os blocos já gravados são preservados.')}
        $issues+=[pscustomobject]@{Kind='Audio';Message=$message}
    }
    # Deliberately continue after an audio failure: both sources may be unavailable.
    if($wantVideo -and ($VideoUnavailable -or -not $cameras.Count -or -not (Test-RecordingCameraSet $u.FFmpeg $cameras))){
        $issues+=[pscustomobject]@{Kind='Camera';Message=(Get-RecordingVisualizationFailure)}
    }
    return $issues
}
function Get-RecordingViewFailure {
    param([switch]$Capturing,[switch]$AudioUnavailable,[switch]$VideoUnavailable)
    $issues=@(Get-RecordingViewIssues -Capturing:$Capturing -AudioUnavailable:$AudioUnavailable -VideoUnavailable:$VideoUnavailable)
    if($issues.Count){return $issues[0]}
    return [pscustomobject]@{Kind='Visualization';Message=(Get-QualityText 'Live view is unavailable. Check the display settings and enable it again.' 'A visualização está indisponível. Verifique as configurações de visualização e volte a ativá-la.')}
}
function New-RecordingViewException {
    param([switch]$AudioUnavailable,[switch]$VideoUnavailable)
    $issues=@(Get-RecordingViewIssues -AudioUnavailable:$AudioUnavailable -VideoUnavailable:$VideoUnavailable)
    if(-not $issues.Count){$issues=@([pscustomobject]@{Kind='Visualization';Message=(Get-QualityText 'Live view is unavailable. Check the display settings and enable it again.' 'A visualização está indisponível. Verifique as configurações de visualização e volte a ativá-la.')})}
    $exception=New-Object InvalidOperationException(($issues | ForEach-Object {$_.Message}) -join [Environment]::NewLine)
    $exception.Data['RecordingViewKind']=$issues[0].Kind
    $exception.Data['RecordingViewIssues']=$issues
    return $exception
}
function Show-RecordingViewFailure {
    param($Exception)
    $u=$script:RecordingUi
    $issues=@($Exception.Data['RecordingViewIssues'])
    if(-not $issues.Count -or $null -eq $issues[0]){$issues=@([pscustomobject]@{Kind=[string]$Exception.Data['RecordingViewKind'];Message=$Exception.Message})}
    # Set both choices before showing dialogs, so no timer can retry a failed source.
    foreach($issue in $issues){
        if($issue.Kind -eq 'Audio'){$u.ShowCharts.Checked=$false}
        elseif($issue.Kind -eq 'Camera'){$u.ShowVideo.Checked=$false}
        else{$u.ShowCharts.Checked=$false;$u.ShowVideo.Checked=$false}
    }
    Update-RecordingViewChoices
    foreach($issue in $issues){
        $title=switch($issue.Kind){
            'Audio' {Get-QualityText 'External audio unavailable' 'Áudio externo indisponível'}
            'Camera' {Get-QualityText 'Camera unavailable' 'Câmara indisponível'}
            default {Get-QualityText 'Live view unavailable' 'Visualização indisponível'}
        }
        Show-RecordingViewWarning $u.Form $issue.Message $title
    }
}
function Show-RecordingViewWarning {
    param($Owner,[string]$Message,[string]$Title)
    [void][Windows.Forms.MessageBox]::Show($Owner,$Message,$Title,'OK','Warning')
}
