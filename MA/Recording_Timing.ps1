<#
Recording_Timing.ps1 - version 168.
Scheduling/timing behavior introduced after version 123. Shared runtime state lives in $script:RecordingUi.
Schedule status values are controller data; localization is applied when displaying them.
Comments describe the current behavior.
#>
# Parse integer seconds or hours:minutes:seconds, allowing durations beyond 24 hours. Reject zero, malformed values and values above 999:59:59.
function ConvertTo-RecordingDurationSeconds {
    param([string]$Text,[switch]$SecondsOnly)
    if($SecondsOnly){
        if($Text -notmatch '^\d{1,8}$'){throw 'Indique a duração em segundos inteiros.'}
        $value=[double]$Text
    } else {
        if($Text -notmatch '^(\d{1,3}):([0-5]\d):([0-5]\d)$'){throw 'Indique a duração no formato hh:mm:ss (ex.: 01:30:00).'}
        $value=([double]$Matches[1]*3600)+([double]$Matches[2]*60)+[double]$Matches[3]
    }
    if($value -le 0 -or $value -gt 3599999){throw 'A duração deve estar entre 1 segundo e 999:59:59.'}
    return $value
}
# Format a nonnegative whole-second duration with at least two hour digits; hours grow naturally beyond 99.
function Format-RecordingDuration {
    param([double]$Seconds)
    $whole=[long][Math]::Max(0,[Math]::Ceiling($Seconds))
    return ('{0:00}:{1:00}:{2:00}' -f [long][Math]::Floor($whole/3600),[long][Math]::Floor(($whole%3600)/60),($whole%60))
}
# Show elapsed time with milliseconds and, when configured, the absolute deadline and remaining duration. Do not expose the recording path here.
function Get-RecordingProgressText {
    param([datetime]$Start,[datetime]$Now)
    $elapsed=0.0
    if($script:captureLogMonitor -and $script:captureLogMonitor.Ready){$elapsed=$script:captureLogMonitor.DisplaySeconds}
    if($script:RecordingUi.TargetDurationSeconds){$elapsed=[Math]::Min($elapsed,$script:RecordingUi.TargetDurationSeconds)}
    $text=(Get-QualityText 'Recording time: ' 'Tempo de gravação: ')+(Format-AnnotationTime $elapsed)
    if(-not $script:captureLogMonitor -or -not $script:captureLogMonitor.Ready){$text+='  |  '+(Get-QualityText 'Waiting for recording to start...' 'A aguardar pelo início da gravação...')}
    $u=$script:RecordingUi
    if($u.ActiveEnd){
        $text+='  |  '+(Get-QualityText 'Ends ' 'Termina ')+([datetime]$u.ActiveEnd).ToString('dd/MM HH:mm:ss')
        $remaining=(([datetime]$u.ActiveEnd)-$Now).TotalSeconds
        if($u.TargetDurationSeconds){$recorded=0.0;if($script:captureLogMonitor -and $script:captureLogMonitor.Ready){$recorded=$script:captureLogMonitor.MinimumOutputSeconds};$remaining=$u.TargetDurationSeconds-$recorded}
        $text+='  |  '+(Get-QualityText 'Remaining ' 'Falta ')+(Format-RecordingDuration $remaining)
    }
    return $text
}
function Update-RecordingClockLabel {
    $ui=$script:RecordingUi
    if(-not $ui -or -not $ui.Running -or -not $ui.Status -or $ui.Status.IsDisposed){return}
    $text=Get-RecordingProgressText $script:startTime ([datetime]::Now)
    if($ui.Status.Text -cne $text){$ui.Status.Text=$text}
}
function Update-RecordingMediaClock {
    $u=$script:RecordingUi;$clock=$script:captureLogMonitor
    if(-not $u.State -or -not $clock -or -not $clock.Ready){return}
    if(-not $u.MediaStarted){
        $u.MediaStarted=$true
        $script:startTime=$clock.StartTime
        $script:metadata.StartTime=$script:startTime
        $u.State.RecordingStart=$script:startTime
        # Duration plans begin with recorded media; absolute deadlines retain their date/time.
        if($u.ActiveSchedule){$u.ActiveEnd=Get-RecordingPlanEnd $u.ActiveSchedule $script:startTime}
        elseif($u.ManualTimer){$u.ActiveEnd=Get-RecordingPlanEnd $u.ManualTimer $script:startTime}
    }
    $u.State.Clock.Ready=$true;$u.State.Clock.Seconds=$clock.Seconds
    $u.State.Duration=$clock.Seconds
    $u.Event.Enabled=-not $u.Stopping
}
# Report the final outcome once per timed/scheduled capture and retain the actual end time in the schedule history.
function Complete-RecordingPlan {
    param([bool]$Success,[datetime]$Ended,[string]$Detail)
    $u=$script:RecordingUi
    if($u.PlanResultReported){return}
    $u.PlanResultReported=$true
    $result=if($Success){Get-QualityText 'Recording completed successfully' 'Gravação terminada com sucesso'}else{Get-QualityText 'Recording failed' 'A gravação terminou com erro'}
    if($Success -and $script:metadata){
        $format='HH:mm:ss.fff'
        if($script:metadata.StartTime.Date -ne $script:metadata.EndTime.Date){$format='dd/MM/yyyy HH:mm:ss.fff'}
        $u.LastRecordingResult=$result+'  |  '+
            (Get-QualityText 'Start: ' 'Início: ')+$script:metadata.StartTime.ToString($format)+'  |  '+
            (Get-QualityText 'End: ' 'Fim: ')+$script:metadata.EndTime.ToString($format)+'  |  '+
            (Get-QualityText 'Duration: ' 'Duração: ')+(Format-AnnotationTime $script:metadata.DurationSeconds)
    }else{$u.LastRecordingResult=$result+' — '+$Ended.ToString('dd/MM/yyyy HH:mm:ss.fff')}
    if($Detail){$u.LastRecordingResult+=' — '+$Detail}
    if($u.ActiveSchedule){$u.ActiveSchedule.Status=$result+' — '+$Ended.ToString('HH:mm:ss')}
    Refresh-RecordingScheduleList
}
# Return the earliest pending entry; missed, active and completed entries are excluded from the next-recording notice.
function Get-NextRecordingSchedule {
    return $script:RecordingUi.ScheduleQueue | Where-Object {$_.Status -eq 'Pendente'} | Sort-Object Start | Select-Object -First 1
}
# Build the idle notice, giving the latest missed recording priority over the last capture result and appending the next pending start.
function Get-RecordingIdleText {
    $u=$script:RecordingUi
    $text=[string]$u.LastRecordingResult
    $missed=Get-LastMissedRecordingSchedule
    if($missed){
        $text=(Get-QualityText 'The last missed recording was scheduled for ' 'A última gravação prevista para ')+([datetime]$missed.Start).ToString('dd/MM/yyyy HH:mm:ss')+(Get-QualityText ' and was not performed.' ' não foi realizada.')
    }
    $next=Get-NextRecordingSchedule
    if($next){
        if($text){$text+=[Environment]::NewLine}
        $text+=(Get-QualityText 'Next recording: ' 'Próxima gravação: ')+([datetime]$next.Start).ToString('dd/MM/yyyy HH:mm:ss')
    }
    return $text
}
# Apply the plan context choice automatically. Mark it as managed so finalization does not reopen the interactive context editor.
function Set-RecordingPlanContext {
    param($Plan)
    $u=$script:RecordingUi
    $u.PlanContextManaged=$true
    if($Plan.UseLastContext){
        $script:CompletedRecordingContext=Copy-SplitObject (Get-LastRecordingContext -RecordingsFolder $script:recordingsPath)
    }else{$script:CompletedRecordingContext=$null}
}

# Select the most recent missed planned start, including legacy status spellings, for the warning text and red schedule button.
function Get-LastMissedRecordingSchedule {
    return $script:RecordingUi.ScheduleQueue | Where-Object {$_.Status -in @('Não realizado','Não executada','Not performed')} | Sort-Object Start -Descending | Select-Object -First 1
}
