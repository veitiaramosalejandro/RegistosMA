# Positive camera offset means its video arrives later than external audio.
function Read-RecordingSyncOffset {
    param($Value)
    if($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)){return 0}
    $n=0
    if($Value -is [bool] -or -not [int]::TryParse([string]$Value,[ref]$n) -or $n -lt -5000 -or $n -gt 5000){throw (Get-QualityText 'Camera sync offset must be an integer between -5000 and 5000 ms.' 'O desfasamento da câmara deve ser um número inteiro entre -5000 e 5000 ms.')}
    return $n
}
function Get-RecordingSyncPlan {
    param($Config,[int]$Mode=0)
    $offsets=@();$audio=0
    foreach($cam in @(Get-RecordingCameras $Config -Selected)){
        $offset=if($Mode -eq 0){Read-RecordingSyncOffset $cam.AudioSyncMs}else{0}
        $offsets+=,$offset;$audio=[Math]::Max($audio,$offset)
    }
    if($Mode -ne 0 -or -not $offsets.Count){$audio=0}
    $clock=if($Mode -eq 0 -and $offsets.Count){'ArrivalClock'}else{'Independent'}
    return [pscustomobject]@{AudioDelayMs=$audio;VideoDelayMs=@($offsets | ForEach-Object {$audio-$_});OffsetsMs=$offsets;ClockMode=$clock}
}
function Get-CurrentRecordingSyncPlan {
    if($script:captureSyncPlan){return $script:captureSyncPlan}
    $mode=0
    if($script:RecordingUi -and $script:RecordingUi.Mode){$mode=[Math]::Max(0,$script:RecordingUi.Mode.SelectedIndex)}
    return Get-RecordingSyncPlan (Read-RecordingConfig $script:configPath) $mode
}
function Get-RecordingAudioDelayFilter {
    $ms=(Get-CurrentRecordingSyncPlan).AudioDelayMs
    if($ms -gt 0){return ",adelay=${ms}:all=1"}
    return ''
}
function Get-RecordingCameraInputArguments {
    param([string]$Url,[switch]$SyncClock)
    $clock=@();if($SyncClock){$clock=@('-use_wallclock_as_timestamps','1','-isync','0')}
    return $clock+@('-fflags','nobuffer','-thread_queue_size','1024','-rtsp_transport','tcp','-timeout','10000000','-analyzeduration','500000','-probesize','1048576','-i',$Url)
}
function Get-RecordingCaptureAudioClockFilter {
    if((Get-CurrentRecordingSyncPlan).ClockMode -eq 'ArrivalClock'){
        # Anchor to the common input clock, then retain every decoded sample.
        # Packet arrival jitter must never stretch or discard sensor samples.
        return 'asetpts=N/SR/TB+STARTPTS,aresample=48000:first_pts=0'
    }
    return 'asetpts=PTS-STARTPTS'
}
function Get-RecordingCaptureVideoClockFilter {return 'setpts=PTS'}
function Set-RecordingPreviewSync {
    param([object[]]$Items,[bool]$Video)
    $result=@($Items);$idx=[Array]::IndexOf($result,'-filter_complex');$graph=[string]$result[$idx+1]
    $plan=Get-CurrentRecordingSyncPlan
    if($Video){
        $prefix=''
        for($i=0;$i -lt $plan.VideoDelayMs.Count;$i++){
            if($plan.VideoDelayMs[$i] -le 0){continue}
            $seconds=($plan.VideoDelayMs[$i]/1000.0).ToString('0.###',[Globalization.CultureInfo]::InvariantCulture)
            $label="[syncvideo$i]";$input="[${i}:v:0]"
            $graph=$graph.Replace($input,$label)
            $prefix+="${input}tpad=start_duration=${seconds}:start_mode=add:color=black${label};"
        }
        $graph=$prefix+$graph
    }elseif($plan.AudioDelayMs -gt 0){
        $graph='[0:a:0]adelay='+$plan.AudioDelayMs+':all=1[syncaudio];'+$graph.Replace('[0:a:0]','[syncaudio]')
    }
    $result[$idx+1]=$graph
    return $result
}
