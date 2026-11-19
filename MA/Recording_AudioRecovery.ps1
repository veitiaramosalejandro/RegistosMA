# Keep the displayed player until its replacement has real source packets.
# Neither retries nor switching players restart the fixed failure deadline.
$script:audioRecovery=$null
$script:recoveryPlayer=$null
$script:recoveryGuard=$null
function Stop-RecordingRecoveryDisplay {
    if($script:recoveryPlayer){
        Stop-PlaybackProcess $script:recoveryPlayer
        $script:recoveryPlayer.Dispose();$script:recoveryPlayer=$null
    }
    if($script:recoveryGuard){$script:recoveryGuard.Dispose();$script:recoveryGuard=$null}
}
function Update-RecordingAudioRecovery {
    $u=$script:RecordingUi
    $wantAudio=$u.ShowCharts.Checked -and $u.Mode.SelectedIndex -ne 2 -and $script:activeAudioSource -and $script:activeAudioSource.Type -in @('RTSP','Local')
    $wantVideo=$u.ShowVideo.Checked -and $u.Mode.SelectedIndex -ne 1 -and @($script:activeCamera | Where-Object {$_}).Count -gt 0
    if(-not $wantAudio -and -not $wantVideo){$script:audioRecovery=$null;return $false}
    $now=[DateTime]::UtcNow
    $monitor=$script:activeAudioMonitor
    $closed=-not $script:activeRenderer -or $script:activeRenderer.HasExited -or -not $script:activePlayer -or $script:activePlayer.HasExited -or ($script:activeCopy -and $script:activeCopy.IsCompleted)
    $audioReady=-not $wantAudio -or ($monitor -and $monitor.Packets -gt 0 -and $monitor.IdleSeconds -lt 2)
    $videoReady=-not $wantVideo -or ($monitor -and $monitor.VideoPackets -gt 0 -and $monitor.MaxVideoIdleSeconds -lt 2)
    if($audioReady -and $videoReady -and -not $closed){
        if($script:recoveryPlayer){
            # Embed the replacement before releasing the displayed window.
            $child=[MachiningMonitor.QualityClock]::FindWindow($script:activePlayer.Id)
            if($child -eq [IntPtr]::Zero){return $true}
            Embed-RecordingVisualization $child
            Stop-RecordingRecoveryDisplay
        }
        $script:audioRecovery=$null;return $false
    }
    $idle=0
    if($wantAudio -and $monitor){$idle=[Math]::Max($idle,$monitor.IdleSeconds)}
    if($wantVideo -and $monitor){$idle=[Math]::Max($idle,$monitor.MaxVideoIdleSeconds)}
    if(-not $script:audioRecovery){
        if(-not $closed -and $idle -lt 2){return $false}
        $script:audioRecovery=@{Deadline=$now.AddSeconds(10-[Math]::Min(10,$idle));NextAttempt=$now}
    }
    if($now -ge $script:audioRecovery.Deadline){throw (New-RecordingViewException)}
    if($now -ge $script:audioRecovery.NextAttempt -and ($closed -or $idle -ge 3)){
        $recovery=$script:audioRecovery
        Stop-ActiveRecordingView -KeepAudioRecovery -PreserveView
        try{Start-ActiveRecordingView -Recovering:([bool]$script:recoveryPlayer)}catch{
            # Keep the displayed window and the original failure deadline.
        }finally{$script:audioRecovery=$recovery;$recovery.NextAttempt=[DateTime]::UtcNow.AddSeconds(1)}
    }
    Hide-RecordingSourceWait
    if($script:recoveryPlayer){$u.Placeholder.Visible=$false}
    return $true
}
