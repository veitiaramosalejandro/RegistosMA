function Get-RecordingPlanSeconds {
    param($Plan)
    if(-not $Plan){return $null}
    $seconds=$null
    if($Plan.Seconds){$seconds=[double]$Plan.Seconds}
    elseif($Plan.Minutes){$seconds=[double]$Plan.Minutes*60}
    if($null -ne $seconds -and $seconds -gt 0 -and -not [double]::IsInfinity($seconds) -and -not [double]::IsNaN($seconds)){return $seconds}
    return $null
}
function Test-RecordingDurationReached {
    param($Clock,[double]$Seconds)
    return $Clock -and $Clock.Ready -and $Clock.MinimumOutputSeconds -ge ($Seconds-0.000001)
}
# Encoder queues may still contain packets after the UI sends q. Limit the newly
# created recording itself, staging and validating every replacement before commit.
function Complete-RecordingDurationLimit {
    param([string]$Folder,[double]$Seconds,[int]$CameraCount,[string]$FFmpeg)
    if($Seconds -le 0){return}
    $root=[IO.Path]::GetFullPath($Folder).TrimEnd('\','/')
    $stage=Join-Path $root ('.duration-'+[guid]::NewGuid().ToString('N'))
    if(-not [IO.Path]::GetFullPath($stage).StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid duration staging path.'}
    $new=Join-Path $stage 'new';$old=Join-Path $stage 'old'
    [void][IO.Directory]::CreateDirectory($new);[void][IO.Directory]::CreateDirectory($old)
    $replace=@{};$remove=@();$moved=@();$installed=@();$committed=$false
    try{
        $kinds=@();for($i=0;$i -lt $CameraCount;$i++){$kind='video';if($i -gt 0){$kind='camera_'+($i+1).ToString('00')};$kinds+=$kind};if($CameraCount -eq 0 -or @(Get-RecordingFiles $root 'audio' 'wav').Count){$kinds+='audio'}
        foreach($kind in $kinds){
            $video=$kind -ne 'audio';$extension='mp4';if(-not $video){$extension='wav'}
            $files=@(Get-RecordingFiles $root $kind $extension)
            $elapsed=0.0;$rows=@();$changed=$false
            foreach($file in $files){
                $length=Get-RecordedFileSeconds $file $video
                if($null -eq $length){throw ('Unable to read recorded media duration: '+$file.Name)}
                $remaining=$Seconds-$elapsed
                if($remaining -le 0.000001){$remove+=$file.FullName;$changed=$true;continue}
                if($length -gt $remaining+0.000001){
                    $target=Join-Path $new $file.Name
                    $duration=$remaining.ToString('0.########',[Globalization.CultureInfo]::InvariantCulture)
                    $args=@('-nostdin','-hide_banner','-loglevel','error','-y','-i',$file.FullName,'-t',$duration)
                    if($video){$args+=@('-map','0:v:0','-map','0:a:0?','-c','copy','-movflags','+faststart')}
                    else{$args+=@('-map','0:a:0','-c:a','pcm_s16le')}
                    $args+=$target
                    $process=Start-PlaybackProcess $FFmpeg $args -QualityClock
                    try{
                        $errors=$process.StandardError.ReadToEndAsync()
                        $watch=[Diagnostics.Stopwatch]::StartNew()
                        while(-not $process.WaitForExit(50)){
                            [Windows.Forms.Application]::DoEvents()
                            if($watch.Elapsed.TotalSeconds -gt 60){Stop-PlaybackProcess $process;throw 'Duration finalization timed out.'}
                        }
                        if($process.ExitCode -ne 0){throw ('Unable to finalize duration: '+$errors.GetAwaiter().GetResult())}
                    }finally{$process.Dispose()}
                    $length=Get-RecordedFileSeconds $target $video
                    if($null -eq $length -or $length -gt $remaining+0.05){throw ('Unexpected finalized duration: '+$file.Name)}
                    if($length -le 0){$remove+=$file.FullName;$changed=$true;continue}
                    $replace[$file.FullName]=$target;$changed=$true
                }
                $start=$elapsed;$elapsed+=$length
                $rows+=('"'+$file.Name+'",'+$start.ToString('0.########',[Globalization.CultureInfo]::InvariantCulture)+','+$elapsed.ToString('0.########',[Globalization.CultureInfo]::InvariantCulture))
            }
            if($changed){
                $csv=Join-Path $root ($kind+'_segments.csv');$targetCsv=Join-Path $new ($kind+'_segments.csv')
                [IO.File]::WriteAllLines($targetCsv,[string[]]$rows,(New-Object Text.UTF8Encoding($false)))
                $replace[$csv]=$targetCsv
            }
        }
        foreach($path in @($replace.Keys)+$remove){
            if([IO.File]::Exists($path)){[IO.File]::Move($path,(Join-Path $old ([IO.Path]::GetFileName($path))));$moved+=$path}
        }
        foreach($path in $replace.Keys){[IO.File]::Move($replace[$path],$path);$installed+=$path}
        $committed=$true
    }finally{
        if(-not $committed){
            foreach($path in $installed){if([IO.File]::Exists($path)){[IO.File]::Delete($path)}}
            foreach($path in $moved){[IO.File]::Move((Join-Path $old ([IO.Path]::GetFileName($path))),$path)}
        }
        if([IO.Directory]::Exists($stage)){[IO.Directory]::Delete($stage,$true)}
    }
}
