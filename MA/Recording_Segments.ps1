<#
Recording_Segments.ps1 - documented version 123.
FFmpeg segmentation support and diagnostics. Video keyframes are aligned with requested block boundaries; CSV timing is checked after capture for discontinuities.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the existing behavior; executable statements are unchanged.
#>
#Requires -Version 5.1
# Verify that FFmpeg supports min_seg_duration before using protected video segmentation.
function Assert-RecordingSegmentationSupport {
    param([string]$FFmpegPath)
    $help=(& $FFmpegPath -hide_banner -h muxer=segment 2>&1 | Out-String)
    if ($help -notmatch '(?m)-min_seg_duration\s') {
        throw (Get-UiText 'A proteção de segmentação requer uma versão FFmpeg com a opção min_seg_duration. Atualize o FFmpeg antes de gravar.')
    }
}
# Force regular keyframes and a 90-percent minimum segment duration for video capture.
# Closed GOPs and forced keyframes align cuts with the requested duration. Reset timestamps
# makes each output block start locally; the CSV list retains its continuous source timing.
# InvariantCulture prevents decimal commas from producing invalid FFmpeg arguments.
function Get-RecordingVideoEncodingSettings {
    param($Config)
    $crf=18;$preset='ultrafast'
    $parsed=0
    if($Config -and [int]::TryParse([string]$Config.VideoCrf,[ref]$parsed) -and $parsed -ge 0 -and $parsed -le 51){$crf=$parsed}
    if($Config -and [string]$Config.VideoPreset -in @('ultrafast','superfast','veryfast','faster','fast','medium')){$preset=[string]$Config.VideoPreset}
    return [pscustomobject]@{Crf=$crf;Preset=$preset}
}
function Get-RecordingVideoSegmentArguments {
    param([ValidateRange(0.000001,86400)][double]$Seconds,[string]$VideoListPath,[string]$VideoPath,[string]$AudioGain='1')
    $culture=[Globalization.CultureInfo]::InvariantCulture
    $duration=$Seconds.ToString('0.########',$culture)
    $minimum=($Seconds*0.9).ToString('0.########',$culture)
    $encodingConfig=$null
    if($script:UiConfigPath -and (Test-Path -LiteralPath $script:UiConfigPath)){$encodingConfig=Read-RecordingConfig $script:UiConfigPath}
    $encoding=Get-RecordingVideoEncodingSettings $encodingConfig
    return @('-map','0:v:0','-map','0:a:0',
        '-c:v','libx264','-preset',$encoding.Preset,'-crf',([string]$encoding.Crf),'-pix_fmt','yuv420p',
        '-flags','+cgop','-sc_threshold','0','-force_key_frames',("expr:gte(t,n_forced*$duration)"),
        '-fps_mode','passthrough','-c:a','aac','-b:a','64k','-filter:a',("volume=$AudioGain"),
        '-f','segment','-reference_stream','v:0','-segment_time',$duration,
        '-min_seg_duration',$minimum,'-segment_time_delta','0.05','-reset_timestamps','1',
        '-segment_list_type','csv','-segment_list',$VideoListPath,$VideoPath)
}
# Inspect segment lists for gaps, long blocks or count differences and write a diagnostic JSON report.
function Write-RecordingSegmentDiagnostic {
    param([string]$Folder,[double]$Seconds,[bool]$WithVideo,[switch]$CameraOnly)
    $issues=@()
    $counts=@{}
    foreach ($kind in @('audio','video')) {
        if($kind -eq 'audio' -and $CameraOnly){continue}
        if ($kind -eq 'video' -and -not $WithVideo) { continue }
        $extension='wav'; if ($kind -eq 'video') { $extension='mp4' }
        $files=@(Get-ChildItem -LiteralPath $Folder -Filter ($kind+'_*.'+$extension) -File)
        $counts[$kind]=$files.Count
        if ($files.Count -eq 0) { $issues+=("No $kind segments were recorded.") }
        $list=Join-Path $Folder ($kind+'_segments.csv')
        if (-not (Test-Path -LiteralPath $list)) { $issues+=("Missing $kind segment list."); continue }
        $previousEnd=$null
        foreach ($row in @(Get-Content -LiteralPath $list -Encoding UTF8 | ConvertFrom-Csv -Header File,Start,End)) {
            $start=0.0; $end=0.0
            $style=[Globalization.NumberStyles]::Float; $culture=[Globalization.CultureInfo]::InvariantCulture
            if (-not [double]::TryParse($row.Start,$style,$culture,[ref]$start) -or -not [double]::TryParse($row.End,$style,$culture,[ref]$end)) { $issues+=("Invalid $kind timing entry."); continue }
            if ($null -ne $previousEnd -and [Math]::Abs($start-$previousEnd) -gt 1) { $issues+=("Discontinuous $kind timeline before "+$row.File+"; source timestamp jump or missing media.") }
            $previousEnd=$end
            if ($end-$start -gt $Seconds*1.5+1) { $issues+=("Long $kind segment: "+$row.File+"; possible missing keyframes/source timestamp jump.") }
        }
    }
    if ($WithVideo -and -not $CameraOnly -and [Math]::Abs($counts.audio-$counts.video) -gt 1) { $issues+='Audio/video segment counts differ by more than one; inspect ffmpeg.log and the segment lists.' }
    $report=[pscustomobject]@{ScriptVersion=52;SegmentSeconds=$Seconds;Counts=$counts;Issues=@($issues);Note='Different counts alone do not prove file corruption. Timestamp gaps and source interruptions cannot be recovered by segmenting.'}
    [IO.File]::WriteAllText((Join-Path $Folder 'segment_diagnostics.json'),($report | ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
    if ($issues.Count) { Write-Warning ('Foram detetadas anomalias na segmentação. Consulte '+(Join-Path $Folder 'segment_diagnostics.json')) }
}
