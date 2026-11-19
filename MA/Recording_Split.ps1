. (Join-Path $PSScriptRoot 'Extraction_Preview.ps1')
. (Join-Path $PSScriptRoot 'Extraction_Replacement.ps1')
. (Join-Path $PSScriptRoot 'Tooltip_Layout.ps1')
. (Join-Path $PSScriptRoot 'Reference_Selection.ps1')
. (Join-Path $PSScriptRoot 'Button_Tooltips.ps1')
<#
Recording_Split.ps1 - version 241.
Extraction planning and export. Validate time intervals, edit per-part context, encode selected media ranges and rebase event annotations into each exported recording.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the current behavior.
#>
#Requires -Version 5.1
# Importing this module has no side effects. All times use the playback timeline.
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Portable_Paths.ps1')
. (Join-Path $PSScriptRoot 'Recording_Contexts.ps1')
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Recordings_Location.ps1')
# Resolve the preferred destination folder for extracted recording parts.
. (Join-Path $PSScriptRoot 'Deletion_Authorization.ps1')
function Get-SplitExportDirectory {
    $configPath=Join-Path $PSScriptRoot 'config.json'
    $value='..\Amostras PMM'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $config=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace([string]$config.RecordingsPath)) { $value=[string]$config.RecordingsPath }
        if (-not [string]::IsNullOrWhiteSpace([string]$config.ExtractedRecordingsPath)) { $value=[string]$config.ExtractedRecordingsPath }
    }
    return Resolve-MonitorPath $value
}
# Deep-copy split context data so edits do not affect the original recording objects.
function Copy-SplitObject { param($Value) return ($Value | ConvertTo-Json -Depth 40 | ConvertFrom-Json) }
# Write extraction metadata as UTF-8 JSON.
function Write-SplitJson {
    param($Path,$Value)
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temp,($Value | ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))
        # PowerShell 5.1 binds a null Replace backup path as an empty string.
        # Keep the previous JSON before overwriting; Copy also supports locations
        # whose filesystem/permissions do not support File.Replace.
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Copy($Path,$Path+'.bak',$true)
            [IO.File]::Copy($temp,$Path,$true)
        } else { [IO.File]::Move($temp,$Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
# Create editable extraction context from the source recording metadata.
function New-SplitContext {
    param($Metadata)
    if ($null -ne $Metadata.Context) { return Copy-SplitObject $Metadata.Context }
    return [pscustomobject]@{Machine='';Operator='';Work='';Part='';PartMaterial='';Operation='';Strategy='';
        Tool=[pscustomobject]@{Tool='';Type='';Material='';HeightMm=$null;DiameterMm=$null;CornerRadiusMm=$null;Flutes=$null;RemainingUsePercent=$null;UsageTimeAtProgramStartMinutes=$null};
        Parameters=[pscustomobject]@{StkXY=$null;StkZ=$null;IncXY=$null;IncZ=$null;SpindleSpeed=[pscustomobject]@{ProgrammedRpm=$null;AdjustmentPercent=100;AdjustedRpm=$null};
        FeedRate=[pscustomobject]@{ProgrammedMmPerMin=$null;AdjustmentPercent=100;AdjustedMmPerMin=$null}};Notes=''}
}
# Validate an extraction interval against the source recording duration.
function Test-SplitPart {
    param($Part,[double]$Duration)
    if ([string]::IsNullOrWhiteSpace($Part.Name) -or $Part.Name -match '[<>:"/\\|?*\x00-\x1f]' -or
        $Part.Name -match '[. ]$' -or $Part.Name -in @('.','..') -or $Part.Name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw 'Nome de gravação inválido.' }
    $a=[double]$Part.Start; $b=[double]$Part.End
    if ([double]::IsNaN($a) -or [double]::IsInfinity($a) -or [double]::IsNaN($b) -or [double]::IsInfinity($b) -or $a -lt 0 -or $b -le $a -or $b -gt $Duration) { throw 'O intervalo deve ter início < fim e estar dentro da gravação.' }
}
# Update extraction progress from encoded seconds and completion state.
function Format-SplitExportTime {
    param([double]$Seconds,[switch]$Estimated)
    $whole=[long][Math]::Ceiling([Math]::Max(0,$Seconds))
    if($Estimated -and $Seconds -gt 300){return ('{0}h {1}m' -f [long][Math]::Floor($whole/3600.0),[long][Math]::Floor(($whole%3600)/60.0))}
    if($whole -lt 60){return ($whole.ToString([Globalization.CultureInfo]::InvariantCulture)+' s')}
    return ('{0:00}:{1:00}:{2:00}' -f [long][Math]::Floor($whole/3600.0),[long][Math]::Floor(($whole%3600)/60.0),($whole%60))
}
function Get-SplitExportRemainingSeconds {
    param([double]$Elapsed,[double]$Completed,[double]$Total)
    if($Elapsed -lt 0.25 -or $Completed -le 0 -or $Total -le 0){return $null}
    return [Math]::Max(0,($Elapsed*([Math]::Max(0,$Total-$Completed))/$Completed))
}
function Update-SplitExportTimes {
    param($Progress)
    $c=$Progress.Tag
    if(-not $c.ExtractionClock -or -not $c.ElapsedLabel){return}
    $elapsed=$c.ExtractionClock.Elapsed.TotalSeconds
    $c.ElapsedLabel.Text=(Get-QualityText 'Elapsed time: ' 'Tempo decorrido: ')+(Format-SplitExportTime ([Math]::Floor($elapsed)))
    $value=Get-QualityText 'Calculating...' 'A calcular…'
    if($c.TimeCompleted){$value='0 s'}
    elseif($c.CancelRequested){$value=Get-QualityText 'Cancelling...' 'A cancelar…'}
    elseif($c.TotalWork -gt 0 -and $c.ProcessedWork -le 0 -and $elapsed -gt 3){$value=Get-QualityText 'Preparing extraction start...' 'A preparar o início da extração…'}
    elseif($c.TotalWork -gt 0 -and $c.ProcessedWork -ge $c.TotalWork){$value=Get-QualityText 'Finishing...' 'A finalizar…'}
    else{
        if($c.ProcessedWork -gt 0 -and $null -eq $c.EstimateBaseTime){$c.EstimateBaseTime=$elapsed;$c.EstimateBaseWork=[double]$c.ProcessedWork}
        $remaining=$null
        if($null -ne $c.EstimateBaseTime){
            $remaining=Get-SplitExportRemainingSeconds ($elapsed-$c.EstimateBaseTime) ($c.ProcessedWork-$c.EstimateBaseWork) ($c.TotalWork-$c.EstimateBaseWork)
        }
        if($null -ne $remaining){$value=Format-SplitExportTime $remaining -Estimated}
    }
    $c.RemainingLabel.Text=(Get-QualityText 'Estimated time remaining: ' 'Tempo estimado restante: ')+$value
}

function Update-SplitExportProgress {
    param($Progress,[double]$Seconds=0,[switch]$Complete)
    if($null -eq $Progress){return}
    $c=$Progress.Tag
    $fraction=0.0
    if($c.FileDuration -gt 0){$fraction=[Math]::Min(1.0,[Math]::Max(0.0,($Seconds/$c.FileDuration)))}
    $weight=1.0;if($c.CurrentWorkWeight -gt 0){$weight=[double]$c.CurrentWorkWeight}
    $work=[double]$c.CompletedWork+$fraction*$c.FileDuration*$weight
    $percent=0
    if($c.TotalWork -gt 0){$percent=[int][Math]::Floor(100*$work/$c.TotalWork)}
    $percent=[Math]::Min(99,[Math]::Max($c.Bar.Value,$percent))
    if($Complete){$percent=100}
    $c.ProcessedWork=[Math]::Max([double]$c.ProcessedWork,$work)
    if($Complete){$c.TimeCompleted=$true;if($c.ExtractionClock){$c.ExtractionClock.Stop()}}
    Update-SplitExportTimes $Progress
    $c.Bar.Value=$percent
    $c.Percent.Text=(Get-QualityText 'Overall progress: ' 'Progresso total: ')+$percent+'%'
    if($Complete){$c.FileLabel.Text=Get-QualityText 'All files extracted.' 'Todos os ficheiros extraídos.'}
    elseif($c.FileName){$c.FileLabel.Text=(Get-QualityText 'File: ' 'Ficheiro: ')+$c.FileName+' — '+[int][Math]::Floor(100*$fraction)+'%'}
    # Child controls invalidate themselves; never synchronously repaint the pressed button.
}
# Run FFmpeg for one export while reporting progress and processing UI events.
function Process-SplitExportInput {
    param($Progress)
    if($null -eq $Progress){return}
    [Windows.Forms.Application]::DoEvents()
    if($Progress.Tag.CancelRequested){throw (Get-QualityText 'Extraction cancelled. Completed recordings were kept.' 'Extração cancelada. As gravações já concluídas foram mantidas.')}
}
function Get-SplitEncoderProgressSeconds {
    param([string]$Line)
    $Line=$Line.Trim()
    # Older FFmpeg calls its microsecond counter out_time_ms, despite the name.
    if($Line -match '^out_time_(?:us|ms)=(-?\d+)$'){return [Math]::Max(0,[double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture)/1000000)}
    if($Line -match '^out_time=(\d+):([0-5]\d):([0-5]\d(?:\.\d+)?)$'){
        return ([double]$Matches[1]*3600+[double]$Matches[2]*60+[double]::Parse($Matches[3],[Globalization.CultureInfo]::InvariantCulture))
    }
    return $null
}
function Invoke-SplitEncoder {
    param($Executable,[string[]]$Arguments,$Progress=$null,[double]$DurationSeconds=0,[string]$FileName='')
    if($null -ne $Progress){
        $Progress.Tag.FileDuration=$DurationSeconds;$Progress.Tag.FileName=$FileName
        Update-SplitExportProgress $Progress
        Process-SplitExportInput $Progress
    }
    $p=Start-PlaybackProcess $Executable (@('-progress','pipe:1','-nostats')+$Arguments) -QualityClock -PipeOutput
    try{
        $read=$p.StandardError.ReadToEndAsync();$lineTask=$p.StandardOutput.ReadLineAsync()
        $lastSeconds=0.0;$paintClock=[Diagnostics.Stopwatch]::StartNew();$batchClock=[Diagnostics.Stopwatch]::StartNew()
        while($true){
            # Give Cancel priority even when the encoder continuously fills its output pipe.
            Process-SplitExportInput $Progress
            $batchClock.Restart();$lines=0
            while($null -ne $lineTask -and $lineTask.IsCompleted -and $lines -lt 32 -and $batchClock.ElapsedMilliseconds -lt 8){
                $line=$lineTask.GetAwaiter().GetResult()
                if($null -eq $line){$lineTask=$null;break}
                $reportedSeconds=Get-SplitEncoderProgressSeconds $line
                if($null -ne $reportedSeconds){$lastSeconds=[Math]::Max($lastSeconds,$reportedSeconds)}
                $lineTask=$p.StandardOutput.ReadLineAsync();$lines++
            }
            if($paintClock.ElapsedMilliseconds -ge 100){Update-SplitExportProgress $Progress $lastSeconds;$paintClock.Restart()}
            Process-SplitExportInput $Progress
            if($p.WaitForExit(15)){
                while($null -ne $lineTask){
                    Process-SplitExportInput $Progress
                    if(-not $lineTask.IsCompleted){[void]$lineTask.Wait(15);continue}
                    $line=$lineTask.GetAwaiter().GetResult()
                    if($null -eq $line){break}
                    $reportedSeconds=Get-SplitEncoderProgressSeconds $line
                if($null -ne $reportedSeconds){$lastSeconds=[Math]::Max($lastSeconds,$reportedSeconds)}
                    $lineTask=$p.StandardOutput.ReadLineAsync()
                }
                break
            }
        }
        while(-not $read.IsCompleted){Process-SplitExportInput $Progress;[void]$read.Wait(15)}
        Process-SplitExportInput $Progress
        $log=$read.GetAwaiter().GetResult()
        if($p.ExitCode -ne 0){throw ('Falha na exportação: '+$log)}
        if($null -ne $Progress){
            Update-SplitExportProgress $Progress $DurationSeconds
            $weight=1.0;if($Progress.Tag.CurrentWorkWeight -gt 0){$weight=[double]$Progress.Tag.CurrentWorkWeight};$Progress.Tag.CompletedWork+=($DurationSeconds*$weight);$Progress.Tag.FileDuration=0
        }
    }finally{if(-not $p.HasExited){Stop-PlaybackProcess $p};$p.Dispose()}
}

# Select events within an extracted interval and rebase their times and inherited parameters.
# A part starts a new timeline: subtract its source start time from exported event positions.
# Preserve the context effective at the cut so later inherited changes remain meaningful.
function Get-SplitAnnotations {
    param([object[]]$Annotations,[double]$Start,[double]$End,$DefaultParameters=$null)
    $ordered=@($Annotations | Sort-Object timestamp_seconds,created_at_utc,id)
    $previous=@($ordered | Where-Object { $_.timestamp_seconds -lt $Start })
    $result=@()
    if ($previous.Count -and -not @($ordered | Where-Object { $_.timestamp_seconds -eq $Start }).Count) {
        $initial=Copy-SplitObject $previous[-1]
        $initial.timestamp_seconds=0.0
        # A synthetic boundary carries inherited state, never a past occurrence.
        $initial | Add-Member NoteProperty occurrences @() -Force
        $result+=$initial
    }
    foreach ($item in $ordered) {
        if ($item.timestamp_seconds -ge $Start -and $item.timestamp_seconds -lt $End) {
            $copy=Copy-SplitObject $item; $copy.timestamp_seconds=[Math]::Round($item.timestamp_seconds-$Start,6); $result+=$copy
        }
    }
    foreach ($copy in $result) {
        if ($null -eq $copy.parameters) {
            $known=@($ordered | Where-Object { $_.timestamp_seconds -le ($Start+$copy.timestamp_seconds) -and $null -ne $_.parameters } | Select-PlaybackReference)
            $parameters=$DefaultParameters; if ($known.Count) { $parameters=$known[0].parameters }
            if ($null -ne $parameters) { $copy | Add-Member NoteProperty parameters (Copy-SplitObject $parameters) -Force }
        }
    }
    # Preserve the full inherited state at the new recording's time origin.
    # Later events keep their explicit changes, so inheritance still works.
    if($result.Count -and $result[0].timestamp_seconds -eq 0 -and $null -ne $result[0].parameters){
        $result[0]|Add-Member NoteProperty parameter_changes (Get-EventParameterMask $result[0].parameters $null -Pin) -Force
    }
    if($result.Count -and $result[0].timestamp_seconds -eq 0){
        $result[0]|Add-Member NoteProperty event_changes ([pscustomobject]@{quality=$true;machine_state=$true}) -Force
    }
    return $result
}
# Export selected intervals and write their media, metadata and optional event annotations.
# Parts are derived recordings: each export has its own media and metadata, while the source
# recording remains available. Validate the plan before invoking the encoder for each part.
function Get-SplitMediaSeekPlan {
    param([string]$Path,[double]$Start,[int]$OffsetMs=0)
    $plan=@{InputArguments=@('-f','concat','-safe','0','-i',$Path);OutputStart=$Start;InputStart=0.0;TemporaryPath=$null}
    # Keep enough real samples before the cut for the existing audio delay/trim.
    $skip=[Math]::Max(0.0,$Start-5.0-[Math]::Abs($OffsetMs/1000.0))
    if($skip -le 0 -or -not [IO.File]::Exists($Path)){return $plan}
    $lines=@([IO.File]::ReadAllLines($Path,[Text.Encoding]::UTF8))
    if(@($lines | Where-Object {$_ -notmatch '^(?:\s*$|ffconcat version 1\.0$|file\s|duration\s)'}).Count){return $plan}
    $files=@($lines | Where-Object {$_ -match '^file\s'})
    $durations=@($lines | Where-Object {$_ -match '^duration\s'})
    if(-not $files.Count -or $files.Count -ne $durations.Count){return $plan}
    $total=0.0
    foreach($line in $durations){
        $d=0.0
        if(-not [double]::TryParse(($line -replace '^duration\s+',''),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$d) -or [double]::IsNaN($d) -or [double]::IsInfinity($d) -or $d -le 0){return $plan}
        $total+=$d
    }
    if($skip -ge $total){return $plan}
    $local=Get-LocalSeekInput $Path $skip
    $seek=([double]$local.Seconds).ToString('0.########',[Globalization.CultureInfo]::InvariantCulture)
    $plan.InputArguments=@('-f','concat','-safe','0','-ss',$seek,'-i',$local.Path)
    $plan.OutputStart=$Start-$skip;$plan.InputStart=$skip
    if($local.Path -ne $Path){$plan.TemporaryPath=$local.Path}
    return $plan
}
function Invoke-SplitMediaEncoder {
    param([string]$Executable,[string]$Path,[double]$Start,[double]$Duration,[string[]]$OutputArguments,$Progress=$null,[string]$FileName='',[int]$OffsetMs=0)
    if($null -ne $Progress){
        $Progress.Tag.CurrentWorkWeight=1.0
        if('-c:v' -notin $OutputArguments -and $Progress.Tag.AudioWorkWeight -gt 0){$Progress.Tag.CurrentWorkWeight=[double]$Progress.Tag.AudioWorkWeight}
    }
    $plan=Get-SplitMediaSeekPlan $Path $Start $OffsetMs
    try{
        $startText=([double]$plan.OutputStart).ToString('0.########',[Globalization.CultureInfo]::InvariantCulture)
        $durationText=$Duration.ToString('0.########',[Globalization.CultureInfo]::InvariantCulture)
        $arguments=@('-nostdin','-v','error','-n')+@($plan.InputArguments)+@('-ss',$startText,'-t',$durationText)+$OutputArguments
        Invoke-SplitEncoder $Executable $arguments $Progress -DurationSeconds $Duration -FileName $FileName
    }finally{if($plan.TemporaryPath -and [IO.File]::Exists($plan.TemporaryPath)){[IO.File]::Delete($plan.TemporaryPath)}}
}

# Re-encoded video and PCM audio are not equal-cost tasks. Ignore stale camera
# metadata for audio-only recordings, and count exactly the encoders that run.
function Initialize-SplitExportWork {
    param($Progress,$Context,$Parts)
    if($null -eq $Progress){return}
    $videoCount=0
    if($Context.HasVideo){$videoCount=[Math]::Max(1,@($Context.CameraTracks | Where-Object {$null -ne $_ -and $_.List}).Count)}
    $audioWeight=1.0;if($videoCount -gt 0){$audioWeight=0.03}
    $c=$Progress.Tag;$c.AudioWorkWeight=$audioWeight;$c.CurrentWorkWeight=1.0
    $c.TotalWork=0.0;$c.CompletedWork=0.0;$c.ProcessedWork=0.0
    $c.EstimateBaseTime=$null;$c.EstimateBaseWork=0.0
    if($c.ExtractionClock){$c.ExtractionClock.Restart()}
    $weight=$videoCount;if($Context.HasAudio){$weight+=$audioWeight}
    foreach($part in $Parts){$c.TotalWork+=([double]$part.End-[double]$part.Start)*$weight}
}
function Export-SplitParts {
    param($State,$Parts,[string]$Destination,$Progress=$null,[bool]$IncludeAnnotations=$true,[string[]]$ReplaceFolders=@())
    if(-not(Test-Path -LiteralPath $Destination -PathType Container)){
        throw (Get-QualityText 'Choose an existing destination folder before extracting.' 'Escolha uma pasta de destino existente antes de extrair.')
    }
    $c=$State.Split; $names=@{}
    foreach ($part in $Parts) {
        Test-SplitPart $part $State.Duration
        $target=Get-SplitTargetPath $Destination $part.Name $c.Folder
        if($names.ContainsKey($part.Name)){throw ('Nome repetido / Duplicate name: '+$part.Name)}
        if([IO.File]::Exists($target) -or ([IO.Directory]::Exists($target) -and $target -notin $ReplaceFolders)){throw ('Pasta existente sem confirmação / Existing folder not approved: '+$part.Name)}
        $names[$part.Name]=$true
    }
    $contextEntries=@(Read-RecordingContexts $c.Folder)
    $annotations=@(); if ($IncludeAnnotations) { $annotations=@(Read-QualityAnnotations $State.Path) }
    $ffmpeg=Find-PlaybackExecutable 'ffmpeg.exe'
    Initialize-SplitExportWork $Progress $c $Parts
    $partNumber=0
    foreach ($part in $Parts) {
        $partNumber++
        if ($null -ne $Progress) {
            if ($Progress.Tag.CancelRequested) { throw 'Extração cancelada. As gravações já concluídas foram mantidas.' }
            $Progress.Tag.Label.Text=(Get-QualityText 'Recording ' 'Gravação ')+$partNumber+'/'+@($Parts).Count+': '+$part.Name
            # Child controls invalidate themselves; never synchronously repaint the pressed button.
        }
        $staging=Join-Path $Destination ('.divisao-'+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($staging)
        try {
            $start=([double]$part.Start).ToString('0.########',[Globalization.CultureInfo]::InvariantCulture)
            $length=[double]$part.End-[double]$part.Start
            $duration=$length.ToString('0.########',[Globalization.CultureInfo]::InvariantCulture)
            $video=$null; $audio=$null
            if ($c.HasVideo) {
                $video='video_000000.mp4'
                Invoke-SplitMediaEncoder $ffmpeg $c.VideoList $part.Start $length @('-map','0:v:0','-map','0:a:0?','-c:v','libx264','-preset','fast','-crf','18','-pix_fmt','yuv420p','-c:a','aac','-movflags','+faststart',(Join-Path $staging $video)) $Progress -FileName (Join-Path $part.Name $video)
            }
            $exportedCameras=@()
            if($c.HasVideo -and $c.CameraTracks.Count){
                for($cameraIndex=0;$cameraIndex -lt $c.CameraTracks.Count;$cameraIndex++){
                    $track=$c.CameraTracks[$cameraIndex]
                    $prefix='video';if($cameraIndex -gt 0){$prefix='camera_'+($cameraIndex+1).ToString('00')}
                    $cameraFile=$prefix+'_000000.mp4'
                    if($cameraIndex -gt 0){
                        Invoke-SplitMediaEncoder $ffmpeg $track.List $part.Start $length @('-vf',('tpad=stop_mode=clone:stop_duration='+$duration),'-map','0:v:0','-map','0:a:0?','-c:v','libx264','-preset','fast','-crf','18','-pix_fmt','yuv420p','-c:a','aac','-movflags','+faststart',(Join-Path $staging $cameraFile)) $Progress -FileName (Join-Path $part.Name $cameraFile)
                    }
                    $exportedCameras+=[pscustomobject]@{Name=$track.Name;VideoFile=($prefix+'_%06d.mp4');Files=@($cameraFile);SegmentList=($prefix+'_segments.csv')}
                }
            }
            if ($c.HasAudio) {
                $audio='audio_000000.wav'
                # Apply the external audio offset once, before trimming. Pad the tail
                # so video and external audio have the same exported duration.
                $filter=(Get-OffsetFilter $c.OffsetMs)+',apad'
                Invoke-SplitMediaEncoder $ffmpeg $c.AudioList $part.Start $length @('-af',$filter,'-map','0:a:0','-c:a','pcm_s16le',(Join-Path $staging $audio)) $Progress -FileName (Join-Path $part.Name $audio) -OffsetMs $c.OffsetMs
            }
            Process-SplitExportInput $Progress
            $meta=Copy-SplitObject $c.Metadata
            if ($null -eq $meta) { $meta=[pscustomobject]@{} }
            $values=@{DurationSeconds=$length;Duration=([TimeSpan]::FromSeconds($length).ToString('hh\:mm\:ss\.fff'));VideoFile=$video;AudioFile=$audio;
                VideoFiles=@();AudioFiles=@();Context=(Copy-SplitObject $part.Context);SegmentMinutes=($length/60);
                SourceRecording=[pscustomobject]@{Folder=$c.Folder;StartSeconds=[double]$part.Start;EndSeconds=[double]$part.End;AudioOffsetMs=$c.OffsetMs}}
            $values.Cameras=$exportedCameras
            if ($video) { $values.VideoFiles=@($video) }; if ($audio) { $values.AudioFiles=@($audio) }
            $values.Mode='AUDIO'; if ($video) { $values.Mode='VIDEO_AUDIO' }
            if ($c.Metadata.StartTime) {
                $origin=[DateTimeOffset]::Parse($c.Metadata.StartTime,[Globalization.CultureInfo]::InvariantCulture)
                $values.StartTime=$origin.AddSeconds($part.Start).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
                $values.EndTime=$origin.AddSeconds($part.End).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
            } else { $values.StartTime=$null; $values.EndTime=$null }
            foreach ($key in $values.Keys) { $meta | Add-Member NoteProperty $key $values[$key] -Force }
            if($null -ne $Progress){$Progress.Tag.FileLabel.Text='metadata.json'}
            Write-SplitJson (Join-Path $staging 'metadata.json') $meta
            $partContexts=@(Get-SplitRecordingContexts $contextEntries $part.Start $part.End $part.Context)
            Write-RecordingContexts $staging $partContexts $length
            if($null -ne $Progress){$Progress.Tag.FileLabel.Text='playback.json'}
            Write-SplitJson (Join-Path $staging 'playback.json') ([pscustomobject]@{AudioOffsetMs=0})
            $selected=@(); if ($IncludeAnnotations) { $selected=@(Get-SplitAnnotations $annotations $part.Start $part.End (New-SplitContext $c.Metadata).Parameters) }
            if($null -ne $Progress){$Progress.Tag.FileLabel.Text='events.json'}
            if($selected.Count -and $selected[0].timestamp_seconds -eq 0){
                # Synthetic start event carries the actual parameter state at the cut.
                $cutState=@{Path=$State.Path;Items=$annotations;ContextEntries=$contextEntries}
                $selected[0].parameters=Get-AnnotationParameters $cutState $part.Start
                $selected[0].parameter_changes=Get-EventParameterMask $selected[0].parameters $null -Pin
            }
            Save-QualityAnnotations (Join-Path $staging 'events.json') $selected
            Process-SplitExportInput $Progress
            Publish-SplitExtraction $staging $Destination $part.Name $c.Folder -ReplaceFolders $ReplaceFolders
        } finally {
            # Only remove the unique staging directory created by this export.
            if ([IO.Directory]::Exists($staging)) { [IO.Directory]::Delete($staging,$true) }
        }
    }
    Update-SplitExportProgress $Progress -Complete
}
# Create a labeled text or numeric field and register it in the extraction editor.
# Keep the existing minute-based storage while presenting a validated duration.
function Convert-ToolUsageTime {
    param([string]$Text)
    if([string]::IsNullOrWhiteSpace($Text)){return $null}
    if($Text -notmatch '^(\d{2,6}):([0-5]\d):([0-5]\d)$'){
        throw (Get-QualityText 'Enter usage time as hh:mm:ss, e.g. 02:05:30. Minutes and seconds must be between 00 and 59.' 'Introduza o tempo de uso em hh:mm:ss, por exemplo 02:05:30. Os minutos e segundos devem estar entre 00 e 59.')
    }
    return ([double]$Matches[1]*60.0+[double]$Matches[2]+[double]$Matches[3]/60.0)
}
function Format-ToolUsageTime {
    param($Minutes)
    if($null -eq $Minutes){return ''}
    $seconds=[long][Math]::Round([double]$Minutes*60,0,[MidpointRounding]::AwayFromZero)
    return ('{0:00}:{1:00}:{2:00}' -f [long][Math]::Floor($seconds/3600.0),[long][Math]::Floor(($seconds%3600)/60.0),($seconds%60))
}

. (Join-Path $PSScriptRoot 'Context_FieldTooltips.ps1')
function Add-SplitEditorField {
    param($Object,[string]$Name,[string]$Label,$Panel,$Fields,[int]$X,[int]$Y,[int]$Width=235,[switch]$Numeric)
    $caption=New-Object Windows.Forms.Label; $caption.Text=$Label; $caption.SetBounds($X,$Y,$Width,20); $Panel.Controls.Add($caption)
    $input=New-Object Windows.Forms.TextBox; $input.Text=[string]$Object.$Name; $input.SetBounds($X,($Y+20),$Width,24); $Panel.Controls.Add($input)
    if($Name -eq 'UsageTimeAtProgramStartMinutes'){
        $Numeric=$false;$input.Text=Format-ToolUsageTime $Object.$Name;$input.Width=[Math]::Min($Width,130);$input.TextAlign='Right'
    }
    if ($Numeric) { $input.Width=[Math]::Min($Width,110); $input.TextAlign='Right' }
    $Fields.Add(@{Object=$Object;Name=$Name;Input=$input;Numeric=[bool]$Numeric})
    Set-ContextFieldTooltip $input $Name
    Set-ContextFieldTooltip $caption $Name
    return $input
}
# Create a visual group for related extraction-context fields.
function New-SplitEditorSection {
    param($Panel,[string]$Title,[int]$X,[int]$Y,[int]$Width,[int]$Height)
    $group=New-Object Windows.Forms.GroupBox; $group.Text=$Title; $group.SetBounds($X,$Y,$Width,$Height); $Panel.Controls.Add($group)
    return $group
}
# Parse an extraction-editor numeric value.
function Read-SplitNumber {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $value=[double]::Parse($Text.Trim().Replace(',','.'),[Globalization.CultureInfo]::InvariantCulture)
    if ($value -lt 0 -or [double]::IsNaN($value) -or [double]::IsInfinity($value)) { throw 'Introduza um número não negativo válido.' }
    return $value
}
# Synchronize extraction interval controls when one time representation changes.
function Sync-SplitTime {
    param($Dialog,[ValidateSet('Start','End')][string]$Kind,[ValidateSet('Clock','Seconds')][string]$Source,[switch]$FromValue)
    $c=$Dialog.Tag
    if ($c.SyncingTime) { return }
    $c.SyncingTime=$true
    try {
        $pair=$c.Times[$Kind]
        $control=$pair.Clock; if ($Source -eq 'Seconds') { $control=$pair.Seconds }
        $seconds=if($FromValue){[double]$control.Value}else{Convert-AnnotationTime $control.Text $Source $c.State.Duration}
        if ($Source -eq 'Clock') {
            if($pair.Seconds -is [Windows.Forms.NumericUpDown]){$pair.Seconds.Value=[decimal]$seconds}
            else{$pair.Seconds.Text=$seconds.ToString('0.###',[Globalization.CultureInfo]::CurrentCulture)}
        }
        else { $pair.Clock.Text=Format-AnnotationTime $seconds }
        $c.TimeValid[$Kind]=$true
        $pair.Clock.BackColor=[Drawing.SystemColors]::Window; $pair.Seconds.BackColor=[Drawing.SystemColors]::Window
        Update-SplitAbsoluteTimes $Dialog
    } catch {
        $c.TimeValid[$Kind]=$false; $control.BackColor=[Drawing.Color]::MistyRose
        $c['Absolute'+$Kind].Text='Tempo inválido'
    } finally { $c.SyncingTime=$false; Update-SplitValidation $Dialog }
}
# Synchronize programmed, adjustment and adjusted machining-rate fields.
function Sync-SplitRate {
    param($Control,[switch]$Normalize)
    $g=$Control.Tag.Group
    if ($g.Updating) { return }
    if ($Normalize -and $g.LastRole -ne 'Percent') { return }
    if (-not $Normalize) { $g.LastRole=$Control.Tag.Role }
    $g.Updating=$true
    try {
        $p=Read-SplitNumber $g.Programmed.Text
        $percent=Read-SplitNumber $g.Percent.Text
        $adjusted=Read-SplitNumber $g.Adjusted.Text
        $key=$Control.Tag.Role
        if ($Normalize -and $key -eq 'Percent' -and $null -ne $percent) {
            $percent=[Math]::Round($percent,2,[MidpointRounding]::AwayFromZero)
            $g.Percent.Text=$percent.ToString('0.00',[Globalization.CultureInfo]::CurrentCulture)
        }
        if ($key -in @('Programmed','Percent')) {
            if ($null -ne $p -and $null -ne $percent) {
                $result=$p*$percent/100
                if ([double]::IsInfinity($result) -or [double]::IsNaN($result)) { throw 'O cálculo excede o intervalo permitido.' }
                $g.Adjusted.Text=$result.ToString('0.########',[Globalization.CultureInfo]::CurrentCulture)
            } elseif ($null -eq $percent) { $g.Adjusted.Text='' }
        } else {
            if ($null -ne $p -and $p -gt 0 -and $null -ne $adjusted) {
                $result=[Math]::Round($adjusted/$p*100,2,[MidpointRounding]::AwayFromZero)
                if ([double]::IsInfinity($result) -or [double]::IsNaN($result)) { throw 'O cálculo excede o intervalo permitido.' }
                $g.Percent.Text=$result.ToString('0.00',[Globalization.CultureInfo]::CurrentCulture)
            } elseif ($null -eq $adjusted -or $null -eq $p -or $p -eq 0) { $g.Percent.Text='' }
            if ($null -ne $p -and $p -eq 0 -and $null -ne $adjusted -and $adjusted -ne 0) { throw 'O valor após ajuste deve ser zero quando o programado é zero.' }
        }
        $g.Valid=$true; $g.Error=''
        foreach ($box in @($g.Programmed,$g.Percent,$g.Adjusted)) { $box.BackColor=[Drawing.SystemColors]::Window }
    } catch {
        $g.Valid=$false; $g.Error=$_.Exception.Message; $Control.BackColor=[Drawing.Color]::MistyRose
    } finally { $g.Updating=$false; Update-SplitValidation $Control.FindForm() }
}
# Attach or clear validation feedback for an extraction field.
function Set-SplitFieldWarning {
    param($Context,$Control,[string]$Text)
    if ($Context.FieldWarnings.ContainsKey($Control)) { $Context.FieldWarnings[$Control].Text=$Text;$Context.FieldWarnings[$Control].Visible=-not [string]::IsNullOrWhiteSpace($Text) }
}
# Check interval and machining fields and refresh editor validation state.
function Update-SplitValidation {
    param($Dialog)
    $c=$Dialog.Tag
    if ($c.AnnotationParameters) { Update-AnnotationParameterValidation $Dialog; return }
    if ($null -eq $c -or $null -eq $c.Warning -or $c.SyncingTime) { return }
    foreach ($rate in $c.Rates) { if ($rate.Updating) { return } }
    foreach ($label in $c.FieldWarnings.Values) { $label.Text='';$label.Visible=$false }
    $errors=New-Object 'System.Collections.Generic.List[string]'
    foreach ($kind in @('Start','End')) {
        $pair=$c.Times[$kind]
        if ($c.TimeValid[$kind]) {
            $pair.Clock.BackColor=[Drawing.SystemColors]::Window; $pair.Seconds.BackColor=[Drawing.SystemColors]::Window
        } else {
            $source=$pair.Clock; if ($pair.Seconds.BackColor -eq [Drawing.Color]::MistyRose) { $source=$pair.Seconds }
            $format='Clock'; if ($source -eq $pair.Seconds) { $format='Seconds' }
            try { $null=Convert-AnnotationTime $source.Text $format $c.State.Duration } catch {
                $message='Segundos inválidos'; if ($format -eq 'Clock') { $message='Use hh:mm:ss.fff' }
                $detail=$_.Exception.Message
                if ([string]::IsNullOrWhiteSpace($source.Text)) {
                    if ($kind -eq 'End') { $message=Get-QualityText 'Set the end' 'Defina o fim'; $detail=Get-QualityText 'The end time is not set.' 'O fim não está definido.' }
                    else { $message=Get-QualityText 'Set the start' 'Defina o início'; $detail=Get-QualityText 'The start time is not set.' 'O início não está definido.' }
                } elseif ($_.Exception.Message -match 'duration|duração') { $message=Get-QualityText 'Exceeds duration' 'Excede duração' }
                $errors.Add($detail)
                Set-SplitFieldWarning $c $source $message
            }
        }
    }
    if ($c.TimeValid.Start -and $c.TimeValid.End) {
        $start=Convert-AnnotationTime $c.Times.Start.Clock.Text 'Clock' $c.State.Duration
        $end=Convert-AnnotationTime $c.Times.End.Clock.Text 'Clock' $c.State.Duration
        if ($end -le $start) {
            $errors.Add('O fim deve ser posterior ao início.')
            foreach ($pair in $c.Times.Values) {
                $pair.Clock.BackColor=[Drawing.Color]::MistyRose; $pair.Seconds.BackColor=[Drawing.Color]::MistyRose
                Set-SplitFieldWarning $c $pair.Clock 'Ordem inválida'; Set-SplitFieldWarning $c $pair.Seconds 'Ordem inválida'
            }
        }
    }
    foreach ($field in $c.Fields) {
        if($field.Name -eq 'UsageTimeAtProgramStartMinutes'){
            try{$null=Convert-ToolUsageTime $field.Input.Text;$field.Input.BackColor=[Drawing.SystemColors]::Window}
            catch{$field.Input.BackColor=[Drawing.Color]::MistyRose;$errors.Add($_.Exception.Message);Set-SplitFieldWarning $c $field.Input 'hh:mm:ss'}
        }
        if ($field.Numeric) {
            try { $null=Read-SplitNumber $field.Input.Text; $field.Input.BackColor=[Drawing.SystemColors]::Window }
            catch { $field.Input.BackColor=[Drawing.Color]::MistyRose; $errors.Add('Introduza um número não negativo válido.'); Set-SplitFieldWarning $c $field.Input 'Número inválido' }
        }
        if ($field.Name -eq 'Name') {
            try {
                Test-SplitPart ([pscustomobject]@{Name=$field.Input.Text;Start=0;End=$c.State.Duration}) $c.State.Duration
                $field.Input.BackColor=[Drawing.SystemColors]::Window
            } catch { $field.Input.BackColor=[Drawing.Color]::MistyRose; $errors.Add($_.Exception.Message); Set-SplitFieldWarning $c $field.Input $_.Exception.Message }
        }
    }
    foreach ($rate in $c.Rates) {
        try {
            $programmed=Read-SplitNumber $rate.Programmed.Text; $adjusted=Read-SplitNumber $rate.Adjusted.Text
            if ($null -ne $programmed -and $programmed -eq 0 -and $null -ne $adjusted -and $adjusted -ne 0) {
                $errors.Add('O valor após ajuste deve ser zero quando o programado é zero.'); $rate.Adjusted.BackColor=[Drawing.Color]::MistyRose
                Set-SplitFieldWarning $c $rate.Adjusted 'Deve ser zero'
            }
        } catch { }
        if (-not $rate.Valid) {
            $errors.Add($rate.Error)
            if ($rate.LastRole) {
                $rate[$rate.LastRole].BackColor=[Drawing.Color]::MistyRose
                Set-SplitFieldWarning $c $rate[$rate.LastRole] 'Valor inválido'
            }
        }
    }
    Update-SplitEditorDuration $Dialog
    $c.Warning.Text=(@($errors | Select-Object -Unique) -join ' ')
    $c.Save.Enabled=$errors.Count -eq 0 -and $c.TimeValid.Start -and $c.TimeValid.End
}
# Create a related set of programmed and adjusted machining-rate controls.
function Add-SplitRateRow {
    param($Object,[string]$ProgrammedKey,[string]$AdjustedKey,[string]$Title,$Panel,$Fields,[int]$Y)
    $caption=New-Object Windows.Forms.Label; $caption.Text=$Title; $caption.SetBounds(12,$Y,($Panel.ClientSize.Width-24),18); $Panel.Controls.Add($caption)
    $group=@{Updating=$false;Valid=$true;Error='';Object=$Object;LastRole=$null}
    $helpName=if($ProgrammedKey -eq 'ProgrammedRpm'){'SpindleSpeed'}else{'FeedRate'}
    Set-ContextFieldTooltip $caption $helpName
    $x=12
    # Each caption must fit inside its own column. Wider captions previously
    # overlapped the next label because columns advanced only 108 pixels.
    $columnWidth=[Math]::Min(148,[int][Math]::Floor(($Panel.ClientSize.Width-48)/3.0))
    $unit='mm/min'; if ($ProgrammedKey -eq 'ProgrammedRpm') { $unit='rpm' }
    foreach ($row in @(@('Programmed',$ProgrammedKey,((Get-QualityText 'Programmed' 'Programado')+' ['+$unit+']')),@('Percent','AdjustmentPercent',(Get-QualityText 'Adjustment [%]' 'Ajuste [%]')),@('Adjusted',$AdjustedKey,((Get-QualityText 'Adjusted' 'Após ajuste')+' ['+$unit+']')))) {
        $label=New-Object Windows.Forms.Label; $label.Text=$row[2]; $label.SetBounds($x,($Y+18),$columnWidth,18); $Panel.Controls.Add($label)
        $box=New-Object Windows.Forms.TextBox; $box.SetBounds($x,($Y+36),96,24); $box.TextAlign='Right'; $box.Text=[string]$Object.($row[1])
        if ($row[0] -eq 'Percent' -and $null -ne $Object.($row[1])) { $box.Text=([Math]::Round([double]$Object.($row[1]),2,[MidpointRounding]::AwayFromZero)).ToString('0.00',[Globalization.CultureInfo]::CurrentCulture) }
        $Panel.Controls.Add($box); $group[$row[0]]=$box; $box.Tag=@{Group=$group;Role=$row[0]}
        Set-ContextFieldTooltip $box $row[1]
        Set-ContextFieldTooltip $label $row[1]
        $Fields.Add(@{Object=$Object;Name=$row[1];Input=$box;Numeric=$true}); $x+=$columnWidth+12
    }
    foreach ($box in @($group.Programmed,$group.Percent,$group.Adjusted)) { $box.Add_TextChanged({param($sender,$eventArgs) Sync-SplitRate $sender}) }
    $group.Percent.Add_Leave({param($sender,$eventArgs) Sync-SplitRate $sender -Normalize})
    return $group
}
# Edit an extraction interval, its name and machining context.
function New-ContextEditorTimeStrip {
    param($Panel,[double]$Start,[double]$End,[double]$Duration,[switch]$ContextMode)
    $strip=@{Times=@{}}
    foreach($spec in @(@('AbsoluteStart','Start date/time','Data/hora Início',12,160),@('AbsoluteEnd','End date/time','Data/hora Fim',180,160))){
        $label=New-Object Windows.Forms.Label;$label.Text=Get-QualityText $spec[1] $spec[2];$label.SetBounds($spec[3],64,$spec[4],20);$Panel.Controls.Add($label)
        $box=New-Object Windows.Forms.TextBox;$box.ReadOnly=$true;$box.SetBounds($spec[3],84,$spec[4],24);$Panel.Controls.Add($box);$strip[$spec[0]]=$box
        Set-ContextFieldTooltip $box $spec[0];Set-ContextFieldTooltip $label $spec[0]
    }
    foreach($spec in @(@('Start','Start','Início',362,472,70,$Start),@('End','End','Fim',564,674,70,$End),@('Duration','Duration','Duração',766,876,70,([Math]::Max(0,$End-$Start))))){
        $label=New-Object Windows.Forms.Label;$label.Text=Get-QualityText $spec[1] $spec[2];$label.SetBounds($spec[3],64,104,20);$Panel.Controls.Add($label)
        $clock=New-Object Windows.Forms.TextBox;$clock.Text=Format-AnnotationTime $spec[6];$clock.SetBounds($spec[3],84,104,24);$clock.ReadOnly=$spec[0] -eq 'Duration' -or ($ContextMode -and $spec[0] -eq 'End');$Panel.Controls.Add($clock)
        $labelSeconds=New-Object Windows.Forms.Label;$labelSeconds.Text=Get-QualityText 'Seconds' 'Segundos';$labelSeconds.SetBounds($spec[4],64,$spec[5],20);$Panel.Controls.Add($labelSeconds)
        if(($ContextMode -and $spec[0] -eq 'Start') -or (-not $ContextMode -and $spec[0] -in @('Start','End'))){
            $seconds=New-Object Windows.Forms.NumericUpDown;$seconds.DecimalPlaces=3;$seconds.Increment=0.001;$seconds.Maximum=[decimal]$Duration;$seconds.Value=[decimal]$spec[6]
        }else{
            $seconds=New-Object Windows.Forms.TextBox;$seconds.Text=([double]$spec[6]).ToString('0.###',[Globalization.CultureInfo]::CurrentCulture);$seconds.TextAlign='Right';$seconds.ReadOnly=$clock.ReadOnly
        }
        $seconds.SetBounds($spec[4],84,$spec[5],24);$Panel.Controls.Add($seconds)
        Set-ContextFieldTooltip $clock ($spec[0]+'Clock');Set-ContextFieldTooltip $label ($spec[0]+'Clock')
        Set-ContextFieldTooltip $seconds ($spec[0]+'Seconds');Set-ContextFieldTooltip $labelSeconds ($spec[0]+'Seconds')
        if($spec[0] -eq 'Duration'){$strip.DurationClock=$clock;$strip.DurationSeconds=$seconds}
        else{$strip.Times[$spec[0]]=@{Clock=$clock;Seconds=$seconds};$clock.Tag=@{Kind=$spec[0];Format='Clock'};$seconds.Tag=@{Kind=$spec[0];Format='Seconds'}}
    }
    return $strip
}


function Update-SplitEditorDuration {
    param($Dialog)
    $c=$Dialog.Tag
    if(-not $c.DurationClock){return}
    try{
        if(-not $c.TimeValid.Start -or -not $c.TimeValid.End){throw 'Invalid interval'}
        $start=Convert-AnnotationTime $c.Times.Start.Clock.Text 'Clock' $c.State.Duration
        $end=Convert-AnnotationTime $c.Times.End.Clock.Text 'Clock' $c.State.Duration
        if($end -le $start){throw 'Invalid interval'}
        $c.DurationClock.Text=Format-AnnotationTime ($end-$start)
        $c.DurationSeconds.Text=($end-$start).ToString('0.###',[Globalization.CultureInfo]::CurrentCulture)
    }catch{$c.DurationClock.Text='-';$c.DurationSeconds.Text='-'}
}
function Show-SplitPartEditor {
    param($State,$Part)
    $d=New-Object Windows.Forms.Form
    try {
        $d.Text=Get-QualityText 'Recording context/program' 'Contexto/programa da gravação'; $d.ClientSize=New-Object Drawing.Size(960,720); $d.MinimumSize=New-Object Drawing.Size(976,540); $d.StartPosition='CenterParent'
        $panel=New-Object Windows.Forms.Panel; $panel.Dock='Fill'; $panel.AutoScroll=$true; $d.Controls.Add($panel)
        $bottom=New-Object Windows.Forms.Panel; $bottom.Dock='Bottom'; $bottom.Height=44; $d.Controls.Add($bottom)
        $copy=Copy-SplitObject $Part; Complete-MetadataContext $copy.Context (New-SplitContext $null); $fields=New-Object 'System.Collections.Generic.List[object]'
        $header=[pscustomobject]@{Name=$copy.Name;Start=(Format-AnnotationTime $copy.Start);End=(Format-AnnotationTime $copy.End)}
        $nameLabel=New-Object Windows.Forms.Label; $nameLabel.Text='Nome da gravação'; $nameLabel.SetBounds(12,14,130,20); $panel.Controls.Add($nameLabel)
        $name=New-Object Windows.Forms.TextBox; $name.Text=$header.Name; $name.SetBounds(148,10,800,24); $panel.Controls.Add($name); $fields.Add(@{Object=$header;Name='Name';Input=$name;Numeric=$false})
        $strip=New-ContextEditorTimeStrip $panel $copy.Start $copy.End $State.Duration
        $absoluteStart=$strip.AbsoluteStart;$absoluteEnd=$strip.AbsoluteEnd;$times=$strip.Times
        foreach($kind in @('Start','End')){$fields.Add(@{Object=$header;Name=$kind;Input=$times[$kind].Clock;Numeric=$false})}
        $general=New-SplitEditorSection $panel (Get-UiText 'General data') 12 148 936 168
        $generalRows=@(@('Machine','Machine'),@('Operator','Operator'),@('Work','Program'),@('Part','Part'),@('PartMaterial','Part material'),@('Operation','Operation'))
        for ($i=0;$i -lt $generalRows.Count;$i++) {
            $row=$generalRows[$i]; $null=Add-SplitEditorField $copy.Context $row[0] (Get-UiText $row[1]) $general $fields (12+($i%3)*312) (18+[int][Math]::Floor($i/3)*46) 288
        }
        $null=Add-SplitEditorField $copy.Context 'Strategy' (Get-UiText 'Strategy') $general $fields 12 110 912
        $tool=New-SplitEditorSection $panel (Get-UiText 'Tool') 12 324 412 258
        $toolRows=@(@('Tool','Tool',12,18,188),@('Type','Type',212,18,188),@('Material','Material',12,64,388),@('HeightMm','Length [mm]',12,110,100),@('DiameterMm','Diameter [mm]',122,110,100),@('CornerRadiusMm','RC (corner radius) [mm]',232,110,176),@('Flutes','Teeth/inserts (cutting edges)',12,156,388),@('UsageTimeAtProgramStartMinutes','Usage time at program start [hh:mm:ss]',12,202,388))
        for ($i=0;$i -lt $toolRows.Count;$i++) {
            $row=$toolRows[$i]; $null=Add-SplitEditorField $copy.Context.Tool $row[0] (Get-UiText $row[1]) $tool $fields $row[2] $row[3] $row[4] -Numeric:($i -ge 3)
        }
        $parameters=New-SplitEditorSection $panel (Get-UiText 'Machining parameters') 436 324 512 258
        $rates=@()
        $rates+=Add-SplitRateRow $copy.Context.Parameters.SpindleSpeed 'ProgrammedRpm' 'AdjustedRpm' (Get-QualityText 'Spindle speed' 'Velocidade de rotação do fuso') $parameters $fields 18
        $rates+=Add-SplitRateRow $copy.Context.Parameters.FeedRate 'ProgrammedMmPerMin' 'AdjustedMmPerMin' (Get-QualityText 'Feed rate' 'Avanço') $parameters $fields 112
        $notes=Add-SplitEditorField $copy.Context 'Notes' (Get-UiText 'Notes') $panel $fields 12 590 936
        $notes.Multiline=$true; $notes.Height=52; $notes.ScrollBars='Vertical'
        $warning=New-Object Windows.Forms.Label; $warning.Visible=$false; $bottom.Controls.Add($warning)
        $save=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $save; $save.Text='Guardar'; $save.SetBounds(12,6,90,30); $bottom.Controls.Add($save)
        $cancel=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $cancel; $cancel.Text='Cancelar'; $cancel.SetBounds(110,6,90,30); $cancel.DialogResult='Cancel'; $bottom.Controls.Add($cancel); $d.CancelButton=$cancel
        $d.Tag=@{Fields=$fields;Copy=$copy;Header=$header;State=$State;AbsoluteStart=$absoluteStart;AbsoluteEnd=$absoluteEnd;Times=$times;TimeValid=@{Start=$true;End=$true};SyncingTime=$false;Rates=$rates;Warning=$warning;Save=$save}
        $d.Tag.DurationClock=$strip.DurationClock;$d.Tag.DurationSeconds=$strip.DurationSeconds
        $d.Tag.FieldWarnings=@{}
        $warningControls=@($fields | Where-Object { $_.Numeric -or $_.Name -in @('Name','Start','End','UsageTimeAtProgramStartMinutes') } | ForEach-Object { $_.Input })+@($times.Start.Seconds,$times.End.Seconds)
        foreach ($control in $warningControls) {
            $label=New-Object Windows.Forms.Label; $label.ForeColor=[Drawing.Color]::Firebrick; $label.SetBounds($control.Left,($control.Bottom+3),$control.Width,28); $control.Parent.Controls.Add($label); $d.Tag.FieldWarnings[$control]=$label
        }
        # Bind each source explicitly, as in the annotation editor. Do not rely
        # on a control Tag or an event handler's surrounding loop variables.
        $times.Start.Clock.Add_TextChanged({param($sender,$eventArgs) Sync-SplitTime $sender.FindForm() 'Start' 'Clock'})
        $times.Start.Seconds.Add_TextChanged({param($sender,$eventArgs) Sync-SplitTime $sender.FindForm() 'Start' 'Seconds'})
        $times.End.Clock.Add_TextChanged({param($sender,$eventArgs) Sync-SplitTime $sender.FindForm() 'End' 'Clock'})
        $times.End.Seconds.Add_TextChanged({param($sender,$eventArgs) Sync-SplitTime $sender.FindForm() 'End' 'Seconds'})
        $times.Start.Seconds.Add_ValueChanged({param($sender,$eventArgs) Sync-SplitTime $sender.FindForm() 'Start' 'Seconds' -FromValue})
        $times.End.Seconds.Add_ValueChanged({param($sender,$eventArgs) Sync-SplitTime $sender.FindForm() 'End' 'Seconds' -FromValue})
        Update-SplitAbsoluteTimes $d
        foreach ($field in $fields) { $field.Input.Add_TextChanged({param($sender,$eventArgs) Update-SplitValidation $sender.FindForm()}) }
        Update-SplitValidation $d
        $save.Add_Click({
            param($sender,$eventArgs)
            $form=$sender.FindForm(); $c=$form.Tag
            try {
                Update-SplitValidation $form
                if (-not $c.Save.Enabled) { return }
                if (-not $c.TimeValid.Start -or -not $c.TimeValid.End) { throw 'Corrija os tempos de início e fim (hh:mm:ss.fff ou segundos).' }
                foreach ($rate in $c.Rates) { if ($rate.LastRole -eq 'Percent') { Sync-SplitRate $rate.Percent -Normalize } }
                foreach ($rate in $c.Rates) { if (-not $rate.Valid) { throw $rate.Error } }
                foreach ($field in $c.Fields) {
                    $value=$field.Input.Text
                    if($field.Name -eq 'UsageTimeAtProgramStartMinutes'){$value=Convert-ToolUsageTime $value}
                    elseif ($field.Numeric) {
                        if ([string]::IsNullOrWhiteSpace($value)) { $value=$null }
                        else { $value=[double]::Parse($value.Replace(',','.'),[Globalization.CultureInfo]::InvariantCulture); if ($value -lt 0 -or [double]::IsNaN($value) -or [double]::IsInfinity($value)) { throw 'Valor numérico inválido.' } }
                    }
                    Test-ToolContextValue $field.Name $value
                    $field.Object.($field.Name)=$value
                }
                $c.Copy.Name=$c.Header.Name
                $c.Copy.Start=Convert-AnnotationTime $c.Header.Start 'Clock' $c.State.Duration
                $c.Copy.End=Convert-AnnotationTime $c.Header.End 'Clock' $c.State.Duration
                Test-SplitPart $c.Copy $c.State.Duration
                # Keep the adjusted value entered by the user: deriving it again
                # from a percentage rounded to two decimals would change it.
                foreach ($rate in @($c.Copy.Context.Parameters.SpindleSpeed,$c.Copy.Context.Parameters.FeedRate)) {
                    if ($null -ne $rate.AdjustmentPercent) { $rate.AdjustmentPercent=[Math]::Round($rate.AdjustmentPercent,2,[MidpointRounding]::AwayFromZero) }
                }
                $form.DialogResult='OK'; $form.Close()
            } catch { [void][Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'Dados inválidos') }
        })
        if ($d.ShowDialog($State.VideoHost.FindForm()) -eq 'OK') {
            # A changed cut start follows the source context unless context fields were edited.
            if($copy.Start -ne $Part.Start -and (ConvertTo-Json -InputObject $copy.Context -Depth 40 -Compress) -ceq (ConvertTo-Json -InputObject $Part.Context -Depth 40 -Compress)){
                $copy.Context=Copy-RecordingContextValue (Get-RecordingContextAt @(Read-RecordingContexts $State.Split.Folder) $copy.Start).context
            }
            return $copy
        }
        return $null
    } finally { $d.Dispose() }
}
# Persist the current extraction plan so it can be reopened.
function Save-SplitDraft {
    param($State)
    Write-SplitJson (Join-Path $State.Split.Folder 'recording_split.json') ([pscustomobject]@{SchemaVersion=1;DurationSeconds=$State.Duration;Parts=$State.Split.Parts.ToArray()})
}
# Refresh the extraction-manager rows from the current plan.
function Update-SplitList {
    param($Dialog)
    $c=$Dialog.Tag; $c.List.Items.Clear()
    foreach ($p in $c.State.Split.Parts) {
        $item=New-Object Windows.Forms.ListViewItem($p.Name)
        foreach ($text in @((Format-AnnotationTime $p.Start),(Format-AnnotationTime $p.End),(Format-AnnotationTime ([double]$p.End-[double]$p.Start)),(([double]$p.End-[double]$p.Start).ToString('0.###',[Globalization.CultureInfo]::CurrentCulture)),(Get-SplitAbsoluteTime $c.State $p.Start),(Get-SplitAbsoluteTime $c.State $p.End))) { [void]$item.SubItems.Add($text) }
        [void]$c.List.Items.Add($item)
    }
    Update-SplitActions $Dialog
}
# Convert a source-relative extraction position to recording wall-clock time.
function Get-SplitAbsoluteTime {
    param($State,[double]$Seconds)
    if (-not $State.Split.Metadata.StartTime) { return 'Data de origem indisponível' }
    return ([DateTimeOffset]::Parse($State.Split.Metadata.StartTime,[Globalization.CultureInfo]::InvariantCulture).AddSeconds($Seconds).ToString('yyyy-MM-dd HH:mm:ss.fff'))
}
# Refresh the absolute start/end times shown in extraction controls.
function Update-SplitAbsoluteTimes {
    param($Dialog)
    $c=$Dialog.Tag
    foreach ($key in @('Start','End')) {
        $field=@($c.Fields | Where-Object { $_.Name -eq $key })[0]
        $target=$c['Absolute'+$key]
        try { $seconds=Convert-AnnotationTime $field.Input.Text 'Clock' $c.State.Duration; $target.Text=Get-SplitAbsoluteTime $c.State $seconds } catch { $target.Text='Tempo relativo inválido' }
    }
}
# Enable extraction-manager actions according to selection and validation state.
function Update-SplitActions {
    param($Dialog)
    $c=$Dialog.Tag; $count=$c.List.SelectedIndices.Count
    $c.Actions['Editar'].Enabled=$count -eq 1; $c.Actions['Remover'].Enabled=$count -gt 0
    $c.Actions['Extrair'].Enabled=$count -gt 0
    if($c.PreviewPartButton){$c.PreviewPartButton.Enabled=$count -eq 1 -and (Test-SplitExtractionReady $c.State)}
    if($c.OpenFolder){$c.OpenFolder.Enabled=[bool](Get-SplitSelectedRecordingFolder $Dialog)}
    if($c.DeleteExtractions){$c.DeleteExtractions.Enabled=@(Get-SplitExtractionDeletionTargets $Dialog).Count -gt 0}
}
# Only existing extracted folders belonging to this source can be deleted here.
function Get-SplitExtractionDeletionTargets {
    param($Dialog)
    $c=$Dialog.Tag
    foreach($index in @($c.List.SelectedIndices)){
        $part=$c.State.Split.Parts[$index]
        try {
            $destination=[IO.Path]::GetFullPath([string]$c.State.Split.ExportDirectory).TrimEnd('\','/')
            $name=[string]$part.Name
            if([string]::IsNullOrWhiteSpace($name) -or $name -in @('.','..') -or $name -match '[<>:"/\\|?*\x00-\x1f]'){continue}
            $path=[IO.Path]::GetFullPath((Join-Path $destination $name)).TrimEnd('\','/')
            if((Split-Path $path -Parent) -ne $destination -or -not(Test-Path -LiteralPath $path -PathType Container)){continue}
            $folder=Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if($folder.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
            $source=[IO.Path]::GetFullPath([string]$c.State.Split.Folder).TrimEnd('\','/')
            if($source -eq $path -or $source.StartsWith($path+'\',[StringComparison]::OrdinalIgnoreCase)){continue}
            $metadata=Get-Content -LiteralPath (Join-Path $path 'metadata.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if(-not $metadata.SourceRecording.Folder){continue}
            $origin=[IO.Path]::GetFullPath([string]$metadata.SourceRecording.Folder).TrimEnd('\','/')
            if($origin -ne $source){continue}
            [pscustomobject]@{Name=$name;Path=$path}
        }catch{}
    }
}
function Confirm-SplitExtractionDeletion {
    param($Dialog,[object[]]$Targets)
    $text=(Get-QualityText 'Permanently delete these extractions?' 'Eliminar definitivamente estas extrações?')+[Environment]::NewLine+[Environment]::NewLine
    foreach($target in $Targets){$text+=$target.Path+[Environment]::NewLine}
    $text+=[Environment]::NewLine+(Get-QualityText 'All files in these folders will be deleted, including audio, video and events. The original recording and the entries in this list will be kept.' 'Serão eliminados todos os ficheiros destas pastas, incluindo áudio, vídeo e eventos. A gravação original e as entradas nesta lista serão mantidas.')
    if(-not ([Windows.Forms.MessageBox]::Show($Dialog,$text,(Get-QualityText 'Delete extractions' 'Eliminar extrações'),'YesNo','Warning','Button2') -eq 'Yes')){return $false}
    return Confirm-DeletionAuthorization $Dialog 'Eliminar pastas extraídas'
}
function Remove-SplitExtractedFolders {
    param($Dialog)
    $targets=@(Get-SplitExtractionDeletionTargets $Dialog | Sort-Object Path -Unique)
    if(-not $targets.Count -or -not(Confirm-SplitExtractionDeletion $Dialog $targets)){return}
    # Recheck the exact absolute paths after confirmation, before any recursive deletion.
    $current=@(Get-SplitExtractionDeletionTargets $Dialog | ForEach-Object {$_.Path})
    foreach($target in $targets){
        if($target.Path -notin $current){throw (Get-QualityText 'An extraction folder changed. Select it again.' 'Uma pasta de extração foi alterada. Volte a selecioná-la.')}
        $links=@(Get-ChildItem -LiteralPath $target.Path -Recurse -Force -ErrorAction Stop | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint})
        if($links.Count){throw (Get-QualityText 'This extraction contains folder links and cannot be deleted here.' 'Esta extração contém ligações a pastas e não pode ser eliminada nesta janela.')}
    }
    try {
        foreach($target in $targets){Remove-Item -LiteralPath $target.Path -Recurse -Force -ErrorAction Stop}
    }finally{Update-SplitActions $Dialog}
}
# Resolve the selected extracted recording, checking the current destination each time.
function Get-SplitSelectedRecordingFolder {
    param($Dialog)
    $c=$Dialog.Tag
    if($c.List.SelectedIndices.Count -ne 1){return $null}
    $part=$c.State.Split.Parts[$c.List.SelectedIndices[0]]
    $destination=[string]$c.State.Split.ExportDirectory
    if([string]::IsNullOrWhiteSpace($destination) -or -not $part.Name){return $null}
    $path=Join-Path $destination $part.Name
    if(Test-Path -LiteralPath $path -PathType Container){return $path}
    return $null
}
# Return the extraction-plan entries currently selected in the list.
function Get-SelectedSplitParts {
    param($Dialog)
    $c=$Dialog.Tag
    return @($c.List.SelectedIndices | Sort-Object | ForEach-Object { $c.State.Split.Parts[$_] })
}
# Set the start or end marker from a playback position.
function Set-SplitMarker {
    param($State,[ValidateSet('Start','End')]$Kind,[double]$Seconds)
    if ($Seconds -lt 0 -or $Seconds -gt $State.Duration -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) { throw 'Tempo fora da gravação.' }
    if ($Kind -eq 'Start') {
        if ($null -ne $State.Split.MarkEnd -and $Seconds -ge $State.Split.MarkEnd) { throw 'O início deve ser anterior ao fim marcado.' }
        $State.Split.MarkStart=$Seconds
    } else {
        if ($null -ne $State.Split.MarkStart -and $Seconds -le $State.Split.MarkStart) { throw 'O fim deve ser posterior ao início marcado.' }
        $State.Split.MarkEnd=$Seconds
    }
    Update-SplitMarkerButtons $State
}
# Size the clear action from its localized text/font and move the following action to avoid overlap.
# Keep a generous minimum so normal Windows button padding does not clip the Portuguese label.
function Set-SplitClearButtonLayout {
    param($State)
    if(-not $State.Split.MarkerButtons){return}
    $clear=$State.Split.MarkerButtons.Clear;$manage=$State.Split.MarkerButtons.Manage
    if(-not $clear -or -not $manage){return}
    if($State.Split.DurationLabel){
        $label=$State.Split.DurationLabel
        $sample=(Get-QualityText 'Extraction duration: ' 'Duração da extração: ')+'00:00:00.000'
        $label.SetBounds(($State.Split.MarkerButtons.End.Right+8),22,([Windows.Forms.TextRenderer]::MeasureText($sample,$label.Font).Width+20),30)
        $next=$label.Right+8
        foreach($button in @($State.Split.PreviewButton,$State.Split.PreviewRestartButton)){
            if($button){$button.SetBounds($next,22,$State.Buttons[0].Width,$State.Buttons[0].Height);$next=$button.Right+8}
        }
        $clear.Left=$next
    }
    $width=[Math]::Max(240,([Windows.Forms.TextRenderer]::MeasureText($clear.Text,$clear.Font)).Width+24)
    $clear.Width=$width;$manage.Left=$clear.Right+8
    $form=$clear.FindForm()
    if($form -and $form.WindowState -eq 'Normal'){
        $required=$manage.Right+12+($form.Width-$form.ClientSize.Width)
        if($form.MinimumSize.Width -lt $required){$form.MinimumSize=New-Object Drawing.Size($required,$form.MinimumSize.Height)}
    }
}
# Refresh marker button labels and availability.
function Update-SplitMarkerButtons {
    param($State)
    if (-not $State.Split.MarkerButtons) { return }
    foreach ($kind in @('Start','End')) {
        $text=Get-UiText 'Mark start for extraction'; if ($kind -eq 'End') { $text=Get-UiText 'Mark end for extraction' }
        $value=$State.Split['Mark'+$kind]
        if ($null -ne $value) { $text+=' - '+(Format-AnnotationTime $value) }
        $State.Split.MarkerButtons[$kind].Text=$text
        if ($State.Tooltip) { $State.Tooltip.SetToolTip($State.Split.MarkerButtons[$kind],$text) }
    }
    Update-SplitExtractionAvailability $State
    Set-SplitClearButtonLayout $State
}
# Check whether the current marker pair defines an exportable interval.
function Test-SplitExtractionReady {
    param($State)
    return ($State.Clock.Ready -and -not $State.Seeking -and $null -eq $State.PendingSeek -and -not $State.Dragging)
}
# Enable or disable extraction actions from the current marker state.
function Update-SplitExtractionAvailability {
    param($State)
    if (-not $State.Split.MarkerButtons) { return }
    Update-SplitReservedDuration $State
    Update-SplitPreview $State
    $ready=Test-SplitExtractionReady $State
    $hasMarkers=$null -ne $State.Split.MarkStart -or $null -ne $State.Split.MarkEnd
    $hasRange=$null -ne $State.Split.MarkStart -and $null -ne $State.Split.MarkEnd -and $State.Split.MarkEnd -gt $State.Split.MarkStart
    $previewAllowed=$ready -and ($State.Paused -or $null -ne $State.Split.Preview)
    if($State.Split.PreviewButton){
        $playing=$State.Split.Preview -and -not $State.Paused
        $State.Split.PreviewButton.Text=if($playing){[string][char]0x23F8}else{[string][char]0x25B6}
        $State.Split.PreviewButton.AccessibleName=if($playing){Get-QualityText 'Pause preview' 'Pausar pré-visualização'}elseif($State.Split.Preview){Get-QualityText 'Resume preview' 'Retomar pré-visualização'}else{Get-QualityText 'Preview extraction' 'Pré-visualizar extração'}
        Update-ButtonActionTooltip $State.Split.PreviewButton
        $State.Split.PreviewButton.Enabled=$previewAllowed -and ($hasRange -or $null -ne $State.Split.Preview)
        $State.Split.PreviewRestartButton.AccessibleName=Get-QualityText 'Restart preview' 'Recomeçar pré-visualização'
        $State.Split.PreviewRestartButton.Enabled=$previewAllowed -and $hasRange
        Update-ButtonActionTooltip $State.Split.PreviewRestartButton
    }
    $key='{0}/{1}' -f $ready,$hasMarkers
    if ($State.Split.AvailabilityKey -eq $key) { return }
    $State.Split.AvailabilityKey=$key
    foreach ($name in $State.Split.MarkerButtons.Keys) {
        $enabled=$ready; if ($name -eq 'Clear') { $enabled=$ready -and $hasMarkers }
        $button=$State.Split.MarkerButtons[$name]
        if ($button.Enabled -ne $enabled) { $button.Enabled=$enabled }
    }
}
function Update-SplitReservedDuration {
    param($State)
    $label=$State.Split.DurationLabel;if(-not $label){return}
    $duration='--:--:--.---'
    if($null -ne $State.Split.MarkStart){
        $position=[Math]::Min([double]$State.Duration,[Math]::Max(0.0,(Get-QualityPosition $State)))
        $duration=Format-AnnotationTime ([Math]::Max(0.0,$position-[double]$State.Split.MarkStart))
    }
    $text=(Get-QualityText 'Extraction duration: ' 'Duração da extração: ')+$duration
    if($label.Text -ne $text){$label.Text=$text}
}
# Clear the pending extraction start and end markers.
function Clear-SplitMarkers {
    param($State)
    if($State.Split.Preview){Stop-SplitPreview $State}
    $State.Split.MarkStart=$null; $State.Split.MarkEnd=$null
    Update-SplitMarkerButtons $State
}
# Build the localized confirmation message for removing extraction-plan entries.
function Get-SplitRemovalMessage {
    param([string]$Name,[int]$Count=1)
    if ($Count -eq 1) {
        return (Get-QualityText 'Remove the recording "' 'Remover a gravação "')+$Name+'"?'
    }
    return (Get-QualityText 'Remove these recordings?' 'Remover estas gravações?')+[Environment]::NewLine+[Environment]::NewLine+$Name
}
# Ask before removing entries from the extraction plan.
function Confirm-SplitRemoval {
    param($Dialog,[string]$Name,[int]$Count=1)
    $title=Get-QualityText 'Remove recording to extract' 'Remover gravação a extrair'
    if ($Count -gt 1) { $title=Get-QualityText 'Remove recordings to extract' 'Remover gravações a extrair' }
    if(-not (([Windows.Forms.MessageBox]::Show($Dialog,(Get-SplitRemovalMessage $Name $Count),$title,'YesNo','Question','Button2') -eq 'Yes'))){return $false}
    return Confirm-DeletionAuthorization $Dialog 'Remover entradas da lista de extrações'
}
# Fit the extraction recording-name column to the available list width.
function Fit-SplitRecordingColumn {
    param($List)
    if ($List.Columns.Count -ne 7) { return }
    if($List.Tag -and $List.Tag.ManualColumns){return}
    $fixedWidth=0
    for ($i=1;$i -lt 7;$i++) { $fixedWidth+=$List.Columns[$i].Width }
    $width=[Math]::Max(160,($List.ClientSize.Width-$fixedWidth-[Windows.Forms.SystemInformation]::VerticalScrollBarWidth))
    if($List.Tag){$List.Tag.FittingColumns=$true}
    try{if ($List.Columns[0].Width -ne $width) { $List.Columns[0].Width=$width }}finally{if($List.Tag){$List.Tag.FittingColumns=$false}}
}
function Initialize-SplitManagerColumns {
    param($List,[string]$Path)
    $List.Tag=@{ColumnLayoutPath=$Path;ManualColumns=$false;RestoringColumns=$true;FittingColumns=$false}
    try{
        if([IO.File]::Exists($Path)){
            $saved=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $widths=@($saved.widths)
            if($saved.schema_version -eq 1 -and $widths.Count -eq $List.Columns.Count){
                $valid=$true
                foreach($width in $widths){if($width -isnot [ValueType] -or $width -lt 0 -or $width -gt 10000 -or $width -ne [Math]::Truncate($width)){$valid=$false;break}}
                if($valid){
                    for($i=0;$i -lt $widths.Count;$i++){$List.Columns[$i].Width=[int]$widths[$i]}
                    $List.Tag.ManualColumns=[bool]$saved.manual
                }
            }
        }
    }catch{ }finally{$List.Tag.RestoringColumns=$false}
    $List.Add_ColumnWidthChanging({param($sender,$eventArgs)
        if(-not $sender.Tag.RestoringColumns -and -not $sender.Tag.FittingColumns){$sender.Tag.ManualColumns=$true}
    })
}
function Save-SplitManagerColumns {
    param($List)
    if(-not $List.Tag -or -not $List.Tag.ColumnLayoutPath){return}
    $widths=@($List.Columns | ForEach-Object {$_.Width})
    Write-SplitJson $List.Tag.ColumnLayoutPath ([pscustomobject]@{schema_version=1;manual=[bool]$List.Tag.ManualColumns;widths=$widths})
}
# Build the suggested name for an extracted recording at the chosen start time.
function Get-SplitRecordingName {
    param($State,[double]$StartSeconds)
    $origin=$State.RecordingStart
    if ($State.Split.Metadata.StartTime) { $origin=[DateTimeOffset]::Parse([string]$State.Split.Metadata.StartTime,[Globalization.CultureInfo]::InvariantCulture) }
    if ($null -eq $origin) { $origin=Get-AnnotationRecordingStart $State.Split.Folder }
    if ($null -eq $origin) { $origin=[DateTimeOffset]::Now }
    return $origin.AddSeconds($StartSeconds).ToString('yyyyMMdd_HHmmss',[Globalization.CultureInfo]::InvariantCulture)
}
# Confirm selected intervals and the destination before running media exports.
function Confirm-SplitExtraction {
    param($Owner,$Parts,[string]$Destination,[string[]]$ReplaceFolders=@())
    $message=Get-QualityText 'Start extraction? This may take some time, depending on the size of the extracted recordings.' 'Pretende iniciar a extração? Este processo pode demorar algum tempo, dependendo do tamanho das novas gravações extraídas.'
    $message+=[Environment]::NewLine+[Environment]::NewLine+(@($Parts).Count.ToString())+(Get-QualityText ' recording(s)' ' gravação(ões)')+[Environment]::NewLine+$Destination
    if($ReplaceFolders.Count){
        $message+=[Environment]::NewLine+[Environment]::NewLine+(Get-QualityText 'The following folders already exist. Replace them with the new extractions? Their previous contents will be deleted after each new extraction completes.' 'As seguintes pastas já existem. Pretende substituí-las pelas novas extrações? O conteúdo anterior será eliminado depois de cada nova extração ficar concluída.')
        $message+=[Environment]::NewLine+($ReplaceFolders -join [Environment]::NewLine)
    }
    if([Windows.Forms.MessageBox]::Show($Owner,$message,(Get-QualityText 'Confirm extraction' 'Confirmar extração'),'YesNo','Question','Button2') -ne 'Yes'){return $false}
    if($ReplaceFolders.Count){return (Confirm-DeletionAuthorization $Owner (Get-QualityText 'Replace existing extractions' 'Substituir extrações existentes'))}
    return $true
}
# Create the progress window used while extracted recordings are encoded.
function Confirm-SplitExtractionCancellation {
    param($Progress)
    $message=Get-QualityText "Cancel the extraction?`n`nCompleted recordings will be kept. The recording currently being extracted will not be saved." "Quer cancelar a extração?`n`nAs gravações já concluídas serão mantidas. A gravação que está a ser extraída não será guardada."
    return [Windows.Forms.MessageBox]::Show($Progress,$message,(Get-QualityText 'Cancel extraction' 'Cancelar extração'),'YesNo','Question','Button2') -eq 'Yes'
}
function Request-SplitExtractionCancellation {
    param($Progress)
    $c=$Progress.Tag
    if($c.Finished -or $c.TimeCompleted -or $c.CancelRequested -or $c.CancellationPromptOpen){return}
    $c.CancellationPromptPending=$false
    $c.CancellationPromptOpen=$true
    try{
        if(Confirm-SplitExtractionCancellation $Progress){
            if($c.ExportJob -and $c.ExportJob.Status -and $c.ExportJob.Status.Done){return}
            $c.CancelRequested=$true
            if($c.ExportJob -and $c.ExportJob.CancelFile){[IO.File]::WriteAllText($c.ExportJob.CancelFile,'cancel')}
            $c.CancelButton.Enabled=$false
            Update-SplitExportTimes $Progress
        }
    }finally{$c.CancellationPromptOpen=$false}
}
# Run extraction inside the progress dialog's OWN modal message filter.
# A modeless owned form shown inside the manager's modal loop can focus a
# button without delivering the complete native mouse-click sequence.
# The UI owns controls and confirmation; a separate runspace owns all export work.
# All media discovery, preparation and export run in a separate process.
function Start-SplitExternalJob {
    param($Progress)
    $c=$Progress.Tag;$job=$c.ExportJob
    if($c.CancellationPromptOpen){return}
    $job.StartTimer.Stop()
    try{
        if($c.CancelRequested){throw (Get-QualityText 'Extraction cancelled. Completed recordings were kept.' 'Extração cancelada. As gravações já concluídas foram mantidas.')}
        $s=$job.State;$split=$s.Split
        $tracks=@($split.CameraTracks | Where-Object {$null -ne $_} | ForEach-Object {[pscustomobject]@{Name=$_.Name;List=$_.List}})
        $parts=@($job.Parts | ForEach-Object {[pscustomobject]@{Name=$_.Name;Start=[double]$_.Start;End=[double]$_.End;Context=$_.Context}})
        $job.Directory=Join-Path ([IO.Path]::GetTempPath()) ('MA-extraction-'+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($job.Directory)
        $job.CancelFile=Join-Path $job.Directory 'cancel';$job.StatusFile=Join-Path $job.Directory 'status.json'
        $request=[pscustomobject]@{Root=$PSScriptRoot;ParentId=$PID;Language=$script:UiLanguage;Destination=$job.Destination;IncludeAnnotations=$job.IncludeAnnotations;ReplaceFolders=@($job.ReplaceFolders);
            State=[pscustomobject]@{Path=$s.Path;Duration=$s.Duration;Split=[pscustomobject]@{Folder=$split.Folder;HasVideo=$split.HasVideo;HasAudio=$split.HasAudio;VideoList=$split.VideoList;AudioList=$split.AudioList;OffsetMs=$split.OffsetMs;CameraTracks=$tracks}};Parts=$parts}
        $requestPath=Join-Path $job.Directory 'request.json'
        [IO.File]::WriteAllText($requestPath,(ConvertTo-Json -InputObject $request -Depth 40),(New-Object Text.UTF8Encoding($false)))
        $workerPath=Join-Path $PSScriptRoot 'Extraction_Worker.ps1'
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$workerPath+'" -RequestPath "'+$requestPath+'"'
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle='Hidden'
        $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        $start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false);$start.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
        $job.Process=New-Object Diagnostics.Process;$job.Process.StartInfo=$start
        if(-not $job.Process.Start()){throw 'Could not start extraction process.'}
        $job.Started=$true;$job.OutputTask=$job.Process.StandardOutput.ReadToEndAsync();$job.ErrorTask=$job.Process.StandardError.ReadToEndAsync()
    }catch{$job.ErrorText=$_.Exception.Message;$c.Finished=$true;$Progress.Close()}
}
function Update-SplitExternalJobWindow {
    param($Progress)
    $c=$Progress.Tag;$job=$c.ExportJob
    if($c.CancellationPromptOpen -or -not $job.Started){return}
    if([IO.File]::Exists($job.StatusFile)){
        try{
            $status=ConvertFrom-Json ([IO.File]::ReadAllText($job.StatusFile)) -ErrorAction Stop
            $job.Status=$status
            $c.Label.Text=$status.Label;$c.FileLabel.Text=$status.FileLabel
            $c.Bar.Value=[Math]::Max(0,[Math]::Min(100,[int]$status.Percent))
            $c.Percent.Text=(Get-QualityText 'Overall progress: ' 'Progresso total: ')+$c.Bar.Value+'%'
            $c.TotalWork=$status.TotalWork;$c.ProcessedWork=$status.ProcessedWork
        }catch{ }
    }
    if($job.Process.HasExited){
        if(-not $job.ErrorTask.IsCompleted){return}
        if($job.Status -and $job.Status.Done){
            $job.ErrorText=[string]$job.Status.ErrorText;$c.TimeCompleted=[bool]$job.Status.Success
        }elseif($c.CancelRequested){$job.ErrorText=Get-QualityText 'Extraction cancelled. Completed recordings were kept.' 'Extração cancelada. As gravações já concluídas foram mantidas.'}
        else{
            $detail=$job.ErrorTask.GetAwaiter().GetResult()
            if($detail.Length -gt 1600){$detail=$detail.Substring(0,1600)}
            $job.ErrorText=(Get-QualityText 'Unable to complete extraction. ' 'Não foi possível concluir a extração. ')+$detail
        }
        $c.ExtractionClock.Stop();Update-SplitExportTimes $Progress
        if($c.TimeCompleted){
            $c.Bar.Value=100;$c.Percent.Text=(Get-QualityText 'Overall progress: ' 'Progresso total: ')+'100%'
            $c.CancelButton.Enabled=$false
            if($null -eq $job.CompletedDisplayUntil){$job.CompletedDisplayUntil=[DateTime]::UtcNow.AddMilliseconds(400);return}
            if([DateTime]::UtcNow -lt $job.CompletedDisplayUntil){return}
        }
        $c.Finished=$true;$Progress.Close()
    }else{Update-SplitExportTimes $Progress}
}
function Show-SplitExportJob {
    param($Owner,$State,$Parts,[string]$Destination,[bool]$IncludeAnnotations=$true,[string[]]$ReplaceFolders=@())
    # Show first: no executable discovery, compilation or secondary engine startup here.
    $progress=New-SplitExportProgressForm
    $job=@{State=$State;Parts=$Parts;Destination=$Destination;IncludeAnnotations=$IncludeAnnotations;ReplaceFolders=$ReplaceFolders;Started=$false;Process=$null;Directory=$null;Status=$null;ErrorText=''}
    $progress.Tag.ExportJob=$job
    $progress.Tag.Label.Text=Get-QualityText 'Preparing extraction...' 'A preparar a extração…'
    $startTimer=New-Object Windows.Forms.Timer;$startTimer.Interval=50;$startTimer | Add-Member NoteProperty ProgressForm $progress;$job.StartTimer=$startTimer
    $startTimer.Add_Tick({param($sender,$eventArgs) Start-SplitExternalJob $sender.ProgressForm})
    $poll=New-Object Windows.Forms.Timer;$poll.Interval=100;$poll | Add-Member NoteProperty ProgressForm $progress
    $poll.Add_Tick({param($sender,$eventArgs) if(-not $sender.ProgressForm.IsDisposed){Update-SplitExternalJobWindow $sender.ProgressForm}})
    $progress.Add_Shown({param($sender,$eventArgs) $sender.Tag.ExportJob.StartTimer.Start()})
    try{$poll.Start();[void]$progress.ShowDialog($Owner)}
    finally{
        $startTimer.Stop();$poll.Stop();$startTimer.Dispose();$poll.Dispose()
        $canClean=$true
        if($job.Started){
            if(-not $job.Process.HasExited){[IO.File]::WriteAllText($job.CancelFile,'cancel');[void]$job.Process.WaitForExit(3000)}
            $canClean=$job.Process.HasExited
            $job.Process.Dispose()
        }
        $progress.Dispose()
        if($canClean -and $job.Directory){
            $full=[IO.Path]::GetFullPath($job.Directory);$prefix=[IO.Path]::Combine([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),'MA-extraction-')
            if($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($full)){try{[IO.Directory]::Delete($full,$true)}catch{ }}
        }
    }
    if($job.ErrorText){throw $job.ErrorText}
}

function New-SplitExportProgressForm {
    Add-Type -AssemblyName System.Windows.Forms
    $progress=New-Object Windows.Forms.Form
    $progress.Text=Get-QualityText 'Extracting recordings' 'A extrair gravações'
    $progress.ClientSize=New-Object Drawing.Size(560,280); $progress.StartPosition='CenterParent'; $progress.FormBorderStyle='FixedDialog'; $progress.MaximizeBox=$false; $progress.MinimizeBox=$false; $progress.AutoValidate='Disable'
    $label=New-Object Windows.Forms.Label; $label.SetBounds(12,12,536,40); $progress.Controls.Add($label)
    $file=New-Object Windows.Forms.Label; $file.SetBounds(12,56,536,42); $file.AutoEllipsis=$true; $progress.Controls.Add($file)
    $bar=New-Object Windows.Forms.ProgressBar; $bar.SetBounds(12,108,536,24); $bar.Style='Continuous'; $progress.Controls.Add($bar)
    $percent=New-Object Windows.Forms.Label; $percent.SetBounds(12,140,536,24); $progress.Controls.Add($percent)
    $cancel=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $cancel; $cancel.Text=Get-QualityText 'Cancel extraction' 'Cancelar extração'; $cancel.SetBounds(346,238,202,30); $cancel.CausesValidation=$false; $progress.Controls.Add($cancel)
    $elapsed=New-Object Windows.Forms.Label;$elapsed.SetBounds(12,168,536,24);$progress.Controls.Add($elapsed)
    $remaining=New-Object Windows.Forms.Label;$remaining.SetBounds(12,194,536,24);$progress.Controls.Add($remaining)
    $progress.Tag=@{CancelButton=$cancel;CancellationPromptOpen=$false;CancellationPromptPending=$false;ElapsedLabel=$elapsed;RemainingLabel=$remaining;ExtractionClock=[Diagnostics.Stopwatch]::StartNew();ProcessedWork=0.0;TimeCompleted=$false;Label=$label;FileLabel=$file;Bar=$bar;Percent=$percent;CancelRequested=$false;Finished=$false;TotalWork=0.0;CompletedWork=0.0;FileDuration=0.0;FileName=''}
    $cancel.Add_Click({param($sender,$eventArgs) Request-SplitExtractionCancellation $sender.FindForm()})
    $progress.Add_FormClosing({param($sender,$eventArgs)
        if(-not $sender.Tag.Finished){$eventArgs.Cancel=$true;Request-SplitExtractionCancellation $sender}
    })
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=250;$progress.Tag.TimeTimer=$timer
    $timer | Add-Member NoteProperty ProgressForm $progress
    $timer.Add_Tick({param($sender,$eventArgs) if(-not $sender.ProgressForm.IsDisposed){Update-SplitExportTimes $sender.ProgressForm}})
    $progress.Add_Disposed({param($sender,$eventArgs) $sender.Tag.TimeTimer.Stop();$sender.Tag.TimeTimer.Dispose();$sender.Tag.ExtractionClock.Stop()})
    $timer.Start()
    Update-SplitExportProgress $progress
    return $progress
}
# Update the extraction destination shown in the manager.
function Set-SplitExportDirectory {
    param($Form,[string]$Path)
    if(-not(Test-Path -LiteralPath $Path -PathType Container)){
        throw (Get-QualityText 'Choose an existing destination folder before extracting.' 'Escolha uma pasta de destino existente antes de extrair.')
    }
    $Form.Tag.State.Split.ExportDirectory=$Path
    $Form.Tag.DestinationPath.Text=$Path
    Update-SplitActions $Form
}
# Open the extraction-plan manager and wire editing, removal and export actions.
function Show-SplitManager {
    param($State)
    $d=New-Object Windows.Forms.Form
    try {
        $d.Text=Get-UiText 'Recording extraction'; $d.ClientSize=New-Object Drawing.Size((918+[Windows.Forms.SystemInformation]::VerticalScrollBarWidth),472); $d.MinimumSize=$d.Size; $d.StartPosition='CenterParent'
        if([string]::IsNullOrWhiteSpace([string]$State.Split.ExportDirectory)){$State.Split.ExportDirectory=Get-SplitExportDirectory}
        $chooseFolder=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $chooseFolder; $chooseFolder.Text=Get-QualityText 'Choose folder...' 'Escolher pasta…'; $chooseFolder.SetBounds(12,10,164,28); $d.Controls.Add($chooseFolder)
        $destinationPath=New-Object Windows.Forms.Label; $destinationPath.Text=$State.Split.ExportDirectory; $destinationPath.AutoEllipsis=$true
        $destinationPath.SetBounds(184,14,($d.ClientSize.Width-196),24); $destinationPath.Anchor='Top,Left,Right'; $d.Controls.Add($destinationPath)
        $list=New-Object Windows.Forms.ListView; Register-ListTooltipLayout $list; $list.View='Details'; $list.FullRowSelect=$true; $list.MultiSelect=$true; $list.HideSelection=$false
        foreach ($column in @(@('Extraction','Extração',160),@('Start','Início',90),@('End','Fim',90),@('Duration','Duração',100),@('Duration (s)','Duração (s)',100),@('Start date/time','Data/hora Início',175),@('End date/time','Data/hora Fim',175))) { [void]$list.Columns.Add((Get-QualityText $column[0] $column[1]),$column[2]) }
        $list.SetBounds(12,44,($d.ClientSize.Width-24),290); $list.Anchor='Top,Bottom,Left,Right'; $d.Controls.Add($list)
        Initialize-SplitManagerColumns $list (Join-Path $PSScriptRoot 'extraction_columns.json')
        $list.Add_ClientSizeChanged({param($sender,$eventArgs) Fit-SplitRecordingColumn $sender})
        Fit-SplitRecordingColumn $list
        $d.Tag=@{State=$State;List=$list;Actions=@{}}
        $d.Add_FormClosing({param($sender,$eventArgs) try{Save-SplitManagerColumns $sender.Tag.List}catch{Show-QualityError $_.Exception.Message}})
        $d.Tag.DestinationPath=$destinationPath; $d.Tag.ChooseFolder=$chooseFolder
        $chooseFolder.Add_Click({
            param($sender,$eventArgs)
            $form=$sender.FindForm()
            try {
                $path=Get-RecordingsDirectory -Graphical -Choose -Owner $form -CurrentPath $form.Tag.State.Split.ExportDirectory -ForExtraction
                if([string]::IsNullOrWhiteSpace($path)){return}
                Set-SplitExportDirectory $form $path
            } catch {[void][Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,$form.Text)}
        })
        $copyAnnotations=New-Object Windows.Forms.CheckBox; $copyAnnotations.Text=Get-QualityText 'Include events from the original recording' 'Incluir eventos da gravação original'; $copyAnnotations.SetBounds(232,395,($d.ClientSize.Width-244),26); $copyAnnotations.Anchor='Bottom,Left,Right'; $copyAnnotations.Checked=$true; $d.Controls.Add($copyAnnotations); $d.Tag.CopyAnnotations=$copyAnnotations
        $preview=New-Object Windows.Forms.Button;Register-ButtonActionTooltip $preview
        $preview.Name='PreviewPlannedExtraction';$preview.Text=Get-QualityText 'Preview' 'Pré-visualizar';$preview.ForeColor=[Drawing.Color]::Black
        # Render the symbol separately so only the icon keeps the main play size.
        $playImage=New-Object Drawing.Bitmap(24,24);$graphics=[Drawing.Graphics]::FromImage($playImage)
        try{
            $graphics.Clear([Drawing.Color]::Transparent)
            [Windows.Forms.TextRenderer]::DrawText($graphics,([string][char]0x25B6),$State.Buttons[0].Font,([Drawing.Rectangle]::new(0,0,24,24)),([Drawing.Color]::FromArgb(0,102,204)),([Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::NoPadding))
        }finally{$graphics.Dispose()}
        $preview.Image=$playImage;$preview.TextImageRelation='ImageBeforeText'
        $preview.Add_Disposed({if($this.Image){$this.Image.Dispose()}})
        $preview.SetBounds(12,389,160,34);$preview.Anchor='Bottom,Left';$preview.Enabled=$false;$d.Controls.Add($preview);$d.Tag.PreviewPartButton=$preview
        $preview.Add_Click({param($sender,$eventArgs)
            $form=$sender.FindForm();$selected=@(Get-SelectedSplitParts $form)
            if($selected.Count -ne 1 -or -not (Test-SplitExtractionReady $form.Tag.State)){return}
            $form.Tag.PreviewPart=[pscustomobject]@{Start=[double]$selected[0].Start;End=[double]$selected[0].End}
            $form.Close()
        })
        $list.Add_SelectedIndexChanged({param($sender,$eventArgs) Update-SplitActions $sender.FindForm()})
        $list.Add_DoubleClick({
            param($sender,$eventArgs)
            $c=$sender.FindForm().Tag
            if ($sender.SelectedIndices.Count -gt 0 -and $c.Actions['Editar'].Enabled) { $c.Actions['Editar'].PerformClick() }
        })
        $x=12
        foreach ($text in @('Adicionar','Editar','Remover','Extrair')) {
            $b=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $b;$b.Name=$text
            $b.Text=switch($text){'Adicionar'{Get-QualityText 'Add' 'Adicionar'}'Editar'{Get-QualityText 'Edit' 'Editar'}'Remover'{Get-QualityText 'Remove' 'Remover'}'Extrair'{Get-QualityText 'Extract' 'Extrair'}}
            $b.SetBounds($x,347,100,34); $b.Anchor='Bottom,Left'; $d.Controls.Add($b); $d.Tag.Actions[$text]=$b; $x+=108
            $b.Add_Click({
                param($sender,$eventArgs)
                $form=$sender.FindForm(); $c=$form.Tag; $s=$c.State; $index=-1; if ($c.List.SelectedIndices.Count) { $index=$c.List.SelectedIndices[0] }
                try {
                    switch ($sender.Name) {
                        'Adicionar' {
                            $a=0.0; if ($null -ne $s.Split.MarkStart) { $a=$s.Split.MarkStart }
                            $b=$s.Duration; if ($null -ne $s.Split.MarkEnd) { $b=$s.Split.MarkEnd }
                            $part=[pscustomobject]@{Name=(Get-SplitRecordingName $s $a);Start=$a;End=$b;Context=(Copy-RecordingContextValue (Get-RecordingContextAt @(Read-RecordingContexts $s.Split.Folder) $a).context)}
                            $edited=Show-SplitPartEditor $s $part
                            if ($null -ne $edited) { $s.Split.Parts.Add($edited); Save-SplitDraft $s }
                        }
                        'Editar' { if ($index -ge 0) { $edited=Show-SplitPartEditor $s $s.Split.Parts[$index]; if ($null -ne $edited) { $s.Split.Parts[$index]=$edited; Save-SplitDraft $s } } }
                        'Remover' {
                            $indices=@($c.List.SelectedIndices | Sort-Object -Descending)
                            $description=(@($indices | ForEach-Object { $s.Split.Parts[$_].Name }) -join ', ')
                            if ($indices.Count -gt 0 -and (Confirm-SplitRemoval $form $description $indices.Count)) { foreach ($i in $indices) { $s.Split.Parts.RemoveAt($i) }; Save-SplitDraft $s }
                        }
                        'Extrair' {
                            $partsToExport=@(Get-SelectedSplitParts $form)
                            if (-not $partsToExport.Count) { throw 'Selecione pelo menos uma gravação para exportar.' }
                            $destination=[string]$s.Split.ExportDirectory
                            if(-not(Test-Path -LiteralPath $destination -PathType Container)){
                                throw (Get-QualityText 'Choose an existing destination folder before extracting.' 'Escolha uma pasta de destino existente antes de extrair.')
                            }
                            $replaceFolders=@(Get-SplitExistingTargets $partsToExport $destination $s.Split.Folder)
                            if(-not(Confirm-SplitExtraction $form $partsToExport $destination -ReplaceFolders $replaceFolders)){return}
                            try {
                                    Save-SplitDraft $s
                                    Show-SplitExportJob $form $s $partsToExport $destination -IncludeAnnotations $c.CopyAnnotations.Checked -ReplaceFolders $replaceFolders
                                    $successText=if($partsToExport.Count -eq 1){Get-QualityText 'Recording extracted successfully.' 'Gravação extraída com sucesso.'}else{Get-QualityText 'Recordings extracted successfully.' 'Gravações extraídas com sucesso.'}
                                    [void][Windows.Forms.MessageBox]::Show($form,$successText,(Get-QualityText 'Recording extraction' 'Extração de gravações'))
                            } finally { $form.UseWaitCursor=$false; $form.Text=Get-UiText 'Recording extraction' }
                        }
                    }
                    Update-SplitList $form
                } catch { [void][Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'Extração de gravações') }
            })
        }
        $openFolder=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $openFolder
        $openFolder.Text=Get-QualityText 'Open extracted recording folder' 'Abrir pasta da gravação extraída'
        $openFolder.SetBounds(444,347,260,34);$openFolder.Anchor='Bottom,Left';$openFolder.Enabled=$false
        $d.Controls.Add($openFolder);$d.Tag.OpenFolder=$openFolder
        $openFolder.Add_Click({
            param($sender,$eventArgs)
            $form=$sender.FindForm();$path=Get-SplitSelectedRecordingFolder $form
            Update-SplitActions $form
            if($path){
                try {Start-Process -FilePath explorer.exe -ArgumentList ('"'+$path+'"')}
                catch {[void][Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,$form.Text)}
            }
        })
        $d.Add_Activated({param($sender,$eventArgs) Update-SplitActions $sender})
        $deleteExtractions=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $deleteExtractions
        $deleteExtractions.Text=Get-QualityText 'Delete extractions' 'Eliminar pasta(s) extraída(s)';$deleteExtractions.SetBounds(712,347,210,34);$deleteExtractions.Anchor='Bottom,Left';$deleteExtractions.Enabled=$false
        $d.Controls.Add($deleteExtractions);$d.Tag.DeleteExtractions=$deleteExtractions
        $deleteExtractions.Add_Click({param($sender,$eventArgs)
            $form=$sender.FindForm()
            try{Remove-SplitExtractedFolders $form}catch{[void][Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,$form.Text)}
        })
        $note=New-Object Windows.Forms.Label; $note.Text=Get-QualityText 'Changes are saved automatically. Use Ctrl or Shift to select multiple extractions.' 'Cada alteração é guardada automaticamente. Use Ctrl ou Shift para selecionar várias extrações.'; $note.SetBounds(12,435,($d.ClientSize.Width-24),30); $note.Anchor='Bottom,Left,Right'; $d.Controls.Add($note)
        Update-SplitList $d; [void]$d.ShowDialog($State.VideoHost.FindForm())
        if($d.Tag.PreviewPart){Start-SplitPartPreview $State $d.Tag.PreviewPart}
    } finally { $d.Dispose() }
}
# Attach extraction actions and source media information to the playback window.
function Read-CompatibleSplitDraft {
    param([string]$Path,[double]$Duration)
    $saved=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if($saved.SchemaVersion -ne 1){throw (Get-QualityText 'Unsupported saved extraction format.' 'Formato da divisão guardada não suportado.')}
    if([double]::IsNaN($Duration) -or [double]::IsInfinity($Duration) -or $Duration -lt 0){throw 'Invalid recording duration.'}
    $parts=@();$adjusted=0;$excluded=0
    foreach($original in @($saved.Parts)){
        if($null -eq $original){continue}
        # Validate the interval itself, independently of the old duration header.
        Test-SplitPart $original ([double]::MaxValue)
        $part=Copy-SplitObject $original
        if([double]$part.Start -ge $Duration){$excluded++;continue}
        if([double]$part.End -gt $Duration){$part.End=$Duration;$adjusted++}
        Test-SplitPart $part $Duration
        $parts+=$part
    }
    $message=$null;$backup=$null
    if($adjusted -or $excluded){
        # Retain the exact original draft, once per distinct content. Loading does
        # not overwrite the plan; the normal Save action persists later edits.
        $hash=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.Substring(0,12)
        $backup=Join-Path (Split-Path $Path -Parent) ('recording_split.duration_backup_'+$hash+'.json')
        if(-not [IO.File]::Exists($backup)){[IO.File]::Copy($Path,$backup,$false)}
        $message=(Get-QualityText 'The effective recording duration differs from the old saved plan. Intervals ending beyond the video were shortened; intervals entirely outside it were not loaded.' 'A duração efetiva da gravação difere da divisão antiga. Os intervalos que ultrapassavam o fim do vídeo foram encurtados; os que ficavam totalmente fora não foram carregados.')
        $message+=[Environment]::NewLine+(Get-QualityText 'Adjusted: ' 'Ajustados: ')+$adjusted+'; '+(Get-QualityText 'outside the recording: ' 'fora da gravação: ')+$excluded
        $message+=[Environment]::NewLine+(Get-QualityText 'Original plan preserved in: ' 'Divisão original preservada em: ')+$backup
    }
    return @{Parts=@($parts);Message=$message;Backup=$backup}
}
function Add-SplitControls {
    param($Panel,$Folder,$VideoList,$AudioList,[bool]$HasVideo,[bool]$HasAudio,[int]$OffsetMs)
    $s=$Panel.Tag; $metadata=$null; $path=Join-Path $Folder 'metadata.json'
    if (Test-Path -LiteralPath $path) { $metadata=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }
    $parts=New-Object 'System.Collections.Generic.List[object]'; $draft=Join-Path $Folder 'recording_split.json'
    if (Test-Path -LiteralPath $draft) {
        $loaded=Read-CompatibleSplitDraft $draft $s.Duration
        foreach ($p in $loaded.Parts) { $parts.Add($p) }
        if($loaded.Message){[void][Windows.Forms.MessageBox]::Show($Panel,$loaded.Message,(Get-QualityText 'Recording extraction' 'Extração de gravações'),'OK','Warning')}
    }
    $s.Split=@{Folder=$Folder;VideoList=$VideoList;AudioList=$AudioList;HasVideo=$HasVideo;HasAudio=$HasAudio;OffsetMs=$OffsetMs;Metadata=$metadata;Parts=$parts;MarkStart=$null;MarkEnd=$null}
    $layout=$Panel.Controls[0]; $row=$layout.RowCount; $layout.RowCount++
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,64)))
    $bar=New-Object Windows.Forms.GroupBox; $bar.Text='Extrair gravações'; $bar.Dock='Fill'; $bar.Margin=New-Object Windows.Forms.Padding(0); $layout.Controls.Add($bar,0,$row)
    $s.Split.MarkerButtons=@{}
    foreach ($spec in @(@('Start','Mark start for extraction',12,280),@('End','Mark end for extraction',300,280),@('Clear','Clear markers for extraction',588,240),@('Manage','Recording extraction',836,170))) {
        $b=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $b; $b.Name=$spec[0]; $b.Text=Get-UiText $spec[1]; $b.SetBounds($spec[2],22,$spec[3],30); $b.Tag=$s; $bar.Controls.Add($b); $s.Split.MarkerButtons[$spec[0]]=$b
        $b.Add_Click({
            param($sender,$eventArgs)
            $s=$sender.Tag
            try {
                if (-not (Test-SplitExtractionReady $s)) { return }
                if ($sender.Name -eq 'Clear') { Clear-SplitMarkers $s; return }
                if ($sender.Name -in @('Start','End')) {
                    $time=[Math]::Min($s.Duration,(Get-QualityPosition $s)); if ($s.Ended) { $time=$s.Duration }
                    Set-SplitMarker $s $sender.Name $time
                    $s.Tooltip.SetToolTip($sender,(Format-AnnotationTime $time))
                } else {
                    if (-not $s.Paused) { Switch-QualityPause $s }
                    Show-SplitManager $s
                }
            } catch { [void][Windows.Forms.MessageBox]::Show($sender.FindForm(),$_.Exception.Message,'Extração de gravações') }
        })
    }
    # Re-measure the clear label if the inherited UI font or display scaling changes.
    $durationLabel=New-Object Windows.Forms.Label;$durationLabel.TextAlign='MiddleLeft';$bar.Controls.Add($durationLabel)
    $s.Split.DurationLabel=$durationLabel
    $previewButton=New-Object Windows.Forms.Button;Register-ButtonActionTooltip $previewButton
    $previewButton.Name='PreviewExtraction';$previewButton.Font=$s.Buttons[0].Font
    $previewButton.ForeColor=[Drawing.Color]::FromArgb(0,102,204)
    $previewButton.Tag=$s;$bar.Controls.Add($previewButton);$s.Split.PreviewButton=$previewButton
    $previewButton.Add_Click({param($sender,$eventArgs) try{Start-SplitPreview $sender.Tag}catch{Show-QualityError $_.Exception.Message}})
    $restartButton=New-Object Windows.Forms.Button;Register-ButtonActionTooltip $restartButton
    $restartButton.Name='RestartExtractionPreview';$restartButton.Text=[string][char]0x21BA;$restartButton.Font=$s.Buttons[0].Font
    $restartButton.ForeColor=[Drawing.Color]::FromArgb(0,102,204)
    $restartButton.Tag=$s;$bar.Controls.Add($restartButton);$s.Split.PreviewRestartButton=$restartButton
    $restartButton.Add_Click({param($sender,$eventArgs) try{Start-SplitPreview $sender.Tag -Restart}catch{Show-QualityError $_.Exception.Message}})
    $s.Tooltip.SetToolTip($durationLabel,(Get-QualityText 'Time from the extraction start marker to the current playback position. Updates while playing or paused. Set a start marker to begin counting.' 'Tempo desde a marca de início da extração até à posição atual da reprodução. Atualiza em reprodução e em pausa. Marque o início para começar a contar.'))
    $durationLabel.Tag=$s;$durationLabel.Add_FontChanged({Set-SplitClearButtonLayout $this.Tag})
    $s.Split.MarkerButtons.Clear.Add_FontChanged({Set-SplitClearButtonLayout $this.Tag})
    Update-SplitMarkerButtons $s
}

# Optional tool fields: whole positive flute count and remaining-use percentage.
function Test-ToolContextValue {
    param([string]$Name,$Value)
    if($null -eq $Value){return}
    if($Name -eq 'UsageTimeAtProgramStartMinutes' -and ($Value -isnot [ValueType] -or [double]::IsNaN([double]$Value) -or [double]::IsInfinity([double]$Value) -or $Value -lt 0)){
        throw (Get-QualityText 'Usage time must be a non-negative number of minutes.' 'O tempo de uso deve ser um número de minutos igual ou superior a zero.')
    }
    if($Name -eq 'CornerRadiusMm' -and ($Value -isnot [ValueType] -or [double]::IsNaN([double]$Value) -or [double]::IsInfinity([double]$Value) -or $Value -lt 0)){
        throw (Get-QualityText 'RC (corner radius) must be a non-negative number in mm.' 'RC (Raio de canto) deve ser um número igual ou superior a zero, em mm.')
    }
    if($Name -eq 'Flutes' -and ($Value -lt 1 -or $Value -ne [Math]::Truncate($Value))){
        throw (Get-QualityText 'Teeth/inserts (cutting edges) must be a positive whole number.' 'Dentes/navalhas (arestas de corte) deve ser um número inteiro superior a zero.')
    }
    if($Name -eq 'RemainingUsePercent' -and ($Value -lt 0 -or $Value -gt 100)){
        throw (Get-QualityText 'Estimated remaining use must be between 0 and 100%.' 'A utilização restante estimada deve estar entre 0 e 100%.')
    }
}
